// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:convert/convert.dart';
import 'package:core/core.dart';

import 'webrtc_mesh.dart';

/// Listens on a contact card's rendezvous capability for first contact.
///
/// It's a bare [WebRtcMesh] on the rendezvous id — no cipher and no DAG traffic.
/// Its only payload is a root-signed device certificate and active-device
/// bundle. That lets each side authenticate the connecting device and obtain
/// the recipient keys needed to bootstrap the encrypted DM.
///
/// The *owner* keeps one of these alive for the lifetime of the app (their
/// standing contact inbox). A *joiner* runs a transient one on the owner's
/// rendezvous just long enough to be discovered, then closes it — after first
/// contact the DM reconnects on its own derived channel, so the rendezvous is
/// never needed again.
class RendezvousIntro {
  const RendezvousIntro({required this.cert, required this.bundle});

  final DeviceCert cert;
  final DeviceBundle bundle;

  static const _prefix = 'rvintro:';

  String encode() =>
      '$_prefix${base64Url.encode(utf8.encode(jsonEncode(<String, Object?>{'cert': cert.toJson(), 'bundle': bundle.toJson()})))}';

  static RendezvousIntro? decode(SyncFrame frame) {
    if (frame is! HaveFrame) return null;
    final raw = frame.heads.where((h) => h.startsWith(_prefix)).firstOrNull;
    if (raw == null) return null;
    try {
      final json =
          (jsonDecode(
                    utf8.decode(
                      base64Url.decode(raw.substring(_prefix.length)),
                    ),
                  )
                  as Map)
              .cast<String, Object?>();
      return RendezvousIntro(
        cert: DeviceCert.fromJson(
          (json['cert']! as Map).cast<String, Object?>(),
        ),
        bundle: DeviceBundle.fromJson(
          (json['bundle']! as Map).cast<String, Object?>(),
        ),
      );
    } catch (_) {
      return null;
    }
  }

  Future<bool> verifyForPeer(String peerHex) async {
    if (cert.deviceKeyHex != peerHex || bundle.rootKeyHex != cert.rootKeyHex) {
      return false;
    }
    if (!bundle.devices.any((key) => hex.encode(key) == peerHex)) return false;
    return await cert.verify() && await bundle.verify();
  }
}

class RendezvousListener {
  RendezvousListener._(this._mesh, this._sub, this._peerSubs);

  final WebRtcMesh _mesh;
  final StreamSubscription<void> _sub;
  final List<StreamSubscription<void>> _peerSubs;

  /// Starts listening on [rendezvousId], calling [onContact] with each verified
  /// peer intro. Skips [ignore] (e.g. your own root or device key) so the
  /// callback only fires for genuinely new contacts.
  static RendezvousListener start({
    required Uri relayUrl,
    List<Uri> fallbackUrls = const [],
    required String rendezvousId,
    required Identity identity,
    required DeviceCert deviceCert,
    required DeviceBundle deviceBundle,
    required Future<void> Function(RendezvousIntro intro) onContact,
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
      late final StreamSubscription<SyncFrame> framesSub;
      framesSub = link.frames.listen((frame) {
        final intro = RendezvousIntro.decode(frame);
        if (intro == null) return;
        unawaited(() async {
          if (!await intro.verifyForPeer(link.peerHex)) return;
          final rootHex = intro.cert.rootKeyHex;
          if (!ignore.contains(link.peerHex) && !ignore.contains(rootHex)) {
            await onContact(intro);
          }
          await framesSub.cancel();
        }());
      });
      peerSubs.add(framesSub);
      link.send(
        HaveFrame([
          RendezvousIntro(cert: deviceCert, bundle: deviceBundle).encode(),
        ]),
      );
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
