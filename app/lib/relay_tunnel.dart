// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:core/core.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'bounded_download.dart';

/// A [FrameChannel] that tunnels gossip frames through the relay for peers that
/// cannot establish a direct WebRTC connection.
///
/// Frames are fragmented before POSTing so the relay can retain its 64 KiB body
/// limit. Every fragment is encrypted with the static ECDH key shared by the two
/// mesh identities, so the relay sees only bounded ciphertext fragments. The
/// receiver authenticates, reassembles, and decodes the original [SyncFrame].
class RelayTunnel implements FrameChannel {
  RelayTunnel({
    required this.baseUrl,
    this.baseUrlProvider,
    required this.identity,
    required this.peerPubkeyHex,
    this.authToken,
    this.authTokenProvider,
    this.onReady,
    this.channelAuthKey,
    http.Client? client,
    this.pollInterval = const Duration(seconds: 1),
  }) : _client = client ?? http.Client(),
       _peerPublicKey = Uint8List.fromList(hex.decode(peerPubkeyHex));

  final Uri baseUrl;
  final Uri Function()? baseUrlProvider;
  final Identity identity;
  final String peerPubkeyHex;
  final String? authToken;
  final String? Function()? authTokenProvider;
  final void Function()? onReady;
  final Uint8List? channelAuthKey;
  final Duration pollInterval;
  final http.Client _client;
  final Uint8List _peerPublicKey;

  final StreamController<SyncFrame> _frames = StreamController<SyncFrame>();
  final Map<String, _TunnelAssembly> _assemblies = {};
  final Random _random = Random.secure();
  Timer? _timer;
  Future<void> _sendTail = Future<void>.value();
  bool _closed = false;
  bool _polling = false;
  bool _ready = false;
  int _assemblyBytes = 0;

  static const _requestTimeout = Duration(seconds: 10);
  static const _assemblyTtl = Duration(minutes: 5);
  static const int _legacyFragmentHeaderBytes = 20;
  static const int _capabilityFragmentHeaderBytes = 52;
  static const int _fragmentPayloadBytes = 40 * 1024;
  static const int _maxFrameBytes = 16 * 1024 * 1024;
  static const int _maxFragments = 512;
  static const int _maxAssemblies = 4;
  static const int _maxAssemblyBytes = 32 * 1024 * 1024;
  static const int _maxTunnelDataBytes = 60 * 1024;
  static const String _encryptedPrefix = 'e1:';
  static const List<int> _legacyFragmentMagic = [0x48, 0x54, 0x31, 0x00];
  static const List<int> _capabilityFragmentMagic = [0x48, 0x54, 0x32, 0x00];

  String get selfPubkeyHex => identity.publicKeyHex;
  int get _fragmentHeaderBytes => channelAuthKey == null
      ? _legacyFragmentHeaderBytes
      : _capabilityFragmentHeaderBytes;
  Uri get _url => baseUrlProvider?.call() ?? baseUrl;
  String? get _token => authTokenProvider?.call() ?? authToken;

  /// True after at least one valid frame has arrived from the peer.
  bool get isReady => _ready;

  @override
  String get peerHex => peerPubkeyHex;

  @override
  Stream<SyncFrame> get frames => _frames.stream;

  /// Starts polling for fragments from the peer.
  void start() {
    if (_closed || _timer != null) return;
    _timer = Timer.periodic(pollInterval, (_) => unawaited(_poll()));
  }

  @override
  void send(SyncFrame frame) {
    if (_closed) return;
    _sendTail = _sendTail.then((_) => _sendFrame(frame)).catchError((Object _) {
      // A failed frame must not poison the serialized upload queue. Gossip and
      // blob requests retry naturally after reconnecting to the peer.
    });
  }

