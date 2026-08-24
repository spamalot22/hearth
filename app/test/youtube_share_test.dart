// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/youtube_share.dart';

void main() {
  test('uses a stable public identity for YouTube embed requests', () {
    final identity = Uri.parse(youtubeEmbedIdentity);

    expect(identity.scheme, 'https');
    expect(identity.host, 'github.com');
    expect(identity.path, '/spamalot22/hearth');
  });

  test('player navigation allowlist rejects lookalike and insecure hosts', () {
    expect(
      isAllowedYoutubePlayerNavigation(
        Uri.parse('https://www.youtube.com/embed/dQw4w9WgXcQ'),
      ),
      isTrue,
    );
    expect(
      isAllowedYoutubePlayerNavigation(
        Uri.parse('https://youtube.com.evil.test/embed/dQw4w9WgXcQ'),
      ),
      isFalse,
    );
    expect(
      isAllowedYoutubePlayerNavigation(
        Uri.parse('http://www.youtube.com/embed/dQw4w9WgXcQ'),
      ),
      isFalse,
    );
    expect(
      isAllowedYoutubePlayerNavigation(Uri.parse('$youtubeEmbedIdentity/')),
      isTrue,
    );
  });

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
      expect(parseYoutubeId('https://m.youtu.be/dQw4w9WgXcQ'), 'dQw4w9WgXcQ');
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
      expect(
        parseYoutubeId('https://youtube.com.evil.test/watch?v=dQw4w9WgXcQ'),
        isNull,
      );
      expect(
        parseYoutubeId('https://notyoutube.com/watch?v=dQw4w9WgXcQ'),
        isNull,
      );
      expect(parseYoutubeId('abc'), isNull);
    });
  });
}
