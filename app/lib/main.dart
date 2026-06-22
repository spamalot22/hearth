import 'dart:async';

import 'package:convert/convert.dart';
import 'package:core/core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'channel.dart';
import 'contacts.dart';
import 'content.dart';
import 'emoji_picker.dart';
import 'gif_search.dart';
import 'group_channel.dart';
import 'key_store.dart';

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
  ChannelRegistry? _registry;
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
    final channels = ChannelManager(
      identity: widget.identity,
      relayUrl: widget.relayUrl,
      live: widget.autoPoll,
      onUpdate: _onUpdate,
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
      _channels = channels;
    });
    // Decrypt the active channel's loaded history: the onUpdate calls during the
    // open loop above ran before _channels was set, so they were no-ops.
    unawaited(_refresh());
  }

  void _onUpdate() => unawaited(_refresh());

  /// Decrypts the active channel's new messages, then re-renders.
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

  /// Searches GIFs (via the relay's proxy) and sends the chosen one.
  Future<void> _sendGif() async {
    final url = await pickGif(context, widget.relayUrl);
    if (url != null) await _publish(GifContent(url));
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
    final channel = GroupChannel.fromInvite(code.trim());
    if (channel == null) {
      if (mounted) setState(() => _error = 'invalid invite code');
      return;
    }
    await _registry?.save(channel);
    if (mounted) setState(() => _groups[channel.id] = channel);
    await _channels?.openGroup(channel.id, channel.key);
  }

  /// Shows the invite code for a group channel, with a copy button.
  Future<void> _shareInvite(String channelId) async {
    final channel = _groups[channelId];
    if (channel == null) return;
    final invite = channel.invite();
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

  // --- contacts / DMs ---

  /// A peer's petname if you've set one, else their `hearth#fingerprint`.
  String _displayName(Uint8List author) =>
      _contacts?.nameFor(hex.encode(author)) ??
      'hearth#${_fingerprint(author)}';

  /// Prompts for a local petname for [author] and stores it.
  Future<void> _renameContact(Uint8List author) async {
    final key = hex.encode(author);
    final name = await _promptText(
      title: 'Name hearth#${_fingerprint(author)}',
      hint: 'petname (only you see this)',
      initial: _contacts?.nameFor(key) ?? '',
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
    return Scaffold(
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
          if (session != null && !session.isDm)
            IconButton(
              onPressed: () => unawaited(_shareInvite(session.channelId)),
              icon: const Icon(Icons.person_add_alt_1),
              tooltip: 'Invite',
            ),
        ],
        bottom: _error == null ? null : _errorBar(context, _error!),
      ),
      drawer: _drawer(context),
      body: session == null
          ? _emptyState(context)
          : Column(
              children: [
                Expanded(child: _messageList(context, session)),
                _composer(context, session),
              ],
            ),
    );
  }

  Widget _messageList(BuildContext context, ChannelSession session) {
    final messages = session.repository.ordered();
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
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('No channel open.'),
          const SizedBox(height: 12),
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
          children: [
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
          ],
        ),
      ),
    );
  }

  Widget _drawerHeader(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    child: Text(title, style: Theme.of(context).textTheme.titleSmall),
  );

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
