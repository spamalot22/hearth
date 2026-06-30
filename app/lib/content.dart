// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

/// The logical content of a message — a typed envelope serialised into the
/// message payload. Keeping it inside the payload means it composes under
/// encryption (we encrypt the envelope) and needs no change to the signed
/// [Message] schema. New types (sticker, sound) slot in here.
sealed class Content {
  const Content({this.replyTo});

  /// If this message is a reply, the hex ID of the message being replied to.
  final String? replyTo;

  Map<String, Object?> toJson();

  /// Serialises to payload bytes.
  List<int> encode() => utf8.encode(jsonEncode({
        ...toJson(),
        if (replyTo != null) 'replyTo': replyTo,
      }));
}

/// Plain text (which already includes emoji — they're just Unicode).
class TextContent extends Content {
  const TextContent(this.text, {super.replyTo});

  final String text;

  @override
  Map<String, Object?> toJson() => {'t': 'text', 'text': text};
}

/// A GIF — like a sticker, an image in the content-addressed blob store,
/// referenced by [blob] hash. Fetched once from its source at send time, then it
/// lives in the blob store and transfers P2P; it's never re-fetched from a CDN.
class GifContent extends Content {
  const GifContent(this.blob);

  final String blob;

  @override
  Map<String, Object?> toJson() => {'t': 'gif', 'blob': blob};
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
/// a display [name] and an [emoji] icon for the soundboard button.
class SoundContent extends Content {
  const SoundContent(this.blob, this.name, [this.emoji = '🔊']);

  final String blob;
  final String name;
  final String emoji;

  @override
  Map<String, Object?> toJson() => {
    't': 'sound',
    'blob': blob,
    'name': name,
    'emoji': emoji,
  };
}

/// A one-off file attachment — any file stored as a content-addressed blob,
/// with its [name] and [mime]. Images render inline; other files show as a chip.
class FileContent extends Content {
  const FileContent(this.blob, this.name, this.mime);

  final String blob;
  final String name;
  final String mime;

  @override
  Map<String, Object?> toJson() => {
    't': 'file',
    'blob': blob,
    'name': name,
    'mime': mime,
  };
}

/// A signed, self-asserted display name. Not rendered as a message — clients
/// index it as the *suggested* petname for its author, who can still be named
/// locally however you like. Self-asserted, so treat it as a suggestion, never
/// proof of identity (the author's pubkey is the real id).
class ProfileContent extends Content {
  const ProfileContent(this.name);

  final String name;

  @override
  Map<String, Object?> toJson() => {'t': 'profile', 'name': name};
}

/// Parses a payload into [Content], falling back to plain text for unknown or
/// legacy (pre-envelope) payloads.
Content parseContent(List<int> payload) {
  try {
    final decoded = jsonDecode(utf8.decode(payload));
    if (decoded is Map) {
      final replyTo = decoded['replyTo'] as String?;
      switch (decoded['t']) {
        case 'text':
          return TextContent(decoded['text'] as String? ?? '',
              replyTo: replyTo);
        case 'gif':
          return GifContent(decoded['blob'] as String? ?? '');
        case 'sticker':
          return StickerContent(decoded['blob'] as String? ?? '');
        case 'sound':
          return SoundContent(
            decoded['blob'] as String? ?? '',
            decoded['name'] as String? ?? 'sound',
            decoded['emoji'] as String? ?? '🔊',
          );
        case 'profile':
          return ProfileContent(decoded['name'] as String? ?? '');
        case 'file':
          return FileContent(
            decoded['blob'] as String? ?? '',
            decoded['name'] as String? ?? 'file',
            decoded['mime'] as String? ?? '',
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
