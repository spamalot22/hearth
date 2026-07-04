// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:animations/animations.dart';
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
import 'package:record/record.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import 'background_poll.dart';
import 'blob_store_hive.dart';
import 'candidate_cache.dart';
import 'channel.dart';
import 'contact_card.dart';
import 'contacts.dart';
import 'content.dart';
import 'device_keys.dart';
import 'device_store.dart';
import 'emoji_picker.dart';
import 'gif_search.dart';
import 'group_channel.dart';
import 'inference_bot.dart';
import 'key_store.dart';
import 'markdown.dart';
import 'media_library.dart';
import 'mesh_control.dart';
import 'network_status.dart';
import 'notify.dart';
import 'profile.dart';
import 'rendezvous.dart';
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
final Uri kRelayUrl = Uri.parse(
  const String.fromEnvironment(
    'RELAY_URL',
    defaultValue: 'http://localhost:8787',
  ),
);

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

/// Android 13+ (API 33) requires an explicit runtime grant for POST_NOTIFICATIONS
/// — without it every notification (live and background_fetch) is silently
/// dropped. The permission is merged into the manifest by the plugin. Requested
/// once the UI is up (not before runApp, or it'd block the app behind a dialog).
Future<void> requestAndroidNotificationPermission() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  await _notifications
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.requestNotificationsPermission();
}

/// A stable, positive notification id for a conversation, so new messages in the
/// same group/DM replace that conversation's notification instead of stacking up
/// a new one per message.
int notificationIdFor(String threadId) => threadId.hashCode & 0x7fffffff;

/// Shows a local notification (desktop/Android, not web). When [threadId] (a
/// channel id) is given, the notification stacks per conversation: a stable id +
/// Android group so a group/DM shows one updating entry rather than one per
/// message, all collapsed under a single Hearth group in the shade.
Future<void> showLocalNotification(
  String title,
  String body, {
  String? threadId,
}) async {
  if (kIsWeb) {
    showWebNotification(title, body);
    return;
  }
  final id = threadId != null ? notificationIdFor(threadId) : _notificationId++;
  await _notifications.show(
    id: id,
    title: title,
    body: body,
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails(
        'hearth_messages',
        'Messages',
        importance: Importance.high,
        groupKey: 'com.hearth.app.messages',
      ),
      windows: WindowsNotificationDetails(),
    ),
  );
}

int _notificationId = 0;
bool _webNotifRequested = false;

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

/// Builds an sRGB [Color] from OKLCH (perceptual lightness `l` 0–1, chroma `c`,
/// hue `hDeg` in degrees). OKLCH is perceptually uniform, so equal hue steps look
/// equally spaced and a fixed `l` reads at a consistent brightness across every
/// hue — unlike HSL, where greens look far brighter than blues. This keeps the
/// per-user / per-channel colours harmonious and legible on the charcoal theme.
Color oklch(double l, double c, double hDeg) {
  final h = hDeg * pi / 180.0;
  final a = c * cos(h);
  final b = c * sin(h);
  // OKLab → LMS (cube roots), then LMS → linear sRGB.
  final l_ = l + 0.3963377774 * a + 0.2158037573 * b;
  final m_ = l - 0.1055613458 * a - 0.0638541728 * b;
  final s_ = l - 0.0894841775 * a - 1.2914855480 * b;
  final lc = l_ * l_ * l_;
  final mc = m_ * m_ * m_;
  final sc = s_ * s_ * s_;
  final r = 4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc;
  final g = -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc;
  final bl = -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc;
  int chan(double x) {
    final v = x <= 0.0031308
        ? 12.92 * x
        : 1.055 * pow(x, 1 / 2.4).toDouble() - 0.055;
    return (v.clamp(0.0, 1.0) * 255).round();
  }

  return Color.fromARGB(255, chan(r), chan(g), chan(bl));
}

/// Test-only seam: lets a widget test simulate a peer's frames arriving (a mesh
/// control, or a received message) without a real WebRTC peer, so two-peer
/// receive-and-render behaviour (read-receipt ticks, block redaction) can be
/// driven. Bound by [ChatScreen] once its state is live.
@visibleForTesting
class HearthTestApi {
  /// Delivers a control as if it arrived from peer [fromHex] over the mesh.
  late void Function(String fromHex, String channelId, MeshControl control)
  injectControl;

  /// The active channel session (for its cipher, repository, publish).
  late ChannelSession? Function() activeChannel;

  /// Re-decrypts + re-renders the active channel (call after injecting a message).
  late Future<void> Function() refresh;

  /// Accepts a `hearth-contact:` card as if scanned/pasted, so the DM-bootstrap
  /// wiring (add contact + openDm) can be driven without the paste dialog or a
  /// live relay. Returns false if the string isn't a valid card.
  late Future<bool> Function(String code) acceptCard;

  /// Simulates someone reaching your card's rendezvous (owner side), so the
  /// incoming message-request gate can be driven without a live mesh.
  late Future<void> Function(String peerHex) simulateIncomingContact;
}

/// The Hearth theme for a given [brightness] — the ember seed with warm surfaces
/// (charcoal in dark, parchment in light) so both modes feel fireside.
ThemeData hearthTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xFFF2792B), // ember
        brightness: brightness,
      ).copyWith(
        surface: dark ? const Color(0xFF1C1714) : const Color(0xFFFBF6F0),
        surfaceContainerLowest: dark ? const Color(0xFF120E0B) : Colors.white,
        surfaceContainerLow: dark
            ? const Color(0xFF1C1714)
            : const Color(0xFFF6EFE7),
        surfaceContainer: dark
            ? const Color(0xFF221B16)
            : const Color(0xFFF1E8DD),
        surfaceContainerHigh: dark
            ? const Color(0xFF2A221B)
            : const Color(0xFFEBE0D3),
        surfaceContainerHighest: dark
            ? const Color(0xFF342A21)
            : const Color(0xFFE3D6C6),
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark
        ? const Color(0xFF16110D)
        : const Color(0xFFFDF9F3),
    appBarTheme: const AppBarTheme(
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 2,
    ),
  );
}

class HearthApp extends StatefulWidget {
  const HearthApp({
    required this.keyStore,
    this.relayUrl,
    this.autoPoll = true,
    this.testApi,
    super.key,
  });

  final KeyStore keyStore;
  final Uri? relayUrl;

  /// Disabled in widget tests so there's no background polling timer.
  final bool autoPoll;

  /// Test-only seam for injecting simulated peer frames. Null in production.
  final HearthTestApi? testApi;

  @override
  State<HearthApp> createState() => _HearthAppState();
}

class _HearthAppState extends State<HearthApp> {
  // Dark by default (the fireside identity); user can switch to light/system.
  final ValueNotifier<ThemeMode> _themeMode = ValueNotifier(ThemeMode.dark);

  @override
  void initState() {
    super.initState();
    if (widget.autoPoll) unawaited(_loadThemeMode());
  }

  Future<void> _loadThemeMode() async {
    try {
      final settings = await SettingsStore.open();
      _themeMode.value = switch (settings.themeMode) {
        'light' => ThemeMode.light,
        'system' => ThemeMode.system,
        _ => ThemeMode.dark,
      };
    } catch (_) {}
  }

  @override
  void dispose() {
    _themeMode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: _themeMode,
      builder: (context, mode, _) => MaterialApp(
        title: 'Hearth',
        debugShowCheckedModeBanner: false,
        theme: hearthTheme(Brightness.light),
        darkTheme: hearthTheme(Brightness.dark),
        themeMode: mode,
        home: _Bootstrap(
          keyStore: widget.keyStore,
          relayUrl: widget.relayUrl ?? kRelayUrl,
          autoPoll: widget.autoPoll,
          testApi: widget.testApi,
          themeMode: _themeMode,
        ),
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
    this.testApi,
    this.themeMode,
  });

  final KeyStore keyStore;
  final Uri relayUrl;
  final bool autoPoll;
  final HearthTestApi? testApi;
  final ValueNotifier<ThemeMode>? themeMode;

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  late final Future<(Identity, DeviceKeys)> _boot = _load();

