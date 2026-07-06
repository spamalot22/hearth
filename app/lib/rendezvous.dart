// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:core/core.dart';

import 'webrtc_mesh.dart';

/// Listens on a contact card's rendezvous capability for first contact.
///
/// It's a bare [WebRtcMesh] on the rendezvous id — no cipher and no DAG traffic,
/// because nothing here exchanges messages. Its only job is discovery: when
/// someone who holds the card connects, the mesh authenticates them with signed
/// signalling (`signal_auth`) and [onContact] fires with their verified pubkey,
/// which the app hands to `openDm` to bootstrap the real derived + PairBox DM.
///
/// The *owner* keeps one of these alive for the lifetime of the app (their
/// standing contact inbox). A *joiner* runs a transient one on the owner's
/// rendezvous just long enough to be discovered, then closes it — after first
/// contact the DM reconnects on its own derived channel, so the rendezvous is
/// never needed again.
class RendezvousListener {
  RendezvousListener._(this._mesh, this._sub, this._peerSubs);

  final WebRtcMesh _mesh;
  final StreamSubscription<void> _sub;
  final List<StreamSubscription<void>> _peerSubs;

  static const _introPrefix = 'rvintro:';

  static String _intro(DeviceCert cert) =>
      '$_introPrefix${base64Url.encode(utf8.encode(jsonEncode(cert.toJson())))}';

  static DeviceCert? _decodeIntro(SyncFrame frame) {
    if (frame is! HaveFrame) return null;
    final raw = frame.heads
        .where((h) => h.startsWith(_introPrefix))
        .firstOrNull;
    if (raw == null) return null;
    try {
      final json = jsonDecode(
        utf8.decode(base64Url.decode(raw.substring(_introPrefix.length))),
      );
      return DeviceCert.fromJson((json as Map).cast<String, Object?>());
    } catch (_) {
      return null;
    }
  }

  /// Starts listening on [rendezvousId], calling [onContact] with the pubkey
  /// (hex) of each peer that reaches it. Skips [ignore] (e.g. your own key, or
  /// on the joiner side the owner you already know) so the callback only fires
  /// for genuinely new contacts.
  static RendezvousListener start({
    required Uri relayUrl,
    List<Uri> fallbackUrls = const [],
    required String rendezvousId,
    required Identity identity,
    DeviceCert? deviceCert,
    required void Function(String peerHex) onContact,
    Set<String> ignore = const {},
  }) {
    final peerSubs = <StreamSubscription<void>>[];
    final mesh = WebRtcMesh(
      baseUrl: relayUrl,
      fallbackUrls: fallbackUrls,
      channel: rendezvousId,
      identity: identity,
    );
    // The mesh starts announcing lazily when something listens to
    // peerConnected. On each link, exchange a one-frame intro containing the
    // device cert, so the peer can resolve our rendezvous device key to our root
    // identity before creating a request/DM.
    final sub = mesh.peerConnected.listen((link) {
      if (deviceCert == null) {
        if (!ignore.contains(link.peerHex)) onContact(link.peerHex);
        return;
      }
      link.send(HaveFrame([_intro(deviceCert)]));
      late final StreamSubscription<SyncFrame> framesSub;
      framesSub = link.frames.listen((frame) {
        final cert = _decodeIntro(frame);
        if (cert == null) return;
        unawaited(() async {
          if (cert.deviceKeyHex != link.peerHex) return;
          if (!await cert.verify()) return;
          final rootHex = cert.rootKeyHex;
          if (!ignore.contains(link.peerHex) && !ignore.contains(rootHex)) {
            onContact(rootHex);
          }
          await framesSub.cancel();
        }());
      });
      peerSubs.add(framesSub);
    });
    return RendezvousListener._(mesh, sub, peerSubs);
  }

  /// Point the underlying mesh at new fallback relays (mirrors channel sessions).
  set fallbackUrls(List<Uri> urls) => _mesh.fallbackUrls = urls;

  Future<void> close() async {
    await _sub.cancel();
    for (final sub in _peerSubs) {
      await sub.cancel();
    }
    _peerSubs.clear();
    await _mesh.close();
  }
}
