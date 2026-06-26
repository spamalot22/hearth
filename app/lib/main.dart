import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:convert/convert.dart';
import 'package:core/core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

import 'blob_store_hive.dart';
import 'channel.dart';
import 'contacts.dart';
import 'content.dart';
import 'emoji_picker.dart';
import 'gif_search.dart';
import 'group_channel.dart';
import 'key_store.dart';
import 'media_library.dart';
import 'profile.dart';
import 'settings.dart';
import 'sound_search.dart';
import 'starter_sounds.dart';
import 'voice.dart';

/// Relay endpoint for local dev (signalling only).
final Uri kRelayUrl = Uri.parse('http://localhost:8787');

void main() {
  runApp(HearthApp(keyStore: SecureKeyStore()));
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
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  ChannelManager? _channels;
  ContactBook? _contacts;
  ChannelRegistry? _registry;
  BlobStore? _blobStore;
  MediaLibrary? _library;
  AudioPlayer? _player;
  VoiceSession? _voice;
  ProfileStore? _profile;
  SettingsStore? _settings;
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
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  /// Opens contacts + the channel registry, then re-opens every group channel
  /// you've joined. In widget tests (autoPoll off) everything stays in-memory —
  /// no Hive, no WebRTC — and there are no channels.
  Future<void> _init() async {
    final contacts = widget.autoPoll ? await ContactBook.open() : null;
    final registry = widget.autoPoll ? await ChannelRegistry.open() : null;
    final blobStore = widget.autoPoll ? await HiveBlobStore.open() : null;
    final library = widget.autoPoll ? await MediaLibrary.open() : null;
    final profile = widget.autoPoll ? await ProfileStore.open() : null;
    final settings = widget.autoPoll ? await SettingsStore.open() : null;
    _settings = settings;
    final savedRelay = settings?.relayUrl;
    if (savedRelay != null) {
      final parsed = Uri.tryParse(savedRelay);
      if (parsed != null && parsed.hasScheme && parsed.hasAuthority) {
        _relayUrl = parsed;
      }
    }
    if (widget.autoPoll) unawaited(_checkRelay());
    if (blobStore != null && library != null) {
      await loadStarterSounds(blobStore, library);
    }
    final channels = ChannelManager(
      identity: widget.identity,
      relayUrl: _relayUrl,
      live: widget.autoPoll,
      onUpdate: _onUpdate,
      blobStore: blobStore,
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
      _player = widget.autoPoll ? AudioPlayer() : null;
      _channels = channels;
    });
    // Decrypt the active channel's loaded history: the onUpdate calls during the
    // open loop above ran before _channels was set, so they were no-ops.
    unawaited(_refresh());
  }

  void _onUpdate() => unawaited(_refresh());

  /// Decrypts the active channel's new messages, indexes any media into your
  /// library, then re-renders.
  Future<void> _refresh() async {
    final active = _channels?.active;
    await active?.refreshContent();
    if (active != null) {
      await _indexLibrary(active);
      _indexProfiles(active);
      _detectNewMembers(active);
      // Publish our own name into a channel the first time we're active in it.
      if (_myName != null && _announced.add(active.channelId)) {
        await _announceName(active);
      }
    }
    if (mounted) setState(() {});
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
    await session.engine.publish(message);
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
  Set<String> _membersOf(ChannelSession session) {
    final self = hex.encode(widget.identity.publicKey);
    return {
      for (final message in session.repository.ordered())
        if (hex.encode(message.author) != self) hex.encode(message.author),
    };
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
    final code = hex.encode(await widget.identity.extractSeed());
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Back up your identity'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Save this recovery code somewhere safe. Anyone who has it can '
              'become you — never share it. It is the only way to restore your '
              'identity if you lose this device.',
            ),
            const SizedBox(height: 12),
            SelectableText(
              code,
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
              Clipboard.setData(ClipboardData(text: code));
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
    final code = await _promptText(
      title: 'Restore identity',
      hint: 'paste your recovery code',
      action: 'Restore',
    );
    if (code == null || code.trim().isEmpty) return;
    Uint8List? seed;
    try {
      final bytes = Uint8List.fromList(hex.decode(code.trim()));
      if (bytes.length == 32) seed = bytes;
    } catch (_) {
      seed = null;
    }
    if (seed == null) {
      if (mounted) setState(() => _error = 'invalid recovery code');
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
      setState(() {
        _relayUp = up;
        _checkingRelay = false;
      });
    }
  }

  /// A coloured dot + label for the relay's reachability.
  Widget _relayStatus() {
    final Color color;
    final String label;
    if (_checkingRelay) {
      (color, label) = (Colors.grey, 'checking…');
    } else if (_relayUp == null) {
      (color, label) = (Colors.grey, 'not checked');
    } else if (_relayUp!) {
      (color, label) = (Colors.green, 'responding');
    } else {
      (color, label) = (Colors.red, 'unreachable');
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(color: color, fontSize: 12)),
      ],
    );
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
    final trimmed = entered.trim();
    final parsed = Uri.tryParse(trimmed);
    if (trimmed.isEmpty ||
        parsed == null ||
        !parsed.hasScheme ||
        !parsed.hasAuthority) {
      if (mounted) setState(() => _error = 'invalid relay URL');
      return;
    }
    await _settings?.setRelayUrl(trimmed);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Relay saved'),
        content: Text('Restart Hearth to connect via\n$trimmed'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    unawaited(_channels?.close());
    unawaited(_voice?.leave());
    unawaited(_player?.dispose());
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    await _publish(TextContent(text));
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
        if (mounted) setState(() => _error = 'could not fetch that GIF');
        return;
      }
      final hash = await store.put(res.bodyBytes);
      await _publish(GifContent(hash));
    } catch (_) {
      if (mounted) setState(() => _error = 'could not fetch that GIF');
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
    final hash = await store.put(bytes);
    await _publish(FileContent(hash, file.name, _mimeFor(file.extension)));
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
    final emoji = await pickEmoji(context) ?? '🔊';
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
        if (mounted) setState(() => _error = 'could not fetch that sound');
        return;
      }
      if (!mounted) return;
      final emoji = await pickEmoji(context) ?? '🔊';
      final hash = await store.put(res.bodyBytes);
      await _publish(SoundContent(hash, picked.name, emoji));
    } catch (_) {
      if (mounted) setState(() => _error = 'could not fetch that sound');
    }
  }

  /// Sound button: play the channel soundboard, search the CC0 library, or
  /// upload your own file.
  Future<void> _addSound(ChannelSession session) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.grid_view_outlined),
              title: const Text('Soundboard'),
              subtitle: const Text('play this channel’s clips'),
              onTap: () => Navigator.pop(context, 'board'),
            ),
            ListTile(
              leading: const Icon(Icons.search),
              title: const Text('Search sounds'),
              onTap: () => Navigator.pop(context, 'search'),
            ),
            ListTile(
              leading: const Icon(Icons.upload_file_outlined),
              title: const Text('Upload your own'),
              onTap: () => Navigator.pop(context, 'upload'),
            ),
          ],
        ),
      ),
    );
    switch (action) {
      case 'board':
        await _openSoundboard(session);
      case 'search':
        await _searchSound();
      case 'upload':
        await _sendSound();
    }
  }

  /// Plays a soundboard clip if its blob is held locally.
  Future<void> _playSound(ChannelSession session, String blob) async {
    final bytes = session.blobOf(blob);
    final player = _player;
    if (bytes == null || player == null) return;
    await player.stop();
    await player.play(BytesSource(bytes));
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
      await session.engine.publish(message);
    } catch (_) {
      if (mounted) setState(() => _error = 'send failed');
    } finally {
      if (mounted) setState(() => _sending = false);
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
      if (mounted) setState(() => _error = 'invalid invite code');
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave channel?'),
        content: const Text(
          "You'll stop receiving its messages and need a new invite to rejoin.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Leave'),
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
    try {
      _voice = await VoiceSession.join(
        channelId: channelId,
        identity: widget.identity,
        relayUrl: _relayUrl,
        onChange: _voiceChanged,
      );
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'microphone access is needed for voice');
      }
    }
  }

  void _voiceChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _leaveVoice() async {
    final voice = _voice;
    _voice = null;
    if (mounted) setState(() {});
    await voice?.leave();
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
          ],
          const Divider(height: 28),
          Text('MEMBERS', style: theme.textTheme.labelSmall),
          for (final key in _membersOf(session))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: _avatar(Uint8List.fromList(hex.decode(key)), radius: 14),
              title: Text(
                _displayName(Uint8List.fromList(hex.decode(key))),
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () =>
                  unawaited(_peerActions(Uint8List.fromList(hex.decode(key)))),
            ),
          if (_membersOf(session).isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text('Just you so far.', style: theme.textTheme.bodySmall),
            ),
          if (!session.isDm) ...[
            const Divider(height: 28),
            TextButton.icon(
              onPressed: () => unawaited(_leaveChannel(session.channelId)),
              icon: const Icon(Icons.logout, size: 18),
              label: const Text('Leave channel'),
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
            ),
          ],
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
        setState(() => _error = 'no new named members to add yet');
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
              icon: const Icon(Icons.tune),
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

  Widget _chatColumn(ChannelSession session) => Column(
    children: [
      Expanded(child: _messageList(context, session)),
      _composer(context, session),
    ],
  );

  Widget _messageList(BuildContext context, ChannelSession session) {
    final messages = session.repository
        .ordered()
        .where((m) => session.contentOf(m) is! ProfileContent)
        .toList();
    if (messages.isEmpty) {
      return const Center(child: Text('No messages yet — say something.'));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: messages.length,
      itemBuilder: (context, i) => _bubble(context, session, messages[i]),
    );
  }

  Widget _emptyState(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.local_fire_department,
            size: 64,
            color: theme.colorScheme.primary,
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
                onTap: () {
                  channels?.activate(s.channelId);
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
                onTap: () {
                  channels?.activate(s.channelId);
                  Navigator.pop(context);
                },
              ),
            _drawerHeader('Identity'),
            ListTile(
              leading: const Icon(Icons.key_outlined),
              title: const Text('Back up identity'),
              onTap: () {
                Navigator.pop(context);
                unawaited(_backupIdentity());
              },
            ),
            ListTile(
              leading: const Icon(Icons.restore),
              title: const Text('Restore identity'),
              onTap: () {
                Navigator.pop(context);
                unawaited(_restoreIdentity());
              },
            ),
            _drawerHeader('Relay'),
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('Relay server'),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _relayUrl.toString(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  _relayStatus(),
                ],
              ),
              trailing: IconButton(
                tooltip: 'Re-check relay',
                icon: const Icon(Icons.refresh),
                onPressed: _checkingRelay
                    ? null
                    : () => unawaited(_checkRelay()),
              ),
              onTap: () {
                Navigator.pop(context);
                unawaited(_setRelayUrl());
              },
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

  Widget _drawerHeader(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    child: Text(title, style: Theme.of(context).textTheme.titleSmall),
  );

  /// Renders a message's content — text, an inline GIF, a sticker, or a sound.
  Widget _contentView(
    BuildContext context,
    ChannelSession session,
    Content content,
  ) {
    return switch (content) {
      TextContent(:final text) => Text(text),
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

  /// Your saved media (everything sent or received), to re-send here.
  Future<void> _openLibrary() async {
    final library = _library;
    final store = _blobStore;
    if (library == null || store == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SizedBox(
        height: 480,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _drawerHeader('Stickers'),
            _imageLibrary(
              library.byKind(MediaKind.sticker),
              store,
              (hash) => _publish(StickerContent(hash)),
            ),
            _drawerHeader('GIFs'),
            _imageLibrary(
              library.byKind(MediaKind.gif),
              store,
              (hash) => _publish(GifContent(hash)),
            ),
            _drawerHeader('Sounds'),
            _soundLibrary(library.byKind(MediaKind.sound)),
          ],
        ),
      ),
    );
  }

  /// A wrap of image-blob thumbnails (stickers/GIFs); tap to re-send.
  Widget _imageLibrary(
    List<MediaItem> items,
    BlobStore store,
    Future<void> Function(String) onPick,
  ) {
    if (items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(8),
        child: Text('Nothing yet'),
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final item in items)
          GestureDetector(
            onTap: () {
              Navigator.pop(context);
              unawaited(onPick(item.hash));
            },
            child: SizedBox(
              width: 72,
              height: 72,
              child: FutureBuilder<Uint8List?>(
                future: store.get(item.hash),
                builder: (context, snapshot) {
                  final bytes = snapshot.data;
                  if (bytes == null) {
                    return const ColoredBox(color: Colors.black12);
                  }
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.memory(bytes, fit: BoxFit.cover),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }

  /// A wrap of named sound chips; tap to re-send to this channel.
  Widget _soundLibrary(List<MediaItem> items) {
    if (items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(8),
        child: Text('Nothing yet'),
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final item in items)
          ActionChip(
            avatar: Text(
              item.emoji ?? '🔊',
              style: const TextStyle(fontSize: 16),
            ),
            label: Text(item.name ?? 'sound'),
            onPressed: () {
              Navigator.pop(context);
              unawaited(
                _publish(
                  SoundContent(
                    item.hash,
                    item.name ?? 'sound',
                    item.emoji ?? '🔊',
                  ),
                ),
              );
            },
          ),
      ],
    );
  }

  /// Opens the channel soundboard — a grid of its clips, tap any to play.
  Future<void> _openSoundboard(ChannelSession session) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        final sounds = _channelSounds(session);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: sounds.isEmpty
                ? const Text('No sounds yet — upload one with the 🎵 button.')
                : Wrap(
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
                          onPressed: () =>
                              unawaited(_playSound(session, sound.blob)),
                        ),
                    ],
                  ),
          ),
        );
      },
    );
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
    const radius = Radius.circular(16);
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

  Widget _composer(BuildContext context, ChannelSession session) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          IconButton(
            onPressed: () => unawaited(_insertEmoji()),
            icon: const Icon(Icons.emoji_emotions_outlined),
            tooltip: 'Emoji',
          ),
          IconButton(
            onPressed: () => unawaited(_sendGif()),
            icon: const Icon(Icons.gif_box_outlined),
            tooltip: 'GIF',
          ),
          IconButton(
            onPressed: () => unawaited(_sendSticker()),
            icon: const Icon(Icons.image_outlined),
            tooltip: 'Sticker',
          ),
          IconButton(
            onPressed: () => unawaited(_sendFile()),
            icon: const Icon(Icons.attach_file),
            tooltip: 'Attach file',
          ),
          IconButton(
            onPressed: () => unawaited(_addSound(session)),
            icon: const Icon(Icons.library_music_outlined),
            tooltip: 'Sound',
          ),
          IconButton(
            onPressed: () => unawaited(_openLibrary()),
            icon: const Icon(Icons.collections_bookmark_outlined),
            tooltip: 'Your media',
          ),
          Expanded(
            child: TextField(
              controller: _input,
              onSubmitted: (_) => unawaited(_send()),
              decoration: InputDecoration(
                hintText: 'Message ${_channelTitle(session)}',
                border: const OutlineInputBorder(),
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
