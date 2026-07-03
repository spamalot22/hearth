// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

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
  RendezvousListener._(this._mesh, this._sub);

  final WebRtcMesh _mesh;
  final StreamSubscription<void> _sub;

  /// Starts listening on [rendezvousId], calling [onContact] with the pubkey
  /// (hex) of each peer that reaches it. Skips [ignore] (e.g. your own key, or
  /// on the joiner side the owner you already know) so the callback only fires
  /// for genuinely new contacts.
  static RendezvousListener start({
    required Uri relayUrl,
    List<Uri> fallbackUrls = const [],
    required String rendezvousId,
    required Identity identity,
    required void Function(String peerHex) onContact,
    Set<String> ignore = const {},
  }) {
    final mesh = WebRtcMesh(
      baseUrl: relayUrl,
      fallbackUrls: fallbackUrls,
      channel: rendezvousId,
      identity: identity,
      onPeerConnectedHex: (peerHex) {
        if (!ignore.contains(peerHex)) onContact(peerHex);
      },
    );
    // The mesh starts announcing lazily when something listens to
    // peerConnected; we consume identity via onPeerConnectedHex instead, so this
    // subscription exists only to kick it into life.
    final sub = mesh.peerConnected.listen((_) {});
    return RendezvousListener._(mesh, sub);
  }

  /// Point the underlying mesh at new fallback relays (mirrors channel sessions).
  set fallbackUrls(List<Uri> urls) => _mesh.fallbackUrls = urls;

  Future<void> close() async {
    await _sub.cancel();
    await _mesh.close();
  }
}
