import 'dart:convert';

/// The logical content of a message — a typed envelope serialised into the
/// message payload. Keeping it inside the payload means it composes under
/// encryption (we encrypt the envelope) and needs no change to the signed
/// [Message] schema. New types (sticker, sound) slot in here.
sealed class Content {
  const Content();

  Map<String, Object?> toJson();

  /// Serialises to payload bytes.
  List<int> encode() => utf8.encode(jsonEncode(toJson()));
}

/// Plain text (which already includes emoji — they're just Unicode).
class TextContent extends Content {
  const TextContent(this.text);

  final String text;

  @override
  Map<String, Object?> toJson() => {'t': 'text', 'text': text};
}

/// A GIF referenced by URL (the image isn't stored — the client fetches it).
class GifContent extends Content {
  const GifContent(this.url);

  final String url;

  @override
  Map<String, Object?> toJson() => {'t': 'gif', 'url': url};
}

/// A sticker — an image stored in the content-addressed blob store and
/// referenced here by its [blob] hash (fetched on demand from peers).
class StickerContent extends Content {
  const StickerContent(this.blob);

  final String blob;

  @override
  Map<String, Object?> toJson() => {'t': 'sticker', 'blob': blob};
}

/// A soundboard clip — audio in the blob store, referenced by [blob] hash, with
/// a display [name] for the soundboard.
class SoundContent extends Content {
  const SoundContent(this.blob, this.name);

  final String blob;
  final String name;

  @override
  Map<String, Object?> toJson() => {'t': 'sound', 'blob': blob, 'name': name};
}

/// Parses a payload into [Content], falling back to plain text for unknown or
/// legacy (pre-envelope) payloads.
Content parseContent(List<int> payload) {
  try {
    final decoded = jsonDecode(utf8.decode(payload));
    if (decoded is Map) {
      switch (decoded['t']) {
        case 'text':
          return TextContent(decoded['text'] as String? ?? '');
        case 'gif':
          return GifContent(decoded['url'] as String? ?? '');
        case 'sticker':
          return StickerContent(decoded['blob'] as String? ?? '');
        case 'sound':
          return SoundContent(
            decoded['blob'] as String? ?? '',
            decoded['name'] as String? ?? 'sound',
          );
      }
    }
  } catch (_) {
    // Not an envelope — treat as legacy plain text below.
  }
  try {
    return TextContent(utf8.decode(payload));
  } catch (_) {
    return const TextContent('');
  }
}
