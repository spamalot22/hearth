import 'dart:async';
import 'dart:convert';

import 'package:core/core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'key_store.dart';
import 'message_storage_hive.dart';
import 'webrtc_transport.dart';

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
  MessageRepository? _repo;
  Transport? _transport;
  StreamSubscription<Message>? _sub;
  String? _error;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  /// Opens on-device storage, hydrates saved history, then starts the transport.
  /// In widget tests (autoPoll off) storage is in-memory and no native plugin —
  /// Hive or WebRTC — is touched.
  Future<void> _init() async {
    final storage = widget.autoPoll
        ? await HiveMessageStorage.open()
        : InMemoryMessageStorage();
    final repo = MessageRepository(storage);
    await repo.load();
    if (!mounted) return;
    setState(() => _repo = repo);
    if (!widget.autoPoll) return;
    final transport = WebRtcTransport(
      baseUrl: widget.relayUrl,
      channel: kChannel,
      selfPubkeyHex: widget.identity.publicKeyHex,
    );
    _transport = transport;
    _sub = transport.incoming.listen(_onIncoming);
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    unawaited(_transport?.close());
    _input.dispose();
    super.dispose();
  }

  Future<void> _onIncoming(Message message) async {
    final repo = _repo;
    if (repo == null) return;
    if (await repo.add(message) && mounted) setState(() {});
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    final repo = _repo;
    if (text.isEmpty || _sending || repo == null) return;
    setState(() => _sending = true);
    try {
      final message = await Message.create(
        author: widget.identity,
        channel: kChannel,
        payload: Uint8List.fromList(utf8.encode(text)),
        prev: repo.heads(),
      );
      await repo.add(message);
      _input.clear();
      setState(() {}); // echo locally right away
      await _transport?.send(message);
    } catch (_) {
      if (mounted) setState(() => _error = 'send failed');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final messages = _repo?.ordered() ?? const <Message>[];
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Hearth'),
            const SizedBox(width: 10),
            Text(
              'hearth#${widget.identity.fingerprint}',
              key: const Key('identity-fingerprint'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        bottom: _error == null ? null : _errorBar(context, _error!),
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? const Center(child: Text('No messages yet — say something.'))
                : ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: messages.length,
                    itemBuilder: (context, i) => _bubble(context, messages[i]),
                  ),
          ),
          _composer(context),
        ],
      ),
    );
  }

  Widget _bubble(BuildContext context, Message message) {
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
              Text(
                'hearth#${_fingerprint(message.author)}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              Text(utf8.decode(message.payload)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _composer(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              onSubmitted: (_) => unawaited(_send()),
              decoration: const InputDecoration(
                hintText: 'Message #general',
                border: OutlineInputBorder(),
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
