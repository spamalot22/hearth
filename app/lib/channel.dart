import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:core/core.dart';

import 'content.dart';
import 'message_storage_hive.dart';
import 'webrtc_mesh.dart';

/// Encrypts/decrypts a channel's payloads — every channel is encrypted now. A
/// group channel uses its shared key ([GroupChannelCipher]); a DM uses the
/// pairwise key ([DmChannelCipher]).
abstract class ChannelCipher {
  Future<Uint8List> encrypt(List<int> plaintext);
  Future<Uint8List> decrypt(Uint8List boxed);
}

class GroupChannelCipher implements ChannelCipher {
  GroupChannelCipher(this._key);

  final Uint8List _key;

  @override
  Future<Uint8List> encrypt(List<int> plaintext) =>
      GroupCipher.encrypt(plaintext, key: _key);

  @override
  Future<Uint8List> decrypt(Uint8List boxed) =>
      GroupCipher.decrypt(boxed, key: _key);
}

class DmChannelCipher implements ChannelCipher {
  DmChannelCipher(this._self, this._peer);

  final Identity _self;
  final List<int> _peer;

  @override
  Future<Uint8List> encrypt(List<int> plaintext) =>
      PairBox.encrypt(plaintext, self: _self, peerEd25519PublicKey: _peer);

  @override
  Future<Uint8List> decrypt(Uint8List boxed) =>
      PairBox.decrypt(boxed, self: _self, peerEd25519PublicKey: _peer);
}

/// Deterministic id for the DM channel between two identities (a hash of the
/// sorted pubkeys), so both sides derive the same one.
Future<String> dmChannelId(String aHex, String bHex) async {
  final pair = [aHex, bHex]..sort();
  final digest = await sha256Digest(utf8.encode(pair.join('|')));
  return 'dm-${hex.encode(digest).substring(0, 24)}';
}

/// One channel's live stack: its durable DAG, gossip [SyncEngine], the mesh that
/// feeds peers in, and the [cipher] for its (always-encrypted) payloads. A DM
/// also carries [peerPubkey], for display; a group channel does not.
class ChannelSession {
  ChannelSession._(
    this.channelId,
    this.repository,
    this.engine,
    this.cipher,
    this.peerPubkey,
    this._mesh,
    this._updatesSub,
    this._peersSub,
  );

  final String channelId;
  final MessageRepository repository;
  final SyncEngine engine;
  final ChannelCipher cipher;

  /// The DM partner's key, or null for a group channel.
  final List<int>? peerPubkey;

  final WebRtcMesh? _mesh;
  final StreamSubscription<void> _updatesSub;
  final StreamSubscription<FrameChannel>? _peersSub;
  final Map<String, Content> _content = {};

  bool get isDm => peerPubkey != null;

  static Future<ChannelSession> open({
    required String channelId,
    required Identity identity,
    required Uri relayUrl,
    required bool live,
    required void Function() onUpdate,
    required ChannelCipher cipher,
    List<int>? peerPubkey,
  }) async {
    final storage = live
        ? await HiveMessageStorage.open(channelId)
        : InMemoryMessageStorage();
    final repository = MessageRepository(storage);
    await repository.load();
    final engine = SyncEngine(repository, channelId);
    final updatesSub = engine.updates.listen((_) => onUpdate());

    WebRtcMesh? mesh;
    StreamSubscription<FrameChannel>? peersSub;
    if (live) {
      mesh = WebRtcMesh(
        baseUrl: relayUrl,
        channel: channelId,
        identity: identity,
      );
      peersSub = mesh.peerConnected.listen(engine.addPeer);
    }

    return ChannelSession._(
      channelId,
      repository,
      engine,
      cipher,
      peerPubkey,
      mesh,
      updatesSub,
      peersSub,
    );
  }

  /// Encrypts [content] for sending.
  Future<Uint8List> encodePayload(Content content) =>
      cipher.encrypt(content.encode());

  /// Decrypts + parses any not-yet-cached messages into the display cache.
  Future<void> refreshContent() async {
    for (final message in repository.ordered()) {
      if (_content.containsKey(message.idHex)) continue;
      try {
        _content[message.idHex] = parseContent(
          await cipher.decrypt(message.payload),
        );
      } catch (_) {
        _content[message.idHex] = const TextContent('🔒 unreadable');
      }
    }
  }

  /// The (decrypted, parsed) content of [message].
  Content contentOf(Message message) =>
      _content[message.idHex] ?? const TextContent('…');

  Future<void> close() async {
    await _updatesSub.cancel();
    await _peersSub?.cancel();
    await _mesh?.close();
    await engine.close();
  }
}

/// Owns every open [ChannelSession] and tracks which one is active. Channels are
/// kept running so messages keep arriving in the background; the UI binds to
/// [active].
class ChannelManager {
  ChannelManager({
    required this.identity,
    required this.relayUrl,
    required this.live,
    required this.onUpdate,
  });

  final Identity identity;
  final Uri relayUrl;
  final bool live;
  final void Function() onUpdate;

  final Map<String, ChannelSession> _sessions = {};
  String? _activeId;

  Iterable<ChannelSession> get sessions => _sessions.values;
  String? get activeId => _activeId;
  ChannelSession? get active => _activeId == null ? null : _sessions[_activeId];

  /// Opens (or focuses) a group channel given its [id] and encryption [key].
  Future<void> openGroup(String id, Uint8List key) async {
    if (!_sessions.containsKey(id)) {
      _sessions[id] = await ChannelSession.open(
        channelId: id,
        identity: identity,
        relayUrl: relayUrl,
        live: live,
        onUpdate: onUpdate,
        cipher: GroupChannelCipher(key),
      );
    }
    _activeId = id;
    onUpdate();
  }

  /// Opens (or focuses) the encrypted DM with [peerPubkey].
  Future<void> openDm(List<int> peerPubkey) async {
    final id = await dmChannelId(identity.publicKeyHex, hex.encode(peerPubkey));
    if (!_sessions.containsKey(id)) {
      _sessions[id] = await ChannelSession.open(
        channelId: id,
        identity: identity,
        relayUrl: relayUrl,
        live: live,
        onUpdate: onUpdate,
        cipher: DmChannelCipher(identity, peerPubkey),
        peerPubkey: peerPubkey,
      );
    }
    _activeId = id;
    onUpdate();
  }

  void activate(String channelId) {
    if (_sessions.containsKey(channelId)) {
      _activeId = channelId;
      onUpdate();
    }
  }

  Future<void> close() async {
    for (final session in _sessions.values.toList()) {
      await session.close();
    }
    _sessions.clear();
  }
}
