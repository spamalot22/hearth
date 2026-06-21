import 'dart:async';
import 'dart:convert';

import 'package:core/core.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

/// A peer-to-peer [Transport] over WebRTC data channels.
///
/// The relay is used only for rendezvous: we announce our presence, discover
/// the other live peers, and trade SDP + ICE through per-recipient mailboxes
/// (`/announce`, `/peers`, `/signal`). Once a data channel opens the backend is
/// out of the loop — messages flow directly between browsers/devices.
///
/// Topology is a full mesh: one [RTCPeerConnection] per peer. To avoid both
/// sides offering at once (glare), the role is decided deterministically — the
/// peer with the lexicographically-greater public key offers, the other waits.
///
/// Each message is the same signed [Message] envelope the relay carried, so
/// everything received is [Message.verify]-ed and forgeries are dropped exactly
/// as before. Signalling itself is still unauthenticated (a later hardening
/// pass binds it to the Ed25519 identity).
class WebRtcTransport implements Transport {
  WebRtcTransport({
    required this.baseUrl,
    required this.channel,
    required this.selfPubkeyHex,
    http.Client? client,
    this.announceInterval = const Duration(seconds: 5),
    this.signalPollInterval = const Duration(milliseconds: 700),
    List<Map<String, dynamic>>? iceServers,
  }) : _client = client ?? http.Client(),
       _iceServers =
           iceServers ??
           const <Map<String, dynamic>>[
             {
               'urls': <String>['stun:stun.l.google.com:19302'],
             },
           ];

  /// Base URL of the relay used for signalling (e.g. `http://localhost:8787`).
  final Uri baseUrl;

  /// Channel everyone in this mesh shares.
  final String channel;

  /// Our own public key (hex) — our peer id in the mesh.
  final String selfPubkeyHex;

  /// How often we re-announce presence and discover new peers.
  final Duration announceInterval;

  /// How often we drain our signal mailbox.
  final Duration signalPollInterval;

  final http.Client _client;
  final List<Map<String, dynamic>> _iceServers;
  final Map<String, _PeerLink> _links = {};

  late final StreamController<Message> _incoming =
      StreamController<Message>.broadcast(onListen: _start);
  Timer? _announceTimer;
  Timer? _signalTimer;
  int _signalSince = 0;
  bool _announcing = false;
  bool _pollingSignals = false;
  bool _closed = false;

  @override
  Stream<Message> get incoming => _incoming.stream;

  /// Live peers we currently hold a connection (or attempt) for.
  Iterable<String> get peers => _links.keys;

  void _start() {
    unawaited(_announce());
    _announceTimer ??= Timer.periodic(
      announceInterval,
      (_) => unawaited(_announce()),
    );
    _signalTimer ??= Timer.periodic(
      signalPollInterval,
      (_) => unawaited(_pollSignals()),
    );
  }

  @override
  Future<void> send(Message message) async {
    final text = jsonEncode(message.toJson());
    for (final link in _links.values.toList()) {
      await link.sendText(text);
    }
  }

