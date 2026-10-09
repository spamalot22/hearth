// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';

import 'support/inference_job_checks.dart';

void main() {
  test(
    'inference waits for native completion and enforces safety bounds',
    () async {
      expect(await checkInferenceJob(), greaterThan(20));
    },
  );
}