  Future<void> _sendFrame(SyncFrame frame) async {
    final encoded = Uint8List.fromList(utf8.encode(frame.encode()));
    if (encoded.length > _maxFrameBytes || _closed) return;
    final total =
        (encoded.length + _fragmentPayloadBytes - 1) ~/ _fragmentPayloadBytes;
    if (total < 1 || total > _maxFragments) return;
    final transferId = Uint8List.fromList(
      List<int>.generate(12, (_) => _random.nextInt(256)),
    );

    for (var index = 0; index < total; index++) {
      if (_closed) return;
      final start = index * _fragmentPayloadBytes;
      final end = min(start + _fragmentPayloadBytes, encoded.length);
      final packet = Uint8List(_fragmentHeaderBytes + end - start);
      packet.setRange(
        0,
        4,
        channelAuthKey == null
            ? _legacyFragmentMagic
            : _capabilityFragmentMagic,
      );
      packet.setRange(4, 16, transferId);
      final header = ByteData.sublistView(packet);
      header.setUint16(16, index, Endian.big);
      header.setUint16(18, total, Endian.big);
      packet.setRange(_fragmentHeaderBytes, packet.length, encoded, start);
      final capability = channelAuthKey;
      if (capability != null) {
        packet.setRange(
          _legacyFragmentHeaderBytes,
          _capabilityFragmentHeaderBytes,
          _fragmentCapability(capability, selfPubkeyHex, peerPubkeyHex, packet),
        );
      }

      final boxed = await PairBox.encrypt(
        packet,
        self: identity,
        peerEd25519PublicKey: _peerPublicKey,
      );
      final data = '$_encryptedPrefix${base64Url.encode(boxed)}';
      if (utf8.encode(data).length > _maxTunnelDataBytes ||
          !await _postWithRetry(data)) {
        return;
      }
    }
  }

