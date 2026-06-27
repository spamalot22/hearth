// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/youtube_share.dart';

void main() {
  group('parseYoutubeId', () {
    test('accepts a raw 11-char id', () {
      expect(parseYoutubeId('dQw4w9WgXcQ'), 'dQw4w9WgXcQ');
    });

    test('extracts from a watch?v= URL (ignoring extra params)', () {
      expect(
        parseYoutubeId('https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=5s'),
        'dQw4w9WgXcQ',
      );
    });

    test('extracts from a youtu.be short link', () {
      expect(parseYoutubeId('https://youtu.be/dQw4w9WgXcQ'), 'dQw4w9WgXcQ');
    });

    test('extracts from /shorts/ and /embed/ paths', () {
      expect(
        parseYoutubeId('https://www.youtube.com/shorts/dQw4w9WgXcQ'),
        'dQw4w9WgXcQ',
      );
      expect(
        parseYoutubeId('https://www.youtube.com/embed/dQw4w9WgXcQ'),
        'dQw4w9WgXcQ',
      );
    });

    test('rejects non-YouTube input and wrong-length ids', () {
      expect(parseYoutubeId('not a link'), isNull);
      expect(parseYoutubeId('https://example.com/watch?v=dQw4w9WgXcQ'), isNull);
      expect(parseYoutubeId('abc'), isNull);
    });
  });
}
