// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'message.dart';

/// A bidirectional stream of [SyncFrame]s to a single peer.
///
/// The gossip [SyncSession] runs over one of these. The app's WebRTC transport
/// provides one per connected peer (backed by that peer's data channel); tests
/// provide an in-memory pair. Single-subscription — exactly one session consumes
/// it.
abstract interface class FrameChannel {
  /// Sends [frame] to the peer.
  void send(SyncFrame frame);

  /// Frames arriving from the peer.
  Stream<SyncFrame> get frames;
}

/// A frame in the gossip protocol: advertise heads ([HaveFrame]), request
/// messages by id ([WantFrame]), or deliver a message ([GiveFrame]).
sealed class SyncFrame {
  const SyncFrame();

  Map<String, Object?> toJson();

  /// The wire encoding (JSON text) for a data channel.
  String encode() => jsonEncode(toJson());

  /// Parses a wire string, or returns null if it isn't a well-formed frame —
  /// callers drop nulls rather than trust malformed input.
  static SyncFrame? decode(String raw) {
    try {
      final json = (jsonDecode(raw) as Map).cast<String, Object?>();
      switch (json['t']) {
        case 'have':
          return HaveFrame((json['heads']! as List).cast<String>());
        case 'want':
          return WantFrame((json['ids']! as List).cast<String>());
        case 'give':
          return GiveFrame(
            Message.fromJson((json['m']! as Map).cast<String, Object?>()),
          );
        case 'wantblob':
          return WantBlobFrame(json['h']! as String);
        case 'giveblob':
          return GiveBlobFrame(
            json['h']! as String,
            base64.decode(json['b']! as String),
          );
        default:
          return null;
      }
    } catch (_) {
      return null;
    }
  }
}

/// "Here are my DAG heads" (hex ids) — sent on connect to start reconciliation.
class HaveFrame extends SyncFrame {
  const HaveFrame(this.heads);

  final List<String> heads;

  @override
  Map<String, Object?> toJson() => {'t': 'have', 'heads': heads};
}

/// "Send me these messages" (hex ids).
class WantFrame extends SyncFrame {
  const WantFrame(this.ids);

  final List<String> ids;

  @override
  Map<String, Object?> toJson() => {'t': 'want', 'ids': ids};
}

/// "Here is a message" — a reply to a want, or a live / forwarded message.
class GiveFrame extends SyncFrame {
  const GiveFrame(this.message);

  final Message message;

  @override
  Map<String, Object?> toJson() => {'t': 'give', 'm': message.toJson()};
}

/// "Send me the media blob with this id" (hex). Media is fetched on demand.
class WantBlobFrame extends SyncFrame {
  const WantBlobFrame(this.hash);

  final String hash;

  @override
  Map<String, Object?> toJson() => {'t': 'wantblob', 'h': hash};
}

/// "Here is a blob's bytes" (base64). The receiver checks the bytes hash to the
/// requested id before storing.
class GiveBlobFrame extends SyncFrame {
  const GiveBlobFrame(this.hash, this.bytes);

  final String hash;
  final Uint8List bytes;

  @override
  Map<String, Object?> toJson() => {
    't': 'giveblob',
    'h': hash,
    'b': base64.encode(bytes),
  };
}
