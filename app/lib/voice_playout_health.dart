// SPDX-License-Identifier: AGPL-3.0-or-later

/// Incoming packets alone do not prove that the audio output is consuming the
/// receiver's jitter buffer. Missing counters are not evidence of a failure.
class VoicePlayoutHealth {
  VoicePlayoutHealth({this.stallTimeout = const Duration(seconds: 15)});

  final Duration stallTimeout;
  int? _packets;
  int? _emitted;
  DateTime? _stalledSince;
  DateTime? _sampleAt;

  bool sample({
    required int? packets,
    required int? emitted,
    required bool enabled,
    required DateTime now,
  }) {
    final previousPackets = _packets;
    final previousEmitted = _emitted;
    final previousAt = _sampleAt;
    _packets = packets;
    _emitted = emitted;
    _sampleAt = now;
    if (!enabled ||
        packets == null ||
        emitted == null ||
        packets < 0 ||
        emitted < 0 ||
        previousPackets == null ||
        previousEmitted == null ||
        packets <= previousPackets ||
        emitted != previousEmitted ||
        previousAt == null ||
        now.isBefore(previousAt) ||
        now.difference(previousAt) > const Duration(seconds: 5)) {
      _stalledSince = null;
      return false;
    }
    _stalledSince ??= now;
    return now.difference(_stalledSince!) >= stallTimeout;
  }
}
