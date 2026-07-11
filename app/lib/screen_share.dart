// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:core/core.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'webrtc_mesh.dart';

/// Capture resolution cap for a screen share. [native] keeps the source's own
/// size; the others cap the long edge (the capturer preserves aspect ratio).
enum ScreenResolution {
  hd('720p', 1280, 720),
  fhd('1080p', 1920, 1080),
  native('Source', null, null);

  const ScreenResolution(this.label, this.maxWidth, this.maxHeight);

  final String label;
  final int? maxWidth;
  final int? maxHeight;
}

/// `getDisplayMedia` constraints selecting a specific desktop [source] at [res].
/// Video-only for v1 — shared audio (and echo prevention) is a later follow-up.
Map<String, dynamic> _displayConstraints(
  DesktopCapturerSource source,
  ScreenResolution res,
) => {
  'video': {
    'deviceId': {'exact': source.id},
    'mandatory': {
      'frameRate': 30.0,
      if (res.maxWidth != null) 'maxWidth': res.maxWidth,
      if (res.maxHeight != null) 'maxHeight': res.maxHeight,
    },
  },
  'audio': false,
};

/// An *outgoing* screen share: a [WebRtcMesh] on `screen:<channelId>:<selfHex>`
/// carrying the captured screen video. The sharer is the sole offerer
/// ([WebRtcMesh.forceInitiator] = true) so the one-way video rides in the
/// initial SDP and viewers answer-only — no renegotiation, and the mesh forms a
/// star with the sharer at the centre rather than a wasteful full mesh.
class ScreenBroadcast {
  ScreenBroadcast._(this.sourceName, this._mesh, this._stream, this._onEnded);

  /// Human-readable name of the shared window/screen, for the UI.
  final String sourceName;

  final WebRtcMesh _mesh;
  final MediaStream _stream;
  final void Function() _onEnded;
  StreamSubscription<void>? _sub;
  bool _closed = false;

  /// Starts capturing [source] at [resolution] and opens the share mesh.
  /// [onEnded] fires if the OS ends the capture (e.g. the shared window closes,
  /// or the user hits the system "stop sharing") so the UI can tidy up. Throws
  /// if the capture is denied/cancelled.
  static Future<ScreenBroadcast> start({
    required String channelId,
    required Identity identity,
    required Uri relayUrl,
    required DesktopCapturerSource source,
    required ScreenResolution resolution,
    required void Function() onEnded,
    bool Function(String peerHex)? peerAllowed,
  }) async {
    final stream = await navigator.mediaDevices.getDisplayMedia(
      _displayConstraints(source, resolution),
    );
    final mesh = WebRtcMesh(
      baseUrl: relayUrl,
      channel: 'screen:$channelId:${identity.publicKeyHex}',
      identity: identity,
      localStream: stream,
      forceInitiator: true, // the sharer offers to every viewer
      peerAllowed: peerAllowed,
    );
    final broadcast = ScreenBroadcast._(source.name, mesh, stream, onEnded);
    // The mesh only starts announcing once peerConnected is listened to.
    broadcast._sub = mesh.peerConnected.listen((_) {});
    // Auto-stop if the OS ends the capture (best-effort: not every platform
    // fires this for screen capture, so the in-app Stop is the primary path).
    for (final track in stream.getVideoTracks()) {
      track.onEnded = () {
        if (!broadcast._closed) broadcast._onEnded();
      };
    }
    return broadcast;
  }

  Future<void> stop() async {
    if (_closed) return;
    _closed = true;
    await _sub?.cancel();
    await _mesh.close();
    for (final track in _stream.getTracks()) {
      await track.stop();
    }
    await _stream.dispose();
  }
}

/// An *incoming* screen share being watched: a receive-only [WebRtcMesh] on the
/// sharer's `screen:<channelId>:<sharerHex>`, rendering their video into
/// [renderer]. Answer-only ([WebRtcMesh.forceInitiator] = false) — the sharer
/// drives the connection.
class ScreenView {
  ScreenView._(this.sharerHex, this._mesh, this.renderer);

  /// Pubkey hex of the peer whose screen this shows.
  final String sharerHex;

  /// The renderer to mount in an `RTCVideoView`.
  final RTCVideoRenderer renderer;

  final WebRtcMesh _mesh;
  StreamSubscription<void>? _sub;
  bool _closed = false;

  /// Whether a live video stream is currently bound — false while first
  /// connecting, and briefly during a reconnect.
  bool get hasVideo => renderer.srcObject != null;

  /// Joins [sharerHex]'s screen mesh and renders their video. [onChange] fires
  /// when the video binds or drops, so the UI can rebuild.
  static Future<ScreenView> watch({
    required String channelId,
    required String sharerHex,
    required Identity identity,
    required Uri relayUrl,
    required void Function() onChange,
    bool Function(String peerHex)? peerAllowed,
  }) async {
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    late final ScreenView view;
    final mesh = WebRtcMesh(
      baseUrl: relayUrl,
      channel: 'screen:$channelId:$sharerHex',
      identity: identity,
      forceInitiator: false, // answer-only; the sharer offers
      peerAllowed: peerAllowed,
      onRemoteStream: (peer, stream) {
        if (view._closed || peer != sharerHex) return;
        renderer.srcObject = stream;
        onChange();
      },
      onPeerLeft: (peer) {
        if (view._closed || peer != sharerHex) return;
        // Transient drop — blank the view; the sharer's mesh re-offers. The
        // view is torn down only on an explicit stop or when the sharer leaves
        // the voice call (handled a layer up).
        renderer.srcObject = null;
        onChange();
      },
    );
    view = ScreenView._(sharerHex, mesh, renderer);
    view._sub = mesh.peerConnected.listen((_) {});
    return view;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sub?.cancel();
    await _mesh.close();
    renderer.srcObject = null;
    await renderer.dispose();
  }
}
