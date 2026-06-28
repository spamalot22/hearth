// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:convert/convert.dart';
import 'package:core/core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    hide Message;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import 'blob_store_hive.dart';
import 'candidate_cache.dart';
import 'channel.dart';
import 'contacts.dart';
import 'content.dart';
import 'emoji_picker.dart';
import 'gif_search.dart';
import 'group_channel.dart';
import 'inference_bot.dart';
import 'key_store.dart';
import 'media_library.dart';
import 'mesh_control.dart';
import 'network_status.dart';
import 'profile.dart';
import 'screen_picker.dart';
import 'screen_share.dart';
import 'settings.dart';
import 'sound_search.dart';
import 'starter_sounds.dart';
import 'unread.dart';
import 'update_checker.dart';
import 'updater.dart';
import 'voice.dart';
import 'youtube_share.dart';

/// Relay endpoint for local dev (signalling only).
final Uri kRelayUrl = Uri.parse('https://hearth-relay.tail62d608.ts.net');

/// Held for process lifetime to enforce single-instance.
// ignore: unused_element
RandomAccessFile? _instanceLock;

/// Public source repository — shown in the drawer so users of a hosted instance
/// can find the source (AGPL-3.0).
const String kSourceUrl = 'https://github.com/spamalot22/hearth';

class _ModelInfo {
  const _ModelInfo(this.id, this.name, this.size, this.description, this.url);
  final String id;
  final String name;
  final String size;
  final String description;
  final String url;
}

const _kAvailableModels = [
  _ModelInfo(
    'tinyllama',
    'TinyLlama 1.1B',
    '~637 MB',
    'Fast, lightweight. Good for testing.',
    'https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf',
  ),
  _ModelInfo(
    'phi3',
    'Phi-3 Mini 3.8B',
    '~2.3 GB',
    'Good balance of quality and speed.',
    'https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf/resolve/main/Phi-3-mini-4k-instruct-q4.gguf',
  ),
  _ModelInfo(
    'mistral7b',
    'Mistral 7B',
    '~4.1 GB',
    'High quality. Needs 8 GB+ RAM.',
    'https://huggingface.co/TheBloke/Mistral-7B-Instruct-v0.2-GGUF/resolve/main/mistral-7b-instruct-v0.2.Q4_K_M.gguf',
  ),
];

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Single-instance guard: if another instance is running, show it and exit.
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS)) {
    final lockFile = File(
      '${(await getApplicationDocumentsDirectory()).path}/.hearth.lock',
    );
    try {
      final lock = await lockFile.open(mode: FileMode.write);
      await lock.lock(FileLock.exclusive);
      _instanceLock = lock; // held for process lifetime
    } on FileSystemException {
      // Another instance holds the lock — bring it to front via window_manager
      // (best-effort; the other instance's tray click handler is the primary path).
      // Then exit this duplicate.
      exit(0);
    }

    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    // Restore last window state (maximised).
    final stateFile = File(
      '${(await getApplicationDocumentsDirectory()).path}/.hearth.window',
    );
    if (stateFile.existsSync() &&
        stateFile.readAsStringSync().contains('max')) {
      // Slight delay lets the native window finish initialising.
      Future.delayed(const Duration(milliseconds: 200), () {
        windowManager.maximize();
      });
    }
    windowManager.addListener(_HearthWindowListener(stateFile));
    await _initSystemTray();
  }
  // Init local notifications for background message toasts.
  await _initNotifications();
  // Clean up leftover update files from previous versions.
  if (!kIsWeb) unawaited(cleanupOldUpdates());
  runApp(HearthApp(keyStore: SecureKeyStore()));
}

final FlutterLocalNotificationsPlugin _notifications =
    FlutterLocalNotificationsPlugin();

Future<void> _initNotifications() async {
  if (kIsWeb) return;
  await _notifications.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      linux: LinuxInitializationSettings(defaultActionName: 'Open'),
      windows: WindowsInitializationSettings(
        appName: 'Hearth',
        appUserModelId: 'com.hearth.app',
        guid: '6e2f7a8b-1c3d-4e5f-9a0b-2c4d6e8f0a1b',
      ),
    ),
  );
}

/// Shows a local notification (desktop/Android, not web).
Future<void> showLocalNotification(String title, String body) async {
  if (kIsWeb) return;
  await _notifications.show(
    id: 0,
    title: title,
    body: body,
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails(
        'hearth_messages',
        'Messages',
        importance: Importance.high,
      ),
      windows: WindowsNotificationDetails(),
    ),
  );
}

class _HearthWindowListener extends WindowListener {
  _HearthWindowListener(this._stateFile);
  final File _stateFile;

  @override
  void onWindowClose() async {
    await windowManager.hide();
  }

  @override
  void onWindowMaximize() => _stateFile.writeAsStringSync('max');

  @override
  void onWindowUnmaximize() => _stateFile.writeAsStringSync('');
}

Future<void> _initSystemTray() async {
  final tray = TrayManager.instance;
  // tray_manager needs a filesystem path, not a Flutter asset key.
  // On Windows the icon is bundled next to the exe; on macOS it's in the app bundle.
  String iconPath;
  if (defaultTargetPlatform == TargetPlatform.windows) {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    iconPath = '$exeDir/data/flutter_assets/assets/app_icon.ico';
  } else {
    iconPath = 'assets/app_icon.png';
  }
  await tray.setIcon(iconPath);
  await tray.setToolTip('Hearth');
  await tray.setContextMenu(
    Menu(
      items: [
        MenuItem(key: 'show', label: 'Show'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: 'Quit'),
      ],
    ),
  );
  tray.addListener(_HearthTrayListener());
}

class _HearthTrayListener extends TrayListener {
  @override
  void onTrayIconMouseDown() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() async {
    await TrayManager.instance.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show':
        await windowManager.show();
        await windowManager.focus();
      case 'quit':
        await windowManager.setPreventClose(false);
        await windowManager.close();
    }
  }
}

class HearthApp extends StatelessWidget {
  const HearthApp({
    required this.keyStore,
    this.relayUrl,
    this.autoPoll = true,
    super.key,
  });

  final KeyStore keyStore;
  final Uri? relayUrl;

  /// Disabled in widget tests so there's no background polling timer.
  final bool autoPoll;

  @override
  Widget build(BuildContext context) {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: const Color(0xFFF2792B), // ember
          brightness: Brightness.dark,
        ).copyWith(
          // Warm charcoal surfaces for a fireside feel (M3 surfaces run cool).
          surface: const Color(0xFF1C1714),
          surfaceContainerLowest: const Color(0xFF120E0B),
          surfaceContainerLow: const Color(0xFF1C1714),
          surfaceContainer: const Color(0xFF221B16),
          surfaceContainerHigh: const Color(0xFF2A221B),
          surfaceContainerHighest: const Color(0xFF342A21),
        );
    return MaterialApp(
      title: 'Hearth',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFF16110D),
        appBarTheme: const AppBarTheme(
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 2,
        ),
      ),
      home: _Bootstrap(
        keyStore: keyStore,
        relayUrl: relayUrl ?? kRelayUrl,
        autoPoll: autoPoll,
      ),
    );
  }
}

/// Loads (or creates) this device's identity, then hands off to the chat.
class _Bootstrap extends StatefulWidget {
  const _Bootstrap({
    required this.keyStore,
    required this.relayUrl,
    required this.autoPoll,
  });

