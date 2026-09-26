// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:core/core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'diagnostics.dart';
import 'mesh_control.dart';
import 'voice_delivery_health.dart';
import 'webrtc_mesh.dart';

/// A live voice call in a channel: a second [WebRtcMesh] on a `voice:<channelId>`
/// signalling namespace, carrying the mic. The mic track is added before the
/// offer, so audio is in the initial SDP — no renegotiation needed. Gossip's
/// mesh is untouched.
///
/// Join/leave **cues** are played locally by every client when it detects a peer
/// arriving or leaving (a rising blip / falling blip), so the whole call hears
/// someone come and go — Discord-style.
class VoiceSession {
  VoiceSession._(
    this.channelId,
    this._mesh,
    this._localStream,
    this._onChange,
    this._audioOutputId,
    this._audioConstraint,
    this._audioInputId,
    this._getUserMedia,
    this._enumerateDevices,
  );

  /// The channel this call belongs to.
  final String channelId;

  final WebRtcMesh _mesh;
  MediaStream _localStream;
  final Object _audioConstraint;
  final String? _audioInputId;
  final Future<MediaStream> Function(Map<String, dynamic>) _getUserMedia;
  final Future<List<MediaDeviceInfo>> Function() _enumerateDevices;
  final void Function() _onChange;
  String? _audioOutputId;

  final AudioPlayer _cuePlayer = AudioPlayer();
  final DateTime _joinedAt = DateTime.now();

  // peerHex -> a renderer bound to their remote stream (drives web playback).
  final Map<String, RTCVideoRenderer> _remotes = {};
  final Map<String, Object> _remoteUpdates = {};
  StreamSubscription<void>? _sub;
  StreamSubscription<SignalControl>? _externalSignalSub;
  StreamSubscription<FrameChannel>? _parentPeerSub;
  Timer? _levelTimer;
  final Map<String, double> _levels = {}; // 'self' or peerHex -> 0..1 level
  final Map<String, MediaStream> _remoteStreams = {}; // peerHex -> their stream
  final Map<String, double> _volumes = {}; // peerHex -> 0..1 playback volume
  bool _muted = false;
  bool _deafened = false;
  bool _closed = false;
  bool _pollingLevels = false;
  bool _loggedInboundRtp = false;
  bool _loggedOutboundRtp = false;
  final Map<String, VoiceDeliveryHealth> _deliveryHealth = {};
  final Map<String, DateTime> _receiptSentAt = {};
  final Map<String, DateTime> _peerRepairAt = {};
  VoiceCaptureHealth _captureHealth = VoiceCaptureHealth();
  bool _captureEnded = false;
  bool _captureSuspended = false;
  bool _captureRepairing = false;
  DateTime? _captureRepairAt;
  String? _captureError;
  int _captureRepairs = 0;
  int _mediaRepairs = 0;

  bool get isMuted => _muted || _deafened;
  bool get isDeafened => _deafened;
  bool connectionFailedFor(Iterable<String> peers) =>
      peers.any(_mesh.connectionFailedFor);

  String diagnosticReport({Iterable<String>? peers}) => [
    'Microphone tracks: ${_localStream.getAudioTracks().length}',
    'Muted: $isMuted; deafened: $isDeafened',
    'Audio RTP observed: sent=$_loggedOutboundRtp received=$_loggedInboundRtp',
    'Capture ended=$_captureEnded suspended=$_captureSuspended repairing=$_captureRepairing',
    'Capture repairs: $_captureRepairs; media link repairs: $_mediaRepairs',
    if (_captureError != null) 'Capture recovery: $_captureError',
    _mesh.diagnosticReport(peers: peers),
  ].join('\n');

  /// A peer's playback volume (0..1) — defaults to full.
  double volumeOf(String peerHex) => _volumes[peerHex] ?? 1.0;

  /// How many peers have an open voice-mesh connection.
  int get peerCount => _mesh.connections.length;

  /// Connected peers, by id, for the participants list.
  List<String> get peerHexes => _mesh.connections.keys.toList();

  /// Latest mic level (0..1) for a participant — 'self' for you, else a peerHex.
  double levelOf(String key) => _levels[key] ?? 0;

