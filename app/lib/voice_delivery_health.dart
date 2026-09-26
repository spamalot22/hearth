// SPDX-License-Identifier: AGPL-3.0-or-later

/// Detects RTP delivery stalls only while the sender's packet count increases
/// and the receiver keeps reporting a stationary count over the direct channel.
/// Silence, mute, missing stats, or a missing heartbeat are not proof of failure.
class VoiceDeliveryHealth {
  VoiceDeliveryHealth({
    this.stallTimeout = const Duration(seconds: 15),
    this.freshness = const Duration(seconds: 8),
  });

  final Duration stallTimeout;
  final Duration freshness;
  int? _sent;
  int? _received;
  DateTime? _sentProgress;
  DateTime? _receiptAt;
  DateTime? _stalledSince;

  void receipt(int received, DateTime now) {
    if (received != _received) _stalledSince = null;
    _received = received;
    _receiptAt = now;
  }

  bool sample(int? sent, {required bool enabled, required DateTime now}) {
    final previous = _sent;
    _sent = sent;
    if (!enabled || sent == null || previous == null || sent < previous) {
      _sentProgress = null;
      _stalledSince = null;
      return false;
    }
    if (sent > previous) _sentProgress = now;
    final progress = _sentProgress;
    final receipt = _receiptAt;
    if (progress == null ||
        receipt == null ||
        now.difference(progress) > freshness ||
        now.difference(receipt) > freshness) {
      _stalledSince = null;
      return false;
    }
    _stalledSince ??= now;
    return now.difference(_stalledSince!) >= stallTimeout;
  }
}

/// Sample duration advances during silence too, unlike microphone amplitude.
/// Only trust this metric after observing it advance on this capture instance.
class VoiceCaptureHealth {
  VoiceCaptureHealth({this.stallTimeout = const Duration(seconds: 15)});
  final Duration stallTimeout;
  double? _samples;
  DateTime? _progressAt;

  bool sample(double? samples, {required bool enabled, required DateTime now}) {
    final previous = _samples;
    _samples = samples;
    if (!enabled ||
        samples == null ||
        !samples.isFinite ||
        previous == null ||
        samples < previous) {
      _progressAt = null;
      return false;
    }
    if (samples > previous) _progressAt = now;
    return _progressAt != null && now.difference(_progressAt!) >= stallTimeout;
  }
}
