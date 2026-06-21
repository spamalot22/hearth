import 'dart:convert';

import 'package:http/http.dart' as http;

import 'message.dart';

/// Thrown when the relay returns a non-success response.
class TransportException implements Exception {
  TransportException(this.message);

  final String message;

  @override
  String toString() => 'TransportException: $message';
}

/// Client for the rendezvous relay: POSTs signed messages and short-polls for
/// new ones in a single [channel].
///
/// A *dumb* transport — it verifies everything it receives and drops anything
/// that fails [Message.verify], so a misbehaving relay can't inject forged
/// messages. Pure Dart (package:http selects the browser client on web), so it
/// lives in `core` and works on every target.
class RelayTransport {
  RelayTransport({
    required this.baseUrl,
    required this.channel,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final Uri baseUrl;
  final String channel;
  final http.Client _client;
  int _since = 0;

  /// The poll cursor (relay sequence number seen so far).
  int get since => _since;

  /// Posts a signed message to the relay. Throws [TransportException] on a
  /// non-200 response (which includes the relay rejecting a bad signature).
  Future<void> send(Message message) async {
    final res = await _client.post(
      baseUrl.replace(path: '/messages'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode(message.toJson()),
    );
    if (res.statusCode != 200) {
      throw TransportException(
        'send failed: HTTP ${res.statusCode} ${res.body}',
      );
    }
  }

  /// Fetches messages newer than the cursor, returning only those that verify,
  /// and advances the cursor past everything the relay returned.
  Future<List<Message>> poll() async {
    final res = await _client.get(
      baseUrl.replace(
        path: '/poll',
        queryParameters: {'channel': channel, 'since': '$_since'},
      ),
    );
    if (res.statusCode != 200) {
      throw TransportException('poll failed: HTTP ${res.statusCode}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    _since = (body['seq'] as num).toInt();

    final verified = <Message>[];
    for (final entry in body['messages'] as List<dynamic>) {
      final message = Message.fromJson((entry as Map).cast<String, Object?>());
      if (await message.verify()) verified.add(message);
    }
    return verified;
  }

  void close() => _client.close();
}
