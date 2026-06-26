import 'dart:convert';
import 'dart:typed_data';

/// Messages the mesh sends peer-to-peer over the data channel *alongside* the
/// gossip `SyncFrame`s, to wean connectivity off the relay: once you hold one live
/// link you can learn of other peers and relay signalling through it, so the relay
/// is only needed for a true cold start.
///
/// On the wire each data-channel message gets a leading tag byte so the two streams
/// don't collide: [kGossipTag] = a raw `SyncFrame` (unchanged), [kControlTag] = a
/// JSON-encoded [MeshControl].
const int kGossipTag = 0x00;
const int kControlTag = 0x01;

sealed class MeshControl {
  const MeshControl();

  Map<String, Object?> toJson();

  /// The data-channel payload for this control message: control tag + JSON.
  Uint8List encode() =>
      Uint8List.fromList([kControlTag, ...utf8.encode(jsonEncode(toJson()))]);

  /// Parses a control body (the bytes after the tag), or null if malformed.
  static MeshControl? decodeBody(List<int> body) {
    try {
      final json = (jsonDecode(utf8.decode(body)) as Map)
          .cast<String, Object?>();
      return switch (json['t']) {
        'peers' => PeersControl(
          ((json['peers'] as List?) ?? const []).cast<String>(),
        ),
        'signal' => SignalControl(
          to: json['to'] as String? ?? '',
          from: json['from'] as String? ?? '',
          kind: json['kind'] as String? ?? '',
          data: ((json['data'] as Map?) ?? const {}).cast<String, Object?>(),
        ),
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }
}

/// "Here are the peers I currently hold a live connection to" — lets a peer learn
/// who is reachable *through* this one (peer-exchange), without asking the relay.
class PeersControl extends MeshControl {
  const PeersControl(this.peers);

  final List<String> peers; // pubkey hex

  @override
  Map<String, Object?> toJson() => {'t': 'peers', 'peers': peers};
}

/// "Forward this signed offer/answer/ICE to peer [to]" — the relayed-signalling
/// path: a peer you are both connected to carries the handshake, so a new
/// connection can form without the relay. [data] is the same signed signal payload
/// the relay's mailbox would carry, so the existing `signal_auth` checks still
/// apply end-to-end.
class SignalControl extends MeshControl {
  const SignalControl({
    required this.to,
    required this.from,
    required this.kind,
    required this.data,
  });

  final String to; // recipient pubkey hex
  final String from; // origin pubkey hex
  final String kind; // 'offer' | 'answer' | 'ice'
  final Map<String, Object?> data; // signed signal payload

  @override
  Map<String, Object?> toJson() => {
    't': 'signal',
    'to': to,
    'from': from,
    'kind': kind,
    'data': data,
  };
}

/// Tags raw gossip (`SyncFrame`) bytes for the data channel.
Uint8List wrapGossip(List<int> syncFrameBytes) =>
    Uint8List.fromList([kGossipTag, ...syncFrameBytes]);

/// Splits an inbound data-channel message into whether it's a control message and
/// the body after the tag. An untagged/empty message is treated as gossip.
({bool isControl, Uint8List body}) splitFrame(Uint8List message) {
  if (message.isEmpty) return (isControl: false, body: message);
  return (
    isControl: message.first == kControlTag,
    body: Uint8List.sublistView(message, 1),
  );
}
