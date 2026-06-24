import 'dart:async';
import 'dart:convert';

import 'package:core/core.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

import 'signal_auth.dart';

/// A peer-to-peer WebRTC mesh that surfaces each connected peer to the gossip
/// layer as a [FrameChannel].
///
/// The relay is used only for rendezvous: we announce presence, discover peers,
/// and trade SDP + ICE through per-recipient mailboxes (`/announce`, `/peers`,
/// `/signal`). Once a peer's data channel opens it surfaces on [peerConnected];
/// from then on the backend is out of the loop and a [SyncEngine] session
/// reconciles directly over the channel.
///
/// Full mesh: one [RTCPeerConnection] per peer. To avoid both sides offering at
/// once (glare), the peer with the lexicographically-greater public key offers
/// and the other waits. Signalling is authenticated — each offer/answer/ICE is
/// Ed25519-signed and verified against the sender's pubkey (see `signal_auth`),
/// so a relay/MITM can't impersonate a peer or swap a DTLS fingerprint.
class WebRtcMesh {
  WebRtcMesh({
    required this.baseUrl,
    required this.channel,
    required this.identity,
    this.localStream,
    this.onRemoteStream,
    this.onPeerLeft,
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

  /// This node's identity — signs our signalling so peers can authenticate it.
  final Identity identity;

  /// Optional local media (the mic) sent to every peer — set for a voice mesh,
  /// null for the gossip mesh. Added to each connection *before* the offer, so
  /// the audio rides in the initial SDP and no renegotiation is needed.
  final MediaStream? localStream;

  /// Called with each peer's remote stream (their mic), for voice playback.
  final void Function(String peerHex, MediaStream stream)? onRemoteStream;

  /// Called with a peer's id when its connection drops — for voice, to play a
  /// disconnect cue and release their audio.
  final void Function(String peerHex)? onPeerLeft;

  /// Our own public key (hex) — our peer id in the mesh.
  late final String selfPubkeyHex = identity.publicKeyHex;

  /// How often we re-announce presence and discover new peers.
  final Duration announceInterval;

  /// How often we drain our signal mailbox.
  final Duration signalPollInterval;

  final http.Client _client;
  final List<Map<String, dynamic>> _iceServers;
  final Map<String, _PeerLink> _links = {};

  late final StreamController<FrameChannel> _peerConnected =
      StreamController<FrameChannel>.broadcast(onListen: _start);
  Timer? _announceTimer;
  Timer? _signalTimer;
  int _signalSince = 0;
  bool _announcing = false;
  bool _pollingSignals = false;
  bool _closed = false;

  /// Emits a [FrameChannel] each time a peer's data channel opens; the app wires
  /// a [SyncEngine] session onto each.
  Stream<FrameChannel> get peerConnected => _peerConnected.stream;

  /// Peers we currently hold a connection (or attempt) for.
  Iterable<String> get peers => _links.keys;

  /// Connected peers' underlying connections (peerHex → pc) — for reading voice
  /// audio-level stats.
  Map<String, RTCPeerConnection> get connections => {
    for (final entry in _links.entries)
      if (entry.value.connection != null) entry.key: entry.value.connection!,
  };

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
          queryParameters: {
            'channel': channel,
            'for': selfPubkeyHex,
            'since': '$_signalSince',
          },
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

  Future<void> _handleSignal(Map<String, Object?> signal) async {
    final from = signal['from'] as String?;
    final kind = signal['kind'] as String?;
    final data = signal['data'];
    if (from == null || kind == null || data is! Map) return;
    final payload = data.cast<String, Object?>();
    // Drop anything not validly signed by the claimed sender — this is what
    // stops a relay/MITM impersonating a peer or substituting a fingerprint.
    if (!await verifySignal(from, selfPubkeyHex, kind, payload)) return;
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
      localStream: localStream,
      onRemoteStream: onRemoteStream,
      onSignal: (kind, data) => _sendSignal(peerHex, kind, data),
      onOpen: _emitPeer,
      onClosed: () {
        _links.remove(peerHex);
        onPeerLeft?.call(peerHex);
      },
    );
    _links[peerHex] = link;
    return link;
  }

  void _emitPeer(_PeerLink link) {
    if (!_closed && !_peerConnected.isClosed) _peerConnected.add(link);
  }

  Future<void> _sendSignal(String to, String kind, Object? data) async {
    final payload = (data! as Map).cast<String, Object?>();
    // Authenticate the signal so a relay/MITM can't forge it or swap the SDP's
    // DTLS fingerprint; the signature rides inside `data`.
    final signed = {
      ...payload,
      'sig': await signSignal(identity, kind, to, payload),
    };
    try {
      await _client.post(
        baseUrl.replace(path: '/signal'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({
          'channel': channel,
          'to': to,
          'from': selfPubkeyHex,
          'kind': kind,
          'data': signed,
        }),
      );
    } catch (_) {
      // Best effort — a dropped candidate just slows ICE; renegotiation retries.
    }
  }

  Future<void> close() async {
    _closed = true;
    _announceTimer?.cancel();
    _signalTimer?.cancel();
    for (final link in _links.values.toList()) {
      await link.dispose();
    }
    _links.clear();
    _client.close();
    if (!_peerConnected.isClosed) await _peerConnected.close();
  }
}

/// One peer connection, exposed to the gossip layer as a [FrameChannel]: it owns
/// the [RTCPeerConnection], its data channel, and the ICE-candidate buffering a
/// handshake needs, and carries [SyncFrame]s once the channel is open.
class _PeerLink implements FrameChannel {
  _PeerLink({
    required this.peerHex,
    required this.initiator,
    required this._iceServers,
    required this.onSignal,
    required this.onOpen,
    required this.onClosed,
    this.localStream,
    this.onRemoteStream,
  });

  final String peerHex;
  final bool initiator;
  final List<Map<String, dynamic>> _iceServers;
  final MediaStream? localStream;
  final void Function(String peerHex, MediaStream stream)? onRemoteStream;
  final void Function(String kind, Object? data) onSignal;
  final void Function(_PeerLink link) onOpen;
  final void Function() onClosed;

  final StreamController<SyncFrame> _frames = StreamController<SyncFrame>();
  RTCPeerConnection? _pc;
  RTCDataChannel? _channel;
  bool _remoteSet = false;
  bool _opened = false;
  bool _disposed = false;
  final List<RTCIceCandidate> _pendingCandidates = [];

  @override
  Stream<SyncFrame> get frames => _frames.stream;

  /// The underlying peer connection — exposed for voice audio-level stats.
  RTCPeerConnection? get connection => _pc;

  @override
  void send(SyncFrame frame) {
    final channel = _channel;
    if (channel?.state == RTCDataChannelState.RTCDataChannelOpen) {
      unawaited(channel!.send(RTCDataChannelMessage(frame.encode())));
    }
  }

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
    // Voice: attach our mic before the offer/answer (so the audio is in the
    // initial SDP), and surface the peer's remote audio for playback.
    final stream = localStream;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        await pc.addTrack(track, stream);
      }
      pc.onTrack = (event) {
        if (event.streams.isNotEmpty) {
          onRemoteStream?.call(peerHex, event.streams.first);
        }
      };
    }
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
      if (message.isBinary) return;
      final frame = SyncFrame.decode(message.text);
      if (frame != null && !_frames.isClosed) _frames.add(frame);
    };
    channel.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen && !_opened) {
        _opened = true;
        onOpen(this); // surfaces this peer to the gossip layer
      }
    };
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
    if (!_frames.isClosed) await _frames.close();
    onClosed();
  }
}
