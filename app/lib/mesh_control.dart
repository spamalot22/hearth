// SPDX-License-Identifier: AGPL-3.0-or-later
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
        'contacts_online' => ContactsOnlineControl(
          ((json['peers'] as List?) ?? const []).cast<String>(),
        ),
        'version' => VersionControl(
          version: json['version'] as String? ?? '',
          manifest: ((json['manifest'] as Map?) ?? const {})
              .cast<String, Object?>(),
        ),
        'typing' => TypingControl(typing: json['typing'] as bool? ?? false),
        'soundboard' => SoundboardControl(blob: json['blob'] as String? ?? ''),
        'screen' => ScreenShareControl(
          sharer: json['sharer'] as String? ?? '',
          active: json['active'] as bool? ?? false,
        ),
        'youtube' => YoutubeControl(
          host: json['host'] as String? ?? '',
          videoId: json['video'] as String? ?? '',
          playing: json['playing'] as bool? ?? false,
          position: (json['pos'] as num?)?.toDouble() ?? 0,
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

/// "These contacts of mine are online right now" — cross-channel peer discovery.
/// Sent periodically to connected peers. The receiver checks if any listed pubkeys
/// are their own contacts and, if so, can route signalling through the sender to
/// reach them without the relay.
class ContactsOnlineControl extends MeshControl {
  const ContactsOnlineControl(this.peers);

  final List<String>
  peers; // pubkey hex of currently-connected peers (all channels)

  @override
  Map<String, Object?> toJson() => {'t': 'contacts_online', 'peers': peers};
}

/// "I'm running this version; here's the signed manifest I last verified" — P2P
/// version enforcement. Exchanged on connect. The receiver verifies the manifest's
/// Ed25519 signature against the hardcoded release public key; if valid and newer,
/// it triggers the update gate. A malicious peer can't forge a manifest (needs the
/// release private key) or replay an old one (seq is checked).
class VersionControl extends MeshControl {
  const VersionControl({required this.version, required this.manifest});

  /// The sender's running app version.
  final String version;

  /// The full signed release manifest (version, seq, assets, sig). The receiver
  /// verifies this independently — trusting the signature, not the peer.
  final Map<String, Object?> manifest;

  @override
  Map<String, Object?> toJson() => {
    't': 'version',
    'version': version,
    'manifest': manifest,
  };
}

/// "I started/stopped typing" — lightweight presence indicator sent over the
/// data channel. The UI shows "X is typing..." for a few seconds.
class TypingControl extends MeshControl {
  const TypingControl({required this.typing});

  final bool typing;

  @override
  Map<String, Object?> toJson() => {'t': 'typing', 'typing': typing};
}

/// "Play this soundboard clip" — sent over the voice mesh so all voice
/// participants play the referenced blob locally.
class SoundboardControl extends MeshControl {
  const SoundboardControl({required this.blob});

  final String blob;

  @override
  Map<String, Object?> toJson() => {'t': 'soundboard', 'blob': blob};
}

/// "I started/stopped sharing my screen" — sent over the voice mesh so every
/// participant knows to join (or drop) my per-sharer screen mesh
/// (`screen:<channelId>:<sharer>`), which carries the screen-share video. Per-
/// sharer namespacing lets several people share at once, each an independent
/// mesh, with no mid-call renegotiation.
class ScreenShareControl extends MeshControl {
  const ScreenShareControl({required this.sharer, required this.active});

  /// The sharer's pubkey hex — names the screen mesh viewers should join.
  final String sharer;

  /// Whether the share just started (true) or stopped (false).
  final bool active;

  @override
  Map<String, Object?> toJson() => {
    't': 'screen',
    'sharer': sharer,
    'active': active,
  };
}

/// "Here's the shared watch-party state" — a synchronised YouTube player driven
/// over the voice mesh. Only the [host] (the member who started the video)
/// broadcasts these; everyone else follows. [videoId] empty means the party was
/// closed. [position] is the host's playback time in seconds, sent on each
/// play/pause/seek and as a periodic heartbeat so followers can correct drift.
class YoutubeControl extends MeshControl {
  const YoutubeControl({
    required this.host,
    required this.videoId,
    required this.playing,
    required this.position,
  });

  /// The host's pubkey hex (the DJ whose playback everyone follows).
  final String host;

  /// The YouTube video id, or '' when the party is closed.
  final String videoId;

  /// Whether the host is playing (true) or paused (false).
  final bool playing;

  /// The host's current playback position, in seconds.
  final double position;

  @override
  Map<String, Object?> toJson() => {
    't': 'youtube',
    'host': host,
    'video': videoId,
    'playing': playing,
    'pos': position,
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
