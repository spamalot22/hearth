// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:core/core.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'mesh_control.dart';
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
  VoiceSession._(this.channelId, this._mesh, this._localStream, this._onChange);

  /// The channel this call belongs to.
  final String channelId;

  final WebRtcMesh _mesh;
  final MediaStream _localStream;
  final void Function() _onChange;

  final AudioPlayer _cuePlayer = AudioPlayer();
  final DateTime _joinedAt = DateTime.now();

  // peerHex -> a renderer bound to their remote stream (drives web playback).
  final Map<String, RTCVideoRenderer> _remotes = {};
  StreamSubscription<void>? _sub;
  Timer? _levelTimer;
  final Map<String, double> _levels = {}; // 'self' or peerHex -> 0..1 level
  final Map<String, MediaStream> _remoteStreams = {}; // peerHex -> their stream
  final Map<String, double> _volumes = {}; // peerHex -> 0..1 playback volume
  bool _muted = false;
  bool _deafened = false;
  bool _closed = false;

  bool get isMuted => _muted || _deafened;
  bool get isDeafened => _deafened;

  /// A peer's playback volume (0..1) — defaults to full.
  double volumeOf(String peerHex) => _volumes[peerHex] ?? 1.0;

  /// How many peers we're hearing.
  int get peerCount => _remotes.length;

  /// Connected peers, by id, for the participants list.
  List<String> get peerHexes => _remotes.keys.toList();

  /// Latest mic level (0..1) for a participant — 'self' for you, else a peerHex.
  double levelOf(String key) => _levels[key] ?? 0;

  /// Whether that participant is speaking right now.
  bool speaking(String key) => levelOf(key) > 0.02;

  /// The remote renderers — the UI mounts a 0-size view per renderer so the
  /// browser actually plays the audio.
  Iterable<RTCVideoRenderer> get remoteRenderers => _remotes.values;

  /// Requests the mic and joins [channelId]'s voice mesh. Throws if mic access
  /// is denied.
  static Future<VoiceSession> join({
    required String channelId,
    required Identity identity,
    required Uri relayUrl,
    required void Function() onChange,
  }) async {
    // On Windows desktop, plain `audio: true` can pick a non-functional
    // default. Enumerate devices and explicitly target the first audioinput so
    // the native WebRTC layer opens the correct capture device.
    Object audioConstraint = true;
    try {
      final devices = await navigator.mediaDevices.enumerateDevices();
      final mics = devices.where((d) => d.kind == 'audioinput').toList();
      if (mics.isNotEmpty && mics.first.deviceId.isNotEmpty) {
        audioConstraint = {
          'deviceId': mics.first.deviceId,
          'autoGainControl': true,
          'noiseSuppression': true,
        };
      }
    } catch (_) {
      // Fall through with default constraint.
    }
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': audioConstraint,
      'video': false,
    });
    // Ensure tracks are enabled — Windows can return them disabled.
    for (final track in stream.getAudioTracks()) {
      track.enabled = true;
    }
    late final VoiceSession session;
    final mesh = WebRtcMesh(
      baseUrl: relayUrl,
      channel: 'voice:$channelId',
      identity: identity,
      localStream: stream,
      onRemoteStream: (peerHex, remote) =>
          unawaited(session._onRemote(peerHex, remote)),
      onPeerLeft: (peerHex) => session._onPeerLeft(peerHex),
      onControl: (_, control) => session._onControl(control),
    );
    session = VoiceSession._(channelId, mesh, stream, onChange);
    // The mesh only starts announcing once peerConnected is listened to.
    session._sub = mesh.peerConnected.listen((_) {});
    session._levelTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => unawaited(session._pollLevels()),
    );
    unawaited(session._playCue(connect: true)); // you joined
    return session;
  }

  /// Polls WebRTC stats for each connection's audio level — a remote's level
  /// from its inbound-rtp report, ours from the media-source report — so the UI
  /// can show who's speaking.
  Future<void> _pollLevels() async {
    if (_closed) return;
    final next = <String, double>{};
    var self = 0.0;
    for (final entry in _mesh.connections.entries) {
      try {
        for (final report in await entry.value.getStats()) {
          final level = report.values['audioLevel'];
          if (level is! num) continue;
          if (report.type == 'inbound-rtp') {
            next[entry.key] = level.toDouble();
          } else if (report.type == 'media-source') {
            self = level.toDouble();
          }
        }
      } catch (_) {
        // A transient stats failure just skips this tick.
      }
    }
    next['self'] = self;
    _levels
      ..clear()
      ..addAll(next);
    _onChange();
  }

  Future<void> _onRemote(String peerHex, MediaStream remote) async {
    if (_closed) return;
    final isNew = !_remotes.containsKey(peerHex);
    final renderer = _remotes[peerHex] ?? RTCVideoRenderer();
    if (isNew) {
      await renderer.initialize();
      _remotes[peerHex] = renderer;
    }
    renderer.srcObject = remote;
    _remoteStreams[peerHex] = remote;
    await _applyVolume(peerHex); // honour deafen / a prior volume for this peer
    // Cue a join only for peers arriving after the initial mesh-connect burst,
    // so joining a busy call doesn't fire one blip per person already there.
    if (isNew && DateTime.now().difference(_joinedAt).inMilliseconds > 1500) {
      unawaited(_playCue(connect: true));
    }
    _onChange();
  }

  void _onPeerLeft(String peerHex) {
    final renderer = _remotes.remove(peerHex);
    if (renderer == null) return; // a failed attempt, not an active participant
    _remoteStreams.remove(peerHex);
    _volumes.remove(peerHex);
    renderer.srcObject = null;
    unawaited(renderer.dispose());
    unawaited(_playCue(connect: false));
    _onChange();
  }

  Future<void> _playCue({required bool connect}) async {
    try {
      await _cuePlayer.stop();
      await _cuePlayer.play(
        BytesSource(
          connect ? _connectTone : _disconnectTone,
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
    _volumes[peerHex] = volume;
    await _applyVolume(peerHex);
    _onChange();
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
      await Helper.setVolume(volume, track);
    }
  }

  /// Leaves the call: tears down the mesh, releases renderers, stops the mic.
  /// Callback for when a peer plays a soundboard clip.
  void Function(String blob)? onSoundboard;

  /// Broadcasts a control message to all voice peers.
  void sendControl(MeshControl control) {
    for (final peerHex in _mesh.connections.keys) {
      _mesh.sendControlTo(peerHex, control);
    }
  }

  void _onControl(MeshControl control) {
    if (control is SoundboardControl && control.blob.isNotEmpty) {
      onSoundboard?.call(control.blob);
    }
  }

  Future<void> leave() async {
    if (_closed) return;
    _closed = true;
    await _sub?.cancel();
    _levelTimer?.cancel();
    await _mesh.close();
    for (final renderer in _remotes.values) {
      renderer.srcObject = null;
      await renderer.dispose();
    }
    _remotes.clear();
    for (final track in _localStream.getTracks()) {
      await track.stop();
    }
    await _localStream.dispose();
    await _cuePlayer.dispose();
    _onChange();
  }

  // Short generated blips so there's no asset to ship — swappable later.
  static final Uint8List _connectTone = _toneWav(523.25, 784.0); // C5 → G5
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
