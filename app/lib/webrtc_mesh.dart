// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:convert/convert.dart';
import 'package:core/core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

import 'bounded_download.dart';
import 'candidate_cache.dart';
import 'diagnostics.dart';
import 'mesh_control.dart';
import 'peer_connection_health.dart';
import 'peer_signal_router.dart';
import 'signal_auth.dart';
import 'update_checker.dart';
import 'webrtc_signal_order.dart';

/// A peer-to-peer WebRTC mesh that surfaces each connected peer to the gossip
/// layer as a [FrameChannel].
///
/// The relay bootstraps a true cold start through `/announce`, `/peers`, and
/// `/signal`. Once any data channel is open, peers introduce the rest of that
/// channel and route signed SDP/ICE over existing links; cached identities can
/// therefore reconnect without the relay while one entry link survives. Open
/// channels surface on [peerConnected], where [SyncEngine] reconciles directly.
///
/// Full mesh: one [RTCPeerConnection] per peer. To avoid both sides offering at
/// once (glare), the peer with the lexicographically-greater public key offers
/// and the other waits. Signalling is authenticated — each offer/answer/ICE is
/// Ed25519-signed and verified against the sender's pubkey (see `signal_auth`),
/// so a relay/MITM can't impersonate a peer or swap a DTLS fingerprint.
class WebRtcMesh {
  WebRtcMesh({
    required this.baseUrl,
    this.fallbackUrls = const [],
    required this.channel,
    required this.identity,
    this.localStream,
    this.onRemoteStream,
    this.onPeerLeft,
    this.onPeerConnectedHex,
    this.onControl,
    this.onRelayPresenceChanged,
    this.peerAllowed,
    this.channelAuthKey,
    this.forceInitiator,
    this.candidateCache,
    this.initialPeers = const <String>{},
    this.externalSignalSender,
    this.externalRouteAvailable,
    this.relayFallbackDelay = Duration.zero,
    this.coordinateRelayDuty = false,
    this.onRelayDutyChanged,
    this.onRelayStandbyProbe,
    this.diagnosticLabel = 'mesh',
    this.standbyProbeInterval = const Duration(minutes: 2),
    http.Client? client,
    this.announceInterval = const Duration(seconds: 5),
    this.signalPollInterval = const Duration(milliseconds: 700),
    this.idleAnnounceInterval = const Duration(seconds: 10),
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

  /// Additional relay URLs to try if the primary is unreachable.
  List<Uri> fallbackUrls;

  /// The relay URL currently in use (may differ from baseUrl after failover).
  late Uri _activeUrl = baseUrl;

  /// The relay currently being used (follows failover).
  Uri get activeUrl => _activeUrl;

  /// Last time the primary relay was probed — used to periodically re-prefer it
  /// after a failover without routing traffic to it before the probe succeeds.
  DateTime _primaryProbeAt = DateTime.now();

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

  /// Called with a peer's id when its data channel opens. Symmetric with
  /// [onPeerLeft]; the rendezvous listener uses it to learn who reached it (the
  /// [peerConnected] stream carries the channel but not the peer's identity).
  final void Function(String peerHex)? onPeerConnectedHex;

  /// Called when a peer sends a mesh control message (peer-exchange / relayed
  /// signalling) over the data channel. Null until track A wires a handler.
  final void Function(String peerHex, MeshControl control)? onControl;

  /// Called when independently-verified, short-lived relay presence changes.
  final VoidCallback? onRelayPresenceChanged;

  /// Optional channel-level admission policy. Signalling authentication proves
  /// who a peer is; this decides whether that identity belongs in this mesh.
  final bool Function(String peerHex)? peerAllowed;

  /// Optional 32-byte capability required on every SDP/ICE signal. Group chat,
  /// voice, and screen meshes set this to the channel encryption key so merely
  /// observing the relay namespace is insufficient to join the mesh.
  final Uint8List? channelAuthKey;

  /// Who offers in this mesh. `null` (default) uses the glare rule — the
  /// lexicographically-greater pubkey offers, so exactly one side of each pair
  /// does. `true` always offers to every discovered peer; `false` never offers
  /// (answer-only). Screen share uses this to make the *sharer* the sole offerer
  /// (a one-way media offer must carry the track) and viewers answer-only, which
  /// also makes the screen mesh a star rather than a full mesh.
  final bool? forceInitiator;

  /// Optional persistent cache of known peer identities. They can reconnect
  /// through a live mesh route, or through relay rendezvous after a cold start.
  final CandidateCache? candidateCache;

  /// Peers already known to be relevant to this short-lived mesh. Voice uses
  /// current channel occupancy rather than dialling every channel member.
  final Set<String> initialPeers;

  /// Carries this mesh's authenticated signalling over an already-open parent
  /// data mesh. The callback returns true only when at least one P2P next hop
  /// accepted the signal.
  final Future<bool> Function(SignalControl signal)? externalSignalSender;

  /// Whether the parent mesh currently has a direct or peer-assisted route.
  final bool Function(String peerHex)? externalRouteAvailable;

  /// Grace period reserved for direct and peer-assisted discovery before relay
  /// rendezvous is enabled. Ordinary chat meshes use zero for cold starts.
  final Duration relayFallbackDelay;

  /// When true, authenticated direct peers rotate redundant relay-watch duty.
  /// Media/star meshes leave this disabled because their topology differs.
  final bool coordinateRelayDuty;

  /// Reports whether this node should perform routine relay work for its
  /// connected component. An outgoing worker may still drain its own signal
  /// mailbox for a bounded handoff window.
  final void Function(bool active)? onRelayDutyChanged;

  /// Performs one courier poll alongside a standby rendezvous probe.
  final Future<void> Function()? onRelayStandbyProbe;

  /// Non-sensitive category included in native WebRTC diagnostics. This must
  /// never contain a channel id, peer id, handle, or message content.
  final String diagnosticLabel;

  /// Maximum steady-state interval between each standby's own relay probes.
  /// A deterministic per-device offset spreads requests within the interval.
  final Duration standbyProbeInterval;

  /// The signed release manifest to send to peers for version enforcement.
  /// Set from the last-verified manifest (GitHub or peer-provided).
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
  final Map<String, String> _signalTransport = {};
  final Map<String, DateTime> _relayReplyUntil = {};
  final Map<String, List<Map<String, Object?>>> _earlyRemoteIce = {};
  final Map<String, DateTime> _relayPresenceUntil = {};
  final Map<String, DateTime> _relayVoicePresenceUntil = {};
  late final PeerSignalRouter _peerSignalRouter = PeerSignalRouter(
    selfPeer: selfPubkeyHex,
    channel: channel,
  );
  final Map<String, _SignalRateWindow> _routedSignalRates = {};
  String? _relayEpoch;
  Uri? _signalCursorUrl;
  bool _relayObserved = false;

  late final StreamController<FrameChannel> _peerConnected =
      StreamController<FrameChannel>.broadcast(onListen: _start);
  final StreamController<SignalControl> _externalSignals =
      StreamController<SignalControl>.broadcast();
  Timer? _announceTimer;
  Timer? _signalTimer;
  Timer? _relayDutyTimer;
  Timer? _standbyProbeTimer;
  Timer? _relayPresenceTimer;
  Timer? _relayFallbackTimer;
  int _signalSince = 0;
  bool _announcing = false;
  bool _pollingSignals = false;
  bool _closed = false;
  bool _started = false;
  bool _recovering = false;
  final Set<String> _intentionalDisconnects = {};
  bool _hasRelayDuty = true;
  bool _standbyProbing = false;
  bool _localVoicePresent = false;
  bool _relayFallbackEnabled = false;
  DateTime? _signalDrainUntil;
  static const RelayDutySchedule _relayDutySchedule = RelayDutySchedule();
  static const Duration _signalHandoffDrain = Duration(seconds: 50);

  /// True when this node should perform the component's routine relay work.
  bool get hasRelayDuty => _hasRelayDuty;

  /// Emits a [FrameChannel] each time a peer's data channel opens; the app wires
  /// a [SyncEngine] session onto each.
  Stream<FrameChannel> get peerConnected => _peerConnected.stream;

  /// Authenticated signalling addressed to a child voice mesh.
  Stream<SignalControl> get externalSignals => _externalSignals.stream;

  /// Peers we currently hold a connection (or attempt) for.
  Iterable<String> get peers => _links.keys;

  /// Returns the link for a specific peer (for sending control messages).
  void sendControlTo(String peerHex, MeshControl control) {
    final link = _links[peerHex];
    if (link != null && link.open) link.sendControl(control);
  }

  /// Waits for control frames already queued on open data channels. Voice uses
  /// this before closing so its explicit leave cannot be discarded locally.
  Future<void> flushPendingSends() async {
    await Future.wait(
      _links.values.where((link) => link.open).map((link) => link.flushSends()),
    );
  }

  /// Closes one peer deliberately without treating it as a failed connection.
  Future<void> disconnectPeer(String peerHex) async {
    final link = _links[peerHex];
    if (link != null) {
      HearthDiagnostics.log(
        '[hearth][$diagnosticLabel] intentional peer disconnect',
      );
      _intentionalDisconnects.add(peerHex);
      await link.dispose();
    }
  }

  /// Attempts to connect to a peer learned through an existing mesh link.
  void maybeInitiateVia(String peerHex, {String? viaPeerHex}) {
    if (viaPeerHex != null) {
      _peerSignalRouter.learnRoute(peerHex, viaPeerHex);
    }
    _maybeInitiate(peerHex);
  }

  /// Whether this mesh can carry an authenticated child-mesh signal toward
  /// [peerHex] without contacting the relay.
  bool canRouteSignalTo(String peerHex) =>
      _peerSignalRouter.hasPath(peerHex, _openPeerIds);

  /// Routes a signal for this channel's voice child over existing P2P links.
  /// The envelope is authenticated before forwarding, even on the originating
  /// device, so malformed child data cannot enter the shared mesh.
  Future<bool> routeExternalSignal(SignalControl control) async {
    if (_closed || control.from != selfPubkeyHex) return false;
    if (!await _peerSignalRouter.authenticate(
      control,
      channelAuthKey: channelAuthKey,
    )) {
      return false;
    }
    if (!_peerSignalRouter.remember(control)) {
      return canRouteSignalTo(control.to);
    }
    return _routeSignal(control);
  }

  /// Delivers a parent-routed signal into this child mesh. Signature and channel
  /// capability verification still happen in [_handleSignal].
  Future<void> receiveExternalSignal(SignalControl control) async {
    if (_closed ||
        control.namespace != channel ||
        control.to != selfPubkeyHex) {
      return;
    }
    await _handleSignal({
      'from': control.from,
      'kind': control.kind,
      'data': control.data,
    }, routedVia: control.from);
  }

  /// Connected peers' underlying connections (peerHex → pc) — for reading voice
  /// audio-level stats.
  Map<String, RTCPeerConnection> get connections => {
    for (final entry in _links.entries)
      if (entry.value.open && entry.value.connection != null)
        entry.key: entry.value.connection!,
  };

  /// Peers with an open direct WebRTC data channel.
  Iterable<String> get connectedPeers => connections.keys;

  /// Peers with a fresh signed relay announcement, whether or not WebRTC opened.
  Iterable<String> get relayVisiblePeers {
    final now = DateTime.now();
    return _relayPresenceUntil.entries
        .where((entry) => entry.value.isAfter(now))
        .map((entry) => entry.key);
  }

  /// Peers whose fresh ordinary-channel announcement includes an independently
  /// verified voice-presence assertion. This is UI occupancy only; it never
  /// carries voice media or grants access to the separate voice mesh.
  Iterable<String> get relayVoicePeers {
    final now = DateTime.now();
    return _relayVoicePresenceUntil.entries
        .where((entry) => entry.value.isAfter(now))
        .map((entry) => entry.key);
  }

  /// Peers known online through either a data path or authenticated presence.
  Iterable<String> get presentPeers => {
    ...connectedPeers,
    ...relayVisiblePeers,
  };

  /// Updates the optional voice assertion carried by the next ordinary-channel
  /// relay announcement. Heartbeats deliberately force an announce even when
  /// the value is unchanged so a standby peer remains visible during a call.
  void announceVoicePresence(bool active) {
    _localVoicePresent = active;
    forceAnnounce();
  }

  void _start() {
    if (_started) return;
    _started = true;
    // A child media mesh can signal over its established parent without touching
    // the relay. Only enable rendezvous after that bounded grace period expires.
    _tryCachedPeers();
    if (relayFallbackDelay <= Duration.zero) {
      unawaited(_enableRelayFallback());
    } else {
      _relayFallbackTimer = Timer(
        relayFallbackDelay,
        () => unawaited(_enableRelayFallback()),
      );
    }
    if (coordinateRelayDuty) {
      _relayDutyTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _refreshRelayDuty(),
      );
    }
  }

  Future<void> _enableRelayFallback() async {
    if (_closed || _relayFallbackEnabled) return;
    _relayFallbackEnabled = true;
    if (relayFallbackDelay > Duration.zero) {
      HearthDiagnostics.log(
        '[hearth][$diagnosticLabel] enabling relay rendezvous fallback',
      );
    }
    await _announce();
    _tryCachedPeers();
    if (_closed) return;
    _scheduleAnnounce();
    _scheduleSignalPoll();
  }

  Iterable<String> get _openPeerIds => _links.entries
      .where((entry) => entry.value.open)
      .map((entry) => entry.key);

  void _tryCachedPeers() {
    final cached = <({String peer, Duration delay})>[
      for (final peer in initialPeers) (peer: peer, delay: Duration.zero),
      ...?candidateCache?.peersToTry(channel),
    ];
    final attempted = <String>{};
    for (final (:peer, :delay) in cached) {
      if (!attempted.add(peer)) continue;
      if (delay == Duration.zero) {
        _maybeInitiate(peer);
      } else {
        Future.delayed(delay, () => _maybeInitiate(peer));
      }
    }
  }

  // Announce often while connecting or peerless, rarely once settled.
  void _scheduleAnnounce() {
    if (_closed || !_relayFallbackEnabled) return;
    final delay = (_handshaking || !_connected)
        ? announceInterval
        : idleAnnounceInterval;
    _announceTimer = Timer(delay, () {
      if (_hasRelayDuty) unawaited(_announce());
      _scheduleAnnounce();
    });
  }

  // Drain the signal mailbox fast only while a handshake is in flight.
  void _scheduleSignalPoll() {
    if (_closed || !_relayFallbackEnabled) return;
    final delay = _handshaking ? signalPollInterval : idleSignalInterval;
    _signalTimer = Timer(delay, () {
      if (_shouldPollRelaySignals) {
        unawaited(_pollSignals());
      } else {
        _authToken = null;
      }
      _scheduleSignalPoll();
    });
  }

  // A handshake just started — reschedule the next poll soon for its replies.
  void _bumpSignalPoll() {
    if (_closed || !_relayFallbackEnabled || _signalTimer == null) return;
    _signalTimer!.cancel();
    _scheduleSignalPoll();
  }

  /// A handshake is in flight (some link not yet open).
  bool get _handshaking => _links.values.any((link) => !link.open);

  /// We hold at least one open connection.
  bool get _connected => _links.values.any((link) => link.open);

  bool get _shouldPollRelaySignals {
    if (_hasRelayDuty) return true;
    final until = _signalDrainUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  void _extendSignalDrain() {
    final until = DateTime.now().add(_signalHandoffDrain);
    if (_signalDrainUntil == null || until.isAfter(_signalDrainUntil!)) {
      _signalDrainUntil = until;
    }
  }

  void _refreshRelayDuty() {
    if (!coordinateRelayDuty || _closed) return;
    final directPeers = connectedPeers.toList(growable: false);
    final active =
        !_connected ||
        _handshaking ||
        _relayDutySchedule.isWorker(
          self: selfPubkeyHex,
          members: directPeers,
          channel: channel,
          now: DateTime.now(),
        );
    _setRelayDuty(active);
  }

  void _setRelayDuty(bool active) {
    if (active == _hasRelayDuty) return;
    _hasRelayDuty = active;
    if (active) {
      _signalDrainUntil = null;
      _standbyProbeTimer?.cancel();
      _standbyProbeTimer = null;
    } else {
      // We may remain visible in relay presence for 15 seconds. Drain this
      // identity's mailbox through that window plus the relay's 30-second
      // signal TTL so handoff cannot strand an offer addressed to us.
      _extendSignalDrain();
      _scheduleStandbyProbe();
    }
    onRelayDutyChanged?.call(active);
    if (!_started) return;

    _announceTimer?.cancel();
    _signalTimer?.cancel();
    _scheduleAnnounce();
    _scheduleSignalPoll();
    if (active) {
      unawaited(() async {
        await _announce();
        if (!_closed && _hasRelayDuty) await _pollSignals();
      }());
    }
  }

  @visibleForTesting
  void debugSetRelayDuty(bool active) => _setRelayDuty(active);

  void _scheduleStandbyProbe() {
    if (_closed || _hasRelayDuty || _standbyProbeTimer != null) return;
    final intervalMs = max(1, standbyProbeInterval.inMilliseconds);
    final spreadMs = max(1, intervalMs ~/ 4);
    final prefix = selfPubkeyHex.substring(0, min(8, selfPubkeyHex.length));
    final offset = int.tryParse(prefix, radix: 16) ?? 0;
    final delayMs = intervalMs - spreadMs + (offset % spreadMs);
    _standbyProbeTimer = Timer(Duration(milliseconds: delayMs), () {
      _standbyProbeTimer = null;
      unawaited(_runStandbyProbe());
    });
  }

  Future<void> _runStandbyProbe() async {
    if (_closed || _hasRelayDuty || _standbyProbing) return;
    _standbyProbing = true;
    _extendSignalDrain();
    try {
      final announced = await _announce();
      if (announced && !_closed && !_hasRelayDuty) await _pollSignals();
      if (!_closed && !_hasRelayDuty) await onRelayStandbyProbe?.call();
    } finally {
      _standbyProbing = false;
      _scheduleStandbyProbe();
    }
  }

  String? _authToken;

  /// The current announce token (valid for ~60s, refreshed each announce cycle).
  String? get authToken => _authToken;

  /// Associates the signal cursor with one relay process. Returns true when
  /// the endpoint or process generation changed and the cursor must restart.
  bool _observeRelay(Uri url, Object? epochValue) {
    var changed = _signalCursorUrl != null && _signalCursorUrl != url;
    if (epochValue is String && epochValue.isNotEmpty) {
      changed = changed || (_relayObserved && _relayEpoch != epochValue);
      _relayEpoch = epochValue;
    } else if (changed) {
      _relayEpoch = null;
    }
    _signalCursorUrl = url;
    _relayObserved = true;
    return changed;
  }

  /// Forces an immediate re-announce (e.g. after relay recovery).
  void forceAnnounce() {
    if (_closed || !_relayFallbackEnabled) return;
    if (!_hasRelayDuty) _extendSignalDrain();
    _announceTimer?.cancel();
    unawaited(_announce());
    if (_started) _scheduleAnnounce();
  }

  /// Replaces peer connections that are no longer healthy after mobile
  /// suspension, then immediately resumes rendezvous. A foreground voice
  /// service can keep a genuinely healthy native link alive while the Flutter
  /// activity is hidden, so closing every link on resume causes avoidable
  /// one-sided reconnect failures.
  Future<void> recoverConnections() async {
    if (_closed || _recovering) return;
    _recovering = true;
    try {
      _announceTimer?.cancel();
      _signalTimer?.cancel();
      _backoffUntil.clear();
      _backoffFailures.clear();
      _earlyRemoteIce.clear();

      final unhealthyLinks = _links.values
          .where((link) => !link.healthy)
          .toList();
      HearthDiagnostics.log(
        '[hearth][$diagnosticLabel] lifecycle recovery: '
        'preserving ${_links.length - unhealthyLinks.length} healthy link(s), '
        'replacing ${unhealthyLinks.length}',
      );
      for (final link in unhealthyLinks) {
        await link.dispose();
      }
    } finally {
      _recovering = false;
    }

    if (_closed) return;
    if (_started && _relayFallbackEnabled) {
      _scheduleAnnounce();
      _scheduleSignalPoll();
    }
    _tryCachedPeers();
    if (_relayFallbackEnabled) {
      await _announce();
      await _pollSignals();
    }
  }

  /// Closes links that no longer satisfy a dynamic admission policy (for
  /// example after learning that a device was revoked).
  Future<void> enforcePeerPolicy() async {
    for (final entry in _links.entries.toList()) {
      if (peerAllowed?.call(entry.key) ?? true) continue;
      await entry.value.dispose();
    }
  }

  /// Announce presence, then start offering to any peer we don't yet have.
  Future<bool> _announce() async {
    if (_announcing || _closed) return false;
    _announcing = true;
    var retrySignals = false;
    try {
      final ts = DateTime.now().toUtc().millisecondsSinceEpoch;
      final sigBytes = await identity.sign(
        presenceSigningBytes(channel, selfPubkeyHex, ts),
      );
      final sig = hex.encode(sigBytes);
      final voiceSig = _localVoicePresent
          ? hex.encode(
              await identity.sign(
                voicePresenceSigningBytes(channel, selfPubkeyHex, ts),
              ),
            )
          : null;
      final authKey = channelAuthKey;
      final payload = jsonEncode({
        'channel': channel,
        'pubkey': selfPubkeyHex,
        'ts': ts,
        'sig': sig,
        if (voiceSig != null) 'voice': true,
        'voiceSig': ?voiceSig,
        if (authKey != null)
          'cap': createPresenceCapabilityProof(
            authKey,
            selfPubkeyHex,
            channel,
            ts,
          ),
      });
      // Re-probe the primary ~once a minute so we return to it after it
      // recovers — otherwise failover is sticky and we'd stay on a fallback
      // indefinitely even once the primary is healthy again.
      final now = DateTime.now();
      final probePrimary =
          _activeUrl != baseUrl &&
          now.difference(_primaryProbeAt) > const Duration(seconds: 60);
      if (probePrimary) _primaryProbeAt = now;
      // Probe the primary first when due, but keep the working relay active
      // until the probe has returned a complete, valid announce response.
      final urls = probePrimary
          ? {baseUrl, _activeUrl, ...fallbackUrls}.toList()
          : {_activeUrl, ...fallbackUrls, baseUrl}.toList();
      for (final url in urls) {
        try {
          final request = http.Request('POST', url.replace(path: '/announce'))
            ..headers['content-type'] = 'application/json'
            ..body = payload;
          final res = await _client
              .send(request)
              .timeout(const Duration(seconds: 5));
          if (res.statusCode != 200) continue;
          final body = await readJsonObjectBounded(
            res,
            maxBytes: 256 * 1024,
            timeout: const Duration(seconds: 5),
          );
          final token = body['token'];
          if (token is! String || token.isEmpty) continue;
          _activeUrl = url;
          if (url == baseUrl) _primaryProbeAt = DateTime.now();
          if (_observeRelay(url, body['relayEpoch'])) {
            _signalSince = 0;
            retrySignals = true;
          }
          _authToken = token;
          await _replaceRelayPresence(body['presence']);
          if (!_hasRelayDuty) _extendSignalDrain();
          final peers = body['peers'];
          if (peers is List) {
            for (final peer in peers.whereType<String>().take(
              _kMaxPeerFanout,
            )) {
              _maybeInitiate(peer);
            }
          }
          return true;
        } catch (_) {
          continue; // try next
        }
      }
    } finally {
      _announcing = false;
      if (retrySignals && !_closed) unawaited(_pollSignals());
    }
    return false;
  }

  Future<void> _replaceRelayPresence(Object? raw) async {
    final List<Object?> claims = raw is List
        ? raw.take(_kMaxPeerFanout).toList()
        : const <Object?>[];
    final valid = await Future.wait(
      claims.map((claim) async {
        if (claim is! Map) return null;
        final value = claim.cast<Object?, Object?>();
        final pubkey = value['pubkey'];
        final ts = value['ts'];
        final sig = value['sig'];
        if (pubkey is! String ||
            ts is! int ||
            sig is! String ||
            pubkey == selfPubkeyHex ||
            !(peerAllowed?.call(pubkey) ?? true)) {
          return null;
        }
        final verified = await verifyRelayPresenceClaim(
          channel: channel,
          pubkey: pubkey,
          timestampMs: ts,
          signatureHex: sig,
          channelKey: channelAuthKey,
          capability: value['cap'],
        );
        if (!verified) return null;
        final voiceSignature = value['voiceSig'];
        final voice =
            value['voice'] == true &&
            voiceSignature is String &&
            await verifyRelayVoicePresenceClaim(
              channel: channel,
              pubkey: pubkey,
              timestampMs: ts,
              signatureHex: voiceSignature,
            );
        return (pubkey: pubkey, voice: voice);
      }),
    );
    if (_closed) return;

    final before = relayVisiblePeers.toSet();
    final voiceBefore = relayVoicePeers.toSet();
    final expires = DateTime.now().add(const Duration(seconds: 20));
    _relayPresenceUntil
      ..clear()
      ..addEntries(
        valid.whereType<({String pubkey, bool voice})>().map(
          (claim) => MapEntry(claim.pubkey, expires),
        ),
      );
    _relayVoicePresenceUntil
      ..clear()
      ..addEntries(
        valid
            .whereType<({String pubkey, bool voice})>()
            .where((claim) => claim.voice)
            .map((claim) => MapEntry(claim.pubkey, expires)),
      );
    _scheduleRelayPresenceExpiry();
    if (!setEquals(before, relayVisiblePeers.toSet()) ||
        !setEquals(voiceBefore, relayVoicePeers.toSet())) {
      onRelayPresenceChanged?.call();
    }
  }

  void _scheduleRelayPresenceExpiry() {
    _relayPresenceTimer?.cancel();
    _relayPresenceTimer = null;
    if (_relayPresenceUntil.isEmpty || _closed) return;
    final earliest = _relayPresenceUntil.values.reduce(
      (a, b) => a.isBefore(b) ? a : b,
    );
    final delay = earliest.difference(DateTime.now());
    _relayPresenceTimer = Timer(
      delay.isNegative ? Duration.zero : delay,
      _expireRelayPresence,
    );
  }

  void _expireRelayPresence() {
    if (_closed) return;
    final before = _relayPresenceUntil.keys.toSet();
    final voiceBefore = _relayVoicePresenceUntil.keys.toSet();
    final now = DateTime.now();
    _relayPresenceUntil.removeWhere((_, expires) => !expires.isAfter(now));
    _relayVoicePresenceUntil.removeWhere((_, expires) => !expires.isAfter(now));
    _scheduleRelayPresenceExpiry();
    if (!setEquals(before, relayVisiblePeers.toSet()) ||
        !setEquals(voiceBefore, relayVoicePeers.toSet())) {
      onRelayPresenceChanged?.call();
    }
  }

  /// Drain the signal mailbox and dispatch each entry to its peer link.
  Future<void> _pollSignals() async {
    if (_pollingSignals || _closed) return;
    _pollingSignals = true;
    var retry = false;
    try {
      final params = <String, String>{
        'channel': channel,
        'for': selfPubkeyHex,
        'since': '$_signalSince',
      };
      final headers = <String, String>{};
      if (_authToken != null) headers['Authorization'] = 'Bearer $_authToken';
      final pollUrl = _activeUrl;
      final request = http.Request(
        'GET',
        pollUrl.replace(path: '/signal', queryParameters: params),
      )..headers.addAll(headers);
      final res = await _client
          .send(request)
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return;
      if (pollUrl != _activeUrl) return;
      final body = await readJsonObjectBounded(
        res,
        maxBytes: 2 * 1024 * 1024,
        timeout: const Duration(seconds: 5),
      );
      if (_observeRelay(pollUrl, body['relayEpoch'])) {
        _signalSince = 0;
        retry = true;
        return;
      }
      final signals = body['signals'];
      if (signals is List) {
        for (final raw in signals.take(256)) {
          try {
            if (raw is Map) {
              await _handleSignal(
                raw.cast<String, Object?>(),
                deliveredByRelay: true,
              );
            }
          } catch (_) {
            // One malformed entry must not hide later signals in the batch.
          }
        }
      }
      final seq = body['seq'];
      if (seq is int && seq > _signalSince) _signalSince = seq;
    } catch (_) {
      // Transient — the next tick retries.
    } finally {
      _pollingSignals = false;
      if (retry && !_closed) unawaited(_pollSignals());
    }
  }

  /// Cap on how many peers a single peer-exchange / announce response can make us
  /// dial, so a malicious peer or relay can't flood us into spawning connections.
  static const int _kMaxPeerFanout = 64;
  static const int _kMaxPeerConnections = 64;
  static const int _kMaxRememberedFailures = 1024;
  static final RegExp _peerIdPattern = RegExp(r'^[0-9a-f]{64}$');

  /// We initiate (offer) only to peers whose key sorts below ours, so exactly
  /// one side of every pair offers.
  void _maybeInitiate(String peerHex) {
    // A pubkey is 32 bytes = 64 hex chars; drop anything malformed or our own.
    if (_closed ||
        !_peerIdPattern.hasMatch(peerHex) ||
        peerHex == selfPubkeyHex ||
        !(peerAllowed?.call(peerHex) ?? true) ||
        _links.containsKey(peerHex) ||
        _links.length >= _kMaxPeerConnections) {
      return;
    }
    // A relay token, an internal route, or a parent data-mesh route can carry
    // fresh SDP/ICE. With none, wait for peer-assisted discovery or the bounded
    // relay fallback rather than creating a doomed PeerConnection.
    if (_authToken == null &&
        !_peerSignalRouter.hasPath(peerHex, _openPeerIds) &&
        !(externalRouteAvailable?.call(peerHex) ?? false)) {
      return;
    }
    // Default policy: the greater key offers (one offerer per pair). A forced
    // policy overrides it — `true` always offers, `false` never does.
    final shouldOffer =
        forceInitiator ?? (selfPubkeyHex.compareTo(peerHex) > 0);
    if (!shouldOffer) {
      // The answer-only side waits on either its parent route or relay mailbox.
      // Do not call
      // _bumpSignalPoll here: while there is no link yet, it selects the idle
      // interval. Repeated five-second announces then keep cancelling and
      // postponing that 15-second timer forever, so the offer is never read.
      if (_relayFallbackEnabled) unawaited(_pollSignals());
      return;
    }
    final until = _backoffUntil[peerHex];
    if (until != null && DateTime.now().isBefore(until)) return; // backing off
    final link = _createLink(peerHex, initiator: true);
    unawaited(() async {
      try {
        await link.start();
      } catch (error) {
        HearthDiagnostics.log(
          '[hearth][$diagnosticLabel] offer failed: ${error.runtimeType}',
        );
        await link.dispose();
      }
    }());
  }

  Future<void> _handleSignal(
    Map<String, Object?> signal, {
    String? routedVia,
    bool authenticated = false,
    bool deliveredByRelay = false,
  }) async {
    final fromValue = signal['from'];
    final kindValue = signal['kind'];
    final data = signal['data'];
    if (fromValue is! String || kindValue is! String || data is! Map) return;
    final from = fromValue;
    final kind = kindValue;
    if (!_peerIdPattern.hasMatch(from) || from == selfPubkeyHex) return;
    if (!(peerAllowed?.call(from) ?? true)) return;
    final payload = data.cast<String, Object?>();
    final control = SignalControl(
      to: selfPubkeyHex,
      from: from,
      kind: kind,
      data: payload,
    );
    // Relay and P2P signalling take the same authenticated path. This also
    // deduplicates a signal delivered over both transports during failover.
    if (!authenticated &&
        !await _peerSignalRouter.authenticate(
          control,
          channelAuthKey: channelAuthKey,
        )) {
      return;
    }
    if (!_peerSignalRouter.remember(control)) return;
    if (deliveredByRelay) {
      _relayReplyUntil[from] = DateTime.now().add(const Duration(seconds: 30));
    }
    if (routedVia != null) {
      _peerSignalRouter.learnRoute(from, routedVia);
    }
    try {
      switch (kind) {
        case 'offer':
          if (!_links.containsKey(from) &&
              _links.length >= _kMaxPeerConnections) {
            return;
          }
          final link = _links[from] ?? _createLink(from, initiator: false);
          await link.handleOffer(payload);
          final earlyIce = _earlyRemoteIce.remove(from);
          if (earlyIce != null) {
            for (final candidate in earlyIce) {
              await link.handleIce(candidate);
            }
          }
        case 'answer':
          await _links[from]?.handleAnswer(payload);
        case 'ice':
          final link = _links[from];
          if (link != null) {
            await link.handleIce(payload);
          } else {
            _bufferEarlyRemoteIce(from, payload);
          }
      }
    } catch (error) {
      HearthDiagnostics.log(
        '[hearth][$diagnosticLabel] $kind handling failed: '
        '${error.runtimeType}',
      );
      // One malformed signed SDP/candidate must not abort the mailbox batch or
      // leave a permanently handshaking link behind.
      await _links[from]?.dispose();
    }
  }

  void _bufferEarlyRemoteIce(String peerHex, Map<String, Object?> candidate) {
    const maxPeers = 64;
    const maxCandidatesPerPeer = 64;
    if (!_earlyRemoteIce.containsKey(peerHex) &&
        _earlyRemoteIce.length >= maxPeers) {
      return;
    }
    final pending = _earlyRemoteIce.putIfAbsent(peerHex, () => []);
    if (pending.length < maxCandidatesPerPeer) pending.add(candidate);
  }

  _PeerLink _createLink(String peerHex, {required bool initiator}) {
    late final _PeerLink link;
    link = _PeerLink(
      peerHex: peerHex,
      initiator: initiator,
      iceServers: _iceServers,
      localStream: localStream,
      onRemoteStream: onRemoteStream,
      diagnosticLabel: diagnosticLabel,
      onControl: (peer, control) {
        _handleControl(peer, control);
        onControl?.call(peer, control);
      },
      onSignal: (kind, data) => _sendSignal(peerHex, kind, data),
      onOpen: _emitPeer,
      onClosed: () {
        // A delayed callback from an old link must never remove a replacement.
        if (!identical(_links[peerHex], link)) return;
        final intentional = _intentionalDisconnects.remove(peerHex);
        _links.remove(peerHex);
        _peerSignalRouter.removeNextHop(peerHex);
        _routedSignalRates.remove(peerHex);
        _signalTransport.remove(peerHex);
        _relayReplyUntil.remove(peerHex);
        _refreshRelayDuty();
        if (_closed) return;
        if (_recovering) {
          onPeerLeft?.call(peerHex);
          return;
        }
        if (intentional) {
          onPeerLeft?.call(peerHex);
          return;
        }
        if (!_backoffFailures.containsKey(peerHex) &&
            _backoffFailures.length >= _kMaxRememberedFailures) {
          final oldest = _backoffFailures.keys.first;
          _backoffFailures.remove(oldest);
          _backoffUntil.remove(oldest);
        }
        final failures = (_backoffFailures[peerHex] ?? 0) + 1;
        _backoffFailures[peerHex] = failures;
        // Exponential: 10s, 20s, 40s, 80s, 160s, capped at 300s (5min).
        final delaySec = min(10 * (1 << (failures - 1)), 300);
        _backoffUntil[peerHex] = DateTime.now().add(
          Duration(seconds: delaySec),
        );
        onPeerLeft?.call(peerHex);
      },
    );
    _links[peerHex] = link;
    _refreshRelayDuty();
    _bumpSignalPoll(); // a handshake just started — poll fast for its replies
    return link;
  }

  void _emitPeer(_PeerLink link) {
    if (!(peerAllowed?.call(link.peerHex) ?? true)) {
      unawaited(link.dispose());
      return;
    }
    _backoffUntil.remove(link.peerHex); // connected — reset its backoff
    _backoffFailures.remove(link.peerHex);
    _relayReplyUntil.remove(link.peerHex);
    _peerSignalRouter.removeNextHop(link.peerHex);
    if (!_closed && !_peerConnected.isClosed) _peerConnected.add(link);
    onPeerConnectedHex?.call(link.peerHex);
    // Persist this peer so next startup can try them immediately.
    unawaited(candidateCache?.touch(channel, link.peerHex) ?? Future.value());
    // Peer-exchange is symmetric: the newcomer learns the existing mesh, and
    // every existing peer learns the newcomer. Either side may be the offerer
    // under the deterministic glare rule, so both directions are required.
    final otherLinks = _links.entries
        .where((e) => e.key != link.peerHex && e.value.open)
        .toList();
    final otherPeers = otherLinks.map((entry) => entry.key).toList();
    if (otherPeers.isNotEmpty) link.sendControl(PeersControl(otherPeers));
    for (final other in otherLinks) {
      other.value.sendControl(PeersControl([link.peerHex]));
    }
    // A single surviving link can now route handshakes to cached peers even
    // when every configured relay is unavailable.
    _tryCachedPeers();
    // Version enforcement: share our version + the signed manifest.
    final manifest = versionManifest;
    if (manifest != null) {
      link.sendControl(VersionControl(version: appVersion, manifest: manifest));
    }
    _refreshRelayDuty();
  }

  /// Handles mesh control messages (peer-exchange + relayed signalling).
  void _handleControl(String fromHex, MeshControl control) {
    switch (control) {
      case PeersControl(:final peers):
        for (final peerHex in peers.take(_kMaxPeerFanout)) {
          _peerSignalRouter.learnRoute(peerHex, fromHex);
          _maybeInitiate(peerHex);
        }
      case SignalControl():
        unawaited(_handleRoutedSignal(fromHex, control));
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
      case VoiceLeaveControl():
        break; // Handled by the external onControl callback (voice layer).
      case ReadWatermarkControl():
        break; // Handled by the external onControl callback (app layer).
      case DeviceRevocationControl():
        break; // Handled by the external onControl callback (app layer).
    }
  }

  Future<void> _handleRoutedSignal(
    String fromLinkHex,
    SignalControl control,
  ) async {
    if (!_allowRoutedSignal(fromLinkHex) ||
        !(peerAllowed?.call(control.from) ?? true) ||
        (control.to != selfPubkeyHex &&
            !(peerAllowed?.call(control.to) ?? true)) ||
        !await _peerSignalRouter.authenticate(
          control,
          channelAuthKey: channelAuthKey,
        )) {
      return;
    }

    if (control.to == selfPubkeyHex) {
      if (control.namespace != null && control.namespace != channel) {
        if (!_peerSignalRouter.remember(control)) return;
        _peerSignalRouter.learnRoute(control.from, fromLinkHex);
        if (!_externalSignals.isClosed) _externalSignals.add(control);
        return;
      }
      await _handleSignal(
        {'from': control.from, 'kind': control.kind, 'data': control.data},
        routedVia: fromLinkHex,
        authenticated: true,
      );
      return;
    }

    if (!_peerSignalRouter.remember(control)) return;
    _peerSignalRouter.learnRoute(control.from, fromLinkHex);
    if (control.hopsRemaining == 0) return;
    _routeSignal(control.forwarded(), exclude: fromLinkHex);
  }

  bool _allowRoutedSignal(String fromLinkHex) {
    final now = DateTime.now();
    final current = _routedSignalRates[fromLinkHex];
    if (current == null ||
        now.difference(current.started) >= const Duration(minutes: 1)) {
      _routedSignalRates[fromLinkHex] = _SignalRateWindow(now, 1);
      return true;
    }
    if (current.count >= 512) return false;
    current.count++;
    return true;
  }

  bool _routeSignal(SignalControl control, {String? exclude}) {
    final nextHops = _peerSignalRouter.nextHops(
      destination: control.to,
      openPeers: _openPeerIds,
      exclude: exclude,
      maxFanout: _kMaxPeerFanout,
    );
    for (final nextHop in nextHops) {
      _links[nextHop]?.sendControl(control);
    }
    return nextHops.isNotEmpty;
  }

  void _logSignalTransport(String peerHex, String transport) {
    if (_signalTransport[peerHex] == transport) return;
    _signalTransport[peerHex] = transport;
    HearthDiagnostics.log('[hearth][$diagnosticLabel] signal using $transport');
  }

  Future<void> _sendSignal(String to, String kind, Object? data) async {
    final payload = (data! as Map).cast<String, Object?>();
    final authKey = channelAuthKey;
    final capability = authKey == null
        ? null
        : createSignalCapabilityProof(
            authKey,
            selfPubkeyHex,
            to,
            channel,
            kind,
            payload,
          );
    // Authenticate the signal so a relay/MITM can't forge it or swap the SDP's
    // DTLS fingerprint; the signature rides inside `data`.
    final signed = <String, Object?>{
      ...payload,
      'sig': await signSignal(identity, channel, kind, to, payload),
    };
    if (capability != null) signed[signalCapabilityField] = capability;
    final control = SignalControl(
      to: to,
      from: selfPubkeyHex,
      kind: kind,
      data: signed,
      namespace: externalSignalSender == null ? null : channel,
    );
    if (!_peerSignalRouter.remember(control)) return;

    // Try the child mesh, then its established parent mesh. Do not duplicate a
    // successfully peer-routed handshake to the relay: relay signalling is the
    // final rendezvous fallback, not a parallel transport.
    final peerFailures = _backoffFailures[to] ?? 0;
    final relayReplyUntil = _relayReplyUntil[to];
    final replyViaRelay =
        relayReplyUntil != null && DateTime.now().isBefore(relayReplyUntil);
    if (peerFailures < 3 && !replyViaRelay) {
      if (_routeSignal(control)) {
        _logSignalTransport(to, 'child mesh');
        return;
      }
      final sendExternal = externalSignalSender;
      if (sendExternal != null && await sendExternal(control)) {
        _logSignalTransport(to, 'parent mesh');
        return;
      }
    }
    _logSignalTransport(to, 'relay rendezvous');
    await _sendSignalToRelay(control);
  }

  Future<void> _sendSignalToRelay(SignalControl control) async {
    final token = _authToken;
    if (token == null) {
      throw StateError('no signalling route is currently available');
    }
    final request = http.Request('POST', _activeUrl.replace(path: '/signal'))
      ..headers.addAll({
        'content-type': 'application/json',
        'Authorization': 'Bearer $token',
      })
      ..body = jsonEncode({
        'channel': channel,
        'to': control.to,
        'from': control.from,
        'kind': control.kind,
        'data': control.data,
      });
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 5));
    await readResponseBytesBounded(
      response,
      maxBytes: 64 * 1024,
      timeout: const Duration(seconds: 5),
    );
    if (response.statusCode != 200) {
      throw StateError('signal delivery failed (${response.statusCode})');
    }
  }

