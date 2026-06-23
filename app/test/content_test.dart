import 'dart:convert';

import 'package:chat_app/content.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('content envelope', () {
    test('text round-trips', () {
      final parsed = parseContent(const TextContent('hello 👋').encode());
      expect(parsed, isA<TextContent>());
      expect((parsed as TextContent).text, 'hello 👋');
    });

    test('gif round-trips', () {
      final parsed = parseContent(const GifContent('https://x/y.gif').encode());
      expect(parsed, isA<GifContent>());
      expect((parsed as GifContent).url, 'https://x/y.gif');
    });

    test('sticker round-trips', () {
      final parsed = parseContent(const StickerContent('1220abcd').encode());
      expect(parsed, isA<StickerContent>());
      expect((parsed as StickerContent).blob, '1220abcd');
    });

    test('sound round-trips', () {
      final parsed = parseContent(
        const SoundContent('1220beef', 'airhorn').encode(),
      );
      expect(parsed, isA<SoundContent>());
      expect((parsed as SoundContent).blob, '1220beef');
      expect(parsed.name, 'airhorn');
    });

    test('legacy plain-text payloads fall back to text', () {
      final parsed = parseContent(utf8.encode('just raw text'));
      expect(parsed, isA<TextContent>());
      expect((parsed as TextContent).text, 'just raw text');
    });

    test('an unknown envelope type falls back to text', () {
      final parsed = parseContent(utf8.encode('{"t":"mystery","x":1}'));
      expect(parsed, isA<TextContent>());
    });
  });
}
