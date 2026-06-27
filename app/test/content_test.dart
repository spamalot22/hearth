import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/content.dart';

void main() {
  group('content envelope', () {
    test('text round-trips', () {
      final parsed = parseContent(const TextContent('hello 👋').encode());
      expect(parsed, isA<TextContent>());
      expect((parsed as TextContent).text, 'hello 👋');
    });

    test('gif round-trips', () {
      final parsed = parseContent(const GifContent('1220cafe').encode());
      expect(parsed, isA<GifContent>());
      expect((parsed as GifContent).blob, '1220cafe');
    });

    test('sticker round-trips', () {
      final parsed = parseContent(const StickerContent('1220abcd').encode());
      expect(parsed, isA<StickerContent>());
      expect((parsed as StickerContent).blob, '1220abcd');
    });

    test('sound round-trips', () {
      final parsed = parseContent(
        const SoundContent('1220beef', 'airhorn', '📯').encode(),
      );
      expect(parsed, isA<SoundContent>());
      expect((parsed as SoundContent).blob, '1220beef');
      expect(parsed.name, 'airhorn');
      expect(parsed.emoji, '📯');
    });

    test('file round-trips', () {
      final parsed = parseContent(
        const FileContent('1220f11e', 'notes.pdf', 'application/pdf').encode(),
      );
      expect(parsed, isA<FileContent>());
      expect((parsed as FileContent).blob, '1220f11e');
      expect(parsed.name, 'notes.pdf');
      expect(parsed.mime, 'application/pdf');
    });

    test('profile round-trips', () {
      final parsed = parseContent(const ProfileContent('Alice').encode());
      expect(parsed, isA<ProfileContent>());
      expect((parsed as ProfileContent).name, 'Alice');
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
