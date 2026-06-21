import 'dart:async';

import 'package:convert/convert.dart';
import 'package:core/core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'channel.dart';
import 'contacts.dart';
import 'content.dart';
import 'emoji_picker.dart';
import 'key_store.dart';

/// Relay endpoint for local dev; the channel everyone shares for now.
final Uri kRelayUrl = Uri.parse('http://localhost:8787');
const String kChannel = 'general';

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
    return MaterialApp(
      title: 'Hearth',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFFE25822), // ember orange
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
    this.autoPoll = true,
    super.key,
  });

  final Identity identity;
  final Uri relayUrl;
  final bool autoPoll;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  ChannelManager? _channels;
  ContactBook? _contacts;
  String? _error;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  /// Opens contacts + the channel manager and joins the default channel. In
  /// widget tests (autoPoll off) everything stays in-memory — no Hive, no WebRTC.
  Future<void> _init() async {
    final contacts = widget.autoPoll ? await ContactBook.open() : null;
    final channels = ChannelManager(
      identity: widget.identity,
      relayUrl: widget.relayUrl,
      live: widget.autoPoll,
      onUpdate: _onUpdate,
    );
    await channels.open(kChannel);
    if (!mounted) {
      await channels.close();
      return;
    }
    setState(() {
      _contacts = contacts;
      _channels = channels;
    });
  }

  void _onUpdate() => unawaited(_refresh());

  /// Decrypts the active channel's new DM messages (no-op for groups), then
  /// re-renders.
  Future<void> _refresh() async {
    await _channels?.active?.refreshContent();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    unawaited(_channels?.close());
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    await _publish(TextContent(text));
  }

  /// Prompts for a GIF URL and sends it.
  Future<void> _sendGif() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Send a GIF'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://…/something.gif',
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = url?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      await _publish(GifContent(trimmed));
    }
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

  /// A peer's petname if you've set one, else their `hearth#fingerprint`.
  String _displayName(Uint8List author) =>
      _contacts?.nameFor(hex.encode(author)) ??
      'hearth#${_fingerprint(author)}';

  /// Prompts for a local petname for [author] and stores it.
  Future<void> _renameContact(Uint8List author) async {
    final key = hex.encode(author);
    final controller = TextEditingController(
      text: _contacts?.nameFor(key) ?? '',
    );
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Name hearth#${_fingerprint(author)}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Petname (only you see this)',
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
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

  @override
  Widget build(BuildContext context) {
    final session = _channels?.active;
    final messages = session?.repository.ordered() ?? const <Message>[];
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('# ${session?.channelId ?? '…'}'),
            Text(
              'hearth#${widget.identity.fingerprint}',
              key: const Key('identity-fingerprint'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        bottom: _error == null ? null : _errorBar(context, _error!),
      ),
      drawer: _drawer(context),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? const Center(child: Text('No messages yet — say something.'))
                : ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: messages.length,
                    itemBuilder: (context, i) =>
                        _bubble(context, session!, messages[i]),
                  ),
          ),
          _composer(context),
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
          children: [
            _drawerHeader('Channels'),
            for (final s in groups)
              ListTile(
                leading: const Icon(Icons.tag),
                title: Text(s.channelId),
                selected: s.channelId == channels?.activeId,
                onTap: () {
                  channels?.activate(s.channelId);
                  Navigator.pop(context);
                },
              ),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('Join a channel'),
              onTap: () {
                Navigator.pop(context);
                unawaited(_joinChannel());
              },
            ),
            if (dms.isNotEmpty) _drawerHeader('Direct messages'),
            for (final s in dms)
              ListTile(
                leading: const Icon(Icons.alternate_email),
                title: Text(_displayName(Uint8List.fromList(s.peerPubkey!))),
                selected: s.channelId == channels?.activeId,
                onTap: () {
                  channels?.activate(s.channelId);
                  Navigator.pop(context);
                },
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

  /// Prompts for a channel name and joins it (creating its local stack).
  Future<void> _joinChannel() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Join a channel'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'channel name'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Join'),
          ),
        ],
      ),
    );
    controller.dispose();
    final id = _channelId(name);
    if (id != null) await _channels?.open(id);
  }

  /// Normalises a typed name to a safe, shareable channel id — so two people who
  /// type "My Room" land in the same channel, and it's safe as a storage key.
  String? _channelId(String? name) {
    final id = name
        ?.trim()
        .toLowerCase()
        .replaceAll(RegExp('[^a-z0-9_-]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return (id == null || id.isEmpty) ? null : id;
  }

  /// Renders a message's content — text, or an inline GIF fetched from its URL.
  Widget _contentView(BuildContext context, Content content) {
    return switch (content) {
      TextContent(:final text) => Text(text),
      GifContent(:final url) => ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 220, maxWidth: 260),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.network(
            url,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stack) => Text('[GIF] $url'),
            loadingBuilder: (context, child, progress) => progress == null
                ? child
                : const Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(),
                  ),
          ),
        ),
      ),
    };
  }

  Widget _bubble(
    BuildContext context,
    ChannelSession session,
    Message message,
  ) {
    final mine = listEquals(message.author, widget.identity.publicKey);
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Card(
        color: mine ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: mine
                    ? null
                    : () => unawaited(_peerActions(message.author)),
                child: Text(
                  mine ? 'you' : _displayName(message.author),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              _contentView(context, session.contentOf(message)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _composer(BuildContext context) {
    final channelId = _channels?.active?.channelId ?? 'general';
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
          Expanded(
            child: TextField(
              controller: _input,
              onSubmitted: (_) => unawaited(_send()),
              decoration: InputDecoration(
                hintText: 'Message #$channelId',
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
