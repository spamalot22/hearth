// SPDX-License-Identifier: AGPL-3.0-or-later
// A deliberately small chat-flavoured markdown renderer: **bold**, *italic*
// (or _italic_), ~~strikethrough~~, `inline code`, ```fenced code blocks```
// and tappable http(s) links. No headings/lists/images — this formats chat
// bubbles, not documents, and a hand-rolled tokenizer keeps the dependency
// tree flat.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// One inline run of styled text. Styles never nest across segments — a chat
/// line is a flat sequence of runs.
class MdSegment {
  const MdSegment(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.strike = false,
    this.code = false,
    this.link,
  }) : mention = null;

  const MdSegment.mention(String pubkeyHex)
    : mention = pubkeyHex,
      text = pubkeyHex,
      bold = false,
      italic = false,
      strike = false,
      code = false,
      link = null;

  final String text;
  final bool bold;
  final bool italic;
  final bool strike;
  final bool code;

  /// Non-null when this run is a tappable URL.
  final String? link;

  /// Non-null (pubkey hex) when this run is a `<@…>` mention. [text] holds the
  /// raw pubkey; the renderer resolves it to the *viewer's* display name.
  final String? mention;
}

final _mentionToken = RegExp(r'<@([0-9a-f]{64})>');

/// The pubkey hexes mentioned in [text] (from its `<@hex>` tokens), in order.
List<String> mentionedPubkeys(String text) =>
    _mentionToken.allMatches(text).map((m) => m.group(1)!).toList();

/// True if [selfHex] is mentioned in [text].
bool mentionsPubkey(String text, String selfHex) =>
    text.contains('<@$selfHex>');

/// Rewrites `<@hex>` tokens to a readable `@name` via [label] — for previews,
/// search and notifications where styling isn't available.
String stripMentions(String text, String Function(String hex) label) =>
    text.replaceAllMapped(_mentionToken, (m) => label(m.group(1)!));

sealed class MdBlock {
  const MdBlock();
}

class MdParagraph extends MdBlock {
  const MdParagraph(this.segments);
  final List<MdSegment> segments;
}

class MdCodeBlock extends MdBlock {
  const MdCodeBlock(this.code);
  final String code;
}

final _fence = RegExp(r'```[^\n`]*\n?([\s\S]*?)```');

// Ordered alternation — longer/most-specific delimiters first so `***` isn't
// eaten as `**` + `*`. Styled content can't start or end with whitespace
// (Discord's rule), so `2 * 3 = 6` stays literal; underscore italic also
// requires non-word neighbours so snake_case_names don't italicise.
final _inline = RegExp(
  r'(`[^`\n]+`)' // 1 inline code
  r'|(\*\*\*(?!\s)[^*\n]+?(?<!\s)\*\*\*)' // 2 bold italic
  r'|(\*\*(?!\s)[^*\n]+?(?<!\s)\*\*)' // 3 bold
  r'|(\*(?!\s)[^*\n]+?(?<!\s)\*)' // 4 italic (star)
  r'|((?<![\w*])_(?!\s)[^_\n]+?(?<!\s)_(?![\w]))' // 5 italic (underscore)
  r'|(~~(?!\s)[^~\n]+?(?<!\s)~~)' // 6 strikethrough
  r'|(<@[0-9a-f]{64}>)' // 7 mention token
  r'|(https?://[^\s<>]+)', // 8 bare URL
);

/// Splits [text] into fenced code blocks and paragraphs of inline segments.
List<MdBlock> parseMarkdown(String text) {
  final blocks = <MdBlock>[];
  var last = 0;
  for (final match in _fence.allMatches(text)) {
    final before = text.substring(last, match.start);
    if (before.trim().isNotEmpty) {
      blocks.add(MdParagraph(parseInline(before.trim())));
    }
    final code = match.group(1) ?? '';
    blocks.add(MdCodeBlock(code.trimRight()));
    last = match.end;
  }
  final tail = text.substring(last);
  if (tail.trim().isNotEmpty || blocks.isEmpty) {
    blocks.add(MdParagraph(parseInline(blocks.isEmpty ? text : tail.trim())));
  }
  return blocks;
}

