import 'dart:convert';

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
