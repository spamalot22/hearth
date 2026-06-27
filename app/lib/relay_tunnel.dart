// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:core/core.dart';
import 'package:http/http.dart' as http;

/// A [FrameChannel] that tunnels gossip frames through the relay for peers that
/// can't establish a direct WebRTC connection (symmetric NAT on both sides).
///
/// The relay sees opaque frame text — messages inside are still E2E-encrypted
/// and signed. This is a fallback, not the default path.
class RelayTunnel implements FrameChannel {
  RelayTunnel({
    required this.baseUrl,
    required this.selfPubkeyHex,
    required this.peerPubkeyHex,
    this.authToken,
    http.Client? client,
    this.pollInterval = const Duration(seconds: 1),
  }) : _client = client ?? http.Client();

  final Uri baseUrl;
  final String selfPubkeyHex;
  final String peerPubkeyHex;
  final String? authToken;
  final Duration pollInterval;
  final http.Client _client;

  final StreamController<SyncFrame> _frames = StreamController<SyncFrame>();
  Timer? _timer;
  bool _closed = false;
  bool _polling = false;

  @override
  Stream<SyncFrame> get frames => _frames.stream;

  /// Starts polling for frames from the peer.
  void start() {
    _timer = Timer.periodic(pollInterval, (_) => unawaited(_poll()));
  }

  @override
  void send(SyncFrame frame) {
    if (_closed) return;
    unawaited(_post(frame.encode()));
  }

  Future<void> _post(String data) async {
    try {
      await _client.post(
        baseUrl.replace(path: '/tunnel'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({
          'from': selfPubkeyHex,
          'to': peerPubkeyHex,
          'data': data,
          if (authToken != null) 'token': authToken,
        }),
      );
    } catch (_) {}
  }

  Future<void> _poll() async {
    if (_closed || _polling) return;
    _polling = true;
    try {
      final params = <String, String>{
        'from': peerPubkeyHex,
        'to': selfPubkeyHex,
      };
      if (authToken != null) params['token'] = authToken!;
      final res = await _client.get(
        baseUrl.replace(path: '/tunnel', queryParameters: params),
      );
      if (res.statusCode != 200) return;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final frames = (body['frames'] as List?)?.cast<String>() ?? [];
      for (final raw in frames) {
        final frame = SyncFrame.decode(raw);
        if (frame != null && !_frames.isClosed) _frames.add(frame);
      }
    } catch (_) {
      // Transient — the next tick retries.
    } finally {
      _polling = false;
    }
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    _client.close();
    if (!_frames.isClosed) await _frames.close();
  }
}
