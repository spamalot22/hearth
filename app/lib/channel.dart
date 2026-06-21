import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:core/core.dart';

import 'message_storage_hive.dart';
import 'webrtc_mesh.dart';

/// Deterministic id for the DM channel between two identities — a hash of their
/// sorted pubkeys, so both compute the same one. Anyone who knows both keys can
/// derive it (the *pairing* is guessable), but the content is [PairBox]-encrypted.
Future<String> dmChannelId(String aHex, String bHex) async {
  final pair = [aHex, bHex]..sort();
  final digest = await sha256Digest(utf8.encode(pair.join('|')));
  return 'dm-${hex.encode(digest).substring(0, 24)}';
}

/// One channel's live stack: its durable DAG ([MessageRepository]), gossip
/// [SyncEngine], and — when running for real — the [WebRtcMesh] that feeds peers
/// in. A DM channel additionally carries [peerPubkey] and encrypts/decrypts its
/// payloads with [PairBox]; a group channel is plaintext.
class ChannelSession {
  ChannelSession._(
    this.channelId,
    this.repository,
    this.engine,
    this._identity,
    this.peerPubkey,
    this._mesh,
    this._updatesSub,
    this._peersSub,
  );

  final String channelId;
  final MessageRepository repository;
  final SyncEngine engine;
  final Identity _identity;

  /// The DM partner's Ed25519 key, or null for a (plaintext) group channel.
  final List<int>? peerPubkey;

  final WebRtcMesh? _mesh;
  final StreamSubscription<void> _updatesSub;
  final StreamSubscription<FrameChannel>? _peersSub;
  final Map<String, String> _plaintext = {};

  bool get isDm => peerPubkey != null;

  /// Opens a channel. With [live] false (widget tests) storage is in-memory and
  /// no mesh runs. [peerPubkey] makes it an encrypted DM. [onUpdate] fires when
  /// this channel stores a message.
  static Future<ChannelSession> open({
    required String channelId,
    required Identity identity,
    required Uri relayUrl,
    required bool live,
    required void Function() onUpdate,
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
      identity,
      peerPubkey,
      mesh,
      updatesSub,
      peersSub,
    );
  }

  /// Encodes [text] for sending — PairBox-encrypted in a DM, plain UTF-8 in a
  /// group channel.
  Future<Uint8List> encodePayload(String text) async {
    final bytes = Uint8List.fromList(utf8.encode(text));
    final peer = peerPubkey;
    return peer == null
        ? bytes
        : PairBox.encrypt(bytes, self: _identity, peerEd25519PublicKey: peer);
  }

  /// Decrypts any not-yet-cached DM messages into the display cache. No-op for a
  /// group channel.
  Future<void> refreshPlaintext() async {
    final peer = peerPubkey;
    if (peer == null) return;
    for (final message in repository.ordered()) {
      if (_plaintext.containsKey(message.idHex)) continue;
      try {
        final clear = await PairBox.decrypt(
          message.payload,
          self: _identity,
          peerEd25519PublicKey: peer,
        );
        _plaintext[message.idHex] = utf8.decode(clear);
      } catch (_) {
        _plaintext[message.idHex] = '🔒 unreadable';
      }
    }
  }

  /// Display text for [message]: decrypted in a DM, the raw text in a group.
  String textOf(Message message) => peerPubkey == null
      ? utf8.decode(message.payload)
      : (_plaintext[message.idHex] ?? '…');

  Future<void> close() async {
    await _updatesSub.cancel();
    await _peersSub?.cancel();
    await _mesh?.close();
    await engine.close();
  }
}

/// Owns every open [ChannelSession] and tracks which one is active. Channels are
/// opened lazily and kept running (so messages keep arriving in the background);
/// the UI binds to [active].
class ChannelManager {
  ChannelManager({
    required this.identity,
    required this.relayUrl,
    required this.live,
    required this.onUpdate,
  });

  final Identity identity;
  final Uri relayUrl;

  /// False in widget tests — keeps storage in-memory and the mesh off.
  final bool live;

  /// Called when a channel updates or the active selection changes.
  final void Function() onUpdate;

  final Map<String, ChannelSession> _sessions = {};
  String? _activeId;

  Iterable<String> get channelIds => _sessions.keys;
  Iterable<ChannelSession> get sessions => _sessions.values;
  String? get activeId => _activeId;
  ChannelSession? get active => _activeId == null ? null : _sessions[_activeId];

  /// Opens [channelId] if it isn't already open, then makes it active.
  Future<void> open(String channelId) async {
    if (!_sessions.containsKey(channelId)) {
      _sessions[channelId] = await ChannelSession.open(
        channelId: channelId,
        identity: identity,
        relayUrl: relayUrl,
        live: live,
        onUpdate: onUpdate,
      );
    }
    _activeId = channelId;
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
        peerPubkey: peerPubkey,
      );
    }
    _activeId = id;
    onUpdate();
  }

  /// Switches the active channel to an already-open [channelId].
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
