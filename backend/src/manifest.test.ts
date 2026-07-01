// SPDX-License-Identifier: AGPL-3.0-or-later
import { describe, it, expect } from 'vitest';

import { manifestSigningBytes } from './manifest';

describe('manifestSigningBytes', () => {
  // This exact string is also asserted by the Dart client
  // (app/test/update_checker_test.dart) — if they ever diverge, signatures stop
  // verifying cross-language, so the two literals must stay identical.
  const expected =
    'hearth/manifest/v1\n0.5.9\n3\nandroid\na.apk\naa\nwindows\nw.zip\nww';

  it('is a canonical newline form with sorted asset keys', () => {
    // Assets passed windows-first to prove the output is sorted (android first).
    const bytes = manifestSigningBytes({
      version: '0.5.9',
      seq: 3,
      assets: {
        windows: { file: 'w.zip', sha256: 'ww' },
        android: { file: 'a.apk', sha256: 'aa' },
      },
    });
    expect(new TextDecoder().decode(bytes)).toBe(expected);
  });
});