  Future<(Identity, DeviceKeys)> _load() async {
    final deviceStore = widget.keyStore is SecureKeyStore
        ? SecureKeyStore(seedKey: 'hearth.device.seed')
        : InMemoryKeyStore();

    // Try loading the root seed (Phase A compat / fresh install that hasn't
    // migrated). If it exists, boot with full root signing.
    final rootSeed = await widget.keyStore.readSeed();
    if (rootSeed != null) {
      final root = await Identity.fromSeed(rootSeed);
      final device = await DeviceKeys.loadOrCreate(root, deviceStore);
      return (root, device);
    }

    // No root seed persisted — check if we have a device key + cert (enrolled
    // device in offline-root mode).
    final devSeed = await deviceStore.readSeed();
    if (devSeed != null) {
      final device = await Identity.fromSeed(devSeed);
      // Load the cert from the device store to get the root pubkey.
      final ds = await DeviceStore.open();
      final cert = ds.certs
          .where((c) => c.deviceKeyHex == device.publicKeyHex)
          .firstOrNull;
      if (cert != null) {
        final rootPub = Identity.fromPublicKey(cert.rootKey);
        return (rootPub, DeviceKeys(device, cert));
      }
    }

    // Nothing at all — first boot. Generate a new root identity, show the
    // recovery phrase, enroll this device, then persist only the device key.
    // For now, fall through to the legacy path (generate + persist root).
    // The enrollment UI will handle discarding the root seed post-enrollment.
    final root = await Identity.loadOrCreate(widget.keyStore);
    final device = await DeviceKeys.loadOrCreate(root, deviceStore);
    return (root, device);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<(Identity, DeviceKeys)>(
      future: _boot,
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
        final (root, device) = snapshot.data!;
        return ChatScreen(
          identity: root,
          deviceKeys: device,
          relayUrl: widget.relayUrl,
          keyStore: widget.keyStore,
          autoPoll: widget.autoPoll,
          testApi: widget.testApi,
          themeMode: widget.themeMode,
        );
      },
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    required this.identity,
    required this.deviceKeys,
    required this.relayUrl,
    required this.keyStore,
    this.autoPoll = true,
    this.testApi,
    this.themeMode,
    super.key,
  });

  /// The root identity — the user's id (message authorship, DM keys, contacts).
  final Identity identity;

  /// This device's subkey + cert. Messages are authored by [identity] but
  /// signed by this device.
  final DeviceKeys deviceKeys;
  final Uri relayUrl;
  final KeyStore keyStore;
  final bool autoPoll;
  final HearthTestApi? testApi;
  final ValueNotifier<ThemeMode>? themeMode;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final TextEditingController _input = TextEditingController();
  final FocusNode _composerFocus = FocusNode();
  final ScrollController _scroll = ScrollController();
  bool _showScrollDown = false;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  ChannelManager? _channels;
  ContactBook? _contacts;
  ChannelRegistry? _registry;
  DmRegistry? _dms; // established DMs, restored on startup
  PendingContactStore? _pending; // outbound first-contacts not yet connected
  RequestStore? _reqStore; // inbound message requests awaiting accept
  // Peer hexes whose inbound DM is quarantined as a request (not yet accepted).
  final Set<String> _requests = {};
  RendezvousListener? _rendezvous; // my standing contact-card inbox
  // Joiner-side rendezvous meshes, keyed by the owner pubkey we're reaching —
  // torn down once their DM connects. Backed by [_pending] so they resume
  // across restarts until first contact lands or the entry expires.
  final Map<String, RendezvousListener> _pendingContact = {};
  BlobStore? _blobStore;
  MediaLibrary? _library;
  AudioPlayer? _player;
  VoiceSession? _voice;
  bool _speakerOn = true;
  // Voice presence: who's in voice per channel (learned via gossip mesh).
  final Map<String, Set<String>> _voicePresence = {}; // channelId -> peerHexes
  final Map<String, DateTime> _voicePresenceTs = {}; // peerHex -> last seen
  Timer? _voicePresenceTimer;
  Timer? _updateCheckTimer;
  // Read receipts: per-peer watermark (channelId -> (peerHex -> messageIdHex))
  final Map<String, Map<String, String>> _readWatermarks = {};
  final Set<String> _readReceiptsDisabled =
      {}; // DM channelIds with receipts off
  final Set<String> _mutedChannels =
      {}; // channels with notifications suppressed
  final Map<String, Set<String>> _pinnedMessages =
      {}; // channelId -> pinned msg IDs
  final Set<String> _blocked = {}; // globally blocked pubkey hexes
  final Set<String> _voiceMuted =
      {}; // per-session muted peers (cleared on leave)
  final Map<String, String> _lastBroadcastWatermark =
      {}; // channelId -> last sent
  // Cached watermark message timestamps for O(1) tick rendering.
  // channelId -> (messageIdHex -> timestampMs)
  final Map<String, Map<String, int>> _watermarkTs = {};
  final Map<String, int> _lastPeerCount = {}; // channelId -> last known peers
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
  DeviceStore? _deviceStore;
  late Uri _relayUrl = widget.relayUrl;
  bool? _relayUp; // null = not checked yet
  bool _checkingRelay = false;
  String? _myName;
  final Map<String, String> _suggested = {}; // pubkeyHex -> self-asserted name
  // pubkeyHex -> fetched avatar image bytes (from self-asserted profiles).
  final Map<String, Uint8List> _avatarBytes = {};
  // pubkeyHex -> (timestampMs, claimIdHex) of the profile claim applied.
  // Profiles arrive per channel, so without this an author's state would be
  // whatever their newest claim in the *most recently indexed* channel said.
  // The id tiebreak keeps equal-timestamp claims deterministic across devices.
  final Map<String, (int, String)> _profileClaim = {};
  String? _myAvatar; // my avatar's blob hash (rides in profile announcements)

  /// Largest avatar image we'll render from a peer. Senders downscale to
  /// ≤128px, but that's a courtesy — receivers must not decode a 10 MB blob
  /// into every message row just because a profile claims it's an avatar.
  static const int _maxAvatarBytes = 256 * 1024;
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
  Message? _replyTo; // message being replied to (shown above composer)
  Message? _editing; // own message being edited (composer sends an EditContent)
  AudioRecorder? _recorder; // voice-message capture (created on first use)
  DateTime? _recordStart; // non-null while recording (composer shows the bar)
  Timer? _recordTicker; // repaints the elapsed label once a second

  /// Persists relay state for the background fetch isolate.
  Future<void> _saveBackgroundState() async {
    final channels = _channels;
    if (channels == null) return;
    // Exclude muted channels — the background isolate has no mute list, so if we
    // handed them over it would notify for channels the user silenced.
    final sessions = channels.sessions
        .where((s) => !_mutedChannels.contains(s.channelId))
        .toList();
    // Seed each channel's cursor with the relay seq the foreground courier has
    // already reached, so the background poll only counts genuinely-new
    // messages (not the backlog, not anything already read in-app).
    final cursors = <String, int>{
      for (final s in sessions)
        if ((s.relaySince ?? 0) > 0) s.channelId: s.relaySince!,
    };
    // Channel id -> local name, so background notifications can label each group/DM.
    final names = <String, String>{
      for (final s in sessions) s.channelId: _channelTitle(s),
    };
    await saveBackgroundPollState(
      relayUrl: _relayUrl.toString(),
      channelIds: sessions.map((s) => s.channelId).toList(),
      cursors: cursors,
      names: names,
      selfAuthor: base64Url.encode(widget.identity.publicKey),
    );
  }

  void _setError(String msg) {
    _errorTimer?.cancel();
    setState(() => _error = msg);
    _errorTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _error = null);
    });
  }

  /// Copies [text] to the clipboard and auto-clears it after 30 seconds.
  void _copyAndClear(String text) {
    Clipboard.setData(ClipboardData(text: text));
    Future.delayed(const Duration(seconds: 30), () {
      // Clipboard.getData may throw on web (no user gesture for read access).
      Clipboard.getData('text/plain')
          .then((data) {
            if (data?.text == text) {
              Clipboard.setData(const ClipboardData(text: ''));
            }
          })
          .catchError((_) {});
    });
  }

  UpdateInfo? _updateInfo;
  double? _updateProgress;
  Offset _lastReactTap = Offset.zero; // where a quick-reaction was tapped
  bool _foreground =
      true; // app is focused → prefer in-app over OS notifications
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
    WidgetsBinding.instance.addObserver(this);
    _input.addListener(_onInputChanged);
    _scroll.addListener(_onScroll);
    widget.testApi
      ?..injectControl = _handleMeshControl
      ..activeChannel = (() => _channels?.active)
      ..refresh = _refresh
      ..acceptCard = ((code) async {
        final card = ContactCard.decode(code);
        if (card == null) return false;
        await _acceptContactCard(card);
        return true;
      })
      ..simulateIncomingContact = _onRendezvousContact;
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
    final dms = widget.autoPoll ? await DmRegistry.open() : null;
    final pending = widget.autoPoll ? await PendingContactStore.open() : null;
    final reqStore = widget.autoPoll ? await RequestStore.open() : null;
    final settings = widget.autoPoll ? await SettingsStore.open() : null;
    _settings = settings;
    if (settings != null) {
      _readReceiptsDisabled.addAll(settings.allReadReceiptsDisabled);
      _blocked.addAll(settings.blockedUsers);
      _mutedChannels.addAll(settings.channelIdsWithPref('muted'));
    }
    _unread = widget.autoPoll ? await UnreadStore.open() : null;
    if (widget.autoPoll) {
      _deviceStore = await DeviceStore.open();
      await _deviceStore!.addCert(widget.deviceKeys.cert);
      // Publish our device bundle (active device set) so peers can encrypt
      // DMs per-device. Re-published each boot in case devices were added/revoked.
      await _publishDeviceBundle();
    }
    if (widget.autoPoll) await initRecentGifs();
    if (!kIsWeb && widget.autoPoll && (settings?.contributeCompute ?? true)) {
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
    // Finish an update download that was interrupted by the app closing. If one
    // is still running, show the update gate + progress bar and track it.
    if (widget.autoPoll) {
      final resumed = await resumePendingUpdate();
      if (resumed != null && mounted) {
        setState(() {
          _updateInfo = resumed;
          _installing = true;
          _updateProgress = 0;
        });
        // Drive it to completion in the background (don't block init). On
        // failure, reset so the gate shows the Install button + error again.
        unawaited(
          attachPendingDownload(
            onProgress: (p) {
              if (mounted) setState(() => _updateProgress = p);
            },
          ).catchError((Object e) {
            if (mounted) {
              setState(() {
                _installing = false;
                _installError = 'Update failed: $e';
              });
            }
          }),
        );
      }
    }
    if (widget.autoPoll) await _checkUpdate();
    if (_updateInfo == null && widget.autoPoll) {
      _updateCheckTimer = Timer.periodic(
        const Duration(minutes: 30),
        (_) => unawaited(_checkUpdate()),
      );
    }
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
      meshIdentity: widget.deviceKeys.device,
      relayUrl: _relayUrl,
      fallbackUrls: (_settings?.fallbackRelays ?? []).map(Uri.parse).toList(),
      live: widget.autoPoll,
      onUpdate: _onUpdate,
      blobStore: blobStore,
      candidateCache: peerCache,
      onBackgroundMessage: _notifyBackground,
      onForceUpdate: (info) {
        if (mounted) setState(() => _updateInfo = info);
      },
      onInference: _handleMeshControl,
      onDmConnected: _onDmConnected,
      isBlocked: _blocked.contains,
      isDeviceRevoked: (hex) => _deviceStore?.isRevoked(hex) ?? false,
      peerBundleLookup: (rootHex) => _deviceStore?.bundleFor(rootHex),
      ownDeviceKeys: () {
        final store = _deviceStore;
        if (store == null) return [widget.deviceKeys.publicKey];
        final revoked = store.revokedDeviceKeys;
        return store.certs
            .where((c) => !revoked.contains(c.deviceKeyHex))
            .map((c) => c.deviceKey)
            .toList();
      },
    );
    for (final group in registry?.all() ?? const <GroupChannel>[]) {
      _groups[group.id] = group;
      await channels.openGroup(group.id, group.key);
    }
    // Restore established DMs (peers you've actually messaged) so they keep
    // receiving without a tap — the DM analogue of the group loop above.
    await _restoreDms(channels, dms);
    // Restore pending connection requests (pubkeys only — no DM is opened for a
    // request, so nothing can be received until you accept). Drop any that are
    // now blocked so a blocked pubkey can't linger in the requests list.
    _requests.addAll(
      (reqStore?.all() ?? const <String>[]).where((h) => !_blocked.contains(h)),
    );
    if (!mounted) {
      await channels.close();
      return;
    }
    setState(() {
      _contacts = contacts;
      _registry = registry;
      _dms = dms;
      _pending = pending;
      _reqStore = reqStore;
      _blobStore = blobStore;
      _library = library;
      _profile = profile;
      _myName = profile?.name;
      _myAvatar = profile?.avatar;
      // Auto-prune old blobs (> 30 days, except bookmarked media).
      if (blobStore is HiveBlobStore && library != null) {
        final keep = library.allHashes();
        unawaited(blobStore.prune(keep: keep));
      }
      _player = widget.autoPoll ? AudioPlayer() : null;
      _channels = channels;
    });
    // My avatar bytes live in the blob store — warm the render cache.
    final myAvatar = _myAvatar;
    if (myAvatar != null && blobStore != null) {
      final avatarBytes = await blobStore.get(myAvatar);
      if (avatarBytes != null && mounted) {
        setState(
          () => _avatarBytes[widget.identity.publicKeyHex] = avatarBytes,
        );
      }
    }
    // Mark all pre-existing channels as read so the drawer doesn't show stale
    // unread counts from history that was loaded before the user opened the app.
    for (final session in channels.sessions) {
      _markRead(session);
      // Load pinned messages for this channel.
      final pinsCsv = settings?.channelPref(session.channelId, 'pinned');
      if (pinsCsv != null && pinsCsv.isNotEmpty) {
        _pinnedMessages[session.channelId] = pinsCsv
            .split(',')
            .where((s) => s.isNotEmpty)
            .toSet();
      }
    }
    // Decrypt the active channel's loaded history: the onUpdate calls during the
    // open loop above ran before _channels was set, so they were no-ops.
    unawaited(_refresh());
    // Listen on my contact-card rendezvous so anyone I handed a card to can
    // reach me for first contact (see rendezvous.dart / contact_card.dart), and
    // resume outbound first-contacts that hadn't connected yet.
    if (widget.autoPoll && profile != null) {
      await profile.ensureRendezvousId(); // durably minted before any card
      _startRendezvous();
    }
    await _resumePendingContacts();
    // Background fetch: poll relay for notifications when app is backgrounded.
    unawaited(initBackgroundFetch());
    // Ask for the Android 13+ notification grant now the UI is up.
    if (widget.autoPoll) unawaited(requestAndroidNotificationPermission());
    unawaited(_saveBackgroundState());
  }

  void _onUpdate() {
    // Re-broadcast voice presence to newly-connected peers immediately.
    if (_voice != null) _broadcastVoicePresence(_voice!.channelId);
    // Re-broadcast read watermark only when peer count increased (new peer).
    final active = _channels?.active;
    if (active != null) {
      final peerCount = active.mesh?.peers.length ?? 0;
      final lastCount = _lastPeerCount[active.channelId] ?? 0;
      if (peerCount > lastCount) {
        final wm = _lastBroadcastWatermark[active.channelId];
        if (wm != null && !_readReceiptsDisabled.contains(active.channelId)) {
          active.broadcast(
            ReadWatermarkControl(channelId: active.channelId, messageId: wm),
          );
        }
      }
      _lastPeerCount[active.channelId] = peerCount;
    }
    unawaited(_refresh());
  }

  void _notifyBackground(String channelId) {
    if (!mounted) return;
    final session = _channels?.sessions
        .where((s) => s.channelId == channelId)
        .firstOrNull;
    // Suppress notifications for DMs from blocked users.
    if (session != null &&
        session.isDm &&
        session.peerPubkey != null &&
        _blocked.contains(hex.encode(session.peerPubkey!))) {
      return;
    }
    final channelName = session != null ? _channelTitle(session) : 'a channel';
    final isDm = session?.isDm ?? false;
    final selfHex = widget.identity.publicKeyHex;

    // Get sender name + message preview from the latest message.
    String sender = '';
    String preview = 'New message';
    var mentionsMe = false;
    if (session != null) {
      final ordered = session.repository.ordered();
      if (ordered.isNotEmpty) {
        final msg = ordered.last;
        final authorHex = hex.encode(msg.author);
        // Suppress notifications for blocked users in group channels.
        if (_blocked.contains(authorHex)) return;
        sender = _displayName(msg.author);
        final content = session.contentOf(msg);
        // Bookkeeping envelopes aren't "a new message" — don't notify.
        if (content.isBookkeeping) return;
        if (content is TextContent) {
          mentionsMe = mentionsPubkey(content.text, selfHex);
          final shown = stripMentions(content.text, _mentionLabel);
          preview = shown.length > 80 ? '${shown.substring(0, 80)}…' : shown;
        } else if (content is GifContent) {
          preview = 'sent a GIF';
        } else if (content is StickerContent) {
          preview = 'sent a sticker';
        } else if (content is SoundContent) {
          preview = '🔊 ${content.name}';
        } else if (content is FileContent) {
          preview = '📎 ${content.name}';
        } else if (content is VoiceContent) {
          preview = 'sent a voice message';
        }
      }
    }

    // Muted channels stay silent — unless you were @mentioned, which pierces.
    if (_mutedChannels.contains(channelId) && !mentionsMe) return;

    final title = isDm
        ? (sender.isNotEmpty ? sender : channelName)
        : (mentionsMe ? '#$channelName · mentioned you' : '#$channelName');
    final body = sender.isNotEmpty
        ? (isDm
              ? preview
              : mentionsMe
              ? '$sender mentioned you: $preview'
              : '$sender: $preview')
        : 'New message';

    // Foreground: an in-app snackbar is enough. Backgrounded (but still alive):
    // raise an OS notification instead — a toast while the app is focused is
    // just noise, and a snackbar while backgrounded is invisible.
    if (_foreground) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isDm ? body : '$title — $body'),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: 'Open',
            onPressed: () {
              _channels?.activate(channelId);
              if (session != null) _markRead(session);
              _replyTo = null;
            },
          ),
        ),
      );
    } else {
      unawaited(showLocalNotification(title, body, threadId: channelId));
    }
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
  void _handleMeshControl(
    String fromHex,
    String channelId,
    MeshControl control,
  ) {
    if (control is VoicePresenceControl) {
      setState(() {
        if (control.channelId.isEmpty) {
          // Peer left voice — remove from all channels.
          for (final set in _voicePresence.values) {
            set.remove(fromHex);
          }
          _voicePresenceTs.remove(fromHex);
        } else {
          (_voicePresence[control.channelId] ??= {}).add(fromHex);
          _voicePresenceTs[fromHex] = DateTime.now();
          // Remove from other channels (can only be in one).
          for (final entry in _voicePresence.entries) {
            if (entry.key != control.channelId) entry.value.remove(fromHex);
          }
        }
        // Prune stale entries (>30s without refresh).
        final cutoff = DateTime.now().subtract(const Duration(seconds: 30));
        _voicePresenceTs.removeWhere((_, ts) => ts.isBefore(cutoff));
        for (final set in _voicePresence.values) {
          set.removeWhere((h) => !_voicePresenceTs.containsKey(h));
        }
      });
      return;
    }
    if (control is ReadWatermarkControl && control.messageId.isNotEmpty) {
      setState(() {
        (_readWatermarks[control.channelId] ??= {})[fromHex] =
            control.messageId;
        // Cache the timestamp for O(1) tick rendering — but only if we haven't
        // already resolved this id, so repeat watermarks don't each trigger an
        // O(n) scan of the message history. (_backfillWatermarkTs covers ids
        // that aren't in our DAG yet, on the next refresh.)
        final cache = _watermarkTs[control.channelId] ??= {};
        if (!cache.containsKey(control.messageId)) {
          final session = _channels?.sessions
              .where((s) => s.channelId == control.channelId)
              .firstOrNull;
          if (session != null) {
            final msg = session.repository
                .ordered()
                .cast<Message?>()
                .firstWhere(
                  (m) => m!.idHex == control.messageId,
                  orElse: () => null,
                );
            if (msg != null) cache[control.messageId] = msg.timestampMs;
          }
        }
      });
      return;
    }
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
    } else if (control is DeviceRevocationControl) {
      _handleDeviceRevocation(control.revocation);
    }
  }

  /// Verifies and persists a received device revocation.
  void _handleDeviceRevocation(DeviceRevocation rev) {
    final store = _deviceStore;
    if (store == null) return;
    // Only accept revocations for our own root (other people's revocations
    // don't matter for Phase A — we'll enforce them in Phase B).
    if (hex.encode(rev.rootKey) != widget.identity.publicKeyHex) return;
    unawaited(() async {
      try {
        if (!await rev.verify()) return;
        await store.addRevocation(rev);
        if (mounted) setState(() {});
      } catch (_) {
        // Persistence failure — revocation will be re-learned on next sync.
      }
    }());
  }

  /// Decrypts the active channel's new messages, indexes any media into your
  /// library, then re-renders.
  Future<void> _refresh() async {
    final active = _channels?.active;
    await active?.refreshContent();
    if (active != null) {
      _learnDeviceCerts(active);
      _maybePersistDm(active);
      await _indexLibrary(active);
      _indexProfiles(active);
      _indexBundles(active);
      _detectNewMembers(active);
      _markRead(active);
      // Backfill any watermark timestamps that were unresolved when received.
      _backfillWatermarkTs(active);
      // Publish our own name/avatar into a channel the first time we're
      // active in it.
      if ((_myName != null || _myAvatar != null) &&
          _announced.add(active.channelId)) {
        await _announceName(active);
        await _maybePublishBundle(active);
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
        case ReactionContent():
          break;
        case EditContent():
          break;
        case DeleteContent():
          break;
        case VoiceContent():
          break; // one-off recording, not a re-usable library item
        case DeviceBundleContent():
          break;
      }
    }
  }

  /// True when profile claim [a] (timestampMs, claimIdHex) should replace [b]:
  /// newer timestamp, ties broken by id so every client picks the same winner.
  static bool _claimBeats((int, String) a, (int, String) b) =>
      a.$1 > b.$1 || (a.$1 == b.$1 && a.$2.compareTo(b.$2) > 0);

  /// Records each author's latest self-asserted name as a *suggested* petname,
  /// and their avatar image once its blob has been fetched. "Latest" is the
  /// claim with the highest (timestamp, id) across all channels (via
  /// [_profileClaim]), so a stale profile in one channel can't clobber a newer
  /// one from another and an avatar removal from the author's other device
  /// propagates. Timestamps are self-asserted, so claims dated further than an
  /// hour into the future are ignored until their time comes — otherwise one
  /// skewed-clock announce would block an author's updates forever (claims are
  /// immutable in the append-only DAG).
  void _indexProfiles(ChannelSession session) {
    final maxSaneTs =
        DateTime.now().toUtc().millisecondsSinceEpoch +
        const Duration(hours: 1).inMilliseconds;
    // Fold first: this session's winning claim per author…
    final winners = <String, (Message, ProfileContent)>{};
    for (final message in session.repository.ordered()) {
      final content = session.contentOf(message);
      if (content is! ProfileContent) continue;
      if (message.timestampMs > maxSaneTs) continue; // skewed-clock claim
      final authorHex = hex.encode(message.author);
      final cur = winners[authorHex];
      if (cur == null ||
          _claimBeats(
            (message.timestampMs, message.idHex),
            (cur.$1.timestampMs, cur.$1.idHex),
          )) {
        winners[authorHex] = (message, content);
      }
    }
    // …then apply each winner against the cross-channel state. A same-claim
    // re-pass applies too — its avatar blob may only now have been fetched.
    for (final entry in winners.entries) {
      final (message, content) = entry.value;
      final claim = (message.timestampMs, message.idHex);
      final prev = _profileClaim[entry.key];
      if (prev != null &&
          prev.$2 != message.idHex &&
          !_claimBeats(claim, prev)) {
        continue;
      }
      _profileClaim[entry.key] = claim;
      if (content.name.isNotEmpty) _suggested[entry.key] = content.name;
      final avatar = content.avatar;
      if (avatar != null) {
        final bytes = session.blobOf(avatar);
        if (bytes != null && bytes.length <= _maxAvatarBytes) {
          _avatarBytes[entry.key] = bytes;
        }
      } else {
        // Their latest claim carries no avatar — stop rendering the old one.
        _avatarBytes.remove(entry.key);
      }
    }
  }

  /// Publishes our self-asserted name (+ avatar hash) into [session] so
  /// members can suggest it.
  Future<void> _announceName(ChannelSession session) async {
    final name = _myName;
    if (name == null && _myAvatar == null) return;
    final message = await _createMessage(
      session,
      await session.encodePayload(
        ProfileContent(name ?? '', avatar: _myAvatar),
      ),
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

  /// Sets (or removes) your avatar: pick an image, downscale it to a small
  /// PNG blob, and re-announce your profile everywhere.
  Future<void> _setMyAvatar() async {
    final store = _blobStore;
    if (store == null) return;
    // With an avatar set, offer change/remove; otherwise straight to the picker.
    var remove = false;
    if (_myAvatar != null) {
      final choice = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.image_outlined),
                title: const Text('Choose a new avatar'),
                onTap: () => Navigator.pop(ctx, 'change'),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Remove avatar'),
                onTap: () => Navigator.pop(ctx, 'remove'),
              ),
            ],
          ),
        ),
      );
      if (choice == null) return;
      remove = choice == 'remove';
    }
    String? hash;
    if (!remove) {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );
      final bytes = result?.files.single.bytes;
      if (bytes == null) return;
      final Uint8List png;
      try {
        png = await downscaleAvatar(bytes);
      } catch (_) {
        if (mounted) _setError('could not read that image');
        return;
      }
      hash = await store.put(png);
      _avatarBytes[widget.identity.publicKeyHex] = png;
    } else {
      _avatarBytes.remove(widget.identity.publicKeyHex);
    }
    await _profile?.setAvatar(hash);
    _myAvatar = hash;
    _announced.clear();
    if (mounted) setState(() {});
    for (final session in _channels?.sessions ?? const <ChannelSession>[]) {
      await _announceName(session);
      _announced.add(session.channelId);
    }
  }

  // Peers whose DM we've already written to the registry this run.
  final Set<String> _persistedDms = {};

  /// Persists a DM once it has real (non-bookkeeping) history, so it restores on
  /// the next launch. A DM with only a profile announce and no conversation is
  /// left unsaved — nothing to restore. Only call with a decrypted session (the
  /// Publishes our device bundle (the set of active device keys) into every
  /// open channel. Called on boot and after device changes (add/revoke).
  Future<void> _publishDeviceBundle() async {
    final store = _deviceStore;
    if (store == null) return;
    // Can't publish a bundle without the root signing key.
    if (!widget.identity.canSign) return;
    final revoked = store.revokedDeviceKeys;
    final activeKeys = store.certs
        .where((c) => !revoked.contains(c.deviceKeyHex))
        .map((c) => c.deviceKey)
        .toList();
    if (activeKeys.isEmpty) return;
    final bundle = await DeviceBundle.publish(
      root: widget.identity,
      devices: activeKeys,
    );
    // Store our own bundle so it's available for self-lookup.
    await store.setBundle(bundle);
    // Gossip the bundle into all open channels (it will be learned by peers
    // via _indexBundles on their next refresh).
    _pendingBundle = DeviceBundleContent(bundle.toJson());
  }

  /// A pending bundle to publish into each channel on next activity.
  DeviceBundleContent? _pendingBundle;

  /// Publishes the pending device bundle into [session] if not already sent.
  Future<void> _maybePublishBundle(ChannelSession session) async {
    final bundle = _pendingBundle;
    if (bundle == null) return;
    final payload = await session.encodePayload(bundle);
    final message = await _createMessage(session, payload);
    await session.publish(message);
  }

  /// Persists device certs seen from messages that match our root identity
  /// (i.e. our other devices). Lightweight — only processes new ones.
  void _learnDeviceCerts(ChannelSession session) {
    final store = _deviceStore;
    if (store == null) return;
    final myRoot = widget.identity.publicKeyHex;
    for (final entry in session.seenCerts.entries) {
      // Only learn certs for our own root identity.
      if (session.deviceRoots[entry.key] != myRoot) continue;
      if (store.isRevoked(entry.key)) continue;
      unawaited(store.addCert(entry.value));
    }
  }

  /// Verifies and persists device bundles from DeviceBundleContent messages.
  final Set<String> _indexedBundleIds = {};

  void _indexBundles(ChannelSession session) {
    final store = _deviceStore;
    if (store == null) return;
    for (final message in session.repository.ordered()) {
      if (_indexedBundleIds.contains(message.idHex)) continue;
      final content = session.contentOf(message);
      if (content is! DeviceBundleContent) continue;
      _indexedBundleIds.add(message.idHex);
      if (content.bundleJson.isEmpty) continue;
      try {
        final bundle = DeviceBundle.fromJson(content.bundleJson);
        // Only accept bundles signed by the message author (can't advertise
        // someone else's device set).
        if (bundle.rootKeyHex != hex.encode(message.author)) continue;
        // Monotonic check is inside setBundle.
        unawaited(bundle.verify().then((valid) {
          if (valid) unawaited(store.setBundle(bundle));
        }));
      } catch (_) {
        // Malformed bundle — skip.
      }
    }
  }

  /// active one, or a background one after its content is parsed).
  void _maybePersistDm(ChannelSession session) {
    final peer = session.peerPubkey;
    if (!session.isDm || peer == null) return;
    final peerHex = hex.encode(peer);
    if (_persistedDms.contains(peerHex)) return;
    final hasHistory = session.repository.ordered().any(
      (m) => !session.contentOf(m).isBookkeeping,
    );
    if (!hasHistory) return;
    _persistedDms.add(peerHex);
    unawaited(_dms?.save(peerHex));
  }

  /// Owner side of first contact: someone holding my card connected to my
  /// rendezvous, and signed signalling proved they're [peerHex]. This is a
  /// **connection request only** — I do *not* open a DM (the content channel),
  /// so they cannot deliver or store any message on my device until I accept.
  /// A stranger can announce "I'd like to talk", nothing more. An existing
  /// contact is trusted, so their DM opens straight away.
  Future<void> _onRendezvousContact(String peerHex) async {
    if (peerHex == widget.identity.publicKeyHex) return;
    // A blocked pubkey is silently dropped — no request, no DM — like every
    // other receive path (notifications, message render, voice).
    if (_blocked.contains(peerHex)) return;
    final channels = _channels;
    if (channels == null) return;
    if (_contacts?.nameFor(peerHex) != null) {
      try {
        await channels.openDm(hex.decode(peerHex));
      } catch (_) {}
    } else if (_requests.add(peerHex)) {
      unawaited(_reqStore?.save(peerHex));
    }
    if (mounted) setState(() {});
  }

  /// Accepts a connection request: the usual add-a-petname prompt, then opens
  /// the DM — only now can messages flow. Nothing was received before this.
  Future<void> _acceptRequest(String peerHex) async {
    final List<int> peer;
    try {
      peer = hex.decode(peerHex);
    } catch (_) {
      return;
    }
    final author = Uint8List.fromList(peer);
    final name = await _promptText(
      title: 'Add hearth#${_fingerprint(author)}?',
      hint: 'petname (only you see this)',
      initial: _suggested[peerHex] ?? '',
      action: 'Accept',
    );
    if (name == null) return; // cancelled — stays a request
    await _contacts?.setName(peerHex, name);
    _requests.remove(peerHex);
    unawaited(_reqStore?.remove(peerHex));
    unawaited(_dms?.save(peerHex)); // established — restore on launch
    _persistedDms.add(peerHex);
    await _channels?.openDm(peer);
    if (mounted) setState(() {});
  }

  /// Declines a connection request. Nothing was ever opened or stored, so this
  /// just forgets the pubkey; [block] additionally drops any re-request.
  Future<void> _declineRequest(String peerHex, {bool block = false}) async {
    if (block) {
      await _blockPeer(peerHex); // also drops the request + persists
      return;
    }
    _requests.remove(peerHex);
    unawaited(_reqStore?.remove(peerHex));
    if (mounted) setState(() {});
  }

  /// Accept / Decline / Block a pending connection request.
  Future<void> _requestActions(String peerHex) async {
    final author = Uint8List.fromList(hex.decode(peerHex));
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('${_displayName(author)} wants to message you'),
            ),
            ListTile(
              leading: const Icon(Icons.check_circle_outline),
              title: const Text('Accept'),
              onTap: () => Navigator.pop(ctx, 'accept'),
            ),
            ListTile(
              leading: const Icon(Icons.cancel_outlined),
              title: const Text('Decline'),
              onTap: () => Navigator.pop(ctx, 'decline'),
            ),
            ListTile(
              leading: Icon(
                Icons.block,
                color: Theme.of(ctx).colorScheme.error,
              ),
              title: const Text('Block'),
              onTap: () => Navigator.pop(ctx, 'block'),
            ),
          ],
        ),
      ),
    );
    switch (action) {
      case 'accept':
        await _acceptRequest(peerHex);
      case 'decline':
        await _declineRequest(peerHex);
      case 'block':
        await _declineRequest(peerHex, block: true);
    }
  }

  /// Joiner side: accept a scanned/pasted contact card. Adds the owner as a
  /// contact (we have their card), opens the DM, and runs a *transient*
  /// rendezvous on the owner's capability so they discover us — torn down once
  /// the DM connects, or after a timeout if they're offline.
  Future<void> _acceptContactCard(ContactCard card) async {
    final ownerHex = card.pubkey;
    if (ownerHex == widget.identity.publicKeyHex) {
      if (mounted) _setError("that's your own contact card");
      return;
    }
    // Adopt the card's relay if we're still on the bundled default (mirrors the
    // channel-invite behaviour), so a fresh install can reach the owner.
    if (card.relayUrl != null &&
        card.relayUrl != _relayUrl.toString() &&
        _relayUrl.toString() == kRelayUrl.toString()) {
      final relay = Uri.tryParse(card.relayUrl!);
      if (relay != null && relay.hasScheme && relay.hasAuthority) {
        await _settings?.setRelayUrl(card.relayUrl!);
        _relayUrl = relay;
        _channels?.updateFallbackUrls(
          (_settings?.fallbackRelays ?? []).map(Uri.parse).toList(),
        );
      }
    }
    // Name suggestion from the card, unless we've already named them.
    if (_contacts?.nameFor(ownerHex) == null) {
      await _contacts?.setName(
        ownerHex,
        card.name ??
            'hearth#${_fingerprint(Uint8List.fromList(hex.decode(ownerHex)))}',
      );
    }
    List<int> ownerKey;
    try {
      ownerKey = hex.decode(ownerHex);
    } catch (_) {
      if (mounted) _setError('invalid contact card');
      return;
    }
    await _channels?.openDm(ownerKey);
    if (mounted) setState(() {});
    if (!widget.autoPoll) return; // no live mesh in tests
    // Persist the attempt so it survives an app close, then announce on the
    // owner's rendezvous so they discover us and open the DM back. It keeps
    // trying (across restarts) until the DM connects or the entry expires —
    // no fixed timeout; _onDmConnected retires it on success.
    await _pending?.save(ownerHex, card.rendezvous);
    _startPendingRendezvous(ownerHex, card.rendezvous);
  }

  /// Announces on [rendezvousId] to reach the card owner [ownerHex] for first
  /// contact. Idempotent per owner (replaces any live listener).
  void _startPendingRendezvous(String ownerHex, String rendezvousId) {
    unawaited(_pendingContact[ownerHex]?.close());
    _pendingContact[ownerHex] = RendezvousListener.start(
      relayUrl: _relayUrl,
      fallbackUrls: (_settings?.fallbackRelays ?? []).map(Uri.parse).toList(),
      rendezvousId: rendezvousId,
      identity: widget.identity,
      ignore: {widget.identity.publicKeyHex},
      // We already know the owner from the card, so a rendezvous connect just
      // confirms reachability; the DM proper forms on its derived channel and
      // _onDmConnected retires this listener once it lands.
      onContact: (_) {},
    );
  }

  /// A DM to [peerHex] connected. If it was a pending first-contact, it's landed
  /// — drop the persisted attempt, stop announcing on its rendezvous, and record
  /// the DM so it restores on next launch even if no message is sent yet (a card
  /// contact you deliberately reached and connected to is established).
  void _onDmConnected(String peerHex) {
    final listener = _pendingContact.remove(peerHex);
    if (listener == null) return;
    unawaited(listener.close());
    unawaited(_pending?.remove(peerHex));
    if (_persistedDms.add(peerHex)) unawaited(_dms?.save(peerHex));
  }

  /// (Re)starts the standing contact-card rendezvous listener on the *current*
  /// relay, closing any previous one — so a relay switch doesn't strand it on
  /// the old relay. No-op until [ProfileStore.ensureRendezvousId] has minted it.
  void _startRendezvous() {
    if (!widget.autoPoll) return;
    final rv = _profile?.rendezvousId;
    if (rv == null) return;
    unawaited(_rendezvous?.close());
    _rendezvous = RendezvousListener.start(
      relayUrl: _relayUrl,
      fallbackUrls: (_settings?.fallbackRelays ?? []).map(Uri.parse).toList(),
      rendezvousId: rv,
      identity: widget.identity,
      ignore: {widget.identity.publicKeyHex},
      onContact: _onRendezvousContact,
    );
  }

  /// Re-opens established DMs on [channels] without disturbing the active
  /// channel. Used at startup and after a relay switch.
  Future<void> _restoreDms(
    ChannelManager channels,
    DmRegistry? registry,
  ) async {
    final keepActive = channels.activeId;
    for (final peerHex in registry?.all() ?? const <String>[]) {
      try {
        await channels.openDm(hex.decode(peerHex));
      } catch (_) {}
    }
    if (keepActive != null) channels.activate(keepActive);
  }

  /// Resumes outbound first-contacts that haven't connected yet — re-open the DM
  /// and re-announce on each owner's rendezvous on the *current* relay, so a
  /// relay switch re-homes them and a card scanned while the owner was offline
  /// still connects whenever you're both next online.
  Future<void> _resumePendingContacts() async {
    if (!widget.autoPoll) return;
    final channels = _channels;
    if (channels == null) return;
    final keepActive = channels.activeId;
    for (final p in await _pending?.live() ?? const <PendingContact>[]) {
      try {
        await channels.openDm(hex.decode(p.ownerPubkeyHex));
      } catch (_) {}
      _startPendingRendezvous(p.ownerPubkeyHex, p.rendezvousId);
    }
    if (keepActive != null) channels.activate(keepActive);
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
      // Also include currently connected mesh peers (they may not have sent a
      // message yet but are live in this channel).
      ...?session.mesh?.peers,
    }..remove(self);
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
    final onlinePeers = _allOnlinePeers();
    final active = members
        .where(
          (k) =>
              onlinePeers.contains(k) || (now - (lastSeen[k] ?? 0)) < sevenDays,
        )
        .toList();
    final inactive = members
        .where(
          (k) =>
              !onlinePeers.contains(k) &&
              (now - (lastSeen[k] ?? 0)) >= sevenDays,
        )
        .toList();

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
    return Material(
      type: MaterialType.transparency,
      child: ListTile(
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
        onTap: () =>
            unawaited(_peerActions(Uint8List.fromList(hex.decode(key)))),
      ),
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
    final phrase = await seedToMnemonic(seed);
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
                'Write these 24 words down in order and keep them somewhere '
                'safe. Anyone who has them can become you — never share them. '
                'They are the only way to restore your identity if you lose '
                'this device.',
              ),
              const SizedBox(height: 16),
              Center(
                child: QrImageView(
                  data: phrase,
                  size: 240, // the 24-word phrase is denser than the old code
                  backgroundColor: Colors.white,
                ),
              ),
              const SizedBox(height: 16),
              const Text('Recovery phrase:', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  phrase,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 14,
                    height: 1.6,
                  ),
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
              _copyAndClear(phrase);
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
            'Scan a QR code from another device, or paste your 24-word '
            'recovery phrase.',
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
          hint: 'paste your 24-word recovery phrase',
          action: 'Restore',
        );
      }
    } else {
      code = await _promptText(
        title: 'Restore identity',
        hint: 'paste your 24-word recovery phrase',
        action: 'Restore',
      );
    }
    if (code == null || code.trim().isEmpty) return;
    // Decode the 24-word recovery phrase. A scanned QR encodes the same phrase,
    // so this handles both. Null if a word is unknown or the checksum fails.
    // Require a 32-byte seed: a shorter but valid BIP39 phrase (e.g. a 12-word
    // wallet phrase) would otherwise be written and then brick the next launch,
    // since Ed25519 key derivation needs exactly 32 bytes.
    final seed = await mnemonicToSeed(code.trim());
    if (seed == null || seed.length != 32) {
      if (mounted) _setError('invalid recovery phrase (need a 24-word phrase)');
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
    // Only a *confirmed newer* release forces an update (it also reaches us
    // peer-to-peer via VersionControl). An unreachable relay must NOT block the
    // app — Hearth is local-first and keeps working P2P/offline; the relay
    // status dot already shows connectivity.
    if (state is UpdateAvailable) {
      setState(() => _updateInfo = state.info);
    }
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
          length: kIsWeb ? 4 : 5,
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
                    Tab(text: 'Devices'),
                    Tab(text: 'Network'),
                    Tab(text: 'Privacy'),
                    if (!kIsWeb) Tab(text: 'AI'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _audioTab(),
                      _identityTab(),
                      _devicesTab(),
                      _networkTab(),
                      _privacyTab(),
                      if (!kIsWeb) _aiTab(),
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
                                .getUserMedia({'audio': true, 'video': false});
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
                    'Appearance',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.dark,
                        icon: Icon(Icons.dark_mode_outlined),
                        label: Text('Dark'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.light,
                        icon: Icon(Icons.light_mode_outlined),
                        label: Text('Light'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.system,
                        icon: Icon(Icons.brightness_auto_outlined),
                        label: Text('Auto'),
                      ),
                    ],
                    selected: {widget.themeMode?.value ?? ThemeMode.dark},
                    onSelectionChanged: (sel) {
                      final mode = sel.first;
                      widget.themeMode?.value = mode;
                      unawaited(_settings?.setThemeMode(mode.name));
                      setTabState(() {});
                    },
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
                  const Divider(height: 24),
                  Text(
                    'Fallback relays',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Tried if the primary relay is unreachable.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  for (final url in _settings?.fallbackRelays ?? <String>[])
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.dns_outlined, size: 20),
                      title: Text(url, overflow: TextOverflow.ellipsis),
                      trailing: IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          final list = [..._settings!.fallbackRelays]
                            ..remove(url);
                          unawaited(_settings!.setFallbackRelays(list));
                          _channels?.updateFallbackUrls(
                            list.map(Uri.parse).toList(),
                          );
                          setTabState(() {});
                        },
                      ),
                    ),
                  TextButton.icon(
                    onPressed: () async {
                      final url = await _promptText(
                        title: 'Add fallback relay',
                        hint: 'https://relay.example.com',
                        action: 'Add',
                      );
                      if (url == null || url.trim().isEmpty) return;
                      var input = url.trim();
                      if (input.startsWith('http://')) {
                        _setError('HTTP is not supported — use HTTPS');
                        return;
                      }
                      if (!input.startsWith('https://')) {
                        input = 'https://$input';
                      }
                      final list = [..._settings!.fallbackRelays, input];
                      await _settings!.setFallbackRelays(list);
                      _channels?.updateFallbackUrls(
                        list.map(Uri.parse).toList(),
                      );
                      setTabState(() {});
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Add relay'),
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
            subtitle: const Text('Reveal your recovery phrase'),
            onTap: () {
              Navigator.pop(context);
              unawaited(_backupIdentity());
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.restore),
            title: const Text('Restore identity'),
            subtitle: const Text('Restore from a recovery phrase'),
            onTap: () {
              Navigator.pop(context);
              unawaited(_restoreIdentity());
            },
          ),
        ],
      ),
    );
  }

  Widget _devicesTab() {
    final store = _deviceStore;
    if (store == null) {
      return const Center(child: Text('Device store not available'));
    }
    final certs = store.certs;
    final revoked = store.revokedDeviceKeys;
    final thisDeviceHex = widget.deviceKeys.publicKeyHex;
    // Sort: this device first, then by issued date descending.
    certs.sort((a, b) {
      if (a.deviceKeyHex == thisDeviceHex) return -1;
      if (b.deviceKeyHex == thisDeviceHex) return 1;
      return b.issuedMs.compareTo(a.issuedMs);
    });
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final cert in certs)
          _deviceTile(cert, isThis: cert.deviceKeyHex == thisDeviceHex,
              isRevoked: revoked.contains(cert.deviceKeyHex)),
        if (certs.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Text('No devices enrolled yet.',
                textAlign: TextAlign.center),
          ),
      ],
    );
  }

  Widget _deviceTile(DeviceCert cert,
      {required bool isThis, required bool isRevoked}) {
    final issued = DateTime.fromMillisecondsSinceEpoch(cert.issuedMs);
    final dateStr =
        '${issued.year}-${issued.month.toString().padLeft(2, '0')}-${issued.day.toString().padLeft(2, '0')}';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        isThis ? Icons.phone_android : Icons.devices_other,
        color: isRevoked
            ? Theme.of(context).colorScheme.error
            : isThis
                ? Theme.of(context).colorScheme.primary
                : null,
      ),
      title: Row(
        children: [
          Flexible(child: Text(cert.name, overflow: TextOverflow.ellipsis)),
          if (isThis)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Chip(
                label: const Text('This device'),
                labelStyle: const TextStyle(fontSize: 11),
                visualDensity: VisualDensity.compact,
              ),
            ),
          if (isRevoked)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Chip(
                label: const Text('Revoked'),
                labelStyle: const TextStyle(fontSize: 11),
                backgroundColor: Theme.of(context).colorScheme.errorContainer,
                visualDensity: VisualDensity.compact,
              ),
            ),
        ],
      ),
      subtitle: Text('Enrolled $dateStr • ${cert.deviceKeyHex.substring(0, 8)}…'),
      trailing: isRevoked
          ? null
          : PopupMenuButton<String>(
              onSelected: (action) {
                switch (action) {
                  case 'rename':
                    if (isThis) _renameThisDevice();
                  case 'revoke':
                    if (!isThis) _revokeDevice(cert);
                }
              },
              itemBuilder: (_) => [
                if (isThis && widget.identity.canSign)
                  const PopupMenuItem(value: 'rename', child: Text('Rename')),
                if (!isThis && widget.identity.canSign)
                  PopupMenuItem(
                    value: 'revoke',
                    child: Text('Revoke',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  ),
              ],
            ),
    );
  }

  Future<void> _renameThisDevice() async {
    final controller = TextEditingController(text: widget.deviceKeys.cert.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename device'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Device name'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || name == widget.deviceKeys.cert.name) {
      return;
    }
    // Re-issue cert with the new name.
    final newCert = await DeviceCert.issue(
      root: widget.identity,
      deviceKey: widget.deviceKeys.device.publicKey,
      name: name,
    );
    await _deviceStore?.updateCert(newCert);
    // Update the in-memory device keys so new messages carry the new name.
    widget.deviceKeys.cert = newCert;
    if (mounted) setState(() {});
  }

  Future<void> _revokeDevice(DeviceCert cert) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revoke device?'),
        content: Text(
          'Revoke "${cert.name}"? It will no longer be able to send messages '
          'as you. This cannot be undone.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error),
              child: const Text('Revoke')),
        ],
      ),
    );
    if (confirmed != true) return;
    final revocation = await DeviceRevocation.issue(
      root: widget.identity,
      deviceKey: cert.deviceKey,
    );
    await _deviceStore?.addRevocation(revocation);
    // Gossip the revocation to all channels so other peers learn it.
    for (final session in _channels?.sessions ?? const <ChannelSession>[]) {
      session.broadcast(DeviceRevocationControl(revocation: revocation));
    }
    // Republish our device bundle without the revoked device.
    await _publishDeviceBundle();
    if (mounted) setState(() {});
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

  Widget _privacyTab() {
    return StatefulBuilder(
      builder: (context, setLocal) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Blocked users', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          if (_blocked.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'No blocked users',
                style: TextStyle(color: Colors.grey),
              ),
            )
          else
            for (final pubHex in _blocked.toList())
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: _avatar(
                  Uint8List.fromList(hex.decode(pubHex)),
                  radius: 14,
                ),
                title: Text(
                  _displayName(Uint8List.fromList(hex.decode(pubHex))),
                ),
                trailing: TextButton(
                  onPressed: () {
                    setState(() => _blocked.remove(pubHex));
                    setLocal(() {});
                    unawaited(_settings?.unblockUser(pubHex));
                  },
                  child: const Text(
                    'Unblock',
                    style: TextStyle(color: Colors.green),
                  ),
                ),
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
    final cache = _channels?.candidateCache;
    await _channels?.close();
    final channels = ChannelManager(
      identity: widget.identity,
      meshIdentity: widget.deviceKeys.device,
      relayUrl: _relayUrl,
      fallbackUrls: (_settings?.fallbackRelays ?? []).map(Uri.parse).toList(),
      live: widget.autoPoll,
      onUpdate: _onUpdate,
      blobStore: _blobStore,
      candidateCache: cache,
      onBackgroundMessage: _notifyBackground,
      onForceUpdate: (info) {
        if (mounted) setState(() => _updateInfo = info);
      },
      onInference: _handleMeshControl,
      onDmConnected: _onDmConnected,
      isBlocked: _blocked.contains,
      isDeviceRevoked: (hex) => _deviceStore?.isRevoked(hex) ?? false,
      peerBundleLookup: (rootHex) => _deviceStore?.bundleFor(rootHex),
      ownDeviceKeys: () {
        final store = _deviceStore;
        if (store == null) return [widget.deviceKeys.publicKey];
        final revoked = store.revokedDeviceKeys;
        return store.certs
            .where((c) => !revoked.contains(c.deviceKeyHex))
            .map((c) => c.deviceKey)
            .toList();
      },
    );
    for (final group in _registry?.all() ?? const <GroupChannel>[]) {
      await channels.openGroup(group.id, group.key);
    }
    await _restoreDms(channels, _dms);
    if (mounted) setState(() => _channels = channels);
    // Re-home first-contact machinery onto the new relay (the old rendezvous +
    // pending listeners were pinned to the previous relay).
    _startRendezvous();
    await _resumePendingContacts();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Track focus so we don't fire OS notifications while the app is in front.
    _foreground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      // Save fresh token for background fetch before the app sleeps.
      unawaited(_saveBackgroundState());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _voicePresenceTimer?.cancel();
    _updateCheckTimer?.cancel();
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
    _recordTicker?.cancel();
    unawaited(_recorder?.dispose());
    unawaited(_rendezvous?.close());
    for (final l in _pendingContact.values) {
      unawaited(l.close());
    }
    super.dispose();
  }

  Future<void> _send() async {
    final raw = _input.text.trim();
    if (raw.isEmpty) return;
    _input.clear();
    _typingTimer?.cancel();
    if (_typingLocally) {
      _typingLocally = false;
      _channels?.active?.sendTyping(false);
    }
    // Turn any @name matching a channel member into a <@hex> mention token.
    final session = _channels?.active;
    final text = session != null ? _resolveMentionsInText(raw, session) : raw;
    final editing = _editing;
    if (editing != null) {
      await _publish(EditContent(editing.idHex, text));
      setState(() => _editing = null);
      _composerFocus.requestFocus();
      return;
    }
    await _publish(TextContent(text, replyTo: _replyTo?.idHex));
    setState(() => _replyTo = null);
    _composerFocus.requestFocus();
    // @bot trigger — broadcast an inference request to the mesh.
    if (raw.startsWith('@bot ')) {
      final prompt = raw.substring(5).trim();
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
    _exitEditMode();
    final url = await pickGif(
      context,
      _relayUrl,
      tokenProvider: () => _channels?.active?.mesh?.authToken,
    );
    if (url == null) return;
    try {
      final res = await http.get(Uri.parse(url));
      if (res.statusCode != 200) {
        if (mounted) _setError('could not fetch that GIF');
        return;
      }
      if (res.bodyBytes.length > HiveBlobStore.maxBytes) {
        if (mounted) _setError('GIF too large (max 10 MB)');
        return;
      }
      final hash = await store.put(res.bodyBytes);
      await _publish(GifContent(hash));
    } catch (_) {
      if (mounted) _setError('could not fetch that GIF');
    }
  }

  /// Opens the sticker picker — a grid of your saved stickers (from your media
  /// library) with an upload button to add new ones.
  Future<void> _sendSticker() async {
    final store = _blobStore;
    final library = _library;
    if (store == null) return;
    _exitEditMode();

    final stickers = library?.byKind(MediaKind.sticker) ?? [];
    // Pre-fetch blob bytes so FutureBuilder doesn't re-fire on rebuild.
    final stickerFutures = [for (final item in stickers) store.get(item.hash)];

    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    'Stickers',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () async {
                      final result = await FilePicker.platform.pickFiles(
                        type: FileType.image,
                        withData: true,
                      );
                      final bytes = result?.files.single.bytes;
                      if (bytes == null) return;
                      if (bytes.length > HiveBlobStore.maxBytes) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Image too large (max 10 MB)'),
                            ),
                          );
                        }
                        return;
                      }
                      final hash = await store.put(bytes);
                      await library?.add(hash, MediaKind.sticker);
                      if (context.mounted) Navigator.pop(context, hash);
                    },
                    icon: const Icon(
                      Icons.add_photo_alternate_outlined,
                      size: 18,
                    ),
                    label: const Text('Upload'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (stickers.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    'No stickers yet — upload one or receive '
                    'some in chat!',
                    style: TextStyle(color: Colors.grey),
                  ),
                )
              else
                SizedBox(
                  height: 200,
                  child: GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                    itemCount: stickers.length,
                    itemBuilder: (context, i) {
                      final item = stickers[i];
                      return FutureBuilder<Uint8List?>(
                        future: stickerFutures[i],
                        builder: (context, snap) {
                          final bytes = snap.data;
                          if (bytes == null) {
                            return const Center(
                              child: SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            );
                          }
                          return GestureDetector(
                            onTap: () => Navigator.pop(context, item.hash),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.memory(
                                bytes,
                                fit: BoxFit.cover,
                                // Decode at grid-cell size, not blob size.
                                cacheWidth:
                                    (120 *
                                            MediaQuery.devicePixelRatioOf(
                                              context,
                                            ))
                                        .round(),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    if (picked != null) {
      await _publish(StickerContent(picked));
    }
  }

  /// Picks any file and sends it as an attachment (image inline, else a chip).
  Future<void> _sendFile() async {
    final store = _blobStore;
    if (store == null) return;
    _exitEditMode();
    final result = await FilePicker.platform.pickFiles(withData: true);
    final file = result?.files.single;
    final bytes = file?.bytes;
    if (file == null || bytes == null) return;
    final danger = _fileDanger(file.name, bytes);
    if (danger != null) {
      if (mounted) _setError(danger);
      return;
    }
    if (bytes.length > HiveBlobStore.maxBytes) {
      if (mounted) _setError('File too large (max 10 MB)');
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

  // --- voice messages ---

  /// Starts recording a voice message; the composer swaps to a recording bar
  /// until send or cancel. Recorded as AAC to a temp file, then blob-ified.
  Future<void> _startVoiceRecording() async {
    final recorder = _recorder ??= AudioRecorder();
    try {
      if (!await recorder.hasPermission()) {
        if (mounted) _setError('microphone permission denied');
        return;
      }
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}${Platform.pathSeparator}'
          'hearth_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: path,
      );
      if (!mounted) return;
      setState(() => _recordStart = DateTime.now());
      _recordTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {}); // tick the elapsed label
      });
    } catch (_) {
      if (mounted) _setError('could not start recording');
    }
  }

  /// Discards an in-flight recording (stops + deletes the temp file).
  Future<void> _cancelVoiceRecording() async {
    _recordTicker?.cancel();
    setState(() => _recordStart = null);
    try {
      await _recorder?.cancel();
    } catch (_) {}
  }

  /// Stops recording and publishes the clip as a [VoiceContent] blob.
  Future<void> _sendVoiceRecording() async {
    _exitEditMode();
    final store = _blobStore;
    final started = _recordStart;
    _recordTicker?.cancel();
    setState(() => _recordStart = null);
    String? path;
    try {
      path = await _recorder?.stop();
    } catch (_) {}
    if (path == null || started == null || store == null) return;
    final elapsed = DateTime.now().difference(started);
    try {
      final file = File(path);
      final bytes = await file.readAsBytes();
      try {
        await file.delete();
      } catch (_) {}
      // A sub-half-second clip is an accidental tap, not a message.
      if (elapsed.inMilliseconds < 500 || bytes.isEmpty) return;
      if (bytes.length > HiveBlobStore.maxBytes) {
        if (mounted) _setError('Recording too long (max 10 MB)');
        return;
      }
      final hash = await store.put(bytes);
      await _publish(VoiceContent(hash, elapsed.inMilliseconds));
    } catch (_) {
      if (mounted) _setError('could not send voice message');
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
    if (bytes.length > HiveBlobStore.maxBytes) {
      if (mounted) _setError('Sound too large (max 10 MB)');
      return;
    }
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
    final picked = await pickSound(
      context,
      _relayUrl,
      tokenProvider: () => _channels?.active?.mesh?.authToken,
    );
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
      if (res.bodyBytes.length > HiveBlobStore.maxBytes) {
        if (mounted) _setError('Sound too large (max 10 MB)');
        return;
      }
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
      if (_soundPlayers.remove(player)) {
        await player.dispose();
      }
    });
    unawaited(
      Future.delayed(const Duration(seconds: 10), () async {
        if (_soundPlayers.remove(player)) {
          await player.stop();
          await player.dispose();
        }
      }),
    );
  }

  /// Builds, persists, and gossips [content] in the active channel.
  /// Builds a message for [session]: authored by the root identity, but signed
  /// by this device (carrying its cert), so peers verify the root→device chain.
  Future<Message> _createMessage(ChannelSession session, Uint8List payload) =>
      Message.create(
        author: widget.identity,
        channel: session.channelId,
        payload: payload,
        prev: session.repository.heads(),
        signingDevice: widget.deviceKeys.device,
        deviceCert: widget.deviceKeys.cert,
      );

  Future<void> _publish(Content content) async {
    final session = _channels?.active;
    if (_sending || session == null) return;
    // Request web notification permission on first user action.
    if (kIsWeb && !_webNotifRequested) {
      _webNotifRequested = true;
      unawaited(requestWebNotificationPermission());
    }
    setState(() => _sending = true);
    try {
      final message = await _createMessage(
        session,
        await session.encodePayload(content),
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
      final message = await _createMessage(
        session,
        await session.encodePayload(content),
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
    unawaited(_saveBackgroundState());
  }

  /// Joins a channel from a pasted invite code.
  Future<void> _joinViaInvite() async {
    String? code;
    // On mobile, offer QR scan as an alternative to pasting.
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      code = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Add via invite or card'),
          content: const Text(
            'Scan or paste a channel invite or a contact card.',
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
                    builder: (_) => const _QrScanPage(title: 'Scan QR'),
                  ),
                );
                if (ctx.mounted) Navigator.pop(ctx, result);
              },
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan QR'),
            ),
            TextButton.icon(
              onPressed: () => Navigator.pop(ctx, ''),
              icon: const Icon(Icons.paste),
              label: const Text('Paste'),
            ),
          ],
        ),
      );
      if (code == null) return;
      if (code.isEmpty && mounted) {
        code = await _promptText(
          title: 'Add via invite or card',
          hint: 'paste an invite or contact code',
          action: 'Add',
        );
      }
    } else {
      code = await _promptText(
        title: 'Add via invite or card',
        hint: 'paste an invite or contact code',
        action: 'Add',
      );
    }
    if (code == null || code.trim().isEmpty) return;
    // A contact card and a channel invite share this scan/paste entry — dispatch
    // by prefix. A card starts a person-to-person DM rather than joining a group.
    final card = ContactCard.decode(code.trim());
    if (card != null) {
      await _acceptContactCard(card);
      return;
    }
    final parsed = GroupChannel.fromInvite(code.trim());
    if (parsed == null) {
      if (mounted) _setError('invalid invite or contact code');
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
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Text('Anyone with this code can join and read messages.'),
            const SizedBox(height: 16),
            SizedBox(
              width: 200,
              height: 200,
              child: QrImageView(
                data: invite,
                padding: const EdgeInsets.all(12),
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            SelectableText(
              invite,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              textAlign: TextAlign.center,
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
              _copyAndClear(invite);
              Navigator.pop(context);
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copy'),
          ),
        ],
      ),
    );
  }

  /// Shows my contact card — a QR + `hearth-contact:` code anyone can scan or
  /// paste to start a DM with me, even with no shared group. The rendezvous id
  /// is the standing one from my profile; sharing the card doesn't expose my
  /// key inbox to anyone who doesn't hold it.
  Future<void> _shareMyContact() async {
    final profile = _profile;
    if (profile == null) return;
    // Durably mint the rendezvous id before it leaves the device in a card.
    final rv = await profile.ensureRendezvousId();
    if (!mounted) return;
    final card = ContactCard(
      pubkey: widget.identity.publicKeyHex,
      rendezvous: rv,
      name: _myName,
      relayUrl: _relayUrl.toString(),
    ).encode();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('My contact card'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Text(
              'Anyone who scans this can message you directly — share it '
              'in person or over another app.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: 200,
              height: 200,
              child: QrImageView(
                data: card,
                padding: const EdgeInsets.all(12),
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            SelectableText(
              card,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              textAlign: TextAlign.center,
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
              _copyAndClear(card);
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
    unawaited(_saveBackgroundState());
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
        meshIdentity: widget.deviceKeys.device,
        relayUrl: _relayUrl,
        onChange: _voiceChanged,
        enhancedNoiseSuppression: _settings?.noiseSuppression ?? false,
        candidateCache: _channels?.candidateCache,
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
      // Broadcast presence over gossip mesh so peers see us in voice.
      _broadcastVoicePresence(channelId);
      _voicePresenceTimer = Timer.periodic(
        const Duration(seconds: 15),
        (_) => _broadcastVoicePresence(channelId),
      );
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) {
        _setError('microphone access is needed for voice');
      }
    }
  }

  void _voiceChanged() {
    // Auto-mute blocked users joining voice.
    final voice = _voice;
    if (voice != null) {
      for (final peer in voice.peerHexes) {
        if (_blocked.contains(peer) && voice.volumeOf(peer) > 0) {
          unawaited(voice.setVolume(peer, 0.0));
        }
      }
    }
    _pruneScreenViews();
    _reannounceShareToNewPeers();
    _pruneWatchParty();
    _reannounceYtToNewPeers();
    if (mounted) setState(() {});
  }

  void _broadcastVoicePresence(String channelId) {
    for (final session in _channels?.sessions ?? const <ChannelSession>[]) {
      session.broadcast(VoicePresenceControl(channelId: channelId));
    }
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
    _voicePresenceTimer?.cancel();
    _voicePresenceTimer = null;
    // Broadcast leave (empty channelId).
    _broadcastVoicePresence('');
    final voice = _voice;
    _voice = null;
    _voiceMuted.clear();
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

  String _fmtTime(double seconds) => formatClipTime(
    seconds.isFinite && seconds > 0 ? (seconds * 1000).round() : 0,
  );

  /// The right-hand **channel control panel** — channel-scoped actions (invite,
  /// voice) and, in a call, the participants with live speaking indicators. A
  /// dedicated home for these controls, with room to grow.
  Widget _channelPanel(ChannelSession session) {
    final theme = Theme.of(context);
    final voice = _voice;
    final inCall = voice != null && voice.channelId == session.channelId;
    // Material (not a plain coloured Container) so the panel's ListTiles paint
    // their ink splashes on a Material ancestor rather than an opaque ColoredBox.
    return Material(
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
                if (session.isDm)
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Read receipts'),
                    subtitle: const Text('Let them see when you\'ve read'),
                    value: !_readReceiptsDisabled.contains(session.channelId),
                    onChanged: (v) {
                      setState(() {
                        if (v) {
                          _readReceiptsDisabled.remove(session.channelId);
                        } else {
                          _readReceiptsDisabled.add(session.channelId);
                        }
                      });
                      unawaited(
                        _settings?.setReadReceiptsDisabled(
                          session.channelId,
                          !v,
                        ),
                      );
                    },
                  ),
                if (session.isDm) const Divider(height: 28),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Mute notifications'),
                  subtitle: const Text('Silence this channel'),
                  value: _mutedChannels.contains(session.channelId),
                  onChanged: (v) {
                    setState(() {
                      if (v) {
                        _mutedChannels.add(session.channelId);
                      } else {
                        _mutedChannels.remove(session.channelId);
                      }
                    });
                    unawaited(
                      _settings?.setChannelPref(
                        session.channelId,
                        'muted',
                        v ? 'true' : null,
                      ),
                    );
                  },
                ),
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.push_pin_outlined, size: 20),
                  title: const Text('Pinned messages'),
                  trailing: Text(
                    '${(_pinnedMessages[session.channelId] ?? {}).length}',
                    style: const TextStyle(color: Colors.grey),
                  ),
                  onTap: () => _showPinned(session),
                ),
                const Divider(height: 28),
                Text('VOICE', style: theme.textTheme.labelSmall),
                const SizedBox(height: 8),
                if (!inCall) ...[
                  _PressableScale(
                    child: FilledButton.icon(
                      onPressed: () => unawaited(_joinVoice(session.channelId)),
                      icon: const Icon(Icons.call),
                      label: const Text('Join voice'),
                    ),
                  ),
                  if (_voicePresence[session.channelId]?.isNotEmpty ?? false)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '🔊 ${_voicePresence[session.channelId]!.map((h) => _contacts?.nameFor(h) ?? h.substring(0, 8)).join(', ')}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ] else ...[
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
                            _speakerOn ? Icons.volume_up : Icons.phone_in_talk,
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
                              await Helper.setSpeakerphoneOnButPreferBluetooth();
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
                      _PressableScale(
                        child: IconButton(
                          onPressed: () => unawaited(_leaveVoice()),
                          icon: const Icon(Icons.call_end),
                          color: theme.colorScheme.error,
                          tooltip: 'Leave voice',
                        ),
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
  /// bar. Tapping a peer opens their volume slider. Long-press to mute.
  Widget _participantTile(
    VoiceSession voice,
    String key,
    Uint8List author,
    String name,
  ) {
    final speaking = voice.speaking(key);
    final isMuted =
        key != 'self' && (_voiceMuted.contains(key) || _blocked.contains(key));
    return InkWell(
      onTap: key == 'self' || isMuted
          ? null
          : () => unawaited(_peerVolume(key, name)),
      onLongPress: key == 'self'
          ? null
          : () {
              // Can't unmute a blocked user — they stay muted.
              if (_blocked.contains(key)) return;
              setState(() {
                if (_voiceMuted.contains(key)) {
                  _voiceMuted.remove(key);
                  _voice?.setVolume(key, 1.0);
                } else {
                  _voiceMuted.add(key);
                  _voice?.setVolume(key, 0.0);
                }
              });
            },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            _SpeakingRings(
              active: speaking && !isMuted,
              level: (voice.levelOf(key) * 4).clamp(0.0, 1.0),
              color: Colors.greenAccent,
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
            if (isMuted)
              const Icon(Icons.mic_off, size: 16, color: Colors.redAccent)
            else
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

  /// The viewer's `@name` label for a mention's [pubkeyHex] (resolved to their
  /// own petname/suggested name, so a mention reads correctly for everyone).
  String _mentionLabel(String pubkeyHex) {
    try {
      return '@${_displayName(Uint8List.fromList(hex.decode(pubkeyHex)))}';
    } catch (_) {
      return '@$pubkeyHex';
    }
  }

  /// Rewrites any `@name` matching a member of [session] into a `<@hex>` token
  /// (see [resolveMentions] for the boundary + code rules).
  String _resolveMentionsInText(String text, ChannelSession session) =>
      resolveMentions(text, {
        for (final h in _membersOf(session))
          _displayName(Uint8List.fromList(hex.decode(h))): h,
      });

  /// Opens a member picker; the chosen member's `@name` is inserted at the
  /// cursor (resolved to a mention token on send).
  Future<void> _insertMention(ChannelSession session) async {
    final members = _membersOf(session).toList();
    if (members.isEmpty) {
      _setError('no one to mention here yet');
      return;
    }
    final chosen = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Mention someone'),
            ),
            for (final h in members)
              ListTile(
                leading: _avatar(Uint8List.fromList(hex.decode(h))),
                title: Text(_displayName(Uint8List.fromList(hex.decode(h)))),
                onTap: () => Navigator.pop(ctx, h),
              ),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    final name = _displayName(Uint8List.fromList(hex.decode(chosen)));
    final value = _input.value;
    final sel = value.selection;
    final at = sel.isValid ? sel.start : value.text.length;
    // A leading space when the mention would otherwise abut a preceding word —
    // without it, `thanks@Bob` fails the boundary check and never resolves.
    final needsSpace = at > 0 && !RegExp(r'\s').hasMatch(value.text[at - 1]);
    final insert = '${needsSpace ? ' ' : ''}@$name ';
    _input.value = TextEditingValue(
      text: value.text.replaceRange(at, sel.isValid ? sel.end : at, insert),
      selection: TextSelection.collapsed(offset: at + insert.length),
    );
    _composerFocus.requestFocus();
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
    final authorHex = hex.encode(author);
    // Can't act on yourself.
    if (authorHex == widget.identity.publicKeyHex) return;
    final isBlocked = _blocked.contains(authorHex);
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
            ListTile(
              leading: Icon(
                isBlocked ? Icons.check_circle_outline : Icons.block,
                color: isBlocked ? Colors.green : Colors.red,
              ),
              title: Text(isBlocked ? 'Unblock' : 'Block'),
              onTap: () => Navigator.pop(context, 'block'),
            ),
          ],
        ),
      ),
    );
    if (action == 'dm') {
      await _channels?.openDm(author);
    } else if (action == 'name') {
      await _renameContact(author);
    } else if (action == 'block') {
      await (isBlocked ? _unblockPeer(authorHex) : _blockPeer(authorHex));
    }
  }

  /// Blocks [peerHex]: persists the block, mutes them in voice, and — per the
  /// plan's DM rule — **closes any DM with them and stops it restoring**, so a
  /// blocked peer's messages are never received or stored again (no session →
  /// no mesh/courier). Also clears any pending first-contact / request for them.
  /// Group messages stay in the DAG (rendered redacted) as before.
  Future<void> _blockPeer(String peerHex) async {
    setState(() => _blocked.add(peerHex));
    await _settings?.blockUser(peerHex);
    if (_voice != null && _voice!.volumeOf(peerHex) > 0) {
      unawaited(_voice!.setVolume(peerHex, 0.0));
    }
    // Drop any in-flight first contact / pending request.
    unawaited(_pendingContact.remove(peerHex)?.close());
    unawaited(_pending?.remove(peerHex));
    _requests.remove(peerHex);
    unawaited(_reqStore?.remove(peerHex));
    // Close + forget the DM so nothing more is ingested (past history stays on
    // disk, just unreachable; re-DMing after unblock would surface it again).
    _persistedDms.remove(peerHex);
    unawaited(_dms?.remove(peerHex));
    final dmId = await dmChannelId(widget.identity.publicKeyHex, peerHex);
    await _channels?.leave(dmId);
    if (mounted) setState(() {});
  }

  Future<void> _unblockPeer(String peerHex) async {
    setState(() => _blocked.remove(peerHex));
    await _settings?.unblockUser(peerHex);
    if (mounted) setState(() {});
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
                onLongPress: () {
                  Navigator.pop(context);
                  unawaited(
                    _peerActions(Uint8List.fromList(hex.decode(entry.key))),
                  );
                },
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
            _copyAndClear(invite);
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
    // A dedicated widget owns the per-member controllers so they outlive the
    // dialog's exit animation (disposing them synchronously here would trip a
    // "used after disposed" assertion — same reason as _TextPromptDialog).
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => _AddMembersDialog(
        members: members,
        labelFor: (key) =>
            'hearth#${_fingerprint(Uint8List.fromList(hex.decode(key)))}',
      ),
    );
    if (result != null) {
      for (final entry in result.entries) {
        await _contacts?.setName(entry.key, entry.value);
      }
      if (mounted) setState(() {});
    }
  }

  /// A reusable single-field prompt.
  Future<String?> _promptText({
    required String title,
    required String hint,
    String initial = '',
    String action = 'OK',
  }) {
    return showDialog<String>(
      context: context,
      builder: (context) => _TextPromptDialog(
        title: title,
        hint: hint,
        initial: initial,
        action: action,
      ),
    );
  }

  // --- view ---

  @override
  Widget build(BuildContext context) {
    // Gate: if a mandatory update was detected (startup or from a peer), block.
    if (_updateInfo != null) {
      return _forceUpdateScreen(context);
    }
    final session = _channels?.active;
    // Wide screens get the channel panel inline (right column); narrow screens
    // reach it via the end drawer.
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final panelInline = session != null && wide;
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        flexibleSpace: _EmberGlow(accent: _channelAccent(session)),
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
          if (session != null)
            IconButton(
              onPressed: () => _openSearch(session),
              icon: const Icon(Icons.search),
              tooltip: 'Search messages',
            ),
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
                      Expanded(
                        child: PageTransitionSwitcher(
                          duration: const Duration(milliseconds: 300),
                          transitionBuilder: (child, primary, secondary) =>
                              SharedAxisTransition(
                                animation: primary,
                                secondaryAnimation: secondary,
                                transitionType:
                                    SharedAxisTransitionType.horizontal,
                                fillColor: Colors.transparent,
                                child: child,
                              ),
                          child: KeyedSubtree(
                            key: ValueKey(session.channelId),
                            child: _chatColumn(session),
                          ),
                        ),
                      ),
                      SizedBox(width: 300, child: _channelPanel(session)),
                    ],
                  )
                else
                  PageTransitionSwitcher(
                    duration: const Duration(milliseconds: 300),
                    transitionBuilder: (child, primary, secondary) =>
                        SharedAxisTransition(
                          animation: primary,
                          secondaryAnimation: secondary,
                          transitionType: SharedAxisTransitionType.horizontal,
                          fillColor: Colors.transparent,
                          child: child,
                        ),
                    child: KeyedSubtree(
                      key: ValueKey(session.channelId),
                      child: _chatColumn(session),
                    ),
                  ),
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
              Positioned(
                bottom: 8,
                right: 8,
                child: IgnorePointer(
                  ignoring: !_showScrollDown,
                  child: AnimatedSlide(
                    offset: _showScrollDown ? Offset.zero : const Offset(0, 2),
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    child: AnimatedOpacity(
                      opacity: _showScrollDown ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: FloatingActionButton.small(
                        backgroundColor: _channelAccent(session),
                        onPressed: _showScrollDown
                            ? () => _scroll.animateTo(
                                _scroll.position.maxScrollExtent,
                                duration: const Duration(milliseconds: 200),
                                curve: Curves.easeOut,
                              )
                            : null,
                        tooltip: 'Scroll to bottom',
                        child: const Icon(
                          Icons.keyboard_arrow_down,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        _typingIndicator(session),
        if (_awaitingAccept(session))
          _awaitingAcceptBar(context, session)
        else
          _composer(context, session),
      ],
    );
  }

  /// Joiner side: true while an outbound first-contact DM hasn't connected yet
  /// (the owner hasn't accepted). You can't send into it until they do.
  bool _awaitingAccept(ChannelSession session) =>
      session.isDm &&
      session.peerPubkey != null &&
      _pendingContact.containsKey(hex.encode(session.peerPubkey!));

  /// Replaces the composer while waiting for the owner to accept your request —
  /// you can't message them until they do (they've received nothing yet).
  Widget _awaitingAcceptBar(BuildContext context, ChannelSession session) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(color: scheme.outlineVariant, width: 0.5),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.hourglass_empty, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'Waiting for '
              '${_displayName(Uint8List.fromList(session.peerPubkey!))} '
              'to accept your request',
              style: TextStyle(color: scheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
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
      // Soundboard clips render in the voice panel, not the timeline.
      if (c.isBookkeeping || c is SoundContent) return false;
      // Hide messages from revoked devices (already stored, filter at display).
      if (m.device != null) {
        final devHex = hex.encode(m.device!);
        if (_deviceStore?.isRevoked(devHex) ?? false) return false;
      }
      return true;
    }).toList();
    return messages.isEmpty
        ? const Center(child: Text('No messages yet — say something.'))
        : RefreshIndicator(
            // Pull down at the top to re-announce to the mesh + re-check the
            // relay, tinted in the channel accent.
            color: _channelAccent(session),
            onRefresh: () async {
              _channels?.reconnect();
              await _checkRelay();
            },
            child: ListView.builder(
              controller: _scroll,
              // Always scrollable so pull-to-refresh works even when the
              // messages don't fill the viewport.
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(8),
              itemCount: messages.length,
              itemBuilder: (context, i) {
                final msg = messages[i];
                // Stagger: newer messages (higher index) appear first,
                // older ones cascade in with 50ms delay each (max 300ms).
                final stagger = ((messages.length - 1 - i) * 50)
                    .clamp(0, 300)
                    .toDouble();
                return TweenAnimationBuilder<double>(
                  key: ValueKey(msg.idHex),
                  tween: Tween(begin: 0, end: 1),
                  duration: Duration(milliseconds: 250 + stagger.toInt()),
                  curve: Curves.easeOutCubic,
                  builder: (context, value, child) {
                    // Delay the visual start by the stagger amount.
                    final progress = ((value * (250 + stagger) - stagger) / 250)
                        .clamp(0.0, 1.0);
                    return Opacity(
                      opacity: progress,
                      child: Transform.translate(
                        offset: Offset(0, 12 * (1 - progress)),
                        child: child,
                      ),
                    );
                  },
                  child: _bubble(context, session, msg),
                );
              },
            ),
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
    final requests = _requests.toList();
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
                      leading: Icon(Icons.tag, color: _channelAccent(s)),
                      title: Text(_channelTitle(s)),
                      selected: s.channelId == channels?.activeId,
                      selectedColor: _channelAccent(s),
                      selectedTileColor: _channelAccent(s).withAlpha(28),
                      trailing: _unreadBadge(s),
                      onTap: () {
                        channels?.activate(s.channelId);
                        _markRead(s);
                        _replyTo = null;
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
                    title: const Text('Add via invite or card'),
                    onTap: () {
                      Navigator.pop(context);
                      unawaited(_joinViaInvite());
                    },
                  ),
                  if (requests.isNotEmpty) ...[
                    _drawerHeader('Message requests'),
                    for (final peerHex in requests)
                      ListTile(
                        leading: const Icon(Icons.mark_email_unread_outlined),
                        title: Text(
                          _displayName(Uint8List.fromList(hex.decode(peerHex))),
                        ),
                        subtitle: const Text('wants to message you'),
                        onTap: () {
                          Navigator.pop(context);
                          unawaited(_requestActions(peerHex));
                        },
                      ),
                  ],
                  _drawerHeader('Direct messages'),
                  ListTile(
                    leading: const Icon(Icons.add),
                    title: const Text('New message'),
                    onTap: () {
                      Navigator.pop(context);
                      unawaited(_newDm());
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.qr_code_2),
                    title: const Text('Share my contact'),
                    onTap: () {
                      Navigator.pop(context);
                      unawaited(_shareMyContact());
                    },
                  ),
                  for (final s in dms)
                    ListTile(
                      leading: Icon(
                        Icons.alternate_email,
                        color: _channelAccent(s),
                      ),
                      title: Text(_channelTitle(s)),
                      selected: s.channelId == channels?.activeId,
                      selectedColor: _channelAccent(s),
                      selectedTileColor: _channelAccent(s).withAlpha(28),
                      trailing: _unreadBadge(s),
                      onTap: () {
                        channels?.activate(s.channelId);
                        _markRead(s);
                        _replyTo = null;
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
            Tooltip(
              message: 'Set your avatar',
              child: GestureDetector(
                onTap: () => unawaited(_setMyAvatar()),
                child: _myAvatar != null
                    ? _avatar(widget.identity.publicKey, radius: 15)
                    : Icon(
                        Icons.local_fire_department,
                        color: theme.colorScheme.primary,
                        size: 28,
                      ),
              ),
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
      final lastId = ordered.last.idHex;
      _unread?.markRead(session.channelId, lastId);
      if (!_readReceiptsDisabled.contains(session.channelId) &&
          _lastBroadcastWatermark[session.channelId] != lastId) {
        _lastBroadcastWatermark[session.channelId] = lastId;
        session.broadcast(
          ReadWatermarkControl(channelId: session.channelId, messageId: lastId),
        );
      }
    }
  }

  /// Resolves any watermark message IDs that weren't in our DAG when received.
  void _backfillWatermarkTs(ChannelSession session) {
    final ch = session.channelId;
    final watermarks = _readWatermarks[ch];
    if (watermarks == null) return;
    final cache = _watermarkTs[ch] ??= {};
    final uncached = watermarks.values.where((id) => !cache.containsKey(id));
    if (uncached.isEmpty) return;
    final ordered = session.repository.ordered();
    final tsMap = <String, int>{
      for (final m in ordered) m.idHex: m.timestampMs,
    };
    for (final id in uncached) {
      final ts = tsMap[id];
      if (ts != null) cache[id] = ts;
    }
  }

  Widget? _unreadBadge(ChannelSession session) {
    final unread = _unread;
    if (unread == null) return null;
    final ids = session.repository.ordered().map((m) => m.idHex).toList();
    final count = unread.unreadCount(session.channelId, ids);
    if (count <= 0) return null;
    final accent = _channelAccent(session);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: accent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: TextStyle(
          color: ThemeData.estimateBrightnessForColor(accent) == Brightness.dark
              ? Colors.white
              : Colors.black87,
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
    String messageId,
  ) {
    return switch (content) {
      TextContent(:final text) =>
        _isSingleEmoji(text)
            ? Text(text, style: const TextStyle(fontSize: 48))
            : MarkdownText(
                text,
                mentionLabel: _mentionLabel,
                onMentionTap: (h) =>
                    unawaited(_peerActions(Uint8List.fromList(hex.decode(h)))),
              ),
      GifContent(:final blob) => _imageBlobView(session, blob, messageId),
      StickerContent(:final blob) => _imageBlobView(session, blob, messageId),
      SoundContent(:final blob, :final name, :final emoji) => _soundView(
        session,
        blob,
        name,
        emoji,
      ),
      VoiceContent(:final blob, :final durationMs) => _voiceView(
        session,
        blob,
        durationMs,
      ),
      FileContent(:final blob, :final name, :final mime) =>
        mime.startsWith('image/')
            ? _imageBlobView(session, blob, messageId)
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
      // Reactions are rendered as chips on their target, not inline.
      ReactionContent() => const SizedBox.shrink(),
      // Edits/tombstones render as their target's state, never inline.
      EditContent() => const SizedBox.shrink(),
      DeleteContent() => const SizedBox.shrink(),
      DeviceBundleContent() => const SizedBox.shrink(),
    };
  }

  /// A non-image file attachment shown as a labelled chip.
  Widget _fileChip(String name) => Chip(
    avatar: const Icon(Icons.insert_drive_file_outlined, size: 18),
    label: Text(name),
  );

  /// A voice message — play/pause + progress once its audio blob has been
  /// fetched, a duration chip with a spinner while it's still coming from peers.
  Widget _voiceView(ChannelSession session, String blob, int durationMs) {
    final bytes = session.blobOf(blob);
    if (bytes == null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Static icon under `flutter test` — a spinner never settles.
          if (_ambientAnimations)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            const Icon(Icons.mic_none, size: 18),
          const SizedBox(width: 8),
          Text('Voice message · ${formatClipTime(durationMs)}'),
        ],
      );
    }
    return _VoiceBubble(
      key: ValueKey('voice:$blob'),
      bytes: bytes,
      durationMs: durationMs,
    );
  }

  /// An image blob — sticker or GIF — once fetched (spinner until then).
  /// Image.memory animates GIFs.
  Widget _imageBlobView(ChannelSession session, String blob, String messageId) {
    final bytes = session.blobOf(blob);
    if (bytes == null) {
      return const SizedBox(
        width: 120,
        height: 120,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final tag = 'img:$messageId:$blob'; // unique even if a blob repeats
    return GestureDetector(
      onTap: () => _openImageViewer(tag, bytes),
      child: Hero(
        tag: tag,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220, maxWidth: 260),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              bytes,
              fit: BoxFit.contain,
              // Peer-sent blobs can be up to 10 MB — decode at the bubble's
              // display size, never at whatever resolution the peer chose.
              // (The tap-to-open viewer decodes full-res, as it should.)
              cacheWidth: (260 * MediaQuery.devicePixelRatioOf(context))
                  .round(),
            ),
          ),
        ),
      ),
    );
  }

  /// Opens a full-screen, pinch-zoomable image viewer with a Hero flight from
  /// the tapped thumbnail. Tap anywhere (or swipe down) to dismiss.
  void _openImageViewer(String tag, Uint8List bytes) {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black.withAlpha(230),
        transitionDuration: const Duration(milliseconds: 250),
        pageBuilder: (ctx, _, _) => GestureDetector(
          onTap: () => Navigator.of(ctx).pop(),
          child: Dismissible(
            key: const Key('image-viewer'),
            direction: DismissDirection.vertical,
            onDismissed: (_) => Navigator.of(ctx).pop(),
            child: Center(
              child: Hero(
                tag: tag,
                child: InteractiveViewer(
                  minScale: 0.8,
                  maxScale: 5,
                  child: Image.memory(bytes, fit: BoxFit.contain),
                ),
              ),
            ),
          ),
        ),
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
  /// This user's hue (0–360), from the first pubkey byte.
  double _userHue(Uint8List author) =>
      (author.isNotEmpty ? author[0] : 0) * 360.0 / 256.0;

  Color _userColor(Uint8List author) {
    // Lighter on the dark theme, darker on light — so it reads on either surface.
    final dark = Theme.of(context).brightness == Brightness.dark;
    return oklch(dark ? 0.72 : 0.5, dark ? 0.13 : 0.15, _userHue(author));
  }

  /// A unique accent colour for a channel, derived from its ID.
  /// DMs use the peer's colour; groups derive from channel ID bytes.
  Color _channelAccent(ChannelSession? session) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final l = dark ? 0.66 : 0.5;
    final c = dark ? 0.12 : 0.14;
    if (session == null) return oklch(l, c, 285); // default violet
    if (session.isDm && session.peerPubkey != null) {
      return _userColor(Uint8List.fromList(session.peerPubkey!));
    }
    final bytes = session.channelId.codeUnits;
    final hue = (bytes.isNotEmpty ? bytes[0] + bytes[1] : 0) * 360.0 / 512.0;
    return oklch(l, c, hue);
  }

  /// A small colour-coded avatar with a subtle two-stop gradient derived from
  /// two pubkey bytes — deterministic, so each identity keeps a recognisable
  /// look. When the author has shared an avatar image (self-asserted profile),
  /// it renders inside the gradient, which stays visible as a ring — the
  /// pubkey-derived colours remain the spoof-resistant cue; the picture is
  /// just decoration.
  Widget _avatar(Uint8List author, {double radius = 16}) {
    final label = _displayName(author).replaceFirst('hearth#', '');
    final initial = label.isEmpty ? '?' : label[0].toUpperCase();
    final hue = _userHue(author);
    // Second stop shifts hue by a byte-derived amount for variety.
    final hue2 = hue + (author.length > 1 ? author[1] : 40) * 80.0 / 256.0 + 20;
    final image = _avatarBytes[hex.encode(author)];
    return Container(
      width: radius * 2,
      height: radius * 2,
      padding: image != null ? const EdgeInsets.all(1.5) : null,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [oklch(0.75, 0.14, hue), oklch(0.6, 0.14, hue2)],
        ),
      ),
      alignment: Alignment.center,
      child: image != null
          ? ClipOval(
              child: Image.memory(
                image,
                fit: BoxFit.cover,
                width: radius * 2,
                height: radius * 2,
                // Decode at display size — never at whatever the peer sent.
                cacheWidth:
                    (radius * 2 * MediaQuery.devicePixelRatioOf(context))
                        .round(),
                gaplessPlayback: true,
              ),
            )
          : Text(
              initial,
              style: TextStyle(
                fontSize: radius * 0.85,
                fontWeight: FontWeight.w600,
                color: Colors.black.withAlpha(160),
              ),
            ),
    );
  }

  Widget _tickIcon(ChannelSession session, Message message) {
    final channelId = session.channelId;
    final watermarks = _readWatermarks[channelId] ?? {};
    final members = _membersOf(session);
    final peers = session.mesh?.peers ?? [];
    final msgTs = message.timestampMs;

    // Count members whose watermark is at or past this message (by timestamp).
    var readBy = 0;
    for (final wmId in watermarks.values) {
      // Watermark is always the latest message they saw — compare timestamps.
      // The watermark timestamp is cached in _watermarkTs for O(1) lookup.
      final wmTs = _watermarkTs[channelId]?[wmId];
      if (wmTs != null && wmTs >= msgTs) readBy++;
    }

    final delivered = peers.isNotEmpty;
    final readAll = members.isNotEmpty && readBy >= members.length;
    final readSome = readBy > 0;

    final Color color;
    final IconData icon;
    if (readAll) {
      color = Colors.blue;
      icon = Icons.done_all;
    } else if (readSome) {
      color = Colors.blue.shade200;
      icon = Icons.done_all;
    } else if (delivered) {
      color = Colors.grey;
      icon = Icons.done_all;
    } else {
      color = Colors.grey;
      icon = Icons.done;
    }
    return GestureDetector(
      onTap: () => _showReadDetails(session, message),
      child: Icon(icon, size: 14, color: color),
    );
  }

  void _showReadDetails(ChannelSession session, Message message) {
    final watermarks = _readWatermarks[session.channelId] ?? {};
    final wmTs = _watermarkTs[session.channelId] ?? {};
    final members = _membersOf(session);
    final msgTs = message.timestampMs;
    final peers = session.mesh?.peers ?? [];

    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Message status', style: Theme.of(ctx).textTheme.titleSmall),
            const SizedBox(height: 12),
            for (final member in members)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: _avatar(
                  Uint8List.fromList(hex.decode(member)),
                  radius: 14,
                ),
                title: Text(
                  _displayName(Uint8List.fromList(hex.decode(member))),
                ),
                trailing: Builder(
                  builder: (_) {
                    final wmId = watermarks[member];
                    if (wmId != null) {
                      final ts = wmTs[wmId] ?? 0;
                      if (ts >= msgTs) {
                        return const Text(
                          'Read',
                          style: TextStyle(color: Colors.blue, fontSize: 12),
                        );
                      }
                    }
                    if (peers.contains(member)) {
                      return const Text(
                        'Delivered',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      );
                    }
                    return const Text(
                      'Sent',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Long-press menu on a message: Reply, React, or Pin.
  void _messageActions(ChannelSession session, Message message) {
    final quickEmojis = ['👍', '❤️', '😂', '😮', '😢', '🔥'];
    final pinned = _pinnedMessages[session.channelId] ?? {};
    final isPinned = pinned.contains(message.idHex);
    final mine = listEquals(message.author, widget.identity.publicKey);
    final editable = mine && _effectiveContent(session, message) is TextContent;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final emoji in quickEmojis)
                    GestureDetector(
                      onTapDown: (d) => _lastReactTap = d.globalPosition,
                      onTap: () {
                        Navigator.pop(ctx);
                        unawaited(
                          _publish(ReactionContent(message.idHex, emoji)),
                        );
                        _showReactionBurst(emoji, _lastReactTap);
                      },
                      child: Text(emoji, style: const TextStyle(fontSize: 28)),
                    ),
                ],
              ),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('Reply'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _replyTo = message;
                  _editing = null;
                });
              },
            ),
            ListTile(
              leading: Icon(
                isPinned ? Icons.push_pin : Icons.push_pin_outlined,
              ),
              title: Text(isPinned ? 'Unpin' : 'Pin'),
              onTap: () {
                Navigator.pop(ctx);
                _togglePin(session.channelId, message.idHex);
              },
            ),
            if (editable)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit'),
                onTap: () {
                  Navigator.pop(ctx);
                  _startEdit(session, message);
                },
              ),
            if (mine)
              ListTile(
                leading: Icon(
                  Icons.delete_outline,
                  color: Theme.of(ctx).colorScheme.error,
                ),
                title: Text(
                  'Delete',
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  unawaited(_confirmDelete(message));
                },
              ),
          ],
        ),
      ),
    );
  }

  /// Puts the composer into edit mode, prefilled with the message's current
  /// (post-edit) text. Sending publishes an [EditContent] instead of a new
  /// message.
  void _startEdit(ChannelSession session, Message message) {
    final content = _effectiveContent(session, message);
    if (content is! TextContent) return;
    setState(() {
      _editing = message;
      _replyTo = null;
    });
    _input.text = content.text;
    _input.selection = TextSelection.collapsed(offset: content.text.length);
    _composerFocus.requestFocus();
  }

  /// Leaves edit mode, dropping the prefilled draft. Called when a non-text
  /// send (GIF, sticker, file, voice) happens while the edit banner is up —
  /// otherwise edit mode stays silently armed and the *next* text send
  /// rewrites the old message instead of posting a new one.
  void _exitEditMode() {
    if (_editing == null) return;
    setState(() => _editing = null);
    _input.clear();
  }

  /// Confirms, then publishes a [DeleteContent] tombstone. The message stays in
  /// the DAG (append-only) but renders as "Message deleted" for everyone.
  Future<void> _confirmDelete(Message message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete message?'),
        content: const Text(
          'It will show as deleted for everyone in this channel.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Delete',
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (_editing?.idHex == message.idHex) {
      setState(() => _editing = null);
      _input.clear();
    }
    await _publish(DeleteContent(message.idHex));
  }

  /// A short particle burst of [emoji] from [origin] when you add a reaction.
  void _showReactionBurst(String emoji, Offset origin) {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _ReactionBurst(
        emoji: emoji,
        origin: origin,
        onDone: () => entry.remove(),
      ),
    );
    overlay.insert(entry);
  }

  void _togglePin(String channelId, String messageId) {
    setState(() {
      final pins = _pinnedMessages[channelId] ??= {};
      if (pins.contains(messageId)) {
        pins.remove(messageId);
      } else {
        pins.add(messageId);
      }
    });
    final pins = _pinnedMessages[channelId] ?? {};
    unawaited(
      _settings?.setChannelPref(
        channelId,
        'pinned',
        pins.isEmpty ? null : pins.join(','),
      ),
    );
  }

  /// Opens a search dialog for the current channel's messages.
  void _openSearch(ChannelSession session) {
    var query = '';
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (ctx, scrollController) => StatefulBuilder(
          builder: (ctx, setLocal) {
            final results = query.isEmpty
                ? <Message>[]
                : session.repository
                      .ordered()
                      .where((m) {
                        if (session.isDeleted(m.idHex)) return false;
                        final content = _effectiveContent(session, m);
                        if (content is TextContent) {
                          // Match against resolved @names, not raw <@hex>.
                          return stripMentions(
                            content.text,
                            _mentionLabel,
                          ).toLowerCase().contains(query.toLowerCase());
                        }
                        return false;
                      })
                      .toList()
                      .reversed
                      .toList();
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  TextField(
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'Search messages…',
                      prefixIcon: Icon(Icons.search),
                      isDense: true,
                    ),
                    onChanged: (v) => setLocal(() => query = v),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: results.isEmpty
                        ? Center(
                            child: Text(
                              query.isEmpty ? 'Type to search' : 'No results',
                              style: const TextStyle(color: Colors.grey),
                            ),
                          )
                        : ListView.builder(
                            controller: scrollController,
                            itemCount: results.length,
                            itemBuilder: (ctx, i) {
                              final msg = results[i];
                              // Effective content — the filter matched the
                              // post-edit text, so show that, not the original;
                              // mention tokens resolved to readable @names.
                              final text = stripMentions(
                                (_effectiveContent(session, msg) as TextContent)
                                    .text,
                                _mentionLabel,
                              );
                              return ListTile(
                                dense: true,
                                leading: _avatar(msg.author, radius: 12),
                                title: Text(
                                  _displayName(msg.author),
                                  style: const TextStyle(fontSize: 12),
                                ),
                                subtitle: Text(
                                  text,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 12),
                                ),
                                trailing: Text(
                                  _time(msg.timestampMs),
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: Colors.grey,
                                  ),
                                ),
                                onTap: () => Navigator.pop(ctx),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  void _showPinned(ChannelSession session) {
    final pins = _pinnedMessages[session.channelId] ?? {};
    final ordered = session.repository.ordered();
    final pinned = ordered.where((m) => pins.contains(m.idHex)).toList();
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Pinned messages',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              if (pinned.isEmpty)
                const Text(
                  'No pinned messages',
                  style: TextStyle(color: Colors.grey),
                )
              else
                for (final msg in pinned)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: _avatar(msg.author, radius: 12),
                    title: Text(
                      _displayName(msg.author),
                      style: const TextStyle(fontSize: 12),
                    ),
                    subtitle: Text(
                      _contentPreview(session, msg),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.push_pin, size: 16),
                      onPressed: () {
                        _togglePin(session.channelId, msg.idHex);
                        Navigator.pop(ctx);
                      },
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }

  String _contentPreview(
    ChannelSession session,
    Message msg, {
    int maxLength = 60,
  }) {
    if (session.isDeleted(msg.idHex)) return 'Message deleted';
    final content = _effectiveContent(session, msg);
    if (content is TextContent) {
      final shown = stripMentions(content.text, _mentionLabel);
      return shown.length > maxLength
          ? '${shown.substring(0, maxLength)}…'
          : shown;
    }
    if (content is GifContent) return 'GIF';
    if (content is StickerContent) return 'Sticker';
    if (content is SoundContent) return '🔊 ${content.name}';
    if (content is FileContent) return '📎 ${content.name}';
    if (content is VoiceContent) {
      return '🎤 Voice message (${formatClipTime(content.durationMs)})';
    }
    if (content is ReactionContent) return '${content.emoji} reacted';
    return 'Message';
  }

  /// The content a message should *render* as: its winning edit's text (with
  /// the original replyTo preserved) when validly edited, else the original.
  /// Edits only apply to text messages; check [ChannelSession.isDeleted] first.
  Content _effectiveContent(ChannelSession session, Message message) {
    final content = session.contentOf(message);
    final edit = session.editOf(message.idHex);
    if (edit != null && content is TextContent) {
      return TextContent(edit.text, replyTo: content.replyTo);
    }
    return content;
  }

  /// Computes reactions for a message: {emoji: [authorHex, ...]}.
  /// A second react with the same emoji from the same author = toggle off.
  Map<String, List<String>> _reactionsFor(
    ChannelSession session,
    String messageId,
  ) {
    final reactions = <String, Set<String>>{};
    for (final msg in session.repository.ordered()) {
      final content = session.contentOf(msg);
      if (content is ReactionContent && content.targetId == messageId) {
        final authorHex = hex.encode(msg.author);
        final set = reactions[content.emoji] ??= {};
        if (set.contains(authorHex)) {
          set.remove(authorHex); // toggle off
        } else {
          set.add(authorHex);
        }
      }
    }
    // Remove empty entries.
    reactions.removeWhere((_, v) => v.isEmpty);
    return reactions.map((k, v) => MapEntry(k, v.toList()));
  }

  Widget _bubble(
    BuildContext context,
    ChannelSession session,
    Message message,
  ) {
    final mine = listEquals(message.author, widget.identity.publicKey);
    final authorHex = hex.encode(message.author);

    // Blocked users in group channels: show redacted placeholder.
    if (!mine && !session.isDm && _blocked.contains(authorHex)) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.72,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.surfaceContainerHigh.withAlpha(100),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(12),
                topRight: Radius.circular(12),
                bottomRight: Radius.circular(12),
              ),
            ),
            child: Text(
              'Blocked message',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ),
      );
    }
    // Blocked users in DMs: skip entirely (invisible).
    if (!mine && session.isDm && _blocked.contains(authorHex)) {
      return const SizedBox.shrink();
    }
    // Reactions render as chips on their target, edits/tombstones as the
    // target's own state — no bookkeeping envelope gets a bubble of its own.
    final rawContent = session.contentOf(message);
    if (rawContent.isBookkeeping) return const SizedBox.shrink();
    // Deleted messages: an inert placeholder (no actions, no reactions).
    if (session.isDeleted(message.idHex)) {
      return Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.surfaceContainerHigh.withAlpha(100),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              'Message deleted',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ),
      );
    }

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
          _contentView(
            context,
            session,
            _effectiveContent(session, message),
            message.idHex,
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (session.editOf(message.idHex) != null &&
                      rawContent is TextContent)
                    Padding(
                      padding: const EdgeInsets.only(right: 3),
                      child: Text(
                        'edited',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontSize: 9,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  if ((_pinnedMessages[session.channelId] ?? {}).contains(
                    message.idHex,
                  ))
                    Padding(
                      padding: const EdgeInsets.only(right: 3),
                      child: Icon(
                        Icons.push_pin,
                        size: 10,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  Text(
                    _time(message.timestampMs),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontSize: 10,
                    ),
                  ),
                  if (mine)
                    Padding(
                      padding: const EdgeInsets.only(left: 3),
                      child: _tickIcon(session, message),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    // Quoted reply preview above the bubble if this message is a reply.
    final content = session.contentOf(message);
    Widget? quoteWidget;
    if (content.replyTo != null) {
      final original = session.repository.ordered().cast<Message?>().firstWhere(
        (m) => m!.idHex == content.replyTo,
        orElse: () => null,
      );
      if (original != null) {
        final origText = _contentPreview(session, original);
        final origName = _displayName(original.author);
        quoteWidget = Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: _userColor(original.author), width: 3),
            ),
            color: Theme.of(
              context,
            ).colorScheme.surfaceContainerHigh.withAlpha(80),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                origName,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: _userColor(original.author),
                ),
              ),
              Text(
                origText,
                style: const TextStyle(fontSize: 11),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        );
      }
    }
    final bubbleWithQuote = quoteWidget != null
        ? Column(
            crossAxisAlignment: mine
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [quoteWidget, bubble],
          )
        : bubble;
    // Reaction chips below the bubble.
    final reactions = _reactionsFor(session, message.idHex);
    final bubbleFinal = reactions.isEmpty
        ? bubbleWithQuote
        : Column(
            crossAxisAlignment: mine
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              bubbleWithQuote,
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Wrap(
                  spacing: 4,
                  children: [
                    for (final entry in reactions.entries)
                      GestureDetector(
                        onTap: () => unawaited(
                          _publish(ReactionContent(message.idHex, entry.key)),
                        ),
                        child: TweenAnimationBuilder<double>(
                          key: ValueKey('${entry.key}:${entry.value.length}'),
                          tween: Tween(begin: 1.3, end: 1.0),
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.elasticOut,
                          builder: (context, scale, child) =>
                              Transform.scale(scale: scale, child: child),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color:
                                  entry.value.contains(
                                    widget.identity.publicKeyHex,
                                  )
                                  ? Theme.of(
                                      context,
                                    ).colorScheme.primaryContainer
                                  : Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '${entry.key} ${entry.value.length}',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
    return GestureDetector(
      onLongPress: () => _messageActions(session, message),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: mine
            ? Align(alignment: Alignment.centerRight, child: bubbleFinal)
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    onTap: () => unawaited(_peerActions(message.author)),
                    child: _avatar(message.author),
                  ),
                  const SizedBox(width: 8),
                  Flexible(child: bubbleFinal),
                ],
              ),
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
    final label = names.length == 1 ? names[0] : names.join(', ');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontStyle: FontStyle.italic,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 4),
          const _BouncingDots(),
        ],
      ),
    );
  }

  String _replyPreview(ChannelSession session) {
    final msg = _replyTo;
    if (msg == null) return '';
    return _contentPreview(session, msg);
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_editing != null)
            Container(
              padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
              color: scheme.surfaceContainerHigh.withAlpha(120),
              child: Row(
                children: [
                  Icon(Icons.edit_outlined, size: 16, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Editing message',
                      style: TextStyle(fontSize: 11, color: scheme.primary),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () {
                      setState(() => _editing = null);
                      _input.clear();
                    },
                  ),
                ],
              ),
            ),
          if (_replyTo != null)
            Container(
              padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
              color: scheme.surfaceContainerHigh.withAlpha(120),
              child: Row(
                children: [
                  Container(
                    width: 3,
                    height: 28,
                    color: _userColor(_replyTo!.author),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _displayName(_replyTo!.author),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: _userColor(_replyTo!.author),
                          ),
                        ),
                        Text(
                          _replyPreview(session),
                          style: const TextStyle(fontSize: 11),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => setState(() => _replyTo = null),
                  ),
                ],
              ),
            ),
          if (_recordStart != null)
            _recordingBar(context, session)
          else
            Row(
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
                if (!session.isDm)
                  IconButton(
                    onPressed: () => unawaited(_insertMention(session)),
                    icon: const Icon(Icons.alternate_email),
                    tooltip: 'Mention',
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
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(24),
                                borderSide: BorderSide(
                                  color: _channelAccent(session),
                                  width: 1.5,
                                ),
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
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                              borderSide: BorderSide(
                                color: _channelAccent(session),
                                width: 1.5,
                              ),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                          ),
                        ),
                ),
                if (!kIsWeb)
                  IconButton(
                    onPressed: () => unawaited(_startVoiceRecording()),
                    icon: const Icon(Icons.mic_none),
                    tooltip: 'Voice message',
                    focusNode: FocusNode(skipTraversal: true),
                  ),
                const SizedBox(width: 8),
                _SendButton(
                  color: _channelAccent(session),
                  onPressed: _sending ? null : () => unawaited(_send()),
                ),
              ],
            ),
        ],
      ),
    );
  }

  /// The composer while a voice message records: red mic, ticking elapsed
  /// time, discard and send.
  Widget _recordingBar(BuildContext context, ChannelSession session) {
    final scheme = Theme.of(context).colorScheme;
    final elapsed = DateTime.now().difference(_recordStart ?? DateTime.now());
    return Row(
      children: [
        const SizedBox(width: 12),
        Icon(Icons.mic, color: scheme.error),
        const SizedBox(width: 8),
        Text(
          formatClipTime(elapsed.inMilliseconds),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Recording…',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
        IconButton(
          onPressed: () => unawaited(_cancelVoiceRecording()),
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Discard',
        ),
        _SendButton(
          color: _channelAccent(session),
          onPressed: () => unawaited(_sendVoiceRecording()),
        ),
      ],
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

/// A single-field prompt dialog that owns its [TextEditingController] and
/// disposes it on unmount — so the controller outlives the dialog's exit
/// animation (disposing it synchronously right after `showDialog` returns
/// trips a "used after being disposed" assertion while the field animates out).
class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.hint,
    required this.initial,
    required this.action,
  });

  final String title;
  final String hint;
  final String initial;
  final String action;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _controller,
      autofocus: true,
      decoration: InputDecoration(hintText: widget.hint),
      onSubmitted: (value) => Navigator.pop(context, value),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _controller.text),
        child: Text(widget.action),
      ),
    ],
  );
}

