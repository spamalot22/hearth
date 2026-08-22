// SPDX-License-Identifier: AGPL-3.0-or-later

typedef WebRtcSignalSender =
    Future<void> Function(String kind, Object? payload);

/// Keeps trickled ICE behind the SDP description that creates its peer link.
///
/// Native WebRTC can emit candidates while `setLocalDescription` is still
/// completing. Sending those requests immediately lets network scheduling put
/// ICE in the rendezvous mailbox before the offer/answer, where the recipient
/// has no peer connection to apply it to yet.
class WebRtcSignalOrder {
  WebRtcSignalOrder({this.maxPendingCandidates = 256});

  final int maxPendingCandidates;
  final List<Map<String, Object?>> _pendingCandidates = [];
  Future<void> _tail = Future<void>.value();
  bool _descriptionSent = false;

  void addCandidate(Map<String, Object?> payload, WebRtcSignalSender send) {
    if (!_descriptionSent) {
      if (_pendingCandidates.length < maxPendingCandidates) {
        _pendingCandidates.add(payload);
      }
      return;
    }
    _enqueueCandidate(payload, send);
  }

  Future<void> sendDescription(
    String kind,
    Map<String, Object?> payload,
    WebRtcSignalSender send,
  ) async {
    await send(kind, payload);
    _descriptionSent = true;
    final pending = List<Map<String, Object?>>.of(_pendingCandidates);
    _pendingCandidates.clear();
    for (final candidate in pending) {
      _enqueueCandidate(candidate, send);
    }
  }

  Future<void> get drained => _tail;

  void clear() => _pendingCandidates.clear();

  void _enqueueCandidate(
    Map<String, Object?> payload,
    WebRtcSignalSender send,
  ) {
    _tail = _tail.then((_) => send('ice', payload)).catchError((Object _) {
      // A later direct handshake retries with a fresh candidate set.
    });
  }
}