  final KeyStore keyStore;
  final Uri relayUrl;
  final bool autoPoll;

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  late final Future<Identity> _identity = Identity.loadOrCreate(
    widget.keyStore,
  );

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Identity>(
      future: _identity,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Text('Failed to load identity: ${snapshot.error}'),
            ),
          );
        }
        return ChatScreen(
          identity: snapshot.data!,
          relayUrl: widget.relayUrl,
          keyStore: widget.keyStore,
          autoPoll: widget.autoPoll,
        );
      },
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    required this.identity,
    required this.relayUrl,
    required this.keyStore,
    this.autoPoll = true,
    super.key,
  });

  final Identity identity;
  final Uri relayUrl;
  final KeyStore keyStore;
  final bool autoPoll;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _composerFocus = FocusNode();
  final ScrollController _scroll = ScrollController();
  bool _showScrollDown = false;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  ChannelManager? _channels;
  ContactBook? _contacts;
  ChannelRegistry? _registry;
  BlobStore? _blobStore;
  MediaLibrary? _library;
  AudioPlayer? _player;
  VoiceSession? _voice;
  bool _speakerOn = true;
  // Screen share (Windows): my outgoing broadcast (null = not sharing), the
  // incoming shares I'm watching by sharer pubkey, and which one the stage shows.
  ScreenBroadcast? _broadcast;
  final Map<String, ScreenView> _screenViews = {};
  String? _selectedShareHex;
  Set<String> _sharedTo = {}; // voice peers already told about my active share
  // Shared YouTube "watch party" (Windows): host-driven, synced over the voice
  // mesh. videoId null = no party; mute/hidden are local-only per member.
  WatchPartyController? _ytController;
  String? _ytVideoId;
  String _ytHostHex = '';
  bool _ytIsHost = false;
  bool _ytPlaying = false;
  double _ytPosition = 0;
  double _ytDuration = 0;
  bool _ytMuted = false;
  bool _ytHidden = false; // I locally closed/disabled my view
  bool _ytSeeking = false; // host is dragging the seek bar
  Timer? _ytHeartbeat;
  Set<String> _ytSharedTo = {};
  ProfileStore? _profile;
  SettingsStore? _settings;
  UnreadStore? _unread;
  late Uri _relayUrl = widget.relayUrl;
  bool? _relayUp; // null = not checked yet
  bool _checkingRelay = false;
  String? _myName;
  final Map<String, String> _suggested = {}; // pubkeyHex -> self-asserted name
  final Set<String> _announced = {}; // channels we've published our name into
  final Set<String> _memberBaseline =
      {}; // channels whose baseline is scheduled
  final Set<String> _baselined = {}; // channels past their initial settle
  final Map<String, Set<String>> _seenMembers =
      {}; // channelId -> known members
  final Set<String> _promptedNew = {}; // members offered to add this session
  final List<({String key, String name})> _newMembers = []; // pending prompts
  bool _promptingMember = false;
  final Map<String, GroupChannel> _groups = {}; // id -> {key, local name}
  String? _error;
  Timer? _errorTimer;
  bool _sending = false;

  void _setError(String msg) {
    _errorTimer?.cancel();
    setState(() => _error = msg);
    _errorTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _error = null);
    });
  }

  UpdateInfo? _updateInfo;
  bool _relayBlocked = false; // released build can't reach the relay to verify
  bool _checkingBlock = false;
  double? _updateProgress;
  bool _installing = false;
  String? _installError;
  // Track recent send timestamps for the composer flame effect.
  final List<int> _recentSendTimes = [];
  final Set<AudioPlayer> _soundPlayers = {};
  InferenceBot? _bot;
  bool _composerOnFire = false;
  Timer? _fireTimer;
  bool _typingLocally = false;
  Timer? _typingTimer;

  @override
  void initState() {
    super.initState();
    _input.addListener(_onInputChanged);
    _scroll.addListener(_onScroll);
    unawaited(_init());
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final far = pos.maxScrollExtent - pos.pixels > 200;
    if (far != _showScrollDown) setState(() => _showScrollDown = far);
  }

  void _onInputChanged() {
    final session = _channels?.active;
    if (session == null) return;
    if (_input.text.isNotEmpty && !_typingLocally) {
      _typingLocally = true;
      session.sendTyping(true);
    }
    // Reset the "stop typing" timer — fires 3s after last keystroke.
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 3), () {
      if (_typingLocally) {
        _typingLocally = false;
        _channels?.active?.sendTyping(false);
      }
    });
  }

  /// Opens contacts + the channel registry, then re-opens every group channel
  /// you've joined. In widget tests (autoPoll off) everything stays in-memory —
  /// no Hive, no WebRTC — and there are no channels.
  Future<void> _init() async {
    final contacts = widget.autoPoll ? await ContactBook.open() : null;
    final registry = widget.autoPoll ? await ChannelRegistry.open() : null;
    final blobStore = widget.autoPoll ? await HiveBlobStore.open() : null;
    final library = widget.autoPoll ? await MediaLibrary.open() : null;
    final peerCache = widget.autoPoll ? await CandidateCache.open() : null;
    final profile = widget.autoPoll ? await ProfileStore.open() : null;
    final settings = widget.autoPoll ? await SettingsStore.open() : null;
    _settings = settings;
    _unread = widget.autoPoll ? await UnreadStore.open() : null;
    if (widget.autoPoll) await initRecentGifs();
    if (widget.autoPoll && (settings?.contributeCompute ?? true)) {
      _bot = await InferenceBot.tryCreate(modelId: settings?.activeModel);
    }
    final savedRelay = settings?.relayUrl;
    if (savedRelay != null) {
      final parsed = Uri.tryParse(savedRelay);
      if (parsed != null && parsed.hasScheme && parsed.hasAuthority) {
        _relayUrl = parsed;
      }
    }
    if (widget.autoPoll) unawaited(_checkRelay());
    if (widget.autoPoll) await _checkUpdate();
    if (_updateInfo != null) {
      // Force update: don't proceed to load channels — show the gate screen.
      if (mounted) setState(() {});
      return;
    }
    if (blobStore != null && library != null) {
      await loadStarterSounds(blobStore, library);
    }
    final channels = ChannelManager(
      identity: widget.identity,
      relayUrl: _relayUrl,
      live: widget.autoPoll,
      onUpdate: _onUpdate,
      blobStore: blobStore,
      candidateCache: peerCache,
      onBackgroundMessage: _notifyBackground,
      onForceUpdate: (info) {
        if (mounted) setState(() => _updateInfo = info);
      },
      onInference: _handleInference,
    );
    for (final group in registry?.all() ?? const <GroupChannel>[]) {
      _groups[group.id] = group;
      await channels.openGroup(group.id, group.key);
    }
    if (!mounted) {
      await channels.close();
      return;
    }
    setState(() {
      _contacts = contacts;
      _registry = registry;
      _blobStore = blobStore;
      _library = library;
      _profile = profile;
      _myName = profile?.name;
      // Auto-prune old blobs (> 30 days, except bookmarked media).
      if (blobStore is HiveBlobStore && library != null) {
        final keep = library.allHashes();
        unawaited(blobStore.prune(keep: keep));
      }
      _player = widget.autoPoll ? AudioPlayer() : null;
      _channels = channels;
    });
    // Mark all pre-existing channels as read so the drawer doesn't show stale
    // unread counts from history that was loaded before the user opened the app.
    for (final session in channels.sessions) {
      _markRead(session);
    }
    // Decrypt the active channel's loaded history: the onUpdate calls during the
    // open loop above ran before _channels was set, so they were no-ops.
    unawaited(_refresh());
  }

  void _onUpdate() => unawaited(_refresh());

  void _notifyBackground(String channelId) {
    if (!mounted) return;
    final session = _channels?.sessions
        .where((s) => s.channelId == channelId)
        .firstOrNull;
    final name = session != null ? _channelTitle(session) : 'a channel';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('New message in #$name'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
    // Also fire a local OS notification (visible when app is in tray/background).
    unawaited(showLocalNotification('Hearth', 'New message in #$name'));
  }

  // --- inference (P2P AI bot) ---

  final Map<String, Completer<String?>> _pendingInference = {};

  /// Broadcasts an inference request to all connected peers.
  void _requestInference(String prompt) {
    final id = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final completer = Completer<String?>();
    _pendingInference[id] = completer;
    // Capture the session now — response should post here even if user switches.
    final session = _channels?.active;
    if (session == null) return;
    session.broadcast(InferenceRequest(id: id, prompt: prompt));
    // Also try locally if we have a model.
    if (_bot != null) {
      unawaited(
        _bot!
            .generate(prompt)
            .then((text) {
              if (text != null && !completer.isCompleted) {
                completer.complete(text);
              }
            })
            .catchError((Object e) {
              if (mounted) _setError('AI model error: $e');
            }),
      );
    }
    // Timeout after 60s.
    completer.future
        .timeout(const Duration(seconds: 60), onTimeout: () => '')
        .then((text) {
          _pendingInference.remove(id);
          if (text != null && text.isNotEmpty && mounted) {
            unawaited(_publishTo(session, TextContent('🤖 $text')));
          } else if (mounted) {
            _setError('No AI peer responded (is anyone running a model?)');
          }
        });
  }

  // Per-peer cooldown so one peer can't peg our CPU with back-to-back requests.
  final Map<String, DateTime> _inferCooldown = {};

  /// Handles incoming inference controls from a peer in [channelId].
  void _handleInference(String fromHex, String channelId, MeshControl control) {
    if (control is InferenceRequest) {
      // A peer wants inference — respond if we have a model and compute is on.
      final bot = _bot;
      if (bot == null || bot.busy) return;
      final now = DateTime.now();
      final last = _inferCooldown[fromHex];
      if (last != null && now.difference(last) < const Duration(seconds: 10)) {
        return; // too soon since this peer's last request
      }
      _inferCooldown[fromHex] = now;
      unawaited(
        bot
            .generate(control.prompt)
            .then((text) {
              if (text == null || text.isEmpty) return;
              // Respond only on the channel the request came from — not every session
              // (which would leak the answer text to unrelated channels' peers).
              for (final s in _channels?.sessions ?? const <ChannelSession>[]) {
                if (s.channelId == channelId) {
                  s.broadcast(InferenceResponse(id: control.id, text: text));
                  break;
                }
              }
            })
            .catchError((Object e) {
              // Model error serving a peer's request — log but don't crash.
              if (mounted) {
                _setError('AI model error while serving request: $e');
              }
            }),
      );
    } else if (control is InferenceResponse) {
      // A peer responded to our request.
      final completer = _pendingInference[control.id];
      if (completer != null && !completer.isCompleted) {
        completer.complete(control.text);
      }
    }
  }

  /// Decrypts the active channel's new messages, indexes any media into your
  /// library, then re-renders.
  Future<void> _refresh() async {
    final active = _channels?.active;
    await active?.refreshContent();
    if (active != null) {
      await _indexLibrary(active);
      _indexProfiles(active);
      _detectNewMembers(active);
      _markRead(active);
      // Publish our own name into a channel the first time we're active in it.
      if (_myName != null && _announced.add(active.channelId)) {
        await _announceName(active);
      }
    }
    if (mounted) {
      setState(() {});
      _scrollToBottom();
    }
  }

  /// Adds the active channel's media (whose blobs are held) to your library, so
  /// anything sent or received can be re-sent in any channel.
  Future<void> _indexLibrary(ChannelSession session) async {
    final library = _library;
    if (library == null) return;
    for (final message in session.repository.ordered()) {
      switch (session.contentOf(message)) {
        case StickerContent(:final blob):
          if (session.blobOf(blob) != null) {
            await library.add(blob, MediaKind.sticker);
          }
        case GifContent(:final blob):
          if (session.blobOf(blob) != null) {
            await library.add(blob, MediaKind.gif);
          }
        case SoundContent(:final blob, :final name, :final emoji):
          if (session.blobOf(blob) != null) {
            await library.add(blob, MediaKind.sound, name: name, emoji: emoji);
          }
        case TextContent():
          break;
        case ProfileContent():
          break;
        case FileContent():
          break; // one-off attachment, not a re-usable library item
      }
    }
  }

  /// Records each author's latest self-asserted name as a *suggested* petname.
  void _indexProfiles(ChannelSession session) {
    for (final message in session.repository.ordered()) {
      final content = session.contentOf(message);
      if (content is ProfileContent && content.name.isNotEmpty) {
        _suggested[hex.encode(message.author)] = content.name;
      }
    }
  }

  /// Publishes our self-asserted name into [session] so members can suggest it.
  Future<void> _announceName(ChannelSession session) async {
    final name = _myName;
    if (name == null) return;
    final message = await Message.create(
      author: widget.identity,
      channel: session.channelId,
      payload: await session.encodePayload(ProfileContent(name)),
      prev: session.repository.heads(),
    );
    await session.publish(message);
  }

  /// Sets your display name (a suggestion to others) and re-announces it.
  Future<void> _setMyName() async {
    final name = await _promptText(
      title: 'Your display name',
      hint: 'what others see (a suggestion they can change)',
      initial: _myName ?? '',
      action: 'Save',
    );
    if (name == null) return;
    final trimmed = name.trim();
    await _profile?.setName(trimmed);
    _myName = trimmed.isEmpty ? null : trimmed;
    _announced.clear();
    if (mounted) setState(() {});
    for (final session in _channels?.sessions ?? const <ChannelSession>[]) {
      if (_myName != null) await _announceName(session);
      _announced.add(session.channelId);
    }
  }

  /// Members (by id) who've posted in [session], excluding you.
  /// All peers currently connected across all channel meshes.
  Set<String> _allOnlinePeers() {
    final result = <String>{};
    for (final s in _channels?.sessions ?? <ChannelSession>[]) {
      result.addAll(s.mesh?.peers ?? []);
    }
    return result;
  }

  /// Last message timestamp per peer across all sessions.
  Map<String, int> _computeLastSeen() {
    final result = <String, int>{};
    for (final s in _channels?.sessions ?? <ChannelSession>[]) {
      for (final msg in s.repository.ordered()) {
        final key = hex.encode(msg.author);
        final ts = msg.timestampMs;
        if (ts > (result[key] ?? 0)) result[key] = ts;
      }
    }
    return result;
  }

  Set<String> _membersOf(ChannelSession session) {
    final self = hex.encode(widget.identity.publicKey);
    return {
      for (final message in session.repository.ordered())
        if (hex.encode(message.author) != self) hex.encode(message.author),
    };
  }

  /// Builds the members list with active (< 7d) and inactive (collapsed) sections.
  List<Widget> _membersList(ChannelSession session) {
    final members = _membersOf(session);
    if (members.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            'Just you so far.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ];
    }
    // Get last message time per member.
    final lastSeen = <String, int>{};
    for (final message in session.repository.ordered()) {
      final key = hex.encode(message.author);
      if (members.contains(key)) lastSeen[key] = message.timestampMs;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    const sevenDays = 7 * 24 * 60 * 60 * 1000;
    final active = members
        .where((k) => (now - (lastSeen[k] ?? 0)) < sevenDays)
        .toList();
    final inactive = members
        .where((k) => (now - (lastSeen[k] ?? 0)) >= sevenDays)
        .toList();

    final onlinePeers = _allOnlinePeers();

    return [
      for (final key in active)
        _memberTile(key, online: onlinePeers.contains(key)),
      if (inactive.isNotEmpty)
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(
            'Inactive (${inactive.length})',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          initiallyExpanded: false,
          children: [
            for (final key in inactive)
              _memberTile(key, online: onlinePeers.contains(key)),
          ],
        ),
    ];
  }

  Widget _memberTile(String key, {bool? online}) {
    final isOnline = online ?? _allOnlinePeers().contains(key);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Stack(
        children: [
          _avatar(Uint8List.fromList(hex.decode(key)), radius: 14),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isOnline ? Colors.green : Colors.grey,
                border: Border.all(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  width: 1.5,
                ),
              ),
            ),
          ),
        ],
      ),
      title: Text(
        _displayName(Uint8List.fromList(hex.decode(key))),
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => unawaited(_peerActions(Uint8List.fromList(hex.decode(key)))),
    );
  }

  /// Prompts you to add a member who joins *after* you're settled in a channel
  /// (joining yourself doesn't flood you — the bulk-add covers existing members).
  /// On first sight of a channel we baseline its members silently after a short
  /// settle, then offer to add anyone new who's shared a name.
  void _detectNewMembers(ChannelSession session) {
    final channel = session.channelId;
    if (_memberBaseline.add(channel)) {
      Timer(const Duration(seconds: 4), () {
        _seenMembers[channel] = _membersOf(session);
        _baselined.add(channel);
      });
      return;
    }
    if (!_baselined.contains(channel)) return; // still settling
    final seen = _seenMembers[channel] ??= {};
    for (final key in _membersOf(session)) {
      if (!seen.add(key)) continue; // already known here
      if (_contacts?.nameFor(key) != null) continue; // already a contact
      final suggested = _suggested[key];
      if (suggested == null) continue; // hasn't shared a name → don't nag
      if (!_promptedNew.add(key)) continue; // offered already this session
      _newMembers.add((key: key, name: suggested));
    }
    if (_newMembers.isNotEmpty) unawaited(_processNewMembers());
  }

  /// Shows the "add this new member?" prompts one at a time — accept their name
  /// or type your own; Cancel skips.
  Future<void> _processNewMembers() async {
    if (_promptingMember) return;
    _promptingMember = true;
    while (_newMembers.isNotEmpty && mounted) {
      final next = _newMembers.removeAt(0);
      final name = await _promptText(
        title: '${next.name} joined',
        hint: 'add as a contact (only you see this name)',
        initial: next.name,
        action: 'Add',
      );
      if (name != null && name.trim().isNotEmpty) {
        await _contacts?.setName(next.key, name.trim());
      }
    }
    _promptingMember = false;
    if (mounted) setState(() {});
  }

  // --- identity backup ---

  /// Shows your recovery code (the seed) to back up. Anyone with it *is* you, so
  /// it's display-only with a warning.
  Future<void> _backupIdentity() async {
    final seed = await widget.identity.extractSeed();
    final codeHex = hex.encode(seed);
    final codeB64 = base64Url.encode(seed).replaceAll('=', '');
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Back up your identity'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Save this recovery code somewhere safe. Anyone who has it can '
                'become you — never share it. It is the only way to restore your '
                'identity if you lose this device.',
              ),
              const SizedBox(height: 16),
              Center(
                child: QrImageView(
                  data: codeB64,
                  size: 200,
                  backgroundColor: Colors.white,
                ),
              ),
              const SizedBox(height: 16),
              const Text('Recovery code:', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 4),
              SelectableText(
                codeB64,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
              ),
              const SizedBox(height: 8),
              Text(
                'Hex: $codeHex',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          FilledButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: codeB64));
              Navigator.pop(context);
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copy'),
          ),
        ],
      ),
    );
  }

  /// Restores an identity from a recovery code, replacing this device's.
  Future<void> _restoreIdentity() async {
    final isMobile =
        Theme.of(context).platform == TargetPlatform.android ||
        Theme.of(context).platform == TargetPlatform.iOS;
    String? code;
    if (isMobile) {
      // Mobile: offer scan or paste.
      code = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Restore identity'),
          content: const Text(
            'Scan a QR code from another device, or paste a recovery code.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton.icon(
              onPressed: () async {
                final result = await Navigator.push<String>(
                  ctx,
                  MaterialPageRoute<String>(
                    builder: (_) => const _QrScanPage(),
                  ),
                );
                if (ctx.mounted) Navigator.pop(ctx, result);
              },
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan QR'),
            ),
            TextButton.icon(
              onPressed: () async {
                Navigator.pop(ctx, ''); // sentinel: show text prompt
              },
              icon: const Icon(Icons.paste),
              label: const Text('Paste'),
            ),
          ],
        ),
      );
      // If "Paste" was chosen (empty sentinel), show text prompt. Cancel = null = abort.
      if (code != null && code.isEmpty && mounted) {
        code = await _promptText(
          title: 'Restore identity',
          hint: 'paste your recovery code',
          action: 'Restore',
        );
      }
    } else {
      code = await _promptText(
        title: 'Restore identity',
        hint: 'paste your recovery code',
        action: 'Restore',
      );
    }
    if (code == null || code.trim().isEmpty) return;
    Uint8List? seed;
    final trimmed = code.trim();
    try {
      if (trimmed.length == 64 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(trimmed)) {
        // Hex format (64 chars = 32 bytes).
        seed = Uint8List.fromList(hex.decode(trimmed));
      } else {
        // Base64url format (43 chars without padding = 32 bytes).
        final padded = trimmed.padRight(
          trimmed.length + (4 - trimmed.length % 4) % 4,
          '=',
        );
        final bytes = base64Url.decode(padded);
        if (bytes.length == 32) seed = Uint8List.fromList(bytes);
      }
    } catch (_) {
      seed = null;
    }
    if (seed == null) {
      if (mounted) _setError('invalid recovery code');
      return;
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Replace this identity?'),
        content: const Text(
          'This device will switch to the restored identity. Your current one '
          'is lost unless you backed it up.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.keyStore.writeSeed(seed);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Identity restored'),
        content: const Text('Restart Hearth to use the restored identity.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// Pings the relay's `/health` to show whether it's actually reachable and
  /// responding (so you can tell if a friend would be able to connect).
  Future<void> _checkRelay() async {
    if (!mounted || _checkingRelay) return;
    setState(() => _checkingRelay = true);
    bool up;
    try {
      final res = await http
          .get(_relayUrl.replace(path: '/health'))
          .timeout(const Duration(seconds: 5));
      up = res.statusCode == 200 && res.body.contains('"ok":true');
    } catch (_) {
      up = false;
    }
    if (mounted) {
      final wasDown = _relayUp == false || _relayUp == null;
      setState(() {
        _relayUp = up;
        _checkingRelay = false;
      });
      // If the relay just came back, kick all sessions to re-announce.
      if (up && wasDown) {
        _channels?.reconnect();
      }
    }
  }

  Future<void> _checkUpdate() async {
    final state = await checkForUpdate(_relayUrl);
    if (!mounted) return;
    setState(() {
      switch (state) {
        case UpdateAvailable(:final info):
          _updateInfo = info;
          _relayBlocked = false;
        case RelayUnreachable():
          // Released build, relay down — block until it's reachable again.
          _relayBlocked = true;
        case UpToDate():
          _relayBlocked = false;
      }
    });
  }

  /// A coloured dot + label for the relay's reachability.
  /// Unique connected peers across all channel meshes.
  int _totalPeerCount() {
    final all = <String>{};
    for (final session in _channels?.sessions ?? const <ChannelSession>[]) {
      final mesh = session.mesh;
      if (mesh != null) all.addAll(mesh.connections.keys);
    }
    return all.length;
  }

  Widget _connectionIndicator() {
    final peers = _totalPeerCount();
    final Color color;
    final String label;
    if (_relayUp == true && peers > 0) {
      color = Colors.green;
      label = 'Connected';
    } else if (_relayUp == true) {
      color = Colors.green;
      label = 'Relay only';
    } else if (peers > 0) {
      color = Colors.amber;
      label = 'Peers only';
    } else {
      color = Colors.red;
      label = 'Offline';
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 10, color: color)),
      ],
    );
  }

  /// Opens the public source repo (AGPL etiquette — let users find the source).
  Future<void> _openSourceCode() async {
    final ok = await launchUrl(
      Uri.parse(kSourceUrl),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't open the source link")),
      );
    }
  }

  Future<void> _openSettings() async {
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: DefaultTabController(
          length: 4,
          child: SizedBox(
            width: 400,
            height: 480,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Row(
                    children: [
                      Text(
                        'Settings',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),
                const TabBar(
                  isScrollable: true,
                  tabs: [
                    Tab(text: 'Audio'),
                    Tab(text: 'Identity'),
                    Tab(text: 'Network'),
                    Tab(text: 'AI'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _audioTab(),
                      _identityTab(),
                      _networkTab(),
                      _aiTab(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Enumerates audio devices. On some platforms (Windows), labels are empty
  /// until getUserMedia has been called at least once, so we do a quick
  /// acquire-and-release first to trigger the permission prompt.
  Future<List<MediaDeviceInfo>> _enumerateAudioDevices() async {
    // On mobile, trigger permission grant first.
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        final stream = await navigator.mediaDevices.getUserMedia({
          'audio': true,
          'video': false,
        });
        for (final t in stream.getTracks()) {
          await t.stop();
        }
        await stream.dispose();
      } catch (_) {}
    }
    var devices = await navigator.mediaDevices.enumerateDevices();
    // On Windows/desktop, enumerateDevices can return empty until a
    // PeerConnection has been created. Create a throwaway one to kick the
    // native layer, then re-enumerate.
    if (devices.where((d) => d.kind == 'audioinput').isEmpty &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux)) {
      try {
        final pc = await createPeerConnection({});
        await pc.close();
        await pc.dispose();
        devices = await navigator.mediaDevices.enumerateDevices();
      } catch (_) {}
    }
    return devices;
  }

  Widget _audioTab() {
    return StatefulBuilder(
      builder: (context, setTabState) {
        return FutureBuilder<List<MediaDeviceInfo>>(
          future: _enumerateAudioDevices(),
          builder: (context, snapshot) {
            final devices = snapshot.data ?? [];
            final seen = <String>{};
            final mics = devices
                .where((d) => d.kind == 'audioinput' && seen.add(d.deviceId))
                .toList();
            seen.clear();
            final speakers = devices
                .where((d) => d.kind == 'audiooutput' && seen.add(d.deviceId))
                .toList();
            return Padding(
              padding: const EdgeInsets.all(16),
              child: ListView(
                children: [
                  Text(
                    'Microphone',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 4),
                  if (mics.isEmpty)
                    const Text('No microphones found')
                  else if (defaultTargetPlatform == TargetPlatform.android ||
                      defaultTargetPlatform == TargetPlatform.iOS)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.mic, size: 20),
                      title: const Text('Built-in Microphone'),
                      trailing: TextButton(
                        child: const Text('Test'),
                        onPressed: () async {
                          try {
                            final stream = await navigator.mediaDevices
                                .getUserMedia({
                                  'audio': true,
                                  'video': false,
                                });
                            await Future<void>.delayed(
                              const Duration(milliseconds: 500),
                            );
                            for (final t in stream.getTracks()) {
                              await t.stop();
                            }
                            await stream.dispose();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('✓ Microphone is working'),
                                ),
                              );
                            }
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('✗ Mic failed: $e')),
                              );
                            }
                          }
                        },
                      ),
                    )
                  else
                    for (final mic in mics)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.mic, size: 20),
                        title: Text(
                          mic.label.isNotEmpty
                              ? mic.label
                              : 'Microphone ${mics.indexOf(mic) + 1}',
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: TextButton(
                          child: const Text('Test'),
                          onPressed: () async {
                            try {
                              final stream = await navigator.mediaDevices
                                  .getUserMedia({
                                    'audio': {
                                      'deviceId': {'exact': mic.deviceId},
                                    },
                                    'video': false,
                                  });
                              await Future<void>.delayed(
                                const Duration(milliseconds: 500),
                              );
                              for (final t in stream.getTracks()) {
                                await t.stop();
                              }
                              await stream.dispose();
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      '✓ ${mic.label.isNotEmpty ? mic.label : "Mic"} is working',
                                    ),
                                  ),
                                );
                              }
                            } catch (e) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      '✗ ${mic.label.isNotEmpty ? mic.label : "Mic"} failed: $e',
                                    ),
                                  ),
                                );
                              }
                            }
                          },
                        ),
                      ),
                  const Divider(height: 24),
                  Text(
                    'Speaker',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 4),
                  if (speakers.isEmpty)
                    const Text('No speakers found')
                  else
                    for (final spk in speakers)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.volume_up, size: 20),
                        title: Text(
                          spk.label.isNotEmpty
                              ? spk.label
                              : 'Speaker ${speakers.indexOf(spk) + 1}',
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: TextButton(
                          child: const Text('Test'),
                          onPressed: () async {
                            final player = AudioPlayer();
                            await player.play(
                              BytesSource(VoiceSession.connectTone),
                            );
                            await Future<void>.delayed(
                              const Duration(milliseconds: 300),
                            );
                            await player.dispose();
                          },
                        ),
                      ),
                  const Divider(height: 24),
                  Text(
                    'Processing',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Noise suppression'),
                    subtitle: const Text(
                      'Reduces background noise in voice chat',
                    ),
                    value: _settings?.noiseSuppression ?? false,
                    onChanged: (v) {
                      unawaited(_settings?.setNoiseSuppression(v));
                      setTabState(() {});
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _identityTab() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.key_outlined),
            title: const Text('Back up identity'),
            subtitle: const Text('Export your recovery code'),
            onTap: () {
              Navigator.pop(context);
              unawaited(_backupIdentity());
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.restore),
            title: const Text('Restore identity'),
            subtitle: const Text('Import a recovery code'),
            onTap: () {
              Navigator.pop(context);
              unawaited(_restoreIdentity());
            },
          ),
        ],
      ),
    );
  }

  Widget _networkTab() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          NetworkStatus(
            relayUp: _relayUp,
            checkingRelay: _checkingRelay,
            peerCount: _totalPeerCount(),
            channelCount: _channels?.sessions.length ?? 0,
            relayUrl: _relayUrl.toString(),
            onTapRelay: () {
              Navigator.pop(context);
              unawaited(_setRelayUrl());
            },
            onRefresh: () => unawaited(_checkRelay()),
          ),
        ],
      ),
    );
  }

  Widget _aiTab() {
    return StatefulBuilder(
      builder: (context, setTabState) {
        return FutureBuilder<Set<String>>(
          future: InferenceBot.downloadedModels(
            _kAvailableModels.map((m) => m.id).toList(),
          ),
          builder: (context, snap) {
            final downloaded = snap.data ?? {};
            final activeModel = _settings?.activeModel;
            return Padding(
              padding: const EdgeInsets.all(16),
              child: ListView(
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('AI bot'),
                    subtitle: const Text(
                      'Respond to @bot requests from other peers using your local model',
                    ),
                    value: _settings?.contributeCompute ?? true,
                    onChanged: (v) {
                      unawaited(_settings?.setContributeCompute(v));
                      setTabState(() {});
                    },
                  ),
                  const Divider(height: 24),
                  Text('Models', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 8),
                  for (final model in _kAvailableModels)
                    Card(
                      child: ListTile(
                        leading: downloaded.contains(model.id)
                            ? Icon(
                                activeModel == model.id
                                    ? Icons.radio_button_checked
                                    : Icons.radio_button_unchecked,
                                color: activeModel == model.id
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              )
                            : null,
                        title: Text(model.name),
                        subtitle: Text('${model.size} · ${model.description}'),
                        onTap: downloaded.contains(model.id)
                            ? () {
                                unawaited(_settings?.setActiveModel(model.id));
                                _bot = null;
                                InferenceBot.tryCreate(
                                  modelId: model.id,
                                ).then((b) => _bot = b);
                                setTabState(() {});
                              }
                            : null,
                        trailing: _downloadingModel == model.id
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : downloaded.contains(model.id)
                            ? const Icon(
                                Icons.check_circle,
                                color: Colors.green,
                                size: 20,
                              )
                            : IconButton(
                                icon: const Icon(Icons.download),
                                onPressed: () => unawaited(
                                  _downloadModel(model, setTabState),
                                ),
                              ),
                      ),
                    ),
                  if (_downloadProgress != null) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: _downloadProgress),
                    Text(
                      '${(_downloadProgress! * 100).toStringAsFixed(0)}%',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }

  String? _downloadingModel;
  double? _downloadProgress;

  Future<void> _downloadModel(
    _ModelInfo model,
    void Function(void Function()) setTabState,
  ) async {
    final path = await InferenceBot.pathFor(model.id);
    final file = File(path);
    setTabState(() {
      _downloadingModel = model.id;
      _downloadProgress = 0;
    });
    try {
      final request = await HttpClient().getUrl(Uri.parse(model.url));
      final response = await request.close();
      final total = response.contentLength;
      var received = 0;
      final sink = file.openWrite();
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          setTabState(() => _downloadProgress = received / total);
        }
      }
      await sink.close();
      // Auto-select the newly downloaded model.
      await _settings?.setActiveModel(model.id);
      _bot = await InferenceBot.tryCreate(modelId: model.id);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('${model.name} installed ✓')));
      }
    } catch (e) {
      // Clean up partial download.
      if (await file.exists()) await file.delete();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Download failed: $e')));
      }
    } finally {
      setTabState(() {
        _downloadingModel = null;
        _downloadProgress = null;
      });
    }
  }

  /// Edits the relay URL (the rendezvous + media-proxy endpoint). Persisted; open
  /// channels keep using the old one until you restart.
  Future<void> _setRelayUrl() async {
    final entered = await _promptText(
      title: 'Relay server',
      hint: 'https://relay.example.com',
      initial: _relayUrl.toString(),
      action: 'Save',
    );
    if (entered == null) return;
    var trimmed = entered.trim();
    if (trimmed.startsWith('http://')) {
      if (mounted) _setError('HTTP is not supported — use HTTPS');
      return;
    }
    if (!trimmed.startsWith('https://')) trimmed = 'https://$trimmed';
    final parsed = Uri.tryParse(trimmed);
    if (trimmed.isEmpty ||
        parsed == null ||
        !parsed.hasScheme ||
        !parsed.hasAuthority) {
      if (mounted) _setError('invalid relay URL');
      return;
    }
    await _settings?.setRelayUrl(trimmed);
    if (!mounted) return;
    setState(() => _relayUrl = parsed);
    // Tear down and rebuild the mesh on the new relay.
    await _channels?.close();
    final channels = ChannelManager(
      identity: widget.identity,
      relayUrl: _relayUrl,
      live: widget.autoPoll,
      onUpdate: _onUpdate,
      blobStore: _blobStore,
      candidateCache: null,
      onBackgroundMessage: _notifyBackground,
      onForceUpdate: (info) {
        if (mounted) setState(() => _updateInfo = info);
      },
      onInference: _handleInference,
    );
    for (final group in _registry?.all() ?? const <GroupChannel>[]) {
      await channels.openGroup(group.id, group.key);
    }
    if (mounted) setState(() => _channels = channels);
  }

  @override
  void dispose() {
    unawaited(_channels?.close());
    unawaited(_broadcast?.stop());
    for (final view in _screenViews.values) {
      unawaited(view.close());
    }
    _screenViews.clear();
    _ytHeartbeat?.cancel();
    _ytController = null;
    unawaited(_voice?.leave());
    unawaited(_player?.dispose());
    _input.dispose();
    _composerFocus.dispose();
    _scroll.dispose();
    _typingTimer?.cancel();
    _fireTimer?.cancel();
    _errorTimer?.cancel();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    _typingTimer?.cancel();
    if (_typingLocally) {
      _typingLocally = false;
      _channels?.active?.sendTyping(false);
    }
    await _publish(TextContent(text));
    _composerFocus.requestFocus();
    // @bot trigger — broadcast an inference request to the mesh.
    if (text.startsWith('@bot ')) {
      final prompt = text.substring(5).trim();
      if (prompt.isNotEmpty) {
        _requestInference(prompt);
      }
    }
    // Fire effect: if 4+ messages in 5 seconds, ignite the composer.
    final now = DateTime.now().millisecondsSinceEpoch;
    _recentSendTimes.add(now);
    _recentSendTimes.removeWhere((t) => now - t > 5000);
    if (_recentSendTimes.length >= 4 && !_composerOnFire) {
      setState(() => _composerOnFire = true);
    }
    if (_composerOnFire) {
      _fireTimer?.cancel();
      _fireTimer = Timer(const Duration(seconds: 10), () {
        if (mounted) setState(() => _composerOnFire = false);
      });
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      if (pos.maxScrollExtent - pos.pixels < 100) {
        _scroll.animateTo(
          pos.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// Searches GIFs (via the relay's proxy), fetches the chosen one's bytes once,
  /// then sends it as a blob — after that it's local + P2P, never re-fetched.
  Future<void> _sendGif() async {
    final store = _blobStore;
    if (store == null) return;
    final url = await pickGif(context, _relayUrl);
    if (url == null) return;
    try {
      final res = await http.get(Uri.parse(url));
      if (res.statusCode != 200) {
        if (mounted) _setError('could not fetch that GIF');
        return;
      }
      final hash = await store.put(res.bodyBytes);
      await _publish(GifContent(hash));
    } catch (_) {
      if (mounted) _setError('could not fetch that GIF');
    }
  }

  /// Picks an image and sends it as a sticker — stored as a content-addressed
  /// blob, fetched on demand by peers (never gossiped to everyone).
  Future<void> _sendSticker() async {
    final store = _blobStore;
    if (store == null) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    final bytes = result?.files.single.bytes;
    if (bytes == null) return;
    final hash = await store.put(bytes);
    await _publish(StickerContent(hash));
  }

  /// Picks any file and sends it as an attachment (image inline, else a chip).
  Future<void> _sendFile() async {
    final store = _blobStore;
    if (store == null) return;
    final result = await FilePicker.platform.pickFiles(withData: true);
    final file = result?.files.single;
    final bytes = file?.bytes;
    if (file == null || bytes == null) return;
    final danger = _fileDanger(file.name, bytes);
    if (danger != null) {
      if (mounted) _setError(danger);
      return;
    }
    final hash = await store.put(bytes);
    await _publish(FileContent(hash, file.name, _mimeFor(file.extension)));
  }

  static const _blockedExtensions = {
    'exe',
    'scr',
    'bat',
    'cmd',
    'ps1',
    'vbs',
    'vbe',
    'wsh',
    'wsf',
    'msi',
    'dll',
    'com',
    'pif',
    'hta',
    'cpl',
    'reg',
    'inf',
    'lnk',
  };

  static const int _maxFileSize = 500 * 1024 * 1024; // 500 MB
  static const int _maxArchiveSize = 2 * 1024 * 1024 * 1024; // 2 GB
  static const _archiveExtensions = {
    'zip',
    '7z',
    'rar',
    'tar',
    'gz',
    'bz2',
    'xz',
    'zst',
  };

  /// Returns a reason string if the file is dangerous, null if safe.
  static String? _fileDanger(String name, List<int> bytes) {
    final ext = name.split('.').last.toLowerCase();
    // Size limit — archives get a higher cap.
    final limit = _archiveExtensions.contains(ext)
        ? _maxArchiveSize
        : _maxFileSize;
    if (bytes.length > limit) {
      return 'File too large (${_archiveExtensions.contains(ext) ? "2 GB" : "500 MB"} max)';
    }
    // Extension check.
    if (_blockedExtensions.contains(ext)) {
      return 'That file type (.$ext) is blocked for safety';
    }
    // Double-extension trick (e.g. report.pdf.exe).
    final parts = name.split('.');
    if (parts.length > 2) {
      final secondLast = parts[parts.length - 2].toLowerCase();
      if (_blockedExtensions.contains(secondLast)) {
        return 'Suspicious double extension detected';
      }
    }
    // Magic bytes: detect PE executables regardless of extension.
    if (bytes.length >= 2 && bytes[0] == 0x4D && bytes[1] == 0x5A) {
      return 'File contains executable code (blocked)';
    }
    return null;
  }

  /// Name-only danger check for received files (no bytes available — used in
  /// the chat view to flag blocked extensions with a warning chip).
  bool _isDangerousFile(String name) {
    final ext = name.split('.').last.toLowerCase();
    if (_blockedExtensions.contains(ext)) return true;
    final parts = name.split('.');
    if (parts.length > 2) {
      return _blockedExtensions.contains(parts[parts.length - 2].toLowerCase());
    }
    return false;
  }

  /// A coarse MIME from a file extension (enough to render images inline).
  String _mimeFor(String? extension) {
    switch (extension?.toLowerCase()) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      default:
        return 'application/octet-stream';
    }
  }

  /// Picks an audio file, lets you name it, and posts it as a soundboard clip.
  Future<void> _sendSound() async {
    final store = _blobStore;
    if (store == null) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      withData: true,
    );
    final file = result?.files.single;
    final bytes = file?.bytes;
    if (file == null || bytes == null) return;
    final name = await _promptText(
      title: 'Name this sound',
      hint: 'e.g. airhorn',
      initial: file.name.split('.').first,
      action: 'Add',
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    final emoji =
        await pickEmoji(context, title: 'Pick an icon for this sound') ?? '🔊';
    final hash = await store.put(bytes);
    await _publish(SoundContent(hash, name.trim(), emoji));
  }

  /// Searches Freesound (via the relay, CC0-filtered), fetches the chosen clip,
  /// and posts it with the emoji you pick.
  Future<void> _searchSound() async {
    final store = _blobStore;
    if (store == null) return;
    final picked = await pickSound(context, _relayUrl);
    if (picked == null) return;
    try {
      final res = await http.get(Uri.parse(picked.url));
      if (res.statusCode != 200) {
        if (mounted) _setError('could not fetch that sound');
        return;
      }
      if (!mounted) return;
      final emoji =
          await pickEmoji(context, title: 'Pick an icon for this sound') ??
          '🔊';
      final hash = await store.put(res.bodyBytes);
      await _publish(SoundContent(hash, picked.name, emoji));
    } catch (_) {
      if (mounted) _setError('could not fetch that sound');
    }
  }

  /// Plays a soundboard clip if its blob is held locally.
  Future<void> _playSound(ChannelSession session, String blob) async {
    final bytes = session.blobOf(blob);
    if (bytes == null) return;
    // Cap concurrent soundboard players to avoid resource exhaustion.
    if (_soundPlayers.length >= 20) return;
    final player = AudioPlayer();
    _soundPlayers.add(player);
    // Fire-and-forget — don't await so rapid spam isn't serialized.
    unawaited(player.play(BytesSource(bytes)).catchError((_) {}));
    // Clean up when done; 10s safety cap for long clips.
    player.onPlayerComplete.listen((_) async {
      await player.dispose();
      _soundPlayers.remove(player);
    });
    unawaited(
      Future.delayed(const Duration(seconds: 10), () async {
        if (_soundPlayers.contains(player)) {
          await player.stop();
          await player.dispose();
          _soundPlayers.remove(player);
        }
      }),
    );
  }

  /// Builds, persists, and gossips [content] in the active channel.
  Future<void> _publish(Content content) async {
    final session = _channels?.active;
    if (_sending || session == null) return;
    setState(() => _sending = true);
    try {
      final message = await Message.create(
        author: widget.identity,
        channel: session.channelId,
        payload: await session.encodePayload(content),
        prev: session.repository.heads(),
      );
      // Persist + gossip to peers; the updates stream re-renders it.
      await session.publish(message);
    } catch (_) {
      if (mounted) _setError('send failed');
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        // Scroll to show the just-sent message.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scroll.hasClients) {
              _scroll.jumpTo(_scroll.position.maxScrollExtent);
            }
          });
        });
      }
    }
  }

  /// Publishes to a specific session (used when the target may differ from active).
  Future<void> _publishTo(ChannelSession session, Content content) async {
    try {
      final message = await Message.create(
        author: widget.identity,
        channel: session.channelId,
        payload: await session.encodePayload(content),
        prev: session.repository.heads(),
      );
      await session.publish(message);
    } catch (_) {
      // Best-effort; inference responses failing silently is acceptable.
    }
  }

  /// Inserts a picked emoji at the cursor in the composer.
  Future<void> _insertEmoji() async {
    final emoji = await pickEmoji(context);
    if (emoji == null) return;
    final value = _input.value;
    final sel = value.selection;
    final start = sel.isValid ? sel.start : value.text.length;
    final end = sel.isValid ? sel.end : value.text.length;
    _input.value = TextEditingValue(
      text: value.text.replaceRange(start, end, emoji),
      selection: TextSelection.collapsed(offset: start + emoji.length),
    );
  }

  // --- channels ---

  /// The active channel's display name: a peer's name for a DM, your local name
  /// for a group.
  String _channelTitle(ChannelSession session) => session.isDm
      ? _displayName(Uint8List.fromList(session.peerPubkey!))
      : (_groups[session.channelId]?.name ?? 'channel');

  /// Creates a brand-new channel (random id + key) with a local name.
  Future<void> _createChannel() async {
    final name = await _promptText(
      title: 'Create a channel',
      hint: 'name it (only you see this)',
      action: 'Create',
    );
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    final channel = GroupChannel.create(trimmed);
    await _registry?.save(channel);
    if (mounted) setState(() => _groups[channel.id] = channel);
    await _channels?.openGroup(channel.id, channel.key);
  }

  /// Joins a channel from a pasted invite code.
  Future<void> _joinViaInvite() async {
    final code = await _promptText(
      title: 'Join via invite',
      hint: 'paste the invite code',
      action: 'Join',
    );
    if (code == null || code.trim().isEmpty) return;
    final parsed = GroupChannel.fromInvite(code.trim());
    if (parsed == null) {
      if (mounted) _setError('invalid invite code');
      return;
    }
    final channel = parsed.channel;
    // Adopt the invite's relay if we're still on the bundled default, so a new
    // joiner never types a URL. (Won't override a relay you've set yourself.)
    String? adoptedRelay;
    final inviteRelay = parsed.relayUrl;
    if (inviteRelay != null &&
        inviteRelay != _relayUrl.toString() &&
        _relayUrl.toString() == kRelayUrl.toString()) {
      final relay = Uri.tryParse(inviteRelay);
      if (relay != null && relay.hasScheme && relay.hasAuthority) {
        await _settings?.setRelayUrl(inviteRelay);
        _relayUrl = relay;
        adoptedRelay = inviteRelay;
      }
    }
    await _registry?.save(channel);
    if (mounted) setState(() => _groups[channel.id] = channel);
    // Mandatorily add the inviter as a contact — guarantees you have at least one
    // edge into the channel (the invite-tree stays connected; they're your
    // cold-start bootstrap peer).
    final inviter = parsed.inviterPubkey;
    if (inviter != null &&
        inviter != widget.identity.publicKeyHex &&
        _contacts?.nameFor(inviter) == null) {
      await _contacts?.setName(
        inviter,
        parsed.inviterName ??
            'hearth#${_fingerprint(Uint8List.fromList(hex.decode(inviter)))}',
      );
    }
    await _channels?.openGroup(channel.id, channel.key);
    // Once history has had a moment to sync, offer to add known members.
    Future.delayed(const Duration(seconds: 3), () {
      final active = _channels?.active;
      if (mounted && active != null && active.channelId == channel.id) {
        unawaited(_addMembers(active, auto: true));
      }
    });
    if (adoptedRelay != null && mounted) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Relay set from invite'),
          content: Text(
            'Restart Hearth to connect to this channel via\n$adoptedRelay',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  /// Shows the invite code for a group channel, with a copy button.
  Future<void> _shareInvite(String channelId) async {
    final channel = _groups[channelId];
    if (channel == null) return;
    final invite = channel.invite(
      inviterPubkeyHex: widget.identity.publicKeyHex,
      inviterName: _myName,
      relayUrl: _relayUrl.toString(),
    );
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Invite to this channel'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Anyone with this code can join and read messages.'),
            const SizedBox(height: 12),
            SelectableText(
              invite,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          FilledButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: invite));
              Navigator.pop(context);
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copy'),
          ),
        ],
      ),
    );
  }

  /// Leaves a group channel: confirm, drop it from the registry, close it.
  Future<void> _leaveChannel(String channelId) async {
    final isLastMember = (_seenMembers[channelId] ?? {}).isEmpty;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave channel?'),
        content: Text(
          isLastMember
              ? "You're the only member — leaving will destroy this channel "
                    'and all its message history permanently.'
              : "You'll stop receiving its messages and need a new invite to "
                    'rejoin.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: isLastMember
                ? FilledButton.styleFrom(backgroundColor: Colors.red)
                : null,
            onPressed: () => Navigator.pop(context, true),
            child: Text(isLastMember ? 'Destroy & leave' : 'Leave'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _registry?.remove(channelId);
    _groups.remove(channelId);
    await _channels?.leave(channelId);
    if (mounted) setState(() {});
  }

  // --- voice ---

  /// Joins (or switches to) voice in [channelId], requesting the mic.
  Future<void> _joinVoice(String channelId) async {
    if (_voice != null) await _leaveVoice();
    // Ensure mic permission on mobile before attempting getUserMedia.
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        _setError('Microphone permission denied');
        return;
      }
    }
    try {
      _voice = await VoiceSession.join(
        channelId: channelId,
        identity: widget.identity,
        relayUrl: _relayUrl,
        onChange: _voiceChanged,
        enhancedNoiseSuppression: _settings?.noiseSuppression ?? false,
      );
      _voice!.onSoundboard = (blob) {
        final session = _channels?.active;
        if (session != null) unawaited(_playSound(session, blob));
      };
      _voice!.onScreenShare = (sharerHex, active) {
        if (active) {
          unawaited(_addScreenView(channelId, sharerHex));
        } else {
          unawaited(_removeScreenView(sharerHex));
        }
      };
      _voice!.onYoutube = _onYoutubeControl;
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) {
        _setError('microphone access is needed for voice');
      }
    }
  }

  void _voiceChanged() {
    _pruneScreenViews();
    _reannounceShareToNewPeers();
    _pruneWatchParty();
    _reannounceYtToNewPeers();
    if (mounted) setState(() {});
  }

  Future<void> _leaveVoice() async {
    await _stopScreenShare(); // no-op if not sharing; tells peers before we go
    if (_ytIsHost && _ytVideoId != null) {
      _voice?.sendControl(
        YoutubeControl(
          host: widget.identity.publicKeyHex,
          videoId: '',
          playing: false,
          position: 0,
        ),
      );
    }
    _endWatchParty();
    final views = _screenViews.values.toList();
    _screenViews.clear();
    _selectedShareHex = null;
    final voice = _voice;
    _voice = null;
    _speakerOn = true;
    if (mounted) setState(() {});
    for (final view in views) {
      await view.close();
    }
    await voice?.leave();
  }

  // --- screen share (Windows) ---

  /// The desktop-webview features (screen share + YouTube watch party) are
  /// Windows-only for now.
  bool get _screenShareSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// Opens the picker and starts sharing the chosen window/screen, announcing it
  /// to the call so everyone joins my screen mesh.
  Future<void> _startScreenShare(ChannelSession session) async {
    final voice = _voice;
    if (voice == null || _broadcast != null) return;
    final choice = await showScreenSharePicker(context);
    if (choice == null || !mounted) return;
    try {
      final broadcast = await ScreenBroadcast.start(
        channelId: session.channelId,
        identity: widget.identity,
        relayUrl: _relayUrl,
        source: choice.source,
        resolution: choice.resolution,
        onEnded: () => unawaited(_stopScreenShare()),
      );
      if (!mounted) {
        await broadcast.stop();
        return;
      }
      _broadcast = broadcast;
      voice.sendControl(
        ScreenShareControl(sharer: widget.identity.publicKeyHex, active: true),
      );
      _sharedTo = voice.peerHexes.toSet();
      setState(() {});
    } catch (e) {
      if (mounted) _setError('screen share failed: $e');
    }
  }

  Future<void> _stopScreenShare() async {
    final broadcast = _broadcast;
    if (broadcast == null) return;
    _broadcast = null;
    _sharedTo.clear();
    // Announce the stop while the voice mesh is still up, so viewers drop it.
    _voice?.sendControl(
      ScreenShareControl(sharer: widget.identity.publicKeyHex, active: false),
    );
    if (mounted) setState(() {});
    await broadcast.stop();
  }

  /// Joins [sharerHex]'s screen mesh to watch their share.
  Future<void> _addScreenView(String channelId, String sharerHex) async {
    if (_screenViews.containsKey(sharerHex)) return; // already watching
    try {
      final view = await ScreenView.watch(
        channelId: channelId,
        sharerHex: sharerHex,
        identity: widget.identity,
        relayUrl: _relayUrl,
        onChange: _voiceChanged,
      );
      if (!mounted) {
        await view.close();
        return;
      }
      _screenViews[sharerHex] = view;
      _selectedShareHex ??= sharerHex;
      setState(() {});
    } catch (_) {
      // Couldn't open the view — ignore; a re-announce will retry.
    }
  }

  Future<void> _removeScreenView(String sharerHex) async {
    final view = _screenViews.remove(sharerHex);
    if (view == null) return;
    if (_selectedShareHex == sharerHex) {
      _selectedShareHex = _screenViews.keys.isEmpty
          ? null
          : _screenViews.keys.first;
    }
    if (mounted) setState(() {});
    await view.close();
  }

  /// Drops any screen view whose sharer has left the voice call (a strong signal
  /// they've stopped, vs. a transient mesh blip which keeps the view alive).
  void _pruneScreenViews() {
    final voice = _voice;
    if (voice == null) return;
    final present = voice.peerHexes.toSet();
    for (final hex
        in _screenViews.keys.where((h) => !present.contains(h)).toList()) {
      unawaited(_removeScreenView(hex));
    }
  }

  /// While I'm sharing, re-announce to any voice peer that has joined since — so
  /// people who join the call mid-share (or whom I just connected to) still learn
  /// of my screen mesh. Re-sends to existing viewers are deduped away.
  void _reannounceShareToNewPeers() {
    final voice = _voice;
    if (voice == null || _broadcast == null) return;
    final current = voice.peerHexes.toSet();
    if (current.difference(_sharedTo).isEmpty) return; // no new peers
    _sharedTo = current;
    voice.sendControl(
      ScreenShareControl(sharer: widget.identity.publicKeyHex, active: true),
    );
  }

  // --- shared YouTube (watch party) ---

  WatchPartyController _newYtController() {
    final c = WatchPartyController();
    c.onStateChange = (playing, position) {
      if (!mounted) return;
      setState(() {
        _ytPlaying = playing;
        if (!_ytSeeking) _ytPosition = position;
      });
    };
    return c;
  }

  /// Starts (or replaces) the shared video, becoming the host.
  Future<void> _startWatchParty(ChannelSession session) async {
    final voice = _voice;
    if (voice == null) return;
    final raw = await showYoutubeStartDialog(context);
    if (raw == null || !mounted) return;
    final id = parseYoutubeId(raw);
    if (id == null) {
      _setError("couldn't read that YouTube link");
      return;
    }
    _ytController ??= _newYtController();
    setState(() {
      _ytVideoId = id;
      _ytHostHex = widget.identity.publicKeyHex;
      _ytIsHost = true;
      _ytPlaying = true;
      _ytPosition = 0;
      _ytDuration = 0;
      _ytHidden = false;
    });
    _broadcastYt();
    _ytSharedTo = voice.peerHexes.toSet();
    _startYtHeartbeat();
  }

  /// Applies the host's watch-party state (I'm a follower).
  void _onYoutubeControl(String senderHex, YoutubeControl control) {
    if (!mounted || senderHex == widget.identity.publicKeyHex) return;
    if (control.videoId.isEmpty) {
      if (senderHex == _ytHostHex) _endWatchParty(); // host closed it
      return;
    }
    // Two near-simultaneous starts: the higher pubkey wins, so both sides
    // converge on one host instead of yielding to each other. If I'm hosting and
    // a lower-key peer also started, keep hosting — my next broadcast wins them.
    if (_ytIsHost && senderHex.compareTo(widget.identity.publicKeyHex) < 0) {
      return;
    }
    // Never trust a network-supplied id: it's interpolated into the player's
    // JS, so reject anything that isn't a clean 11-char YouTube id.
    final videoId = parseYoutubeId(control.videoId);
    if (videoId == null) return;
    final position = control.position.isFinite && control.position >= 0
        ? control.position
        : 0.0;
    final isNew = _ytVideoId != videoId || _ytHostHex != senderHex;
    _ytHeartbeat?.cancel(); // someone else hosts now
    _ytHeartbeat = null;
    if (isNew) _ytHidden = false; // a fresh video re-engages everyone
    if (!_ytHidden) _ytController ??= _newYtController();
    setState(() {
      _ytHostHex = senderHex;
      _ytIsHost = false;
      _ytVideoId = videoId;
      _ytPlaying = control.playing;
      if (isNew) _ytPosition = position;
    });
    unawaited(_applyRemoteYt(videoId, control.playing, position, isNew));
  }

  Future<void> _applyRemoteYt(
    String videoId,
    bool playing,
    double position,
    bool isNew,
  ) async {
    final c = _ytController;
    if (c == null || !c.isReady || _ytHidden) return;
    if (!isNew) {
      final cur = await c.currentTime();
      if ((cur - position).abs() > 2.0) await c.seek(position);
    }
    if (playing) {
      await c.play();
    } else {
      await c.pause();
    }
  }

  void _broadcastYt() {
    final id = _ytVideoId;
    if (!_ytIsHost || id == null) return;
    _voice?.sendControl(
      YoutubeControl(
        host: widget.identity.publicKeyHex,
        videoId: id,
        playing: _ytPlaying,
        position: _ytPosition,
      ),
    );
  }

  void _startYtHeartbeat() {
    _ytHeartbeat?.cancel();
    var tick = 0;
    _ytHeartbeat = Timer.periodic(const Duration(seconds: 1), (_) async {
      final c = _ytController;
      if (!_ytIsHost || c == null || !c.isReady || _ytVideoId == null) return;
      final pos = await c.currentTime();
      if (!mounted) return;
      if (!_ytSeeking) setState(() => _ytPosition = pos);
      if (_ytDuration == 0) {
        final d = await c.duration();
        if (mounted && d > 0) setState(() => _ytDuration = d);
      }
      if (++tick % 4 == 0) _broadcastYt(); // network heartbeat every ~4s
    });
  }

  void _ytTogglePlay() {
    setState(() => _ytPlaying = !_ytPlaying);
    final c = _ytController;
    unawaited(_ytPlaying ? c?.play() : c?.pause());
    _broadcastYt();
  }

  void _ytSeekTo(double pos) {
    setState(() {
      _ytPosition = pos;
      _ytSeeking = false;
    });
    unawaited(_ytController?.seek(pos));
    _broadcastYt();
  }

  void _toggleYtMute() {
    setState(() => _ytMuted = !_ytMuted);
    unawaited(_ytController?.setMuted(_ytMuted));
  }

  /// Local close — stops watching for me only; others keep going.
  void _closeYtLocal() {
    _ytHeartbeat?.cancel();
    _ytHeartbeat = null;
    setState(() {
      _ytHidden = true;
      _ytController = null;
    });
  }

  /// Re-mounts my player after a local close, resuming near the last position.
  void _rejoinYt() {
    _ytController = _newYtController();
    setState(() => _ytHidden = false);
    if (_ytIsHost) _startYtHeartbeat();
  }

  /// Full teardown (I left voice, or the host ended it).
  void _endWatchParty() {
    _ytHeartbeat?.cancel();
    _ytHeartbeat = null;
    _ytController = null;
    _ytSharedTo = {};
    _ytVideoId = null;
    _ytHostHex = '';
    _ytIsHost = false;
    _ytPlaying = false;
    _ytHidden = false;
    if (mounted) setState(() {});
  }

  /// Ends the party for me if its host has left the voice call.
  void _pruneWatchParty() {
    final voice = _voice;
    if (voice == null || _ytVideoId == null || _ytIsHost) return;
    if (!voice.peerHexes.contains(_ytHostHex)) _endWatchParty();
  }

  /// While hosting, re-broadcast to voice peers that have joined since.
  void _reannounceYtToNewPeers() {
    final voice = _voice;
    if (voice == null || !_ytIsHost || _ytVideoId == null) return;
    final current = voice.peerHexes.toSet();
    if (current.difference(_ytSharedTo).isEmpty) return;
    _ytSharedTo = current;
    _broadcastYt();
  }

  String _fmtTime(double seconds) {
    final s = seconds.isFinite && seconds > 0 ? seconds.round() : 0;
    final sec = (s % 60).toString().padLeft(2, '0');
    return '${s ~/ 60}:$sec';
  }

  /// The right-hand **channel control panel** — channel-scoped actions (invite,
  /// voice) and, in a call, the participants with live speaking indicators. A
  /// dedicated home for these controls, with room to grow.
  Widget _channelPanel(ChannelSession session) {
    final theme = Theme.of(context);
    final voice = _voice;
    final inCall = voice != null && voice.channelId == session.channelId;
    return Container(
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Row(
                  children: [
                    Icon(
                      session.isDm ? Icons.alternate_email : Icons.tag,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _channelTitle(session),
                        style: theme.textTheme.titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                if (!session.isDm) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => unawaited(_shareInvite(session.channelId)),
                    icon: const Icon(Icons.person_add_alt_1),
                    label: const Text('Invite'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => unawaited(_addMembers(session)),
                    icon: const Icon(Icons.group_add_outlined),
                    label: const Text('Add members'),
                  ),
                ],
                const Divider(height: 28),
                Text('VOICE', style: theme.textTheme.labelSmall),
                const SizedBox(height: 8),
                if (!inCall)
                  FilledButton.icon(
                    onPressed: () => unawaited(_joinVoice(session.channelId)),
                    icon: const Icon(Icons.call),
                    label: const Text('Join voice'),
                  )
                else ...[
                  Row(
                    children: [
                      IconButton(
                        onPressed: voice.toggleMute,
                        icon: Icon(voice.isMuted ? Icons.mic_off : Icons.mic),
                        tooltip: voice.isMuted ? 'Unmute' : 'Mute',
                      ),
                      IconButton(
                        onPressed: voice.toggleDeafen,
                        icon: Icon(
                          voice.isDeafened ? Icons.headset_off : Icons.headset,
                        ),
                        tooltip: voice.isDeafened ? 'Undeafen' : 'Deafen',
                      ),
                      if (defaultTargetPlatform == TargetPlatform.android ||
                          defaultTargetPlatform == TargetPlatform.iOS)
                        PopupMenuButton<String>(
                          icon: Icon(
                            _speakerOn
                                ? Icons.volume_up
                                : Icons.phone_in_talk,
                          ),
                          tooltip: 'Audio output',
                          onSelected: (value) async {
                            if (value == 'speaker') {
                              await Helper.setSpeakerphoneOn(true);
                              setState(() => _speakerOn = true);
                            } else if (value == 'earpiece') {
                              await Helper.setSpeakerphoneOn(false);
                              setState(() => _speakerOn = false);
                            } else if (value == 'bluetooth') {
                              await Helper
                                  .setSpeakerphoneOnButPreferBluetooth();
                              setState(() => _speakerOn = true);
                            }
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(
                              value: 'speaker',
                              child: ListTile(
                                dense: true,
                                leading: Icon(Icons.volume_up),
                                title: Text('Speaker'),
                              ),
                            ),
                            const PopupMenuItem(
                              value: 'earpiece',
                              child: ListTile(
                                dense: true,
                                leading: Icon(Icons.phone_in_talk),
                                title: Text('Earpiece'),
                              ),
                            ),
                            const PopupMenuItem(
                              value: 'bluetooth',
                              child: ListTile(
                                dense: true,
                                leading: Icon(Icons.bluetooth_audio),
                                title: Text('Bluetooth'),
                              ),
                            ),
                          ],
                        ),
                      if (_screenShareSupported)
                        IconButton(
                          onPressed: () {
                            if (_broadcast != null) {
                              unawaited(_stopScreenShare());
                            } else {
                              unawaited(_startScreenShare(session));
                            }
                          },
                          icon: Icon(
                            _broadcast != null
                                ? Icons.stop_screen_share
                                : Icons.screen_share,
                          ),
                          color: _broadcast != null
                              ? theme.colorScheme.primary
                              : null,
                          tooltip: _broadcast != null
                              ? 'Stop sharing'
                              : 'Share screen',
                        ),
                      const Spacer(),
                      IconButton(
                        onPressed: () => unawaited(_leaveVoice()),
                        icon: const Icon(Icons.call_end),
                        color: theme.colorScheme.error,
                        tooltip: 'Leave voice',
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  _participantTile(
                    voice,
                    'self',
                    widget.identity.publicKey,
                    voice.isMuted ? 'You (muted)' : 'You',
                  ),
                  for (final peerHex in voice.peerHexes)
                    _participantTile(
                      voice,
                      peerHex,
                      Uint8List.fromList(hex.decode(peerHex)),
                      _displayName(Uint8List.fromList(hex.decode(peerHex))),
                    ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => unawaited(_openVoiceSoundboard(session)),
                    icon: const Icon(Icons.library_music_outlined),
                    label: const Text('Soundboard'),
                  ),
                  if (_screenShareSupported) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () => unawaited(_startWatchParty(session)),
                      icon: const Icon(Icons.smart_display_outlined),
                      label: Text(
                        _ytVideoId == null ? 'Start a video' : 'Change video',
                      ),
                    ),
                  ],
                ],
                const Divider(height: 28),
                Text('MEMBERS', style: theme.textTheme.labelSmall),
                ..._membersList(session),
              ],
            ),
          ),
          if (!session.isDm)
            Container(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: theme.colorScheme.outlineVariant,
                    width: 0.5,
                  ),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: TextButton.icon(
                onPressed: () => unawaited(_leaveChannel(session.channelId)),
                icon: const Icon(Icons.logout, size: 16),
                label: const Text('Leave channel'),
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// One voice participant: avatar (green ring when speaking) + name + level
  /// bar. Tapping a peer opens their volume slider.
  Widget _participantTile(
    VoiceSession voice,
    String key,
    Uint8List author,
    String name,
  ) {
    final speaking = voice.speaking(key);
    return InkWell(
      onTap: key == 'self' ? null : () => unawaited(_peerVolume(key, name)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: speaking ? Colors.greenAccent : Colors.transparent,
                  width: 2,
                ),
              ),
              child: _avatar(author, radius: 14),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                name,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            SizedBox(
              width: 44,
              child: LinearProgressIndicator(
                value: (voice.levelOf(key) * 4).clamp(0.0, 1.0),
                minHeight: 4,
                backgroundColor: Colors.white24,
                color: Colors.greenAccent,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Per-user playback volume (0 mutes just that person).
  Future<void> _peerVolume(String peerHex, String name) async {
    final voice = _voice;
    if (voice == null) return;
    var volume = voice.volumeOf(peerHex);
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: Theme.of(context).textTheme.titleSmall),
                Row(
                  children: [
                    const Icon(Icons.volume_mute),
                    Expanded(
                      child: Slider(
                        value: volume,
                        onChanged: (v) {
                          setSheet(() => volume = v);
                          unawaited(voice.setVolume(peerHex, v));
                        },
                      ),
                    ),
                    const Icon(Icons.volume_up),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // --- contacts / DMs ---

  /// What to call someone: your petname, else their self-asserted (suggested)
  /// name, else their `hearth#fingerprint`.
  String _displayName(Uint8List author) {
    final key = hex.encode(author);
    return _contacts?.nameFor(key) ??
        _suggested[key] ??
        'hearth#${_fingerprint(author)}';
  }

  /// Prompts for a local petname for [author] and stores it.
  Future<void> _renameContact(Uint8List author) async {
    final key = hex.encode(author);
    final name = await _promptText(
      title: 'Name hearth#${_fingerprint(author)}',
      hint: 'petname (only you see this)',
      initial: _contacts?.nameFor(key) ?? _suggested[key] ?? '',
      action: 'Save',
    );
    if (name == null) return;
    await _contacts?.setName(key, name);
    if (mounted) setState(() {});
  }

  /// Tapped a peer's name: offer to DM them or give them a local name.
  Future<void> _peerActions(Uint8List author) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.alternate_email),
              title: const Text('Message privately'),
              onTap: () => Navigator.pop(context, 'dm'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Set a name'),
              onTap: () => Navigator.pop(context, 'name'),
            ),
          ],
        ),
      ),
    );
    if (action == 'dm') {
      await _channels?.openDm(author);
    } else if (action == 'name') {
      await _renameContact(author);
    }
  }

  /// Picks one of your contacts and opens an encrypted DM. You can only DM people
  /// you've added (by naming them) — there's no directory of all users.
  Future<void> _newDm() async {
    final contacts = _contacts?.entries() ?? const <String, String>{};
    if (contacts.isEmpty) {
      if (mounted) {
        setState(
          () => _error = "no contacts yet — tap someone's name to add them",
        );
      }
      return;
    }
    final chosenHex = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Message a contact'),
            ),
            for (final entry in contacts.entries)
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(entry.value),
                onTap: () => Navigator.pop(context, entry.key),
              ),
          ],
        ),
      ),
    );
    if (chosenHex != null) {
      await _channels?.openDm(hex.decode(chosenHex));
    }
  }

  /// Full contacts management view: list, rename, remove, DM, or invite to a
  /// channel.
  Future<void> _openContacts() async {
    final contacts = _contacts;
    if (contacts == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => _ContactsPage(
          contacts: contacts,
          groups: _groups,
          identity: widget.identity,
          onlinePeers: _allOnlinePeers(),
          lastSeen: _computeLastSeen(),
          onDm: (pubkeyHex) async {
            await _channels?.openDm(hex.decode(pubkeyHex));
            if (mounted) setState(() {});
          },
          onInvite: (pubkeyHex, channelId) {
            final channel = _groups[channelId];
            if (channel == null) return;
            final invite = channel.invite(
              inviterPubkeyHex: widget.identity.publicKeyHex,
              inviterName: _myName,
              relayUrl: _relayUrl.toString(),
            );
            Clipboard.setData(ClipboardData(text: invite));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Invite copied — send it to them!'),
                behavior: SnackBarBehavior.floating,
              ),
            );
          },
          onRemove: (pubkeyHex) async {
            await contacts.setName(pubkeyHex, '');
            if (mounted) setState(() {});
          },
          onRename: (pubkeyHex) async {
            final name = await _promptText(
              title: 'Rename contact',
              hint: 'local petname',
              initial: contacts.nameFor(pubkeyHex) ?? '',
              action: 'Save',
            );
            if (name != null && name.trim().isNotEmpty) {
              await contacts.setName(pubkeyHex, name.trim());
              if (mounted) setState(() {});
            }
          },
        ),
      ),
    );
  }

  /// Offers to add the channel's members (those who've shared a name) to
  /// contacts with their suggested petnames — you tick who; nothing is added
  /// without confirming. [auto] (used right after joining) stays silent when
  /// there's no one new yet.
  Future<void> _addMembers(ChannelSession session, {bool auto = false}) async {
    final self = hex.encode(widget.identity.publicKey);
    final members = <String, String>{}; // pubkeyHex -> suggested name
    for (final message in session.repository.ordered()) {
      final key = hex.encode(message.author);
      if (key == self || _contacts?.nameFor(key) != null) continue;
      final suggested = _suggested[key];
      if (suggested != null) members[key] = suggested;
    }
    if (members.isEmpty) {
      if (!auto && mounted) {
        _setError('no new named members to add yet');
      }
      return;
    }
    final selected = {for (final key in members.keys) key: true};
    // One editable petname field per member, pre-filled with their suggestion —
    // so you can amend any name before adding.
    final names = {
      for (final entry in members.entries)
        entry.key: TextEditingController(text: entry.value),
    };
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => AlertDialog(
          title: const Text('Add members to contacts'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final key in members.keys)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Checkbox(
                          value: selected[key],
                          onChanged: (v) =>
                              setSheet(() => selected[key] = v ?? false),
                        ),
                        Expanded(
                          child: TextField(
                            controller: names[key],
                            decoration: InputDecoration(
                              isDense: true,
                              labelText:
                                  'hearth#${_fingerprint(Uint8List.fromList(hex.decode(key)))}',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Add selected'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true) {
      for (final key in members.keys) {
        final name = names[key]!.text.trim();
        if (selected[key] == true && name.isNotEmpty) {
          await _contacts?.setName(key, name);
        }
      }
      if (mounted) setState(() {});
    }
    for (final controller in names.values) {
      controller.dispose();
    }
  }

  /// A reusable single-field prompt.
  Future<String?> _promptText({
    required String title,
    required String hint,
    String initial = '',
    String action = 'OK',
  }) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(action),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  // --- view ---

  @override
  Widget build(BuildContext context) {
    // Gate: if a mandatory update was detected (startup or from a peer), block.
    if (_updateInfo != null) {
      return _forceUpdateScreen(context);
    }
    if (_relayBlocked) {
      return _relayBlockedScreen(context);
    }
    final session = _channels?.active;
    // Wide screens get the channel panel inline (right column); narrow screens
    // reach it via the end drawer.
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final panelInline = session != null && wide;
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(session == null ? 'Hearth' : _channelTitle(session)),
            Text(
              'hearth#${widget.identity.fingerprint}',
              key: const Key('identity-fingerprint'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          if (session != null && !wide)
            IconButton(
              onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
              icon: const Icon(Icons.people_outline),
              tooltip: 'Channel controls',
            ),
        ],
        bottom: _error == null ? null : _errorBar(context, _error!),
      ),
      onDrawerChanged: (open) {
        if (open) unawaited(_checkRelay());
      },
      drawer: _drawer(context),
      endDrawer: (session != null && !wide)
          ? Drawer(child: SafeArea(child: _channelPanel(session)))
          : null,
      body: session == null
          ? _emptyState(context)
          : Stack(
              children: [
                if (panelInline)
                  Row(
                    children: [
                      Expanded(child: _chatColumn(session)),
                      SizedBox(width: 300, child: _channelPanel(session)),
                    ],
                  )
                else
                  _chatColumn(session),
                // Hidden 1x1 sinks so the browser plays each remote's audio.
                for (final renderer
                    in _voice?.remoteRenderers ?? const <RTCVideoRenderer>[])
                  Positioned(
                    left: 0,
                    bottom: 0,
                    width: 1,
                    height: 1,
                    child: RTCVideoView(renderer),
                  ),
              ],
            ),
    );
  }

  Widget _chatColumn(ChannelSession session) {
    final stage = _screenStage(session);
    final watchParty = _watchPartyStage(session);
    return Column(
      children: [
        ?stage,
        ?watchParty,
        Expanded(
          child: Stack(
            children: [
              _messageList(context, session),
              if (_showScrollDown)
                Positioned(
                  bottom: 8,
                  right: 8,
                  child: FloatingActionButton.small(
                    onPressed: () => _scroll.animateTo(
                      _scroll.position.maxScrollExtent,
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                    ),
                    tooltip: 'Scroll to bottom',
                    child: const Icon(Icons.keyboard_arrow_down),
                  ),
                ),
            ],
          ),
        ),
        _typingIndicator(session),
        _composer(context, session),
      ],
    );
  }

  /// The shared YouTube "watch party" stage atop the chat: the synced player
  /// (host gets play/pause + a seek bar; everyone gets local mute + close), or a
  /// slim "rejoin" banner after a local close. Null when there's no party here.
  Widget? _watchPartyStage(ChannelSession session) {
    final voice = _voice;
    final videoId = _ytVideoId;
    if (voice == null ||
        voice.channelId != session.channelId ||
        videoId == null) {
      return null;
    }
    final theme = Theme.of(context);

    if (_ytHidden || _ytController == null) {
      return Container(
        margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          children: [
            Icon(
              Icons.smart_display_outlined,
              size: 16,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 8),
            const Expanded(child: Text('Watch party hidden')),
            TextButton(onPressed: _rejoinYt, child: const Text('Rejoin')),
          ],
        ),
      );
    }

    final hostName = _ytIsHost
        ? 'You'
        : _displayName(Uint8List.fromList(hex.decode(_ytHostHex)));

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
            child: Row(
              children: [
                Icon(
                  Icons.smart_display,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Watch party · $hostName',
                    style: theme.textTheme.labelLarge,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  onPressed: _toggleYtMute,
                  icon: Icon(_ytMuted ? Icons.volume_off : Icons.volume_up),
                  tooltip: _ytMuted ? 'Unmute video' : 'Mute video',
                  iconSize: 20,
                ),
                IconButton(
                  onPressed: _closeYtLocal,
                  icon: const Icon(Icons.close),
                  tooltip: 'Close video',
                  iconSize: 20,
                ),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: ColoredBox(
                color: Colors.black,
                child: WatchPartyPlayer(
                  key: ObjectKey(_ytController),
                  controller: _ytController!,
                  videoId: videoId,
                  startSeconds: _ytPosition,
                  startPlaying: _ytPlaying,
                  muted: _ytMuted,
                ),
              ),
            ),
          ),
          if (_ytIsHost)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  IconButton(
                    onPressed: _ytTogglePlay,
                    icon: Icon(_ytPlaying ? Icons.pause : Icons.play_arrow),
                    tooltip: _ytPlaying ? 'Pause' : 'Play',
                  ),
                  Expanded(
                    child: Slider(
                      value: _ytDuration > 0
                          ? _ytPosition.clamp(0, _ytDuration)
                          : 0,
                      max: _ytDuration > 0 ? _ytDuration : 1,
                      onChangeStart: _ytDuration > 0
                          ? (_) => _ytSeeking = true
                          : null,
                      onChanged: _ytDuration > 0
                          ? (v) => setState(() => _ytPosition = v)
                          : null,
                      onChangeEnd: _ytDuration > 0 ? _ytSeekTo : null,
                    ),
                  ),
                  Text(
                    _fmtTime(_ytPosition),
                    style: theme.textTheme.labelSmall,
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// The screen-share "stage" atop the chat: the selected incoming share (with a
  /// switcher when several are live) plus a banner when I'm sharing. Returns null
  /// when there's nothing to show for this channel's call.
  Widget? _screenStage(ChannelSession session) {
    final voice = _voice;
    if (voice == null || voice.channelId != session.channelId) return null;
    final broadcasting = _broadcast != null;
    final live = _screenViews.values.where((v) => v.hasVideo).toList();
    if (!broadcasting && live.isEmpty) return null;
    final theme = Theme.of(context);

    ScreenView? selected;
    final sel = _selectedShareHex;
    if (sel != null) {
      final v = _screenViews[sel];
      if (v != null && v.hasVideo) selected = v;
    }
    selected ??= live.isNotEmpty ? live.first : null;

    final headerText = selected != null
        ? '${_displayName(Uint8List.fromList(hex.decode(selected.sharerHex)))} is sharing'
        : broadcasting
        ? "You're sharing ${_broadcast!.sourceName}"
        : 'Screen share';

    return Container(
      margin: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
            child: Row(
              children: [
                Icon(
                  Icons.screen_share,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    headerText,
                    style: theme.textTheme.labelLarge,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (broadcasting)
                  TextButton.icon(
                    onPressed: () => unawaited(_stopScreenShare()),
                    icon: const Icon(Icons.stop_screen_share, size: 16),
                    label: const Text('Stop sharing'),
                  ),
              ],
            ),
          ),
          if (live.length > 1)
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  for (final v in live)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(
                          _displayName(
                            Uint8List.fromList(hex.decode(v.sharerHex)),
                          ),
                        ),
                        selected: v.sharerHex == selected?.sharerHex,
                        onSelected: (_) =>
                            setState(() => _selectedShareHex = v.sharerHex),
                      ),
                    ),
                ],
              ),
            ),
          if (selected != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: ColoredBox(
                  color: Colors.black,
                  child: RTCVideoView(
                    selected.renderer,
                    objectFit:
                        RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _messageList(BuildContext context, ChannelSession session) {
    final messages = session.repository.ordered().where((m) {
      final c = session.contentOf(m);
      return c is! ProfileContent && c is! SoundContent;
    }).toList();
    return messages.isEmpty
        ? const Center(child: Text('No messages yet — say something.'))
        : ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.all(8),
            itemCount: messages.length,
            itemBuilder: (context, i) {
              final msg = messages[i];
              return TweenAnimationBuilder<double>(
                key: ValueKey(msg.idHex),
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                builder: (context, value, child) => Opacity(
                  opacity: value,
                  child: Transform.translate(
                    offset: Offset(0, 12 * (1 - value)),
                    child: child,
                  ),
                ),
                child: _bubble(context, session, msg),
              );
            },
          );
  }

  Widget _forceUpdateScreen(BuildContext context) {
    final theme = Theme.of(context);
    // In-app install is only wired for Android + Windows; elsewhere the user
    // updates manually (web reloads; macOS/Linux fetch a build).
    final canInstall =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.windows);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.system_update,
                size: 64,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text('Update required', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                'Hearth v${_updateInfo!.version} is available. '
                '${canInstall ? "Install it to continue." : "Please update to continue."}',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'You are running ${appVersion == "dev" ? "a dev build" : "v$appVersion"}.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 24),
              if (_installing) ...[
                SizedBox(
                  width: 240,
                  child: LinearProgressIndicator(
                    value: (_updateProgress ?? 0) > 0 ? _updateProgress : null,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _updateProgress != null
                      ? 'Downloading ${(_updateProgress! * 100).round()}%…'
                      : 'Downloading…',
                  style: theme.textTheme.bodySmall,
                ),
              ] else if (canInstall) ...[
                FilledButton.icon(
                  onPressed: () => unawaited(_startInstall()),
                  icon: const Icon(Icons.download),
                  label: Text('Install v${_updateInfo!.version}'),
                ),
                if (_installError != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _installError!,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _startInstall() async {
    setState(() {
      _installing = true;
      _updateProgress = 0;
      _installError = null;
    });
    try {
      await downloadAndInstall(
        _updateInfo!,
        onProgress: (p) {
          if (mounted) setState(() => _updateProgress = p);
        },
      );
      // Windows relaunches via its helper (we never return here). Android opens
      // the system installer — leave the gate up until the user finishes.
    } catch (e) {
      if (mounted) {
        setState(() {
          _installing = false;
          _installError = 'Update failed: $e';
        });
      }
    }
  }

  /// Shown when a released build can't reach the relay to verify its version — a
  /// deliberate kill-switch while the project is private. Retry re-checks.
  Widget _relayBlockedScreen(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off, size: 64, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text('Connect to a relay', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                "Hearth can't reach a relay to check you're up to date. Connect to "
                'a relay to continue and pick up any update.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _relayUrl.toString(),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _checkingBlock
                    ? null
                    : () => unawaited(_retryRelayBlock()),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  final url = await _promptText(
                    title: 'Change relay',
                    hint: 'https://your-relay.example.com',
                    action: 'Connect',
                  );
                  if (url == null || url.trim().isEmpty) return;
                  var relayInput = url.trim();
                  if (relayInput.startsWith('http://')) {
                    _setError('HTTP is not supported — use HTTPS');
                    return;
                  }
                  if (!relayInput.startsWith('https://')) {
                    relayInput = 'https://$relayInput';
                  }
                  final parsed = Uri.tryParse(relayInput);
                  if (parsed == null || !parsed.hasScheme) {
                    _setError('Invalid URL');
                    return;
                  }
                  setState(() => _relayUrl = parsed);
                  await _settings?.setRelayUrl(relayInput);
                  unawaited(_retryRelayBlock());
                },
                icon: const Icon(Icons.edit),
                label: const Text('Change relay'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _retryRelayBlock() async {
    setState(() => _checkingBlock = true);
    await _checkRelay();
    await _checkUpdate();
    if (mounted) setState(() => _checkingBlock = false);
  }

  Widget _emptyState(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.8, end: 1.0),
            duration: const Duration(seconds: 2),
            curve: Curves.easeInOut,
            builder: (context, value, child) =>
                Transform.scale(scale: value, child: child),
            child: Icon(
              Icons.local_fire_department,
              size: 64,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 16),
          Text('Welcome to Hearth', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            'Create a channel, or join one with an invite.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () => unawaited(_createChannel()),
            icon: const Icon(Icons.add),
            label: const Text('Create a channel'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => unawaited(_joinViaInvite()),
            icon: const Icon(Icons.link),
            label: const Text('Join via invite'),
          ),
        ],
      ),
    );
  }

  Widget _drawer(BuildContext context) {
    final channels = _channels;
    final sessions = channels?.sessions.toList() ?? const <ChannelSession>[];
    final groups = sessions.where((s) => !s.isDm);
    final dms = sessions.where((s) => s.isDm);
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  _brandHeader(),
                  _drawerHeader('Channels'),
                  for (final s in groups)
                    ListTile(
                      leading: const Icon(Icons.tag),
                      title: Text(_channelTitle(s)),
                      selected: s.channelId == channels?.activeId,
                      trailing: _unreadBadge(s),
                      onTap: () {
                        channels?.activate(s.channelId);
                        _markRead(s);
                        Navigator.pop(context);
                      },
                    ),
                  ListTile(
                    leading: const Icon(Icons.add),
                    title: const Text('Create a channel'),
                    onTap: () {
                      Navigator.pop(context);
                      unawaited(_createChannel());
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.link),
                    title: const Text('Join via invite'),
                    onTap: () {
                      Navigator.pop(context);
                      unawaited(_joinViaInvite());
                    },
                  ),
                  _drawerHeader('Direct messages'),
                  ListTile(
                    leading: const Icon(Icons.add),
                    title: const Text('New message'),
                    onTap: () {
                      Navigator.pop(context);
                      unawaited(_newDm());
                    },
                  ),
                  for (final s in dms)
                    ListTile(
                      leading: const Icon(Icons.alternate_email),
                      title: Text(_channelTitle(s)),
                      selected: s.channelId == channels?.activeId,
                      trailing: _unreadBadge(s),
                      onTap: () {
                        channels?.activate(s.channelId);
                        _markRead(s);
                        Navigator.pop(context);
                      },
                    ),
                  _drawerHeader('Contacts'),
                  ListTile(
                    leading: const Icon(Icons.people_outline),
                    title: const Text('Manage contacts'),
                    trailing: Text(
                      '${_contacts?.entries().length ?? 0}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      unawaited(_openContacts());
                    },
                  ),
                  const Divider(height: 24),
                ],
              ),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.settings_outlined, size: 20),
              title: const Text('Settings'),
              onTap: () {
                Navigator.pop(context);
                unawaited(_openSettings());
              },
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.code, size: 20),
              title: const Text('Source code'),
              subtitle: Text(
                'AGPL-3.0 · ${appVersion == 'dev' ? 'dev build' : 'v$appVersion'}',
              ),
              trailing: _connectionIndicator(),
              onTap: () => unawaited(_openSourceCode()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _brandHeader() {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => unawaited(_setMyName()),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              theme.colorScheme.primaryContainer,
              theme.colorScheme.surfaceContainerLowest,
            ],
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.local_fire_department,
              color: theme.colorScheme.primary,
              size: 28,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Hearth', style: theme.textTheme.titleLarge),
                  Text(
                    _myName ?? 'Tap to set your name',
                    style: theme.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    appVersion == 'dev' ? 'dev build' : 'v$appVersion',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.6,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.edit_outlined,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  void _markRead(ChannelSession session) {
    final ordered = session.repository.ordered();
    if (ordered.isNotEmpty) {
      _unread?.markRead(session.channelId, ordered.last.idHex);
    }
  }

  Widget? _unreadBadge(ChannelSession session) {
    final unread = _unread;
    if (unread == null) return null;
    final ids = session.repository.ordered().map((m) => m.idHex).toList();
    final count = unread.unreadCount(session.channelId, ids);
    if (count <= 0) return null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: TextStyle(
          color: Theme.of(context).colorScheme.onPrimary,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _drawerHeader(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    child: Text(title, style: Theme.of(context).textTheme.titleSmall),
  );

  /// Renders a message's content — text, an inline GIF, a sticker, or a sound.
  /// True if [text] is 1–3 emoji with no other characters.
  bool _isSingleEmoji(String text) {
    final t = text.trim();
    if (t.isEmpty || t.length > 20) return false; // fast bail
    final chars = t.characters;
    if (chars.length > 3) return false;
    // Every grapheme cluster must start in an emoji-range codepoint.
    return chars.every((c) => c.runes.first > 0x2000);
  }

  Widget _contentView(
    BuildContext context,
    ChannelSession session,
    Content content,
  ) {
    return switch (content) {
      TextContent(:final text) =>
        _isSingleEmoji(text)
            ? Text(text, style: const TextStyle(fontSize: 48))
            : Text(text),
      GifContent(:final blob) => _imageBlobView(session, blob),
      StickerContent(:final blob) => _imageBlobView(session, blob),
      SoundContent(:final blob, :final name, :final emoji) => _soundView(
        session,
        blob,
        name,
        emoji,
      ),
      FileContent(:final blob, :final name, :final mime) =>
        mime.startsWith('image/')
            ? _imageBlobView(session, blob)
            : _isDangerousFile(name)
            ? Chip(
                avatar: Icon(
                  Icons.warning_amber,
                  size: 18,
                  color: Theme.of(context).colorScheme.error,
                ),
                label: Text(
                  '$name (blocked)',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              )
            : _fileChip(name),
      // Profile claims aren't shown in the timeline (filtered in _messageList).
      ProfileContent() => const SizedBox.shrink(),
    };
  }

  /// A non-image file attachment shown as a labelled chip.
  Widget _fileChip(String name) => Chip(
    avatar: const Icon(Icons.insert_drive_file_outlined, size: 18),
    label: Text(name),
  );

  /// An image blob — sticker or GIF — once fetched (spinner until then).
  /// Image.memory animates GIFs.
  Widget _imageBlobView(ChannelSession session, String blob) {
    final bytes = session.blobOf(blob);
    if (bytes == null) {
      return const SizedBox(
        width: 120,
        height: 120,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220, maxWidth: 260),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(bytes, fit: BoxFit.contain),
      ),
    );
  }

  /// A soundboard clip — emoji icon + name, tap to play (once its blob is in).
  Widget _soundView(
    ChannelSession session,
    String blob,
    String name,
    String emoji,
  ) {
    return ActionChip(
      avatar: Text(emoji, style: const TextStyle(fontSize: 16)),
      label: Text(name),
      onPressed: () => unawaited(_playSound(session, blob)),
    );
  }

  /// The channel's soundboard: its distinct sound clips, newest first.
  List<SoundContent> _channelSounds(ChannelSession session) {
    final seen = <String>{};
    final sounds = <SoundContent>[];
    for (final message in session.repository.ordered()) {
      final content = session.contentOf(message);
      if (content is SoundContent &&
          content.blob.isNotEmpty &&
          seen.add(content.blob)) {
        sounds.add(content);
      }
    }
    return sounds.reversed.toList();
  }

  /// Opens the soundboard from the voice panel — playing a clip broadcasts it
  /// to all voice participants via a control frame.
  Future<void> _openVoiceSoundboard(ChannelSession session) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        final sounds = _channelSounds(session);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Soundboard',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'Plays for everyone in voice',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                if (sounds.isEmpty)
                  const Text('No sounds yet — add one below.')
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final sound in sounds)
                        ActionChip(
                          avatar: Text(
                            sound.emoji,
                            style: const TextStyle(fontSize: 16),
                          ),
                          label: Text(sound.name),
                          onPressed: () {
                            unawaited(_playSoundToVoice(session, sound.blob));
                          },
                        ),
                    ],
                  ),
                const Divider(height: 24),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        unawaited(_searchSound());
                      },
                      icon: const Icon(Icons.search, size: 18),
                      label: const Text('Search'),
                    ),
                    TextButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        unawaited(_sendSound());
                      },
                      icon: const Icon(Icons.upload_file_outlined, size: 18),
                      label: const Text('Upload'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Plays a sound locally AND broadcasts it to voice peers.
  Future<void> _playSoundToVoice(ChannelSession session, String blob) async {
    // Play locally (fire-and-forget).
    unawaited(_playSound(session, blob));
    // Broadcast to voice peers via the voice mesh.
    _voice?.sendControl(SoundboardControl(blob: blob));
  }

  /// A deterministic warm colour per person, derived from their pubkey.
  Color _userColor(Uint8List author) {
    final hue = (author.isNotEmpty ? author[0] : 0) * 360.0 / 256.0;
    return HSLColor.fromAHSL(1, hue, 0.5, 0.62).toColor();
  }

  /// A small colour-coded avatar (initial of the display name).
  Widget _avatar(Uint8List author, {double radius = 16}) {
    final label = _displayName(author).replaceFirst('hearth#', '');
    final initial = label.isEmpty ? '?' : label[0].toUpperCase();
    return CircleAvatar(
      radius: radius,
      backgroundColor: _userColor(author),
      child: Text(
        initial,
        style: TextStyle(
          fontSize: radius * 0.85,
          fontWeight: FontWeight.w600,
          color: Colors.black87,
        ),
      ),
    );
  }

  Widget _bubble(
    BuildContext context,
    ChannelSession session,
    Message message,
  ) {
    final mine = listEquals(message.author, widget.identity.publicKey);
    final scheme = Theme.of(context).colorScheme;
    const radius = Radius.circular(12);
    final bubble = Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.72,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: mine ? scheme.primaryContainer : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.only(
          topLeft: radius,
          topRight: radius,
          bottomLeft: mine ? radius : Radius.zero,
          bottomRight: mine ? Radius.zero : radius,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!mine)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                _displayName(message.author),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: _userColor(message.author),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          _contentView(context, session, session.contentOf(message)),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                _time(message.timestampMs),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontSize: 10,
                ),
              ),
            ),
          ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: mine
          ? Align(alignment: Alignment.centerRight, child: bubble)
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: () => unawaited(_peerActions(message.author)),
                  child: _avatar(message.author),
                ),
                const SizedBox(width: 8),
                Flexible(child: bubble),
              ],
            ),
    );
  }

  Widget _typingIndicator(ChannelSession session) {
    final typers = _channels?.typingPeers[session.channelId] ?? const {};
    if (typers.isEmpty) return const SizedBox.shrink();
    final names = typers
        .map(
          (hex) => _displayName(
            Uint8List.fromList(
              List.generate(
                hex.length ~/ 2,
                (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
              ),
            ),
          ),
        )
        .toList();
    final text = names.length == 1
        ? '${names[0]} is typing…'
        : '${names.join(", ")} are typing…';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontStyle: FontStyle.italic,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _composer(BuildContext context, ChannelSession session) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(color: scheme.outlineVariant, width: 0.5),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Row(
        children: [
          IconButton(
            onPressed: () => unawaited(_insertEmoji()),
            icon: const Icon(Icons.emoji_emotions_outlined),
            tooltip: 'Emoji',
            focusNode: FocusNode(skipTraversal: true),
          ),
          IconButton(
            onPressed: () => unawaited(_sendGif()),
            icon: const Icon(Icons.gif_box_outlined),
            tooltip: 'GIF',
            focusNode: FocusNode(skipTraversal: true),
          ),
          IconButton(
            onPressed: () => unawaited(_sendSticker()),
            icon: const Icon(Icons.image_outlined),
            tooltip: 'Sticker',
            focusNode: FocusNode(skipTraversal: true),
          ),
          IconButton(
            onPressed: () => unawaited(_sendFile()),
            icon: const Icon(Icons.attach_file),
            tooltip: 'Attach file',
            focusNode: FocusNode(skipTraversal: true),
          ),
          Expanded(
            child: _composerOnFire
                ? _FlameBox(
                    child: TextField(
                      controller: _input,
                      focusNode: _composerFocus,
                      onSubmitted: (_) {
                        unawaited(_send());
                        _composerFocus.requestFocus();
                      },
                      decoration: InputDecoration(
                        hintText: 'Message ${_channelTitle(session)}',
                        filled: true,
                        fillColor: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                    ),
                  )
                : TextField(
                    controller: _input,
                    focusNode: _composerFocus,
                    onSubmitted: (_) {
                      unawaited(_send());
                      _composerFocus.requestFocus();
                    },
                    decoration: InputDecoration(
                      hintText: 'Message ${_channelTitle(session)}',
                      filled: true,
                      fillColor: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                    ),
                  ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: _sending ? null : () => unawaited(_send()),
            icon: const Icon(Icons.send),
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _errorBar(BuildContext context, String text) {
    return PreferredSize(
      preferredSize: const Size.fromHeight(22),
      child: Container(
        width: double.infinity,
        color: Theme.of(context).colorScheme.errorContainer,
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(text, textAlign: TextAlign.center),
      ),
    );
  }
}

/// First 4 bytes of a public key as hex — the short author label.
String _fingerprint(Uint8List key) =>
    key.sublist(0, 4).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// A message's local send time as `HH:mm`.
String _time(int millis) {
  final t = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
  return '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';
}

/// Standalone contacts management page.
class _ContactsPage extends StatefulWidget {
  const _ContactsPage({
    required this.contacts,
    required this.groups,
    required this.identity,
    required this.onlinePeers,
    required this.lastSeen,
    required this.onDm,
    required this.onInvite,
    required this.onRemove,
    required this.onRename,
  });

  final ContactBook contacts;
  final Map<String, GroupChannel> groups;
  final Identity identity;
  final Set<String> onlinePeers;
  final Map<String, int> lastSeen; // pubkeyHex -> epoch ms
  final Future<void> Function(String pubkeyHex) onDm;
  final void Function(String pubkeyHex, String channelId) onInvite;
  final Future<void> Function(String pubkeyHex) onRemove;
  final Future<void> Function(String pubkeyHex) onRename;

  @override
  State<_ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends State<_ContactsPage> {
  String _formatLastSeen(int? ms) {
    if (ms == null || ms == 0) return 'Offline';
    final ago = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(ms),
    );
    if (ago.inMinutes < 1) return 'Last seen just now';
    if (ago.inHours < 1) return 'Last seen ${ago.inMinutes}m ago';
    if (ago.inDays < 1) return 'Last seen ${ago.inHours}h ago';
    if (ago.inDays < 7) return 'Last seen ${ago.inDays}d ago';
    return 'Last seen over a week ago';
  }

  @override
  Widget build(BuildContext context) {
    final selfHex = widget.identity.publicKeyHex;
    final entries = Map.of(widget.contacts.entries())..remove(selfHex);
    final myName = widget.contacts.nameFor(selfHex);
    return Scaffold(
      appBar: AppBar(title: const Text('Contacts')),
      body: Column(
        children: [
          // Your profile card.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  child: const Icon(Icons.person, color: Colors.white),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      myName ?? 'You',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      'hearth#${selfHex.substring(0, 8)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: entries.isEmpty
                ? const Center(
                    child: Text(
                      "No contacts yet — tap someone's name in a chat to add them.",
                    ),
                  )
                : ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (context, i) {
                      final pubkeyHex = entries.keys.elementAt(i);
                      final name = entries.values.elementAt(i);
                      final online = widget.onlinePeers.contains(pubkeyHex);
                      return ListTile(
                        leading: Stack(
                          children: [
                            CircleAvatar(child: Text(name[0].toUpperCase())),
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: online ? Colors.green : Colors.grey,
                                  border: Border.all(
                                    color: Theme.of(
                                      context,
                                    ).scaffoldBackgroundColor,
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        title: Text(name),
                        subtitle: Text(
                          online
                              ? 'Online'
                              : _formatLastSeen(widget.lastSeen[pubkeyHex]),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: online ? Colors.green : null),
                        ),
                        trailing: PopupMenuButton<String>(
                          onSelected: (action) => _onAction(action, pubkeyHex),
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'dm',
                              child: Text('Direct message'),
                            ),
                            PopupMenuItem(
                              value: 'invite',
                              child: Text('Invite to channel'),
                            ),
                            PopupMenuItem(
                              value: 'rename',
                              child: Text('Rename'),
                            ),
                            PopupMenuItem(
                              value: 'remove',
                              child: Text('Remove'),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _onAction(String action, String pubkeyHex) async {
    switch (action) {
      case 'dm':
        await widget.onDm(pubkeyHex);
        if (mounted) Navigator.pop(context);
      case 'invite':
        await _pickChannelAndInvite(pubkeyHex);
      case 'rename':
        await widget.onRename(pubkeyHex);
        if (mounted) setState(() {});
      case 'remove':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Remove contact?'),
            content: const Text('You can always add them again later.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Remove'),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          await widget.onRemove(pubkeyHex);
          if (mounted) setState(() {});
        }
    }
  }

  Future<void> _pickChannelAndInvite(String pubkeyHex) async {
    final groups = widget.groups;
    if (groups.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No channels to invite to.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final channelId = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Invite to which channel?'),
            ),
            for (final entry in groups.entries)
              ListTile(
                leading: const Icon(Icons.tag),
                title: Text(entry.value.name),
                onTap: () => Navigator.pop(context, entry.key),
              ),
          ],
        ),
      ),
    );
    if (channelId != null) widget.onInvite(pubkeyHex, channelId);
  }
}

/// Wraps a child in an animated flame effect around the perimeter.
class _FlameBox extends StatefulWidget {
  const _FlameBox({required this.child});
  final Widget child;

  @override
  State<_FlameBox> createState() => _FlameBoxState();
}

class _FlameBoxState extends State<_FlameBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) => CustomPaint(
        foregroundPainter: _FlamePainter(_ctrl.value),
        child: child,
      ),
      child: widget.child,
    );
  }
}

class _FlamePainter extends CustomPainter {
  _FlamePainter(this.phase);
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rng = phase * 2 * pi;

    // Organic flame tongues around the perimeter — varied sizes, bezier shapes.
    const count = 32;
    final perimeter = 2 * (size.width + size.height);
    for (var i = 0; i < count; i++) {
      final t = i / count;
      // Each flame has its own frequency + phase offset for organic motion.
      final f1 = sin(t * 17.3 + rng * 2.1) * 0.5 + 0.5;
      final f2 = sin(t * 11.7 + rng * 1.7 + 1.3) * 0.5 + 0.5;
      final height = 6.0 + f1 * 14.0 + f2 * 6.0;
      final width = 3.0 + f2 * 4.0;
      final opacity = 0.5 + f1 * 0.4;

      // Position along perimeter.
      final d = t * perimeter;
      late Offset pos;
      late Offset dir;

      if (d < size.width) {
        pos = Offset(d, 0);
        dir = const Offset(0, -1);
      } else if (d < size.width + size.height) {
        pos = Offset(size.width, d - size.width);
        dir = const Offset(1, 0);
      } else if (d < 2 * size.width + size.height) {
        pos = Offset(size.width - (d - size.width - size.height), size.height);
        dir = const Offset(0, 1);
      } else {
        pos = Offset(0, size.height - (d - 2 * size.width - size.height));
        dir = const Offset(-1, 0);
      }

      final perp = Offset(-dir.dy, dir.dx);
      final tip = pos + dir * height;
      final cp1 = pos + dir * (height * 0.6) + perp * (width * 1.2);
      final cp2 = pos + dir * (height * 0.6) - perp * (width * 1.2);

      // Bezier flame shape — smooth organic curve.
      final path = Path()
        ..moveTo(pos.dx - perp.dx * width * 0.5, pos.dy - perp.dy * width * 0.5)
        ..cubicTo(
          cp1.dx,
          cp1.dy,
          tip.dx + perp.dx * 0.5,
          tip.dy + perp.dy * 0.5,
          tip.dx,
          tip.dy,
        )
        ..cubicTo(
          tip.dx - perp.dx * 0.5,
          tip.dy - perp.dy * 0.5,
          cp2.dx,
          cp2.dy,
          pos.dx + perp.dx * width * 0.5,
          pos.dy + perp.dy * width * 0.5,
        )
        ..close();

      // Warm gradient: red core → orange → yellow tip.
      final color = Color.lerp(
        Color.lerp(Colors.red[700], Colors.deepOrange, f1)!,
        Colors.yellow[600],
        f2 * 0.6,
      )!.withValues(alpha: opacity);

      canvas.drawPath(path, Paint()..color = color);
    }

    // Warm glow border.
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(24)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..shader = LinearGradient(
          colors: [
            Colors.orange.withValues(alpha: 0.9),
            Colors.yellow.withValues(alpha: 0.7),
            Colors.deepOrange.withValues(alpha: 0.9),
          ],
        ).createShader(rect),
    );

    // Outer glow (soft bloom).
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.inflate(3), const Radius.circular(27)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4)
        ..color = Colors.orange.withValues(alpha: 0.3 + sin(rng) * 0.1),
    );
  }

  @override
  bool shouldRepaint(_FlamePainter old) => old.phase != phase;
}

/// Full-screen camera scanner for QR identity restore (mobile only).
class _QrScanPage extends StatefulWidget {
  const _QrScanPage();
  @override
  State<_QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<_QrScanPage> {
  bool _scanned = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan recovery QR')),
      body: MobileScanner(
        onDetect: (capture) {
          if (_scanned) return;
          final code = capture.barcodes.firstOrNull?.rawValue;
          if (code != null && code.trim().isNotEmpty) {
            _scanned = true;
            Navigator.pop(context, code.trim());
          }
        },
      ),
    );
  }
}