/// Bulk "add channel members to contacts" dialog. Owns one editable petname
/// controller per member and disposes them on unmount (so they outlive the
/// dialog's exit animation). Pops a map of the ticked members' final names
/// (empty ones dropped), or null if cancelled.
class _AddMembersDialog extends StatefulWidget {
  const _AddMembersDialog({required this.members, required this.labelFor});

  final Map<String, String> members; // pubkeyHex -> suggested name
  final String Function(String key) labelFor;

  @override
  State<_AddMembersDialog> createState() => _AddMembersDialogState();
}

class _AddMembersDialogState extends State<_AddMembersDialog> {
  late final Map<String, bool> _selected = {
    for (final key in widget.members.keys) key: true,
  };
  late final Map<String, TextEditingController> _controllers = {
    for (final entry in widget.members.entries)
      entry.key: TextEditingController(text: entry.value),
  };

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add members to contacts'),
    content: SizedBox(
      width: double.maxFinite,
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final key in widget.members.keys)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Checkbox(
                    value: _selected[key],
                    onChanged: (v) =>
                        setState(() => _selected[key] = v ?? false),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _controllers[key],
                      decoration: InputDecoration(
                        isDense: true,
                        labelText: widget.labelFor(key),
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
        onPressed: () => Navigator.pop(context),
        child: const Text('Not now'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, <String, String>{
          for (final key in widget.members.keys)
            if (_selected[key] == true &&
                _controllers[key]!.text.trim().isNotEmpty)
              key: _controllers[key]!.text.trim(),
        }),
        child: const Text('Add selected'),
      ),
    ],
  );
}

