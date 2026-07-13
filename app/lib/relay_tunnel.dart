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
    this.authTokenProvider,
    this.onReady,
    http.Client? client,
    this.pollInterval = const Duration(seconds: 1),
  }) : _client = client ?? http.Client();

  final Uri baseUrl;
  final String selfPubkeyHex;
  final String peerPubkeyHex;
  final String? authToken;
  final String? Function()? authTokenProvider;
  final void Function()? onReady;
  final Duration pollInterval;
  final http.Client _client;

  final StreamController<SyncFrame> _frames = StreamController<SyncFrame>();
  Timer? _timer;
  bool _closed = false;
  bool _polling = false;
  bool _ready = false;
  static const _requestTimeout = Duration(seconds: 10);

  String? get _token => authTokenProvider?.call() ?? authToken;

  /// True after at least one valid frame has arrived from the peer.
  bool get isReady => _ready;

  @override
  String get peerHex => peerPubkeyHex;

  @override
  Stream<SyncFrame> get frames => _frames.stream;

  /// Starts polling for frames from the peer.
  void start() {
    if (_closed || _timer != null) return;
    _timer = Timer.periodic(pollInterval, (_) => unawaited(_poll()));
  }

  @override
  void send(SyncFrame frame) {
    if (_closed) return;
    unawaited(_post(frame.encode()));
  }

  Future<void> _post(String data) async {
    try {
      final token = _token;
      await _client
          .post(
            baseUrl.replace(path: '/tunnel'),
            body: jsonEncode({
              'from': selfPubkeyHex,
              'to': peerPubkeyHex,
              'data': data,
            }),
            headers: {
              'Content-Type': 'application/json',
              if (token != null) 'Authorization': 'Bearer $token',
            },
          )
          .timeout(_requestTimeout);
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
      final headers = <String, String>{};
      final token = _token;
      if (token != null) headers['Authorization'] = 'Bearer $token';
      final res = await _client
          .get(
            baseUrl.replace(path: '/tunnel', queryParameters: params),
            headers: headers,
          )
          .timeout(_requestTimeout);
      if (res.statusCode != 200) return;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final frames = body['frames'];
      if (frames is! List) return;
      for (final raw in frames.whereType<String>().take(100)) {
        final frame = SyncFrame.decode(raw);
        if (frame != null && !_frames.isClosed) {
          if (!_ready) {
            _ready = true;
            onReady?.call();
          }
          _frames.add(frame);
        }
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
    _timer = null;
    _client.close();
    if (!_frames.isClosed) {
      final hadListener = _frames.hasListener;
      final done = _frames.close();
      // A single-subscription controller's close future never completes if its
      // stream was never listened to. Closing is still synchronous in that
      // case, so there is no listener to wait for.
      if (hadListener) await done;
    }
  }
}