  /// Announce presence, then start offering to any peer we don't yet have.
  Future<void> _announce() async {
    if (_announcing || _closed) return;
    _announcing = true;
    try {
      final res = await _client.post(
        baseUrl.replace(path: '/announce'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({'channel': channel, 'pubkey': selfPubkeyHex}),
      );
      if (res.statusCode != 200) return;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      for (final peer in (body['peers'] as List).cast<String>()) {
        _maybeInitiate(peer);
      }
    } catch (_) {
      // Transient (relay down, blip) — the next tick retries.
    } finally {
      _announcing = false;
    }
  }

  /// Drain the signal mailbox and dispatch each entry to its peer link.
  Future<void> _pollSignals() async {
    if (_pollingSignals || _closed) return;
    _pollingSignals = true;
    try {
      final res = await _client.get(
        baseUrl.replace(
          path: '/signal',
          queryParameters: {'for': selfPubkeyHex, 'since': '$_signalSince'},
        ),
      );
      if (res.statusCode != 200) return;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      _signalSince = (body['seq'] as num).toInt();
      for (final raw in body['signals'] as List) {
        await _handleSignal((raw as Map).cast<String, Object?>());
      }
    } catch (_) {
      // Transient — the next tick retries.
    } finally {
      _pollingSignals = false;
    }
  }

  /// We initiate (offer) only to peers whose key sorts below ours, so exactly
  /// one side of every pair offers.
  void _maybeInitiate(String peerHex) {
    if (_closed || _links.containsKey(peerHex)) return;
    if (selfPubkeyHex.compareTo(peerHex) <= 0) return; // they offer to us
    final link = _createLink(peerHex, initiator: true);
    unawaited(link.start());
  }

  Future<void> _handleSignal(Map<String, Object?> sig) async {
    final from = sig['from'] as String?;
    final kind = sig['kind'] as String?;
    final data = sig['data'];
    if (from == null || kind == null || data is! Map) return;
    final payload = data.cast<String, Object?>();
    switch (kind) {
      case 'offer':
        final link = _links[from] ?? _createLink(from, initiator: false);
        await link.handleOffer(payload);
      case 'answer':
        await _links[from]?.handleAnswer(payload);
      case 'ice':
        await _links[from]?.handleIce(payload);
    }
  }

  _PeerLink _createLink(String peerHex, {required bool initiator}) {
    final link = _PeerLink(
      peerHex: peerHex,
      initiator: initiator,
      iceServers: _iceServers,
      onSignal: (kind, data) => _sendSignal(peerHex, kind, data),
      onMessage: _deliver,
      onClosed: () => _links.remove(peerHex),
    );
    _links[peerHex] = link;
    return link;
  }

  Future<void> _sendSignal(String to, String kind, Object? data) async {
    try {
      await _client.post(
        baseUrl.replace(path: '/signal'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({
          'to': to,
          'from': selfPubkeyHex,
          'kind': kind,
          'data': data,
        }),
      );
    } catch (_) {
      // Best effort — a dropped candidate just slows ICE; renegotiation retries.
    }
  }

  /// Decode, verify, and surface a data-channel message.
  Future<void> _deliver(String text) async {
    if (_closed || _incoming.isClosed) return;
    try {
      final json = (jsonDecode(text) as Map).cast<String, Object?>();
      final message = Message.fromJson(json);
      if (await message.verify() && !_incoming.isClosed) {
        _incoming.add(message);
      }
    } catch (_) {
      // Malformed or unverifiable — drop it.
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    _announceTimer?.cancel();
    _signalTimer?.cancel();
    for (final link in _links.values.toList()) {
      await link.dispose();
    }
    _links.clear();
    _client.close();
    if (!_incoming.isClosed) await _incoming.close();
  }
}

/// One side of a peer connection: owns the [RTCPeerConnection], its data
/// channel, and the ICE-candidate buffering that handshakes need.
class _PeerLink {
  _PeerLink({
    required this.peerHex,
    required this.initiator,
    required this._iceServers,
    required this.onSignal,
    required this.onMessage,
    required this.onClosed,
  });

  final String peerHex;
  final bool initiator;
  final List<Map<String, dynamic>> _iceServers;
  final void Function(String kind, Object? data) onSignal;
  final Future<void> Function(String text) onMessage;
  final void Function() onClosed;

  RTCPeerConnection? _pc;
  RTCDataChannel? _channel;
  bool _remoteSet = false;
  bool _disposed = false;
  final List<RTCIceCandidate> _pendingCandidates = [];

  Future<RTCPeerConnection> _ensurePc() async {
    final existing = _pc;
    if (existing != null) return existing;
    final pc = await createPeerConnection({'iceServers': _iceServers});
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return; // end-of-candidates marker
      onSignal('ice', {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };
    pc.onDataChannel = _wireChannel;
    pc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        unawaited(dispose());
      }
    };
    _pc = pc;
    return pc;
  }

  /// Initiator path: open the data channel and send an offer.
  Future<void> start() async {
    final pc = await _ensurePc();
    _wireChannel(await pc.createDataChannel('hearth', RTCDataChannelInit()));
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    onSignal('offer', {'sdp': offer.sdp, 'type': offer.type});
  }

  Future<void> handleOffer(Map<String, Object?> data) async {
    final pc = await _ensurePc();
    await pc.setRemoteDescription(
      RTCSessionDescription(data['sdp'] as String?, data['type'] as String?),
    );
    _remoteSet = true;
    await _flushCandidates();
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    onSignal('answer', {'sdp': answer.sdp, 'type': answer.type});
  }

  Future<void> handleAnswer(Map<String, Object?> data) async {
    final pc = _pc;
    if (pc == null) return;
    await pc.setRemoteDescription(
      RTCSessionDescription(data['sdp'] as String?, data['type'] as String?),
    );
    _remoteSet = true;
    await _flushCandidates();
  }

  Future<void> handleIce(Map<String, Object?> data) async {
    final candidate = RTCIceCandidate(
      data['candidate'] as String?,
      data['sdpMid'] as String?,
      (data['sdpMLineIndex'] as num?)?.toInt(),
    );
    // Candidates can arrive before the remote description is set; buffer them.
    if (!_remoteSet) {
      _pendingCandidates.add(candidate);
      return;
    }
    await _pc?.addCandidate(candidate);
  }

  Future<void> _flushCandidates() async {
    final pc = _pc;
    if (pc == null) return;
    for (final candidate in _pendingCandidates) {
      await pc.addCandidate(candidate);
    }
    _pendingCandidates.clear();
  }

  void _wireChannel(RTCDataChannel channel) {
    _channel = channel;
    channel.onMessage = (message) {
      if (!message.isBinary) unawaited(onMessage(message.text));
    };
  }

  Future<void> sendText(String text) async {
    final channel = _channel;
    if (channel?.state == RTCDataChannelState.RTCDataChannelOpen) {
      await channel!.send(RTCDataChannelMessage(text));
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _channel?.close();
    } catch (_) {}
    try {
      await _pc?.close();
    } catch (_) {}
    onClosed();
  }
}