  /// Whether that participant is speaking right now.
  bool speaking(String key) => levelOf(key) > 0.02;

  /// The remote renderers — the UI mounts a 0-size view per renderer so the
  /// browser actually plays the audio.
  Iterable<RTCVideoRenderer> get remoteRenderers => _remotes.values;

  /// Re-negotiate voice links after a mobile OS has suspended networking.
  Future<void> recoverConnections() async {
    if (_closed) return;
    _captureHealth = VoiceCaptureHealth();
    _deliveryHealth.clear();
    if (_captureEnded ||
        (_captureSuspended && !isMuted) ||
        _localStream.getAudioTracks().isEmpty) {
      unawaited(_repairCapture());
    }
    await _mesh.recoverConnections();
  }

  /// Attempts a direct voice link to a participant discovered on the parent
  /// channel mesh. Fresh ICE is routed over that mesh before relay rendezvous.
  void connectTo(String peerHex) {
    if (!_closed) _mesh.maybeInitiateVia(peerHex);
  }

  Future<void> disconnectFrom(String peerHex) => _mesh.disconnectPeer(peerHex);

  /// Requests the mic and joins [channelId]'s voice mesh. Throws if mic access
  /// is denied.
  static Future<VoiceSession> join({
    required String channelId,
    required Identity identity,
    Identity? meshIdentity,
    required Uri relayUrl,
    List<Uri> fallbackUrls = const [],
    required void Function() onChange,
    bool enhancedNoiseSuppression = false,
    String? audioInputId,
    String? audioOutputId,
    WebRtcMesh? signalingMesh,
    Set<String> initialPeers = const <String>{},
    bool Function(String peerHex)? peerAllowed,
    Uint8List? channelAuthKey,
    Future<MediaStream> Function(Map<String, dynamic>)? getUserMedia,
    Future<List<MediaDeviceInfo>> Function()? enumerateDevices,
  }) async {
    final openCapture = getUserMedia ?? navigator.mediaDevices.getUserMedia;
    final listDevices =
        enumerateDevices ?? navigator.mediaDevices.enumerateDevices;
    // On desktop, select devices before opening the first real capture stream.
    // Windows WebRTC can lock its audio module to whichever defaults the first
    // getUserMedia call used, so a permission "probe" must not open and close a
    // throwaway microphone before the configured devices are applied.
    Object audioConstraint = true;
    String? activeOutputId = audioOutputId;
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      try {
        if (kIsWeb) {
          // Browsers may withhold labels until permission has been granted.
          final probe = await openCapture({'audio': true, 'video': false});
          for (final track in probe.getTracks()) {
            await track.stop();
          }
          await probe.dispose();
        }

        var devices = await listDevices();
        if (!kIsWeb &&
            devices.every((device) => device.kind != 'audioinput') &&
            (defaultTargetPlatform == TargetPlatform.windows ||
                defaultTargetPlatform == TargetPlatform.linux)) {
          // The native desktop plugin may not enumerate until its factory has
          // been initialized. A PeerConnection does that without opening the
          // microphone or fixing the audio module to a default device.
          final pc = await createPeerConnection({});
          await pc.close();
          await pc.dispose();
          devices = await listDevices();
        }
        final mic = preferredAudioDevice(devices, 'audioinput', audioInputId);
        final output = kIsWeb
            ? null
            : preferredAudioDevice(devices, 'audiooutput', audioOutputId);
        if (output != null) activeOutputId = output.deviceId;
        if (mic != null || output != null || enhancedNoiseSuppression) {
          audioConstraint = desktopVoiceAudioConstraint(
            input: mic,
            output: output,
            web: kIsWeb,
            enhancedNoiseSuppression: enhancedNoiseSuppression,
          );
        }
        if (!kIsWeb) {
          var inputSelected = mic == null;
          var outputSelected = output == null;
          if (mic != null) {
            try {
              await Helper.selectAudioInput(mic.deviceId);
              inputSelected = true;
            } catch (_) {}
          }
          if (output != null) {
            try {
              await Helper.selectAudioOutput(output.deviceId);
              outputSelected = true;
            } catch (_) {}
          }
          HearthDiagnostics.log(
            '[hearth][voice] desktop devices selected '
            'input=$inputSelected output=$outputSelected',
          );
        }
      } catch (error) {
        HearthDiagnostics.log(
          '[hearth][voice] desktop device initialization failed: '
          '${error.runtimeType}',
        );
        // Fall through with default constraint.
      }
    } else if (enhancedNoiseSuppression) {
      audioConstraint = {
        'autoGainControl': true,
        'noiseSuppression': true,
        'echoCancellation': true,
      };
    }
    MediaStream? stream;
    // Try the explicit device first; fall back to unconstrained if it fails.
    try {
      stream = await openCapture({'audio': audioConstraint, 'video': false});
    } catch (error) {
      HearthDiagnostics.log(
        '[hearth][voice] constrained microphone open failed: '
        '${error.runtimeType}; retrying default',
      );
      stream = await openCapture({'audio': true, 'video': false});
    }
    if (stream.getAudioTracks().isEmpty) {
      await _disposeCapture(stream);
      throw StateError('Microphone returned no audio track');
    }
    // Ensure tracks are enabled — Windows can return them disabled.
    for (final track in stream.getAudioTracks()) {
      track.enabled = true;
    }
    HearthDiagnostics.log(
      '[hearth][voice] local audio stream ready '
      'tracks=${stream.getAudioTracks().length}',
    );
    VoiceSession? session;
    WebRtcMesh? mesh;
    try {
      mesh = WebRtcMesh(
        baseUrl: relayUrl,
        fallbackUrls: fallbackUrls,
        channel: 'voice:$channelId',
        identity: meshIdentity ?? identity,
        localStream: stream,
        // The parent remembers contacts. A voice call only dials peers with
        // current voice presence, not everybody seen in a previous call.
        initialPeers: initialPeers,
        externalSignalSender: signalingMesh?.routeExternalSignal,
        externalRouteAvailable: signalingMesh?.canRouteSignalTo,
        externalRouteQuality: signalingMesh?.signalRouteTo,
        peerResponseTimeout: const Duration(seconds: 12),
        relayFallbackDelay: signalingMesh == null
            ? Duration.zero
            : const Duration(seconds: 35),
        retryBackoffBase: const Duration(seconds: 2),
        retryBackoffMax: const Duration(seconds: 30),
        peerAllowed: peerAllowed,
        channelAuthKey: channelAuthKey,
        diagnosticLabel: 'voice',
        onRemoteStream: (peerHex, remote) =>
            unawaited(session?._onRemote(peerHex, remote)),
        onPeerLeft: (peerHex) => session?._onPeerLeft(peerHex),
        onControl: (peer, control) => session?._onControl(peer, control),
      );
      session = VoiceSession._(
        channelId,
        mesh,
        stream,
        onChange,
        activeOutputId,
        audioConstraint,
        audioInputId,
        openCapture,
        listDevices,
      );
      session._bindCapture();
      session._externalSignalSub = signalingMesh?.externalSignals
          .where((signal) => signal.namespace == 'voice:$channelId')
          .listen((signal) => unawaited(mesh!.receiveExternalSignal(signal)));
      session._parentPeerSub = signalingMesh?.peerConnected.listen(
        (_) => mesh!.retryConnections(),
      );
      // The mesh only starts announcing once peerConnected is listened to.
      session._sub = mesh.peerConnected.listen((_) => session?._onChange());
      // On mobile, route audio to speaker (not earpiece) by default.
      if (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS) {
        await Helper.setSpeakerphoneOn(true);
      }
      session._levelTimer = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => unawaited(session?._pollLevels()),
      );
      unawaited(session._playCue(connect: true)); // you joined
      return session;
    } catch (_) {
      if (session != null) {
        await session.leave();
      } else {
        await mesh?.close();
        await _disposeCapture(stream);
      }
      rethrow;
    }
  }

  /// Polls WebRTC stats for each connection's audio level — a remote's level
  /// from its inbound-rtp report, ours from the media-source report — so the UI
  /// can show who's speaking.
  Future<void> _pollLevels() async {
    if (_closed || _pollingLevels) return;
    _pollingLevels = true;
    try {
      await _readLevels();
    } finally {
      _pollingLevels = false;
    }
  }

  Future<void> _readLevels() async {
    if (_captureEnded || _localStream.getAudioTracks().isEmpty) {
      unawaited(_repairCapture());
    }
    final next = <String, double>{};
    var self = 0.0;
    double? captureSamples;
    for (final entry in _mesh.connections.entries.toList()) {
      try {
        final reports = await entry.value.getStats().timeout(
          const Duration(seconds: 3),
        );
        if (_closed) return;
        if (!identical(_mesh.connections[entry.key], entry.value)) continue;
        int? sentPackets;
        int? receivedPackets;
        for (final report in reports) {
          final samples = report.values['totalSamplesDuration'];
          if (report.type == 'media-source' &&
              samples is num &&
              samples.isFinite &&
              samples >= 0) {
            // A newly created sender can have a lower counter than an older
            // one. Progress on any sender proves that capture is still alive.
            captureSamples = (captureSamples ?? 0) + samples.toDouble();
          }
          final packetsReceived = report.values['packetsReceived'];
          if (report.type == 'inbound-rtp' &&
              packetsReceived is num &&
              packetsReceived.isFinite &&
              packetsReceived >= 0) {
            receivedPackets = (receivedPackets ?? 0) + packetsReceived.toInt();
          }
          if (!_loggedInboundRtp &&
              report.type == 'inbound-rtp' &&
              packetsReceived is num &&
              packetsReceived > 0) {
            _loggedInboundRtp = true;
            HearthDiagnostics.log('[hearth][voice] inbound audio RTP received');
          }
          final packetsSent = report.values['packetsSent'];
          if (report.type == 'outbound-rtp' &&
              packetsSent is num &&
              packetsSent.isFinite &&
              packetsSent >= 0) {
            sentPackets = (sentPackets ?? 0) + packetsSent.toInt();
          }
          if (!_loggedOutboundRtp &&
              report.type == 'outbound-rtp' &&
              packetsSent is num &&
              packetsSent > 0) {
            _loggedOutboundRtp = true;
            HearthDiagnostics.log('[hearth][voice] outbound audio RTP sent');
          }
          final level = report.values['audioLevel'];
          if (level is! num || !level.isFinite) continue;
          final normalizedLevel = level.toDouble().clamp(0.0, 1.0);
          if (report.type == 'inbound-rtp') {
            next[entry.key] = normalizedLevel;
          } else if (report.type == 'media-source' ||
              report.type == 'outbound-rtp') {
            // Windows native may report under outbound-rtp instead of
            // media-source; take whichever is non-zero.
            if (normalizedLevel > self) self = normalizedLevel;
          }
        }
        final now = DateTime.now();
        if (receivedPackets != null &&
            !_deafened &&
            volumeOf(entry.key) > 0 &&
            receivedPackets <= 9007199254740991 &&
            now.difference(
                  _receiptSentAt[entry.key] ??
                      DateTime.fromMillisecondsSinceEpoch(0),
                ) >=
                const Duration(seconds: 3)) {
          _receiptSentAt[entry.key] = now;
          _mesh.sendControlTo(entry.key, VoiceReceiptControl(receivedPackets));
        }
        final health = _deliveryHealth.putIfAbsent(
          entry.key,
          VoiceDeliveryHealth.new,
        );
        if (health.sample(
          sentPackets,
          enabled: !isMuted && !_captureSuspended && !_captureRepairing,
          now: now,
        )) {
          _repairMediaPeer(entry.key);
        }
      } catch (_) {
        // A transient stats failure just skips this tick.
        _deliveryHealth.remove(entry.key);
      }
    }
    if (_closed) return;
    if (_captureHealth.sample(
      captureSamples,
      enabled: !isMuted && !_captureSuspended && !_captureRepairing,
      now: DateTime.now(),
    )) {
      unawaited(_repairCapture());
    }
    // Fallback: if no stats gave us a self level, check if the track is live.
    if (self == 0.0 && !_captureEnded && !_captureSuspended) {
      final tracks = _localStream.getAudioTracks();
      if (tracks.isNotEmpty && tracks.first.enabled) {
        // Track exists and is enabled — report a minimal non-zero so the UI
        // doesn't show "dead mic". Actual audio will show real levels once
        // stats report properly (some Windows WebRTC builds lag a few seconds).
        // Only do this if the track's muted flag isn't set.
        if (tracks.first.muted != true) self = 0.01;
      }
    }
    next['self'] = self;
    _levels
      ..clear()
      ..addAll(next);
    _onChange();
  }

  void _repairMediaPeer(String peer) {
    final now = DateTime.now();
    if (_closed ||
        now.difference(
              _peerRepairAt[peer] ?? DateTime.fromMillisecondsSinceEpoch(0),
            ) <
            const Duration(seconds: 30)) {
      return;
    }
    if (_peerRepairAt.length >= 64 && !_peerRepairAt.containsKey(peer)) {
      _peerRepairAt.remove(_peerRepairAt.keys.first);
    }
    _peerRepairAt[peer] = now;
    _mediaRepairs++;
    HearthDiagnostics.log('[hearth][voice] repairing stalled RTP delivery');
    unawaited(_mesh.repairPeer(peer));
  }

  void _bindCapture() {
    final stream = _localStream;
    for (final track in stream.getAudioTracks()) {
      track.onEnded = () {
        if (_closed || !identical(_localStream, stream)) return;
        _captureEnded = true;
        unawaited(_repairCapture());
      };
      track.onMute = () {
        if (!_closed && identical(_localStream, stream)) {
          _captureSuspended = true;
        }
      };
      track.onUnMute = () {
        if (!_closed && identical(_localStream, stream)) {
          _captureSuspended = false;
        }
      };
    }
  }

  Future<MediaStream> _openRecoveredCapture(Object constraint) async {
    var expired = false;
    final pending = _getUserMedia({'audio': constraint, 'video': false}).then((
      stream,
    ) async {
      if (expired || _closed) {
        await _disposeCapture(stream);
        throw StateError('capture request retired');
      }
      return stream;
    });
    try {
      return await pending.timeout(const Duration(seconds: 10));
    } finally {
      expired = true;
    }
  }

  Future<void> _repairCapture() async {
    final now = DateTime.now();
    if (_closed ||
        _captureRepairing ||
        now.difference(
              _captureRepairAt ?? DateTime.fromMillisecondsSinceEpoch(0),
            ) <
            const Duration(seconds: 30)) {
      return;
    }
    _captureRepairing = true;
    _captureRepairAt = now;
    MediaStream? replacement;
    try {
      var constraint = _audioConstraint;
      if (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.windows ||
              defaultTargetPlatform == TargetPlatform.linux ||
              defaultTargetPlatform == TargetPlatform.macOS)) {
        try {
          final devices = await _enumerateDevices().timeout(
            const Duration(seconds: 3),
          );
          final input = preferredAudioDevice(
            devices,
            'audioinput',
            _audioInputId,
          );
          final output = preferredAudioDevice(
            devices,
            'audiooutput',
            _audioOutputId,
          );
          constraint = desktopVoiceAudioConstraint(
            input: input,
            output: output,
            web: false,
            enhancedNoiseSuppression: switch (_audioConstraint) {
              {'googNoiseSuppression': true} => true,
              _ => false,
            },
          );
          if (input != null) {
            await Helper.selectAudioInput(
              input.deviceId,
            ).timeout(const Duration(seconds: 3));
          }
          if (output != null) {
            await Helper.selectAudioOutput(
              output.deviceId,
            ).timeout(const Duration(seconds: 3));
            _audioOutputId = output.deviceId;
          }
        } catch (_) {}
      }
      if (_closed) return;
      try {
        replacement = await _openRecoveredCapture(constraint);
      } catch (_) {
        if (_closed) return;
        replacement = await _openRecoveredCapture(true);
      }
      if (_closed) return;
      if (replacement.getAudioTracks().isEmpty) {
        throw StateError('capture returned no audio track');
      }
      for (final track in replacement.getAudioTracks()) {
        track.enabled = !isMuted;
      }
      final old = _localStream;
      for (final track in old.getAudioTracks()) {
        track.onEnded = null;
        track.onMute = null;
        track.onUnMute = null;
        track.enabled = false;
      }
      _localStream = replacement;
      replacement = null;
      _captureEnded = false;
      _captureSuspended = isMuted;
      _captureHealth = VoiceCaptureHealth();
      _deliveryHealth.clear();
      _bindCapture();
      _captureRepairs++;
      _captureError = null;
      HearthDiagnostics.log('[hearth][voice] microphone capture restored');
      try {
        await _mesh.replaceLocalStream(_localStream);
      } finally {
        await _disposeCapture(old);
      }
    } catch (error) {
      _captureError = 'Failed (${error.runtimeType}); retry is rate-limited';
      HearthDiagnostics.log(
        '[hearth][voice] capture recovery failed: ${error.runtimeType}',
      );
    } finally {
      if (replacement != null) await _disposeCapture(replacement);
      _captureRepairing = false;
      if (!_closed) _onChange();
    }
  }

  static Future<void> _disposeCapture(MediaStream stream) async {
    for (final track in stream.getTracks()) {
      try {
        track.onEnded = null;
        track.onMute = null;
        track.onUnMute = null;
        track.enabled = false;
        await track.stop().timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    try {
      await stream.dispose().timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  Future<void> _onRemote(String peerHex, MediaStream remote) async {
    if (_closed) return;
    final update = Object();
    _remoteUpdates[peerHex] = update;
    bool current() => !_closed && identical(_remoteUpdates[peerHex], update);
    // Apply hard mute before asynchronous renderer setup or device selection.
    _remoteStreams[peerHex] = remote;
    for (final track in remote.getAudioTracks()) {
      track.enabled = !_deafened && volumeOf(peerHex) > 0;
    }
    final isNew = !_remotes.containsKey(peerHex);
    final renderer = _remotes[peerHex] ?? RTCVideoRenderer();
    if (isNew) {
      try {
        await renderer.initialize();
      } catch (error) {
        HearthDiagnostics.log(
          '[hearth][voice] remote renderer initialization failed: ${error.runtimeType}',
        );
        try {
          await renderer.dispose();
        } catch (_) {}
        return;
      }
      if (!current()) {
        await renderer.dispose();
        return;
      }
      _remotes[peerHex] = renderer;
    }
    renderer.srcObject = remote;
    final outputId = _audioOutputId;
    if (kIsWeb && outputId != null && outputId.isNotEmpty) {
      try {
        final selected = await renderer.audioOutput(outputId);
        HearthDiagnostics.log(
          '[hearth][voice] remote audio output '
          '${selected ? 'attached' : 'attachment failed'}',
        );
      } catch (error) {
        HearthDiagnostics.log(
          '[hearth][voice] remote audio output attachment failed: '
          '${error.runtimeType}',
        );
      }
    }
    if (!current()) return;
    await _applyVolume(peerHex); // honour deafen / a prior volume for this peer
    if (!current()) return;
    // Cue a join only for peers arriving after the initial mesh-connect burst,
    // so joining a busy call doesn't fire one blip per person already there.
    if (isNew && DateTime.now().difference(_joinedAt).inMilliseconds > 1500) {
      unawaited(_playCue(connect: true));
    }
    _onChange();
  }

  void _onPeerLeft(String peerHex) {
    _remoteUpdates.remove(peerHex);
    _levels.remove(peerHex);
    final renderer = _remotes.remove(peerHex);
    _remoteStreams.remove(peerHex);
    _deliveryHealth.remove(peerHex);
    _receiptSentAt.remove(peerHex);
    if (renderer != null) {
      renderer.srcObject = null;
      unawaited(renderer.dispose().catchError((Object _) {}));
      unawaited(_playCue(connect: false));
    }
    if (!_closed) _onChange();
  }

  Future<void> _playCue({required bool connect}) async {
    try {
      await _cuePlayer.stop();
      await _cuePlayer.play(
        BytesSource(
          connect ? connectTone : _disconnectTone,
          mimeType: 'audio/wav',
        ),
      );
    } catch (_) {
      // A missed cue shouldn't disrupt the call.
    }
  }

  /// Mutes/unmutes your mic.
  void toggleMute() {
    _muted = !_muted;
    _applyMic();
    _onChange();
  }

  /// Deafens/undeafens: silences everyone (and forces your mic off while
  /// deafened, Discord-style).
  void toggleDeafen() {
    _deafened = !_deafened;
    _applyMic();
    for (final peerHex in _remoteStreams.keys) {
      unawaited(_applyVolume(peerHex));
    }
    _onChange();
  }

  /// Sets a peer's playback volume (0..1) — 0 mutes just that person.
  Future<void> setVolume(String peerHex, double volume) async {
    if (!volume.isFinite) return;
    if (_volumes.length >= 128 && !_volumes.containsKey(peerHex)) {
      _volumes.remove(_volumes.keys.first);
    }
    volume = volume.clamp(0.0, 1.0);
    _volumes[peerHex] = volume;
    await _applyVolume(peerHex);
    _onChange();
  }

  /// Switches WebRTC playout immediately and remembers the choice for remote
  /// renderers that arrive later in this call.
  Future<bool> setAudioOutput(String deviceId) async {
    if (deviceId.isEmpty) return false;
    try {
      if (kIsWeb) {
        var selected = true;
        for (final renderer in _remotes.values.toList()) {
          selected = await renderer.audioOutput(deviceId) && selected;
        }
        if (!selected) return false;
      } else {
        await Helper.selectAudioOutput(deviceId);
      }
      _audioOutputId = deviceId;
      return true;
    } catch (_) {
      return false;
    }
  }

  // Your mic is live only when neither muted nor deafened.
  void _applyMic() {
    for (final track in _localStream.getAudioTracks()) {
      track.enabled = !_muted && !_deafened;
    }
  }

  Future<void> _applyVolume(String peerHex) async {
    final stream = _remoteStreams[peerHex];
    if (stream == null) return;
    final volume = _deafened ? 0.0 : volumeOf(peerHex);
    for (final track in stream.getAudioTracks()) {
      track.enabled = volume > 0; // hard mute at 0 (reliable on the receiver)
      try {
        await Helper.setVolume(
          volume,
          track,
        ).timeout(const Duration(seconds: 3));
      } catch (error) {
        HearthDiagnostics.log(
          '[hearth][voice] volume update failed: ${error.runtimeType}',
        );
      }
    }
  }

  /// Leaves the call: tears down the mesh, releases renderers, stops the mic.
  /// Callback for when a peer plays a soundboard clip.
  void Function(String blob)? onSoundboard;

  /// Callback for when a peer starts (true) / stops (false) sharing their
  /// screen, so the app can join or drop that sharer's screen mesh.
  void Function(String sharerHex, bool active)? onScreenShare;

  /// Callback for shared-YouTube ("watch party") state from the host.
  void Function(String senderHex, YoutubeControl control)? onYoutube;

  /// Broadcasts a control message to all voice peers.
  void sendControl(MeshControl control) {
    for (final peerHex in _mesh.connections.keys) {
      _mesh.sendControlTo(peerHex, control);
    }
  }

  Future<void> enforcePeerPolicy() => _mesh.enforcePeerPolicy();

  void _onControl(String peerHex, MeshControl control) {
    if (control is SoundboardControl && control.blob.isNotEmpty) {
      onSoundboard?.call(control.blob);
    } else if (control is ScreenShareControl) {
      // The sender peerHex is the authenticated sharer (control rides their own
      // signed link), so trust it over the payload's self-reported `sharer`.
      onScreenShare?.call(peerHex, control.active);
    } else if (control is YoutubeControl) {
      onYoutube?.call(peerHex, control);
    } else if (control is VoiceLeaveControl) {
      // Remove the actual mesh link, not only its renderer. Otherwise an
      // immediate rejoin with the same identity is blocked by the stale link.
      unawaited(_mesh.disconnectPeer(peerHex));
    } else if (control is VoiceReceiptControl &&
        _mesh.connections.containsKey(peerHex)) {
      _deliveryHealth
          .putIfAbsent(peerHex, VoiceDeliveryHealth.new)
          .receipt(control.packetsReceived, DateTime.now());
    }
  }

  Future<void> leave() async {
    if (_closed) return;
    _closed = true;
    _remoteUpdates.clear();
    _levelTimer?.cancel();
    // Silence capture immediately; native stop must not delay the leave frame.
    for (final track in _localStream.getTracks()) {
      try {
        track.enabled = false;
      } catch (_) {}
    }
    final captureCleanup = _disposeCapture(_localStream);
    // Notify peers immediately so they don't wait for ICE timeout.
    sendControl(VoiceLeaveControl());
    try {
      await _mesh.flushPendingSends().timeout(
        const Duration(milliseconds: 750),
      );
    } catch (_) {
      // Closing the data channel still tells peers eventually if a flush stalls.
    }
    await _sub?.cancel();
    await _externalSignalSub?.cancel();
    await _parentPeerSub?.cancel();
    _levelTimer?.cancel();
    try {
      await _mesh.close();
    } catch (_) {}
    for (final renderer in _remotes.values.toList()) {
      try {
        renderer.srcObject = null;
        await renderer.dispose().timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    _remotes.clear();
    _remoteStreams.clear();
    _levels.clear();
    _deliveryHealth.clear();
    _receiptSentAt.clear();
    _peerRepairAt.clear();
    _volumes.clear();
    await captureCleanup;
    try {
      await _cuePlayer.dispose().timeout(const Duration(seconds: 3));
    } catch (_) {}
    _onChange();
  }

  // Short generated blips so there's no asset to ship — swappable later.
  static final Uint8List connectTone = _toneWav(523.25, 784.0); // C5 → G5
  static final Uint8List speakerTestTone = _toneWav(440.0, 660.0, ms: 700);
  static final Uint8List _disconnectTone = _toneWav(784.0, 392.0); // G5 → G4
}

/// A tiny 16-bit-PCM mono WAV that sweeps [startHz]→[endHz] under a smooth
/// envelope (no clicks). Used for the join/leave blips.
Uint8List _toneWav(
  double startHz,
  double endHz, {
  int ms = 170,
  int rate = 44100,
}) {
  final n = (rate * ms / 1000).round();
  final b = BytesBuilder();
  void str(String s) => b.add(s.codeUnits);
  void u32(int v) =>
      b.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
  void u16(int v) => b.add([v & 0xff, (v >> 8) & 0xff]);

  final dataLen = n * 2;
  str('RIFF');
  u32(36 + dataLen);
  str('WAVE');
  str('fmt ');
  u32(16);
  u16(1); // PCM
  u16(1); // mono
  u32(rate);
  u32(rate * 2); // byte rate
  u16(2); // block align
  u16(16); // bits/sample
  str('data');
  u32(dataLen);
  for (var i = 0; i < n; i++) {
    final p = i / n;
    final freq = startHz + (endHz - startHz) * p;
    final env = sin(pi * p); // 0 → 1 → 0
    final sample = (sin(2 * pi * freq * i / rate) * env * 0.35 * 32767).round();
    u16(sample & 0xffff);
  }
  return b.toBytes();
}

/// Resolves a persisted audio choice against the devices that still exist.
/// Device identifiers can disappear when a USB or Bluetooth device is removed.
MediaDeviceInfo? preferredAudioDevice(
  Iterable<MediaDeviceInfo> devices,
  String kind,
  String? preferredId,
) {
  MediaDeviceInfo? first;
  for (final device in devices) {
    if (device.kind != kind || device.deviceId.isEmpty) continue;
    first ??= device;
    if (preferredId != null && device.deviceId == preferredId) return device;
  }
  return first;
}

/// Builds flutter_webrtc's desktop audio constraint shape. On native desktop,
/// the plugin intentionally uses `deviceId` for playout and legacy `sourceId`
/// for capture; setting the output here selects it before playout initializes.
Map<String, Object> desktopVoiceAudioConstraint({
  required MediaDeviceInfo? input,
  required MediaDeviceInfo? output,
  required bool web,
  required bool enhancedNoiseSuppression,
}) => {
  if (web && input != null)
    'deviceId': {'exact': input.deviceId}
  else if (!web && output != null)
    'deviceId': output.deviceId,
  if (!web && input != null)
    'optional': [
      {'sourceId': input.deviceId},
    ],
  'autoGainControl': true,
  'noiseSuppression': true,
  'echoCancellation': true,
  if (enhancedNoiseSuppression) 'googNoiseSuppression': true,
  if (enhancedNoiseSuppression) 'googHighpassFilter': true,
};