  Future<void> close() async {
    _closed = true;
    _announceTimer?.cancel();
    _signalTimer?.cancel();
    _relayDutyTimer?.cancel();
    _standbyProbeTimer?.cancel();
    _relayPresenceTimer?.cancel();
    _relayFallbackTimer?.cancel();
    for (final link in _links.values.toList()) {
      await link.dispose();
    }
    _links.clear();
    _earlyRemoteIce.clear();
    _routedSignalRates.clear();
    _signalTransport.clear();
    _relayReplyUntil.clear();
    _relayPresenceUntil.clear();
    _relayVoicePresenceUntil.clear();
    _client.close();
    if (!_peerConnected.isClosed) await _peerConnected.close();
    if (!_externalSignals.isClosed) await _externalSignals.close();
  }
}

class _SignalRateWindow {
  _SignalRateWindow(this.started, this.count);

  final DateTime started;
  int count;
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
    required this.diagnosticLabel,
  }) {
    _handshakeTimer = Timer(const Duration(seconds: 30), () {
      if (!_opened) unawaited(dispose());
    });
  }

  @override
  final String peerHex;
  final bool initiator;
  final List<Map<String, dynamic>> _iceServers;
  final MediaStream? localStream;
  final void Function(String peerHex, MediaStream stream)? onRemoteStream;
  final Future<void> Function(String kind, Object? data) onSignal;
  final void Function(_PeerLink link) onOpen;
  final void Function() onClosed;
  final void Function(String peerHex, MeshControl control)? onControl;
  final String diagnosticLabel;

  final StreamController<SyncFrame> _frames = StreamController<SyncFrame>();
  RTCPeerConnection? _pc;
  RTCDataChannel? _channel;
  bool _remoteSet = false;
  bool _opened = false;
  bool _disposed = false;
  Timer? _handshakeTimer;
  late final PeerConnectionHealthMonitor _health = PeerConnectionHealthMonitor(
    onStale: () => unawaited(dispose()),
  );
  Future<void> _sendTail = Future<void>.value();
  final List<RTCIceCandidate> _pendingCandidates = [];
  final List<MediaStream> _syntheticRemoteStreams = [];
  final WebRtcSignalOrder _outgoingSignals = WebRtcSignalOrder();
  static const int _maxPendingCandidates = 256;
  static const int _maxDataChannelFrameBytes = 16 * 1024 * 1024;
  static const int _maxBufferedSendBytes = 512 * 1024;

  @override
  Stream<SyncFrame> get frames => _frames.stream;

  /// The underlying peer connection — exposed for voice audio-level stats.
  RTCPeerConnection? get connection => _pc;

  /// Whether this link's data channel is open (handshake complete).
  bool get open => _opened;

  /// Native state is still usable, so activity resume must not tear it down.
  bool get healthy => isPeerConnectionHealthy(
    dataChannelOpen: _opened,
    connectionState: _pc?.connectionState,
    iceState: _pc?.iceConnectionState,
  );

  @override
  void send(SyncFrame frame) {
    _sendText(wrapGossip(frame.encode()));
  }

  /// Sends a mesh control message (peer-exchange / relayed signalling) to this peer.
  void sendControl(MeshControl control) => _sendText(control.encode());

  Future<void> flushSends() => _sendTail;

  void _sendText(String text) {
    final channel = _channel;
    if (channel != null &&
        channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      _sendTail = _sendTail
          .then((_) async {
            if (_disposed ||
                channel.state != RTCDataChannelState.RTCDataChannelOpen) {
              return;
            }
            final bufferDeadline = DateTime.now().add(
              const Duration(seconds: 30),
            );
            while (!_disposed &&
                channel.state == RTCDataChannelState.RTCDataChannelOpen) {
              var buffered = channel.bufferedAmount ?? 0;
              try {
                buffered = await channel.getBufferedAmount();
              } catch (_) {
                // Some web implementations only expose the synchronous getter.
              }
              if (buffered <= _maxBufferedSendBytes) break;
              if (DateTime.now().isAfter(bufferDeadline)) {
                throw TimeoutException(
                  'WebRTC data-channel send buffer stalled',
                );
              }
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            if (!_disposed &&
                channel.state == RTCDataChannelState.RTCDataChannelOpen) {
              await channel.send(RTCDataChannelMessage(text));
            }
          })
          .catchError((Object _) {
            if (!_disposed) unawaited(dispose());
          });
    }
  }

  Future<RTCPeerConnection> _ensurePc() async {
    final existing = _pc;
    if (existing != null) return existing;
    final pc = await createPeerConnection({'iceServers': _iceServers});
    HearthDiagnostics.log(
      '[hearth][$diagnosticLabel] peer connection created '
      'role=${initiator ? 'offerer' : 'answerer'}',
    );
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return; // end-of-candidates marker
      final payload = <String, Object?>{
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      };
      _outgoingSignals.addCandidate(payload, onSignal);
    };
    pc.onDataChannel = _wireChannel;
    pc.onConnectionState = (state) {
      HearthDiagnostics.log(
        '[hearth][$diagnosticLabel] connection state=$state',
      );
      _health.handlePeerState(state);
    };
    pc.onIceConnectionState = (state) {
      HearthDiagnostics.log('[hearth][$diagnosticLabel] ICE state=$state');
      _health.handleIceState(state);
    };
    pc.onIceGatheringState = (state) {
      HearthDiagnostics.log('[hearth][$diagnosticLabel] ICE gathering=$state');
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
    pc.onTrack = (event) => unawaited(_handleRemoteTrack(event));
    _pc = pc;
    return pc;
  }

  Future<void> _handleRemoteTrack(RTCTrackEvent event) async {
    if (_disposed) return;
    HearthDiagnostics.log(
      '[hearth][$diagnosticLabel] remote ${event.track.kind} track '
      'streams=${event.streams.length}',
    );
    if (event.streams.isNotEmpty) {
      onRemoteStream?.call(peerHex, event.streams.first);
      return;
    }

    // Unified Plan permits a track without an associated MediaStream. The
    // Windows native plugin can emit that shape, but renderers require a
    // stream, so materialize one instead of silently dropping live audio.
    MediaStream? synthetic;
    try {
      final created = await createLocalMediaStream(
        'hearth-remote-${DateTime.now().microsecondsSinceEpoch}',
      );
      synthetic = created;
      await created.addTrack(event.track);
      if (_disposed) {
        await created.dispose();
        return;
      }
      _syntheticRemoteStreams.add(created);
      onRemoteStream?.call(peerHex, created);
    } catch (error) {
      await synthetic?.dispose();
      HearthDiagnostics.log(
        '[hearth][$diagnosticLabel] could not attach streamless '
        '${event.track.kind} track: ${error.runtimeType}',
      );
    }
  }

  /// Initiator path: open the data channel and send an offer.
  Future<void> start() async {
    final pc = await _ensurePc();
    _wireChannel(await pc.createDataChannel('hearth', RTCDataChannelInit()));
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    await _outgoingSignals.sendDescription('offer', {
      'sdp': offer.sdp,
      'type': offer.type,
    }, onSignal);
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
    await _outgoingSignals.sendDescription('answer', {
      'sdp': answer.sdp,
      'type': answer.type,
    }, onSignal);
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
      if (_pendingCandidates.length >= _maxPendingCandidates) return;
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
      final wireLength = message.isBinary
          ? message.binary.length
          : message.text.length;
      if (wireLength > _maxDataChannelFrameBytes) {
        debugPrint(
          '[hearth] dropped oversized frame ($wireLength bytes) from $peerHex',
        );
        return;
      }
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
      if (frame == null && message.isBinary) {
        debugPrint(
          '[hearth] dropped malformed binary frame '
          '(${message.binary.length} bytes) from $peerHex',
        );
      }
    };
    channel.onDataChannelState = (state) {
      HearthDiagnostics.log(
        '[hearth][$diagnosticLabel] data channel state=$state',
      );
      if (state == RTCDataChannelState.RTCDataChannelOpen && !_opened) {
        _opened = true;
        _handshakeTimer?.cancel();
        _handshakeTimer = null;
        onOpen(this); // surfaces this peer to the gossip layer
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        unawaited(dispose());
      }
    };
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _handshakeTimer?.cancel();
    _handshakeTimer = null;
    _health.close();
    _pendingCandidates.clear();
    _outgoingSignals.clear();
    try {
      await _channel?.close();
    } catch (_) {}
    try {
      await _pc?.close();
    } catch (_) {}
    if (!_frames.isClosed) await _frames.close();
    onClosed();
    for (final stream in _syntheticRemoteStreams) {
      try {
        await stream.dispose();
      } catch (_) {}
    }
    _syntheticRemoteStreams.clear();
  }
}
