// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'message.dart';

/// Carries the relay storage capability outside the request URL so routine
/// reverse-proxy access logs do not disclose private mailbox identifiers.
const relayMailboxHeader = 'x-hearth-mailbox';

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
    this.mailbox,
    this.baseUrlProvider,
    http.Client? client,
    this.pollInterval = const Duration(seconds: 1),
    this.requestTimeout = const Duration(seconds: 10),
  }) : _client = client ?? http.Client();

  final Uri baseUrl;
  final String channel;
  final String? mailbox;
  final Duration pollInterval;
  final Duration requestTimeout;
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
  bool _moreAvailable = false;
  String? _relayEpoch;
  Uri? _cursorUrl;
  bool _epochObserved = false;
  static const _maxPollResponseBytes = 8 * 1024 * 1024;
  static const _maxSendResponseBytes = 64 * 1024;

  /// The relay storage capability, distinct from the signed logical channel.
  String get relayMailbox => mailbox ?? channel;

  /// The poll cursor (relay sequence number seen so far).
  int get since => _since;

  /// The relay process generation associated with [since].
  String? get relayEpoch => _relayEpoch;

  @override
  Stream<Message> get incoming => _incoming.stream;

  /// Pauses polling (e.g. when P2P peers are connected and handling delivery).
  void pause() => _paused = true;

  /// Resumes polling (e.g. when the last P2P peer disconnects).
  void resume() => _paused = false;

  /// Performs one poll even while routine polling is paused. Distributed relay
  /// standbys use this as a low-frequency fail-safe when elected workers are
  /// unreachable or suspended.
  Future<void> probe() => _pollOnce(ignorePause: true);

  void _startPolling() {
    _timer ??= Timer.periodic(pollInterval, (_) => unawaited(_pollOnce()));
  }

  Future<void> _pollOnce({bool ignorePause = false}) async {
    if (_busy || (_paused && !ignorePause)) return;
    _busy = true;
    try {
      // Drain a bounded number of server pages per tick. Each HTTP response is
      // small, while a client returning after a long outage still catches up
      // promptly instead of waiting one full poll interval per page.
      for (var page = 0; page < 10; page++) {
        final messages = await poll();
        if (_incoming.isClosed) return;
        for (final message in messages) {
          _incoming.add(message);
        }
        if (!_moreAvailable) break;
      }
    } catch (_) {
      // Transient failure (relay down, network blip) — next tick retries.
    } finally {
      _busy = false;
    }
  }

  @override
  Future<void> send(Message message) async {
    final url = _url;
    var request = http.Request('POST', url.replace(path: '/v2/messages'))
      ..headers['content-type'] = 'application/json'
      ..headers[relayMailboxHeader] = relayMailbox
      ..body = jsonEncode(message.toJson());
    var result = await _perform(request, _maxSendResponseBytes);
    if (result.$1.statusCode == 404 || result.$1.statusCode == 405) {
      // Staggered deployment compatibility: old relays do not understand the
      // versioned/header protocol. Leak the capability into the URL only while
      // talking to one of those relays so delivery remains available.
      request =
          http.Request(
              'POST',
              url.replace(
                path: '/messages',
                queryParameters: mailbox == null ? null : {'mailbox': mailbox!},
              ),
            )
            ..headers['content-type'] = 'application/json'
            ..body = jsonEncode(message.toJson());
      result = await _perform(request, _maxSendResponseBytes);
    }
    final (res, responseBody) = result;
    if (res.statusCode != 200) {
      throw TransportException(
        'send failed: HTTP ${res.statusCode} ${utf8.decode(responseBody)}',
      );
    }
  }

  /// One poll round: fetches messages newer than the cursor, returns only those
  /// that verify, and advances the cursor.
  Future<List<Message>> poll() => _poll(allowEpochRetry: true);

  Future<List<Message>> _poll({required bool allowEpochRetry}) async {
    final url = _url;
    if (_cursorUrl != null && _cursorUrl != url) {
      // Sequence numbers are local to one relay process. A failover endpoint
      // has an unrelated sequence space; repository dedup makes replay safe.
      _since = 0;
      _relayEpoch = null;
      _epochObserved = false;
    }
    _cursorUrl = url;
    final params = <String, String>{'since': '$_since'};
    var request = http.Request(
      'GET',
      url.replace(path: '/v2/poll', queryParameters: params),
    )..headers[relayMailboxHeader] = relayMailbox;
    var result = await _perform(request, _maxPollResponseBytes);
    if (result.$1.statusCode == 404 || result.$1.statusCode == 405) {
      request = http.Request(
        'GET',
        url.replace(
          path: '/poll',
          queryParameters: {'channel': relayMailbox, ...params},
        ),
      );
      result = await _perform(request, _maxPollResponseBytes);
    }
    final (res, bodyBytes) = result;
    if (res.statusCode != 200) {
      throw TransportException('poll failed: HTTP ${res.statusCode}');
    }
    final body = jsonDecode(utf8.decode(bodyBytes)) as Map<String, dynamic>;
    final responseEpoch = body['relayEpoch'];
    if (responseEpoch is String && responseEpoch.isNotEmpty) {
      final changed = _epochObserved && _relayEpoch != responseEpoch;
      _relayEpoch = responseEpoch;
      if (changed && allowEpochRetry) {
        // The relay is in-memory, so a process restart resets all sequence
        // numbers. Retry once from zero to receive post-restart messages.
        _since = 0;
        _moreAvailable = true;
        return _poll(allowEpochRetry: false);
      }
    }
    _epochObserved = true;
    _moreAvailable = body['more'] == true;
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

  Future<(http.StreamedResponse, Uint8List)> _perform(
    http.Request request,
    int maxResponseBytes,
  ) async {
    final response = await _client.send(request).timeout(requestTimeout);
    final body = await _readBounded(response, maxResponseBytes, requestTimeout);
    return (response, body);
  }

  static Future<Uint8List> _readBounded(
    http.StreamedResponse response,
    int maxBytes,
    Duration timeout,
  ) async {
    final expected = response.contentLength;
    if (expected != null && expected > maxBytes) {
      throw TransportException('relay response exceeds $maxBytes bytes');
    }
    final bytes = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in response.stream.timeout(timeout)) {
      length += chunk.length;
      if (length > maxBytes) {
        throw TransportException('relay response exceeds $maxBytes bytes');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }
}