  Future<bool> _postWithRetry(String data) async {
    for (var attempt = 0; attempt < 5 && !_closed; attempt++) {
      try {
        final token = _token;
        final request = http.Request('POST', _url.replace(path: '/tunnel'))
          ..headers.addAll({
            'Content-Type': 'application/json',
            if (token != null) 'Authorization': 'Bearer $token',
          })
          ..body = jsonEncode({
            'from': selfPubkeyHex,
            'to': peerPubkeyHex,
            'data': data,
          });
        final res = await _client.send(request).timeout(_requestTimeout);
        await readResponseBytesBounded(
          res,
          maxBytes: 64 * 1024,
          timeout: _requestTimeout,
        );
        if (res.statusCode == 200) return true;
        if (res.statusCode != 403 &&
            res.statusCode != 429 &&
            res.statusCode < 500) {
          return false;
        }
      } catch (_) {
        // Retry transient network failures below.
      }
      if (attempt < 4 && !_closed) {
        await Future<void>.delayed(
          Duration(milliseconds: 250 * (1 << attempt)),
        );
      }
    }
    return false;
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
      final request = http.Request(
        'GET',
        _url.replace(path: '/tunnel', queryParameters: params),
      )..headers.addAll(headers);
      final res = await _client.send(request).timeout(_requestTimeout);
      if (res.statusCode != 200) return;
      final body = await readJsonObjectBounded(
        res,
        maxBytes: 4 * 1024 * 1024,
        timeout: _requestTimeout,
      );
      final fragments = body['frames'];
      if (fragments is! List) return;
      for (final raw in fragments.whereType<String>().take(64)) {
        final frame = await _decodeFragment(raw);
        if (frame != null && !_frames.isClosed) {
          if (!_ready) {
            _ready = true;
            onReady?.call();
          }
          _frames.add(frame);
        }
      }
      _pruneAssemblies(DateTime.now());
    } catch (_) {
      // Transient failure or hostile relay response: the next poll retries.
    } finally {
      _polling = false;
    }
  }

  Future<SyncFrame?> _decodeFragment(String raw) async {
    if (!raw.startsWith(_encryptedPrefix) || raw.length > _maxTunnelDataBytes) {
      return null;
    }
    try {
      final boxed = Uint8List.fromList(
        base64Url.decode(raw.substring(_encryptedPrefix.length)),
      );
      final packet = await PairBox.decrypt(
        boxed,
        self: identity,
        peerEd25519PublicKey: _peerPublicKey,
      );
      final capability = channelAuthKey;
      final expectedMagic = capability == null
          ? _legacyFragmentMagic
          : _capabilityFragmentMagic;
      if (packet.length < _fragmentHeaderBytes ||
          !_startsWith(packet, expectedMagic)) {
        return null;
      }
      if (capability != null) {
        final supplied = packet.sublist(
          _legacyFragmentHeaderBytes,
          _capabilityFragmentHeaderBytes,
        );
        final expected = _fragmentCapability(
          capability,
          peerPubkeyHex,
          selfPubkeyHex,
          packet,
        );
        if (!_constantTimeBytes(supplied, expected)) return null;
      }
      final header = ByteData.sublistView(packet);
      final index = header.getUint16(16, Endian.big);
      final total = header.getUint16(18, Endian.big);
      final payload = Uint8List.sublistView(packet, _fragmentHeaderBytes);
      if (total < 1 ||
          total > _maxFragments ||
          index >= total ||
          payload.length > _fragmentPayloadBytes) {
        return null;
      }

      final id = hex.encode(packet.sublist(4, 16));
      final now = DateTime.now();
      _pruneAssemblies(now);
      var assembly = _assemblies[id];
      if (assembly == null) {
        while (_assemblies.length >= _maxAssemblies) {
          _removeAssembly(_assemblies.keys.first);
        }
        assembly = _TunnelAssembly(total, now);
        _assemblies[id] = assembly;
      } else if (assembly.total != total) {
        _removeAssembly(id);
        return null;
      }
      assembly.touched = now;
      if (assembly.chunks[index] != null) return null;
      final copy = Uint8List.fromList(payload);
      assembly.chunks[index] = copy;
      assembly.bytes += copy.length;
      assembly.received++;
      _assemblyBytes += copy.length;
      if (assembly.bytes > _maxFrameBytes) {
        _removeAssembly(id);
        return null;
      }
      while (_assemblyBytes > _maxAssemblyBytes && _assemblies.isNotEmpty) {
        _removeAssembly(_assemblies.keys.first);
      }
      if (!_assemblies.containsKey(id) || assembly.received != total) {
        return null;
      }

      final complete = BytesBuilder(copy: false);
      for (final chunk in assembly.chunks) {
        if (chunk == null) return null;
        complete.add(chunk);
      }
      _removeAssembly(id);
      return SyncFrame.decode(utf8.decode(complete.takeBytes()));
    } catch (_) {
      return null;
    }
  }

  void _pruneAssemblies(DateTime now) {
    for (final entry in _assemblies.entries.toList()) {
      if (now.difference(entry.value.touched) > _assemblyTtl) {
        _removeAssembly(entry.key);
      }
    }
  }

  void _removeAssembly(String id) {
    final removed = _assemblies.remove(id);
    if (removed != null) _assemblyBytes -= removed.bytes;
  }

  static bool _startsWith(List<int> bytes, List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }

  static List<int> _fragmentCapability(
    List<int> key,
    String from,
    String to,
    Uint8List packet,
  ) {
    if (key.length != 32) throw ArgumentError.value(key.length, 'key');
    final authenticated = BytesBuilder(copy: false)
      ..add(utf8.encode('hearth/tunnel-capability/v1\n$from\n$to\n'))
      ..add(packet.sublist(0, _legacyFragmentHeaderBytes))
      ..add(packet.sublist(_capabilityFragmentHeaderBytes));
    return Hmac(sha256, key).convert(authenticated.takeBytes()).bytes;
  }

  static bool _constantTimeBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    _assemblies.clear();
    _assemblyBytes = 0;
    _client.close();
    if (!_frames.isClosed) {
      final hadListener = _frames.hasListener;
      final done = _frames.close();
      if (hadListener) await done;
    }
  }
}

class _TunnelAssembly {
  _TunnelAssembly(this.total, this.touched)
    : chunks = List<Uint8List?>.filled(total, null);

  final int total;
  final List<Uint8List?> chunks;
  DateTime touched;
  int bytes = 0;
  int received = 0;
}
