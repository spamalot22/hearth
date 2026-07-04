// SPDX-License-Identifier: AGPL-3.0-or-later
// The chat-markdown tokenizer, plus a widget pass proving a formatted message
// renders through the real MarkdownText (styles applied, links tappable-shaped,
// code blocks boxed).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/markdown.dart';

MdSegment _only(String text) {
  final blocks = parseMarkdown(text);
  expect(blocks, hasLength(1));
  final segments = (blocks.single as MdParagraph).segments;
  expect(segments, hasLength(1));
  return segments.single;
}

void main() {
  group('inline tokenizer', () {
    test('plain text is one plain segment', () {
      final s = _only('just words');
      expect(s.text, 'just words');
      expect(s.bold || s.italic || s.strike || s.code, isFalse);
      expect(s.link, isNull);
    });

    test('**bold**, *italic*, _italic_, ~~strike~~, `code`', () {
      expect(_only('**b**').bold, isTrue);
      expect(_only('*i*').italic, isTrue);
      expect(_only('_i_').italic, isTrue);
      expect(_only('~~s~~').strike, isTrue);
      expect(_only('`c`').code, isTrue);
      expect(_only('`c`').text, 'c');
    });

    test('***bold italic*** sets both flags', () {
      final s = _only('***bi***');
      expect(s.bold, isTrue);
      expect(s.italic, isTrue);
      expect(s.text, 'bi');
    });

    test('mixed line keeps plain runs between styled ones', () {
      final blocks = parseMarkdown('say **hi** to `code` ok');
      final segs = (blocks.single as MdParagraph).segments;
      expect(segs.map((s) => s.text).toList(), [
        'say ',
        'hi',
        ' to ',
        'code',
        ' ok',
      ]);
      expect(segs[1].bold, isTrue);
      expect(segs[3].code, isTrue);
    });

    test('snake_case_names do not italicise', () {
      final blocks = parseMarkdown('use snake_case_names here');
      final segs = (blocks.single as MdParagraph).segments;
      expect(segs, hasLength(1));
      expect(segs.single.italic, isFalse);
    });

    test('URLs become links, trailing punctuation excluded', () {
      final blocks = parseMarkdown('see https://example.com/x, ok');
      final segs = (blocks.single as MdParagraph).segments;
      final link = segs.firstWhere((s) => s.link != null);
      expect(link.link, 'https://example.com/x');
      expect(segs.map((s) => s.text).join(), 'see https://example.com/x, ok');
    });

    test('unterminated markers stay literal', () {
      expect(_only('2 * 3 = 6, *not 5').text, contains('*not 5'));
      final s = _only('a ** b');
      expect(s.bold, isFalse);
      expect(s.text, 'a ** b');
    });
  });

  group('fenced code blocks', () {
    test('a fence becomes a code block between paragraphs', () {
      final blocks = parseMarkdown('before\n```\nlet x = 1;\n```\nafter');
      expect(blocks, hasLength(3));
      expect(blocks[0], isA<MdParagraph>());
      expect((blocks[1] as MdCodeBlock).code, 'let x = 1;');
      expect(blocks[2], isA<MdParagraph>());
    });

    test('a language tag on the fence is ignored, not rendered', () {
      final blocks = parseMarkdown('```dart\nprint("hi");\n```');
      expect((blocks.single as MdCodeBlock).code, 'print("hi");');
    });

    test('markdown inside a fence is left alone', () {
      final blocks = parseMarkdown('```\n**not bold**\n```');
      expect((blocks.single as MdCodeBlock).code, '**not bold**');
    });
  });

  testWidgets('MarkdownText renders styled runs and a code box', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MarkdownText('**bold** and `mono`\n```\nblock\n```'),
        ),
      ),
    );
    expect(
      find.textContaining('bold', findRichText: true),
      findsOneWidget,
      reason: 'inline runs render as one rich text',
    );
    expect(find.text('block'), findsOneWidget, reason: 'code block renders');
    // The code block sits in its own decorated container.
    final box = tester.widget<Container>(
      find.ancestor(of: find.text('block'), matching: find.byType(Container)),
    );
    expect((box.decoration as BoxDecoration?)?.borderRadius, isNotNull);
  });

  group('mentions', () {
    // A real 64-char lowercase-hex pubkey shape.
    final hexA = 'a' * 64;
    final hexB = 'b' * 64;

    test('extracts mentioned pubkeys in order', () {
      expect(mentionedPubkeys('hi <@$hexA> and <@$hexB>'), [hexA, hexB]);
      expect(mentionedPubkeys('no mentions here'), isEmpty);
    });

    test('mentionsPubkey detects a specific pubkey', () {
      expect(mentionsPubkey('yo <@$hexA>', hexA), isTrue);
      expect(mentionsPubkey('yo <@$hexA>', hexB), isFalse);
    });

    test('stripMentions resolves tokens to readable @names', () {
      final out = stripMentions(
        'hey <@$hexA> and <@$hexB>!',
        (h) => h == hexA ? '@Alice' : '@Bob',
      );
      expect(out, 'hey @Alice and @Bob!');
    });

    test('a partial/short token is not a mention', () {
      // 63 hex chars — not a full pubkey, so left as literal text.
      final short = 'a' * 63;
      expect(mentionedPubkeys('<@$short>'), isEmpty);
      final blocks = parseMarkdown('<@$short>');
      final segs = (blocks.single as MdParagraph).segments;
      expect(segs.every((s) => s.mention == null), isTrue);
    });

    test('the tokenizer yields a mention segment', () {
      final blocks = parseMarkdown('ping <@$hexA> now');
      final segs = (blocks.single as MdParagraph).segments;
      final mention = segs.firstWhere((s) => s.mention != null);
      expect(mention.mention, hexA);
    });

    group('resolveMentions', () {
      final members = {'Alice': hexA, 'Al': hexB};

      test('rewrites @name to a token, longest-name-first', () {
        expect(resolveMentions('hi @Alice', members), 'hi <@$hexA>');
        // @Al must not eat the front of @Alice.
        expect(
          resolveMentions('hi @Alice and @Al', members),
          'hi <@$hexA> and <@$hexB>',
        );
      });

      test('boundaries: start, punctuation, and non-abutting', () {
        expect(resolveMentions('@Alice!', members), '<@$hexA>!');
        expect(resolveMentions('(@Alice)', members), '(<@$hexA>)');
      });

      test('does not match inside a word or an email', () {
        expect(resolveMentions('foo@Alice', members), 'foo@Alice');
        expect(resolveMentions('@Alicexyz', members), '@Alicexyz');
      });

      test('Unicode boundary: a shorter name does not match a longer word', () {
        final m = {'Бор': hexA};
        expect(resolveMentions('@Бориса', m), '@Бориса');
        expect(resolveMentions('@Бор', m), '<@$hexA>');
      });

      test('leaves @names inside code untouched', () {
        expect(
          resolveMentions('use `@Alice` here', members),
          'use `@Alice` here',
        );
        expect(
          resolveMentions('```\n@Alice\n``` then @Al', members),
          '```\n@Alice\n``` then <@$hexB>',
        );
      });
    });

    testWidgets('MarkdownText renders a mention via its label', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MarkdownText(
              'hey <@$hexA> there',
              mentionLabel: (h) => '@Alice',
              onMentionTap: (_) {},
            ),
          ),
        ),
      );
      expect(
        find.textContaining('@Alice', findRichText: true),
        findsOneWidget,
        reason: 'the mention renders resolved to the viewer label',
      );
      expect(
        find.textContaining(hexA, findRichText: true),
        findsNothing,
        reason: 'the raw pubkey never shows',
      );
    });
  });
}
