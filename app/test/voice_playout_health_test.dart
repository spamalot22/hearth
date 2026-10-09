// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'support/voice_playout_checks.dart';

void main() {
  test('playout recovery needs sustained RTP with no jitter-buffer output', () {
    expect(checkVoicePlayoutHealth(), 176);
  });
}
