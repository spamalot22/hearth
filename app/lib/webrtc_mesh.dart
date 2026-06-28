// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:convert/convert.dart';
import 'package:core/core.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

import 'candidate_cache.dart';
import 'mesh_control.dart';
import 'relay_tunnel.dart';
import 'signal_auth.dart';
import 'update_checker.dart';

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
    this.onControl,
    this.forceInitiator,
    this.candidateCache,
    http.Client? client,
    this.announceInterval = const Duration(seconds: 5),
    this.signalPollInterval = const Duration(milliseconds: 700),
    this.idleAnnounceInterval = const Duration(seconds: 30),
    this.idleSignalInterval = const Duration(seconds: 15),
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

  /// Called when a peer sends a mesh control message (peer-exchange / relayed
  /// signalling) over the data channel. Null until track A wires a handler.
  final void Function(String peerHex, MeshControl control)? onControl;

  /// Who offers in this mesh. `null` (default) uses the glare rule — the
  /// lexicographically-greater pubkey offers, so exactly one side of each pair
  /// does. `true` always offers to every discovered peer; `false` never offers
  /// (answer-only). Screen share uses this to make the *sharer* the sole offerer
  /// (a one-way media offer must carry the track) and viewers answer-only, which
  /// also makes the screen mesh a star rather than a full mesh.
  final bool? forceInitiator;

  /// Optional persistent cache of known peers — enables instant reconnect.
  final CandidateCache? candidateCache;

  /// The signed release manifest to send to peers for version enforcement.
  /// Set from the last-verified manifest (relay or peer-provided).
  Map<String, Object?>? versionManifest;

  /// Our own public key (hex) — our peer id in the mesh.
  late final String selfPubkeyHex = identity.publicKeyHex;

  /// How often we re-announce presence and discover new peers.
  final Duration announceInterval;

  /// How often we drain our signal mailbox.
  final Duration signalPollInterval;

  /// Slow rates used once we're settled (connected, no handshake in flight), so
  /// the server is barely touched in steady state.
  final Duration idleAnnounceInterval;
  final Duration idleSignalInterval;

  final http.Client _client;
  final List<Map<String, dynamic>> _iceServers;
  final Map<String, _PeerLink> _links = {};
  // Per-peer reconnect backoff: after a failure, don't re-offer to a peer until
  // this time, so a flapping peer doesn't thrash the announce loop.
  final Map<String, DateTime> _backoffUntil = {};
  final Map<String, int> _backoffFailures = {}; // consecutive failure count
  final Map<String, RelayTunnel> _tunnels = {}; // peerHex -> active tunnel

  late final StreamController<FrameChannel> _peerConnected =
      StreamController<FrameChannel>.broadcast(onListen: _start);
  Timer? _announceTimer;
  Timer? _signalTimer;
  int _signalSince = 0;
  bool _announcing = false;
  bool _pollingSignals = false;
  bool _closed = false;
  bool _started = false;

  /// Emits a [FrameChannel] each time a peer's data channel opens; the app wires
  /// a [SyncEngine] session onto each.
  Stream<FrameChannel> get peerConnected => _peerConnected.stream;

  /// Peers we currently hold a connection (or attempt) for.
  Iterable<String> get peers => _links.keys;

  /// Returns the link for a specific peer (for sending control messages).
  void sendControlTo(String peerHex, MeshControl control) {
    final link = _links[peerHex];
    if (link != null && link.open) link.sendControl(control);
  }

  /// Attempts to connect to a peer we've learned about (e.g. via contacts-online).
  void maybeInitiateVia(String peerHex) => _maybeInitiate(peerHex);

  /// Connected peers' underlying connections (peerHex → pc) — for reading voice
  /// audio-level stats.
  Map<String, RTCPeerConnection> get connections => {
    for (final entry in _links.entries)
      if (entry.value.connection != null) entry.key: entry.value.connection!,
  };

  void _start() {
    if (_started) return;
    _started = true;
    // Try cached peers with staggered delays (before waiting for relay announce).
    final cached = candidateCache?.peersToTry(channel) ?? [];
    for (final (:peer, :delay) in cached) {
      if (delay == Duration.zero) {
        _maybeInitiate(peer);
      } else {
        Future.delayed(delay, () => _maybeInitiate(peer));
      }
    }
    unawaited(_announce());
    _scheduleAnnounce();
    _scheduleSignalPoll();
  }

  // Announce often while connecting or peerless, rarely once settled.
  void _scheduleAnnounce() {
    if (_closed) return;
    final delay = (_handshaking || !_connected)
        ? announceInterval
        : idleAnnounceInterval;
    _announceTimer = Timer(delay, () {
      unawaited(_announce());
      _scheduleAnnounce();
    });
  }

  // Drain the signal mailbox fast only while a handshake is in flight.
  void _scheduleSignalPoll() {
    if (_closed) return;
    final delay = _handshaking ? signalPollInterval : idleSignalInterval;
    _signalTimer = Timer(delay, () {
      unawaited(_pollSignals());
      _scheduleSignalPoll();
    });
  }

  // A handshake just started — reschedule the next poll soon for its replies.
  void _bumpSignalPoll() {
    if (_closed || _signalTimer == null) return;
    _signalTimer!.cancel();
    _scheduleSignalPoll();
  }

  /// A handshake is in flight (some link not yet open).
  bool get _handshaking => _links.values.any((link) => !link.open);

  /// We hold at least one open connection.
  bool get _connected => _links.values.any((link) => link.open);

  String? _authToken;

  /// Forces an immediate re-announce (e.g. after relay recovery).
  void forceAnnounce() {
    _announceTimer?.cancel();
    unawaited(_announce());
  }

  /// Announce presence, then start offering to any peer we don't yet have.
  Future<void> _announce() async {
    if (_announcing || _closed) return;
    _announcing = true;
    try {
      final ts = DateTime.now().toUtc().millisecondsSinceEpoch;
      final sigBytes = await identity.sign(
        utf8.encode('announce|$channel|$selfPubkeyHex|$ts'),
      );
      final sig = hex.encode(sigBytes);
      final res = await _client.post(
        baseUrl.replace(path: '/announce'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({
          'channel': channel,
          'pubkey': selfPubkeyHex,
          'ts': ts,
          'sig': sig,
        }),
      );
      if (res.statusCode != 200) return;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      _authToken = body['token'] as String?;
      for (final peer in (body['peers'] as List).cast<String>().take(
        _kMaxPeerFanout,
      )) {
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
      final params = <String, String>{
        'channel': channel,
        'for': selfPubkeyHex,
        'since': '$_signalSince',
      };
      if (_authToken != null) params['token'] = _authToken!;
      final res = await _client.get(
        baseUrl.replace(path: '/signal', queryParameters: params),
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

  /// Cap on how many peers a single peer-exchange / announce response can make us
  /// dial, so a malicious peer or relay can't flood us into spawning connections.
  static const int _kMaxPeerFanout = 64;

  /// We initiate (offer) only to peers whose key sorts below ours, so exactly
  /// one side of every pair offers.
  void _maybeInitiate(String peerHex) {
    // A pubkey is 32 bytes = 64 hex chars; drop anything malformed or our own.
    if (_closed ||
        peerHex.length != 64 ||
        peerHex == selfPubkeyHex ||
        _links.containsKey(peerHex)) {
      return;
    }
    // Default policy: the greater key offers (one offerer per pair). A forced
    // policy overrides it — `true` always offers, `false` never does.
    final shouldOffer =
        forceInitiator ?? (selfPubkeyHex.compareTo(peerHex) > 0);
    if (!shouldOffer) return;
    final until = _backoffUntil[peerHex];
    if (until != null && DateTime.now().isBefore(until)) return; // backing off
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
    if (!await verifySignal(from, selfPubkeyHex, channel, kind, payload)) {
      return;
    }
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
      onControl: (peer, control) {
        _handleControl(peer, control);
        onControl?.call(peer, control);
      },
      onSignal: (kind, data) => _sendSignal(peerHex, kind, data),
      onOpen: _emitPeer,
      onClosed: () {
        _links.remove(peerHex);
        final failures = (_backoffFailures[peerHex] ?? 0) + 1;
        _backoffFailures[peerHex] = failures;
        // Exponential: 10s, 20s, 40s, 80s, 160s, capped at 300s (5min).
        final delaySec = min(10 * (1 << (failures - 1)), 300);
        _backoffUntil[peerHex] = DateTime.now().add(
          Duration(seconds: delaySec),
        );
        // After 3 consecutive failures, try the relay tunnel (symmetric NAT).
        if (failures == 3 && !_closed) {
          _openTunnel(peerHex);
        }
        onPeerLeft?.call(peerHex);
      },
    );
    _links[peerHex] = link;
    _bumpSignalPoll(); // a handshake just started — poll fast for its replies
    return link;
  }

  void _emitPeer(_PeerLink link) {
    _backoffUntil.remove(link.peerHex); // connected — reset its backoff
    _backoffFailures.remove(link.peerHex);
    // Close any relay tunnel for this peer — direct connection wins.
    final tunnel = _tunnels.remove(link.peerHex);
    if (tunnel != null) unawaited(tunnel.close());
    if (!_closed && !_peerConnected.isClosed) _peerConnected.add(link);
    // Persist this peer so next startup can try them immediately.
    unawaited(candidateCache?.touch(channel, link.peerHex) ?? Future.value());
    // Peer-exchange: tell the new peer about everyone else we're connected to.
    final otherPeers = _links.entries
        .where((e) => e.key != link.peerHex && e.value.open)
        .map((e) => e.key)
        .toList();
    if (otherPeers.isNotEmpty) link.sendControl(PeersControl(otherPeers));
    // Version enforcement: share our version + the signed manifest.
    final manifest = versionManifest;
    if (manifest != null) {
      link.sendControl(VersionControl(version: appVersion, manifest: manifest));
    }
  }

  /// Handles mesh control messages (peer-exchange + relayed signalling).
  void _handleControl(String fromHex, MeshControl control) {
    switch (control) {
      case PeersControl(:final peers):
        for (final peerHex in peers.take(_kMaxPeerFanout)) {
          _maybeInitiate(peerHex);
        }
      case SignalControl(:final to, :final from, :final kind, :final data):
        if (to == selfPubkeyHex) {
          // Addressed to us — handle as if it came from the relay.
          unawaited(_handleSignal({'from': from, 'kind': kind, 'data': data}));
        } else {
          // Not for us — forward to the target if we have a link.
          _links[to]?.sendControl(control);
        }
      case ContactsOnlineControl():
        break; // Handled by the external onControl callback (app layer).
      case VersionControl():
        break; // Handled by the external onControl callback (app layer).
      case TypingControl():
        break; // Handled by the external onControl callback (app layer).
      case SoundboardControl():
        break; // Handled by the external onControl callback (voice layer).
      case ScreenShareControl():
        break; // Handled by the external onControl callback (voice layer).
      case YoutubeControl():
        break; // Handled by the external onControl callback (voice layer).
      case InferenceRequest():
        break; // Handled by the external onControl callback (app layer).
      case InferenceResponse():
        break; // Handled by the external onControl callback (app layer).
      case VoicePresenceControl():
        break; // Handled by the external onControl callback (app layer).
    }
  }

  /// Opens a relay tunnel as a fallback when ICE fails — symmetric NAT on both
  /// sides can't go direct, so the relay forwards opaque ciphertext.
  void _openTunnel(String peerHex) {
    if (_tunnels.containsKey(peerHex)) return; // already tunnelling
    final tunnel = RelayTunnel(
      baseUrl: baseUrl,
      selfPubkeyHex: selfPubkeyHex,
      peerPubkeyHex: peerHex,
      authToken: _authToken,
    );
    _tunnels[peerHex] = tunnel;
    tunnel.start();
    if (!_closed && !_peerConnected.isClosed) {
      _peerConnected.add(tunnel);
    }
  }

  Future<void> _sendSignal(String to, String kind, Object? data) async {
    final payload = (data! as Map).cast<String, Object?>();
    // Authenticate the signal so a relay/MITM can't forge it or swap the SDP's
    // DTLS fingerprint; the signature rides inside `data`.
    final signed = {
      ...payload,
      'sig': await signSignal(identity, channel, kind, to, payload),
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
          if (_authToken != null) 'token': _authToken,
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
    for (final tunnel in _tunnels.values) {
      await tunnel.close();
    }
    _tunnels.clear();
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
    this.onControl,
  });

  final String peerHex;
  final bool initiator;
  final List<Map<String, dynamic>> _iceServers;
  final MediaStream? localStream;
  final void Function(String peerHex, MediaStream stream)? onRemoteStream;
  final void Function(String kind, Object? data) onSignal;
  final void Function(_PeerLink link) onOpen;
  final void Function() onClosed;
  final void Function(String peerHex, MeshControl control)? onControl;

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

  /// Whether this link's data channel is open (handshake complete).
  bool get open => _opened;

  @override
  void send(SyncFrame frame) {
    final channel = _channel;
    if (channel?.state == RTCDataChannelState.RTCDataChannelOpen) {
      unawaited(
        channel!.send(RTCDataChannelMessage(wrapGossip(frame.encode()))),
      );
    }
  }

  /// Sends a mesh control message (peer-exchange / relayed signalling) to this peer.
  void sendControl(MeshControl control) {
    final channel = _channel;
    if (channel?.state == RTCDataChannelState.RTCDataChannelOpen) {
      unawaited(channel!.send(RTCDataChannelMessage(control.encode())));
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
    // Voice/screen: attach our local media before the offer/answer so it rides
    // in the initial SDP (no renegotiation). Sharers/voice have a localStream;
    // receive-only viewers have none and just add nothing.
    final stream = localStream;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        await pc.addTrack(track, stream);
      }
    }
    // Surface the peer's remote media. Wired unconditionally — a receive-only
    // viewer (no localStream) still needs onTrack to get the sharer's video.
    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        onRemoteStream?.call(peerHex, event.streams.first);
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
      final String text;
      if (message.isBinary) {
        text = utf8.decode(message.binary, allowMalformed: true);
      } else {
        text = message.text;
      }
      final split = splitFrame(text);
      if (split.isControl) {
        final control = MeshControl.decodeBody(split.body);
        if (control != null) onControl?.call(peerHex, control);
        return;
      }
      final frame = SyncFrame.decode(split.body);
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