/// A one-shot particle burst of an emoji, spraying upward-ish from [origin] and
/// fading over ~700ms — shown as an overlay when a reaction is added. Calls
/// [onDone] when finished so the overlay entry can remove itself.
class _ReactionBurst extends StatefulWidget {
  const _ReactionBurst({
    required this.emoji,
    required this.origin,
    required this.onDone,
  });

  final String emoji;
  final Offset origin;
  final VoidCallback onDone;

  @override
  State<_ReactionBurst> createState() => _ReactionBurstState();
}

class _ReactionBurstState extends State<_ReactionBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final List<double> _angles;

  @override
  void initState() {
    super.initState();
    final rnd = Random();
    // Six particles spread in an upward-biased fan.
    _angles = List.generate(
      6,
      (_) => -pi / 2 + (rnd.nextDouble() - 0.5) * pi * 0.9,
    );
    _c =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 700),
        )..addStatusListener((s) {
          if (s == AnimationStatus.completed) widget.onDone();
        });
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = Curves.easeOut.transform(_c.value);
          return Stack(
            children: [
              for (final a in _angles)
                Positioned(
                  left: widget.origin.dx + cos(a) * 64 * t - 12,
                  top: widget.origin.dy + sin(a) * 64 * t - 12 - 24 * t,
                  child: Opacity(
                    opacity: (1 - t).clamp(0.0, 1.0),
                    child: Transform.scale(
                      scale: 0.6 + t * 0.7,
                      child: Text(
                        widget.emoji,
                        style: const TextStyle(fontSize: 22),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Audio-reactive concentric rings that pulse outward from a speaking voice
/// participant's avatar — the ring radius/opacity track the live mic [level].
class _SpeakingRings extends StatefulWidget {
  const _SpeakingRings({
    required this.active,
    required this.level,
    required this.color,
    required this.child,
  });

  final bool active;
  final double level; // 0–1, normalised mic level
  final Color color;
  final Widget child;

  @override
  State<_SpeakingRings> createState() => _SpeakingRingsState();
}

class _SpeakingRingsState extends State<_SpeakingRings>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    if (_ambientAnimations) _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 40,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) => CustomPaint(
          painter: _RingPainter(
            phase: _c.value,
            level: widget.active ? widget.level.clamp(0.0, 1.0) : 0.0,
            color: widget.color,
          ),
          child: child,
        ),
        child: Center(child: widget.child),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.phase, required this.level, required this.color});

  final double phase; // 0–1 animation phase
  final double level; // 0–1 mic level (0 = draw nothing)
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (level <= 0.02) return;
    final center = size.center(Offset.zero);
    const baseR = 15.0;
    for (var i = 0; i < 2; i++) {
      final p = (phase + i * 0.5) % 1.0;
      final r = baseR + p * 9 * level;
      final alpha = ((1 - p) * 0.55 * level * 255).round().clamp(0, 255);
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color.withAlpha(alpha),
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.phase != phase || old.level != level;
}

/// A slow, breathing ember glow for the app-bar background — a gradient in the
/// channel [accent] that drifts direction and intensity over ~8s. Subtle, warm,
/// and reinforces the hearth identity without distracting from the content.
class _EmberGlow extends StatefulWidget {
  const _EmberGlow({required this.accent});

  final Color accent;

  @override
  State<_EmberGlow> createState() => _EmberGlowState();
}

/// Whether continuous ambient animations should run. Off under `flutter test`
/// (the test binding is not a [WidgetsFlutterBinding]), where a repeating ticker
/// would make `pumpAndSettle` time out and the motion adds nothing headless.
bool get _ambientAnimations => WidgetsBinding.instance is WidgetsFlutterBinding;

class _EmberGlowState extends State<_EmberGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 8),
  );

  @override
  void initState() {
    super.initState();
    if (_ambientAnimations) _c.repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_c.value);
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(-1 + t * 0.5, -1),
              end: Alignment(1, 1 - t * 0.4),
              colors: [
                widget.accent.withAlpha((20 + 20 * t).round()),
                widget.accent.withAlpha((6 * (1 - t)).round()),
                Colors.transparent,
              ],
              stops: const [0.0, 0.5, 1.0],
            ),
          ),
        );
      },
    );
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
  const _QrScanPage({this.title = 'Scan recovery QR'});
  final String title;
  @override
  State<_QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<_QrScanPage> {
  bool _scanned = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
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

/// Three animated dots that bounce sequentially (typing indicator).
class _BouncingDots extends StatefulWidget {
  const _BouncingDots();

  @override
  State<_BouncingDots> createState() => _BouncingDotsState();
}

class _BouncingDotsState extends State<_BouncingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          // Each dot is offset by 0.2 in the animation cycle.
          final t = (_controller.value + i * 0.2) % 1.0;
          // Bounce: sin curve peaks at 0.5, producing a smooth up-down.
          final offset = -3.0 * (t < 0.5 ? t * 2 : (1 - t) * 2);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: Transform.translate(
              offset: Offset(0, offset),
              child: Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: color.withAlpha(180),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// The composer's send button — a filled icon that plays a one-shot "launch"
/// (the paper plane flies up-and-away and a fresh one settles in) on send.
/// Decodes any picked image and re-encodes it as a small PNG (≤128px on the
/// long side, aspect preserved) so avatars stay tiny for P2P gossip. Throws on
/// undecodable input. Dimensions come from the image header
/// ([ui.ImageDescriptor]) so the pixels are decoded exactly once, at target
/// size — never at native resolution.
Future<Uint8List> downscaleAvatar(Uint8List bytes) async {
  // Everything here is engine-owned memory — dispose all of it on every path,
  // including the undecodable-input throw the caller catches.
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final wide = descriptor.width >= descriptor.height;
    final long = wide ? descriptor.width : descriptor.height;
    codec = await descriptor.instantiateCodec(
      targetWidth: wide ? min(128, long) : null,
      targetHeight: wide ? null : min(128, long),
    );
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('could not encode avatar');
    return data.buffer.asUint8List();
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// mm:ss for a clip length or playback position.
String formatClipTime(int ms) {
  final s = (ms / 1000).round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// Playback UI for a fetched voice message: play/pause, progress bar, time.
/// The [AudioPlayer] is created on first play, so a rendered-but-unplayed
/// bubble never touches the audio plugin (widget tests included).
class _VoiceBubble extends StatefulWidget {
  const _VoiceBubble({
    super.key,
    required this.bytes,
    required this.durationMs,
  });

  final Uint8List bytes;
  final int durationMs;

  @override
  State<_VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<_VoiceBubble> {
  /// The bubble currently playing — starting another pauses it first, so two
  /// voice messages never talk over each other.
  static _VoiceBubbleState? _nowPlaying;

  AudioPlayer? _player;
  bool _playing = false;
  Duration _position = Duration.zero;

  @override
  void dispose() {
    if (identical(_nowPlaying, this)) _nowPlaying = null;
    unawaited(_player?.dispose());
    super.dispose();
  }

  /// Pause triggered by another bubble starting.
  void _yield() {
    unawaited(_player?.pause().catchError((_) {}));
    if (mounted) setState(() => _playing = false);
  }

  Future<void> _toggle() async {
    if (!_playing && !identical(_nowPlaying, this)) {
      _nowPlaying?._yield();
      _nowPlaying = this;
    }
    var player = _player;
    if (player == null) {
      player = _player = AudioPlayer();
      player.onPositionChanged.listen((p) {
        if (mounted) setState(() => _position = p);
      });
      player.onPlayerComplete.listen((_) {
        if (mounted) {
          setState(() {
            _playing = false;
            _position = Duration.zero;
          });
        }
      });
    }
    try {
      if (_playing) {
        await player.pause();
        if (mounted) setState(() => _playing = false);
      } else if (_position > Duration.zero) {
        await player.resume();
        if (mounted) setState(() => _playing = true);
      } else {
        await player.play(BytesSource(widget.bytes));
        if (mounted) setState(() => _playing = true);
      }
    } catch (_) {
      if (mounted) setState(() => _playing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = _playing || _position > Duration.zero;
    final progress = widget.durationMs == 0
        ? 0.0
        : (_position.inMilliseconds / widget.durationMs).clamp(0.0, 1.0);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: () => unawaited(_toggle()),
          icon: Icon(
            _playing ? Icons.pause_circle_filled : Icons.play_circle_filled,
            size: 32,
          ),
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          tooltip: _playing ? 'Pause' : 'Play',
        ),
        SizedBox(
          width: 110,
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 3,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          formatClipTime(active ? _position.inMilliseconds : widget.durationMs),
          style: const TextStyle(fontSize: 12),
        ),
      ],
    );
  }
}

class _SendButton extends StatefulWidget {
  const _SendButton({required this.color, required this.onPressed});

  final Color color;
  final VoidCallback? onPressed;

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _fire() {
    widget.onPressed?.call();
    if (_ambientAnimations) _c.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return _PressableScale(
      child: IconButton.filled(
        style: IconButton.styleFrom(backgroundColor: widget.color),
        onPressed: widget.onPressed == null ? null : _fire,
        icon: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final t = _c.value;
            // First half: fly up-right and fade out. Second half: settle a
            // fresh icon back in from centre.
            final launching = t < 0.5;
            final phase = launching ? t * 2 : (t - 0.5) * 2;
            final eased = Curves.easeOut.transform(phase);
            return Transform.translate(
              offset: launching ? Offset(eased * 14, -eased * 14) : Offset.zero,
              child: Opacity(
                opacity: (launching ? 1 - eased : eased).clamp(0.0, 1.0),
                child: const Icon(Icons.send),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Wraps a child with a subtle scale-down animation on press (0.95x).
class _PressableScale extends StatefulWidget {
  const _PressableScale({required this.child});
  final Widget child;

  @override
  State<_PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<_PressableScale>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );
    _scale = Tween(
      begin: 1.0,
      end: 0.93,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapDown: (_) => _controller.forward(),
      onTapUp: (_) => _controller.reverse(),
      onTapCancel: () => _controller.reverse(),
      child: ScaleTransition(scale: _scale, child: widget.child),
    );
  }
}