/// Tokenises one paragraph into styled runs (no nesting, single pass).
List<MdSegment> parseInline(String text) {
  final segments = <MdSegment>[];
  var last = 0;
  for (final m in _inline.allMatches(text)) {
    if (m.start > last) segments.add(MdSegment(text.substring(last, m.start)));
    final token = m.group(0)!;
    if (m.group(1) != null) {
      segments.add(MdSegment(token.substring(1, token.length - 1), code: true));
    } else if (m.group(2) != null) {
      segments.add(
        MdSegment(
          token.substring(3, token.length - 3),
          bold: true,
          italic: true,
        ),
      );
    } else if (m.group(3) != null) {
      segments.add(MdSegment(token.substring(2, token.length - 2), bold: true));
    } else if (m.group(4) != null || m.group(5) != null) {
      segments.add(
        MdSegment(token.substring(1, token.length - 1), italic: true),
      );
    } else if (m.group(6) != null) {
      segments.add(
        MdSegment(token.substring(2, token.length - 2), strike: true),
      );
    } else if (m.group(7) != null) {
      // <@hex> — strip the <@ … > wrapper, keep the pubkey.
      segments.add(MdSegment.mention(token.substring(2, token.length - 1)));
    } else {
      // Trailing punctuation is almost never part of a pasted URL.
      final trimmed = token.replaceFirst(RegExp(r'[.,;:!?)\]]+$'), '');
      segments.add(MdSegment(trimmed, link: trimmed));
      if (trimmed.length < token.length) {
        segments.add(MdSegment(token.substring(trimmed.length)));
      }
    }
    last = m.end;
  }
  if (last < text.length) segments.add(MdSegment(text.substring(last)));
  return segments;
}

/// Renders chat-flavoured markdown. Stateful only to own (and dispose) the
/// link-tap gesture recognizers.
class MarkdownText extends StatefulWidget {
  const MarkdownText(
    this.text, {
    super.key,
    this.style,
    this.mentionLabel,
    this.onMentionTap,
  });

  final String text;
  final TextStyle? style;

  /// Resolves a mention's pubkey hex to the viewer's display text (e.g.
  /// `@Alice`). When null, a mention renders as its raw `@hex`.
  final String Function(String pubkeyHex)? mentionLabel;

  /// Called when a mention is tapped (with its pubkey hex).
  final void Function(String pubkeyHex)? onMentionTap;

  @override
  State<MarkdownText> createState() => _MarkdownTextState();
}

class _MarkdownTextState extends State<MarkdownText> {
  // Parse output + link recognizers are derived from widget.text alone, so
  // they're built once per text (not per rebuild — the chat screen setStates
  // on every mesh event) and recognizers stay alive across frames instead of
  // being disposed while a previous frame's spans might still route a tap.
  late List<MdBlock> _blocks;
  // Tap recognizers for links and mentions, keyed by their segment.
  final Map<MdSegment, TapGestureRecognizer> _recognizers = {};

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void didUpdateWidget(MarkdownText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _parse();
  }

  @override
  void dispose() {
    for (final r in _recognizers.values) {
      r.dispose();
    }
    super.dispose();
  }

  void _parse() {
    for (final r in _recognizers.values) {
      r.dispose();
    }
    _recognizers.clear();
    _blocks = parseMarkdown(widget.text);
    for (final block in _blocks) {
      if (block is! MdParagraph) continue;
      for (final s in block.segments) {
        final link = s.link;
        final mention = s.mention;
        if (link != null) {
          _recognizers[s] = TapGestureRecognizer()
            ..onTap = () {
              final uri = Uri.tryParse(link);
              if (uri != null) {
                launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            };
        } else if (mention != null && widget.onMentionTap != null) {
          _recognizers[s] = TapGestureRecognizer()
            ..onTap = () => widget.onMentionTap!(mention);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = widget.style ?? DefaultTextStyle.of(context).style;
    final children = <Widget>[
      for (final block in _blocks)
        switch (block) {
          MdParagraph(:final segments) => Text.rich(
            TextSpan(
              children: [for (final s in segments) _span(s, base, scheme)],
            ),
          ),
          MdCodeBlock(:final code) => Container(
            margin: const EdgeInsets.symmetric(vertical: 2),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: scheme.onSurface.withAlpha(18),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              code,
              style: base.copyWith(fontFamily: 'monospace', fontSize: 13),
            ),
          ),
        },
    ];
    return children.length == 1
        ? children.single
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: children,
          );
  }

  InlineSpan _span(MdSegment s, TextStyle base, ColorScheme scheme) {
    if (s.link != null) {
      return TextSpan(
        text: s.text,
        recognizer: _recognizers[s],
        style: base.copyWith(
          color: scheme.primary,
          decoration: TextDecoration.underline,
        ),
      );
    }
    if (s.mention != null) {
      final label = widget.mentionLabel?.call(s.mention!) ?? '@${s.mention}';
      return TextSpan(
        text: label,
        recognizer: _recognizers[s],
        style: base.copyWith(
          color: scheme.primary,
          fontWeight: FontWeight.w600,
          backgroundColor: scheme.primary.withAlpha(28),
        ),
      );
    }
    return TextSpan(
      text: s.text,
      style: base.copyWith(
        fontWeight: s.bold ? FontWeight.w700 : null,
        fontStyle: s.italic ? FontStyle.italic : null,
        decoration: s.strike ? TextDecoration.lineThrough : null,
        fontFamily: s.code ? 'monospace' : null,
        backgroundColor: s.code ? scheme.onSurface.withAlpha(18) : null,
      ),
    );
  }
}
