import 'dart:convert';

/// Messages the mesh sends peer-to-peer over the data channel *alongside* the
/// gossip `SyncFrame`s, to wean connectivity off the relay: once you hold one live
/// link you can learn of other peers and relay signalling through it, so the relay
/// is only needed for a true cold start.
///
/// The data channel carries text, so each message gets a one-character tag so the
/// two streams don't collide: [kGossipTag] = a gossip `SyncFrame` (its JSON body),
/// [kControlTag] = a JSON-encoded [MeshControl]. A `SyncFrame` is JSON (`{…}`), so an
/// untagged message is safely treated as legacy gossip from a peer on an older build.
const String kGossipTag = '0';
const String kControlTag = '1';

sealed class MeshControl {
  const MeshControl();

  Map<String, Object?> toJson();

  /// The data-channel text for this control message: control tag + JSON.
  String encode() => '$kControlTag${jsonEncode(toJson())}';

  /// Parses a control body (the text after the tag), or null if malformed.
  static MeshControl? decodeBody(String body) {
    try {
      final json = (jsonDecode(body) as Map).cast<String, Object?>();
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

/// Tags a gossip frame's text for the data channel.
String wrapGossip(String syncFrameText) => '$kGossipTag$syncFrameText';

/// Splits an inbound data-channel text message into whether it's a control message
/// and the body after the tag. An untagged message (older peer) is treated as
/// gossip — safe because a `SyncFrame` is JSON, never starting with a tag char.
({bool isControl, String body}) splitFrame(String message) {
  if (message.isEmpty) return (isControl: false, body: message);
  return switch (message[0]) {
    kControlTag => (isControl: true, body: message.substring(1)),
    kGossipTag => (isControl: false, body: message.substring(1)),
    _ => (isControl: false, body: message), // untagged legacy gossip
  };
}
