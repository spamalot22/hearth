// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'message.dart';

/// A bidirectional channel for [Message]s.
///
/// Implementations: [RelayTransport] (HTTP short-poll, here in `core`) and the
/// app's WebRTC data-channel transport. The app talks to whichever it has
/// through this one interface — send a message, listen for incoming ones.
abstract interface class Transport {
  /// Sends [message] over the transport.
  Future<void> send(Message message);

  /// Verified messages arriving from the transport. Broadcast + hot: a listener
  /// sees messages that arrive after it subscribes.
  Stream<Message> get incoming;

  /// Stops the transport and releases its resources.
  Future<void> close();
}

/// Thrown when the relay returns a non-success response.
class TransportException implements Exception {
  TransportException(this.message);

  final String message;

  @override
  String toString() => 'TransportException: $message';
}

/// [Transport] over the rendezvous relay: POSTs messages to `/messages` and
/// short-polls `/poll`. Verifies everything it receives and drops anything that
/// fails [Message.verify]. Pure Dart (package:http picks the browser client on
/// web), so it stays in `core`.
class RelayTransport implements Transport {
  RelayTransport({
    required this.baseUrl,
    required this.channel,
    this.baseUrlProvider,
    http.Client? client,
    this.pollInterval = const Duration(seconds: 1),
  }) : _client = client ?? http.Client();

  final Uri baseUrl;
  final String channel;
  final Duration pollInterval;
  final http.Client _client;

  /// Returns the active relay URL (follows failover). Falls back to [baseUrl].
  final Uri Function()? baseUrlProvider;

  Uri get _url => baseUrlProvider?.call() ?? baseUrl;

  late final StreamController<Message> _incoming =
      StreamController<Message>.broadcast(onListen: _startPolling);
  Timer? _timer;
  int _since = 0;
  bool _busy = false;
  bool _paused = false;
  static const _requestTimeout = Duration(seconds: 10);

  /// The poll cursor (relay sequence number seen so far).
  int get since => _since;

  @override
  Stream<Message> get incoming => _incoming.stream;

  /// Pauses polling (e.g. when P2P peers are connected and handling delivery).
  void pause() => _paused = true;

  /// Resumes polling (e.g. when the last P2P peer disconnects).
  void resume() => _paused = false;

  void _startPolling() {
    _timer ??= Timer.periodic(pollInterval, (_) => unawaited(_pollOnce()));
  }

  Future<void> _pollOnce() async {
    if (_busy || _paused) return;
    _busy = true;
    try {
      final messages = await poll();
      if (_incoming.isClosed) return;
      for (final message in messages) {
        _incoming.add(message);
      }
    } catch (_) {
      // Transient failure (relay down, network blip) — next tick retries.
    } finally {
      _busy = false;
    }
  }

  @override
  Future<void> send(Message message) async {
    final res = await _client
        .post(
          _url.replace(path: '/messages'),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode(message.toJson()),
        )
        .timeout(_requestTimeout);
    if (res.statusCode != 200) {
      throw TransportException(
        'send failed: HTTP ${res.statusCode} ${res.body}',
      );
    }
  }

  /// One poll round: fetches messages newer than the cursor, returns only those
  /// that verify, and advances the cursor.
  Future<List<Message>> poll() async {
    final params = <String, String>{'channel': channel, 'since': '$_since'};
    final res = await _client
        .get(_url.replace(path: '/poll', queryParameters: params))
        .timeout(_requestTimeout);
    if (res.statusCode != 200) {
      throw TransportException('poll failed: HTTP ${res.statusCode}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final seqValue = body['seq'];
    if (seqValue is int && seqValue > _since) _since = seqValue;

    final verified = <Message>[];
    final entries = body['messages'];
    if (entries is! List) return verified;
    for (final entry in entries) {
      try {
        final message = Message.fromJson(
          (entry as Map).cast<String, Object?>(),
        );
        if (message.channel == channel && await message.verify()) {
          verified.add(message);
        }
      } catch (_) {
        // One malformed entry shouldn't abort the whole poll round.
      }
    }
    return verified;
  }

  @override
  Future<void> close() async {
    _timer?.cancel();
    _client.close();
    await _incoming.close();
  }
}
