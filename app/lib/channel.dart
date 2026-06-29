// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:core/core.dart';

import 'candidate_cache.dart';
import 'content.dart';
import 'mesh_control.dart';
import 'message_storage_hive.dart';
import 'update_checker.dart';
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
    this.blobStore,
    this._mesh,
    this._updatesSub,
    this._peersSub,
    this._blobSub,
    this._relayCourier,
  );

  final String channelId;
  final MessageRepository repository;
  final SyncEngine engine;
  final ChannelCipher cipher;
  final BlobStore? blobStore;

  /// The DM partner's key, or null for a group channel.
  final List<int>? peerPubkey;

  final WebRtcMesh? _mesh;
  final StreamSubscription<void> _updatesSub;
  final StreamSubscription<FrameChannel>? _peersSub;
  final StreamSubscription<String>? _blobSub;
  final RelayTransport? _relayCourier;
  final Map<String, Content> _content = {};
  final Map<String, Uint8List> _blobs = {};
  final Set<String> _requested = {};
  StreamSubscription<Message>? _courierSub;

  bool get isDm => peerPubkey != null;

  /// The underlying WebRTC mesh (for peer count / connectivity status).
  WebRtcMesh? get mesh => _mesh;

  static Future<ChannelSession> open({
    required String channelId,
    required Identity identity,
    required Uri relayUrl,
    List<Uri> fallbackUrls = const [],
    required bool live,
    required void Function() onUpdate,
    required ChannelCipher cipher,
    required BlobStore? blobStore,
    CandidateCache? candidateCache,
    List<int>? peerPubkey,
    void Function()? onPeerConnected,
    void Function(String fromHex, List<String> peers)? onContactsOnline,
    void Function(Map<String, Object?> manifest)? onVersionControl,
    void Function(String peerHex, bool typing)? onTyping,
    void Function(String fromHex, String channelId, MeshControl control)?
    onInference,
  }) async {
    final storage = live
        ? await HiveMessageStorage.open(channelId)
        : InMemoryMessageStorage();
    final repository = MessageRepository(storage);
    await repository.load();
    final engine = SyncEngine(repository, channelId, blobStore: blobStore);
    final updatesSub = engine.updates.listen((_) => onUpdate());
    // A fetched blob arriving just triggers a refresh; refreshContent loads it
    // from the store.
    final blobSub = engine.blobArrived.listen((_) => onUpdate());

    WebRtcMesh? mesh;
    StreamSubscription<FrameChannel>? peersSub;
    RelayTransport? courier;
    if (live) {
      mesh = WebRtcMesh(
        baseUrl: relayUrl,
        fallbackUrls: fallbackUrls,
        channel: channelId,
        identity: identity,
        candidateCache: candidateCache,
        onPeerLeft: (_) {
          // Resume relay polling when the last P2P peer drops.
          if (mesh?.peers.isEmpty ?? true) courier?.resume();
          onUpdate(); // Refresh UI so member online status updates.
        },
        onControl: (fromHex, control) {
          if (control is ContactsOnlineControl) {
            onContactsOnline?.call(fromHex, control.peers);
          } else if (control is VersionControl) {
            onVersionControl?.call(control.manifest);
          } else if (control is TypingControl) {
            onTyping?.call(fromHex, control.typing);
          } else if (control is InferenceRequest ||
              control is InferenceResponse) {
            onInference?.call(fromHex, channelId, control);
          } else if (control is VoicePresenceControl) {
            onInference?.call(fromHex, channelId, control);
          }
        },
      );
      peersSub = mesh.peerConnected.listen((peer) {
        engine.addPeer(peer);
        courier?.pause(); // P2P is live — no need to poll the relay.
        onPeerConnected?.call();
        onUpdate(); // Refresh UI so new peer appears in member list.
      });

      // Relay courier: polls the relay for messages that arrived while we were
      // offline (or couldn't P2P-connect). Polls slowly — it's a fallback, not
      // the primary path.
      courier = RelayTransport(
        baseUrl: relayUrl,
        channel: channelId,
        pollInterval: const Duration(seconds: 10),
        tokenProvider: () => mesh?.authToken,
        baseUrlProvider: () => mesh?.activeUrl ?? relayUrl,
      );
    }

    final session = ChannelSession._(
      channelId,
      repository,
      engine,
      cipher,
      peerPubkey,
      blobStore,
      mesh,
      updatesSub,
      peersSub,
      blobSub,
      courier,
    );

    // Feed relay-couriered messages into the sync engine (deduplication is
    // handled by the repository — add() returns false for known ids).
    if (courier != null) {
      session._courierSub = courier.incoming.listen((message) {
        unawaited(engine.publish(message));
      });
    }

    return session;
  }

  /// Encrypts [content] for sending.
  Future<Uint8List> encodePayload(Content content) =>
      cipher.encrypt(content.encode());

  /// Broadcasts typing state to all connected peers in this channel.
  void sendTyping(bool typing) {
    final mesh = _mesh;
    if (mesh == null) return;
    for (final peerHex in mesh.connections.keys) {
      mesh.sendControlTo(peerHex, TypingControl(typing: typing));
    }
  }

  /// Broadcasts a control frame to all connected peers in this channel.
  void broadcast(MeshControl control) {
    final mesh = _mesh;
    if (mesh == null) return;
    for (final peerHex in mesh.connections.keys) {
      mesh.sendControlTo(peerHex, control);
    }
  }

  /// Publishes a message to the P2P mesh AND the relay courier (best-effort).
  /// The relay copy ensures offline peers can pick it up later.
  Future<void> publish(Message message) async {
    await engine.publish(message);
    // Best-effort relay send — failure is fine (relay might be down, or peer
    // will get it via P2P later).
    try {
      await _relayCourier?.send(message);
    } catch (_) {}
  }

  /// Decrypts + parses any not-yet-cached messages, then makes sure any blob
  /// (sticker/sound) they reference is fetched into the local cache.
  Future<void> refreshContent() async {
    for (final message in repository.ordered()) {
      if (!_content.containsKey(message.idHex)) {
        try {
          _content[message.idHex] = parseContent(
            await cipher.decrypt(message.payload),
          );
        } catch (_) {
          _content[message.idHex] = const TextContent('🔒 unreadable');
        }
      }
      await _ensureBlob(_content[message.idHex]!);
    }
  }

  /// Loads a referenced blob from the store, or asks peers for it once.
  Future<void> _ensureBlob(Content content) async {
    final hash = switch (content) {
      GifContent(:final blob) => blob,
      StickerContent(:final blob) => blob,
      SoundContent(:final blob) => blob,
      FileContent(:final blob) => blob,
      _ => null,
    };
    final store = blobStore;
    if (hash == null || hash.isEmpty || store == null) return;
    if (_blobs.containsKey(hash)) return;
    final bytes = await store.get(hash);
    if (bytes != null) {
      _blobs[hash] = bytes;
    } else if (_requested.add(hash)) {
      engine.requestBlob(hash);
    }
  }

  /// The (decrypted, parsed) content of [message].
  Content contentOf(Message message) =>
      _content[message.idHex] ?? const TextContent('…');

  /// The bytes of a held blob (sticker/sound), or null if not yet fetched.
  Uint8List? blobOf(String hash) => _blobs[hash];

  Future<void> close() async {
    await _updatesSub.cancel();
    await _peersSub?.cancel();
    await _blobSub?.cancel();
    await _courierSub?.cancel();
    await _mesh?.close();
    await _relayCourier?.close();
    await engine.close();
  }

  /// Forces the mesh to re-announce to the relay (e.g. after relay recovery).
  void reconnect() => _mesh?.forceAnnounce();
}

/// Owns every open [ChannelSession] and tracks which one is active. Channels are
/// kept running so messages keep arriving in the background; the UI binds to
/// [active].
class ChannelManager {
  ChannelManager({
    required this.identity,
    required this.relayUrl,
    this.fallbackUrls = const [],
    required this.live,
    required this.onUpdate,
    this.blobStore,
    this.candidateCache,
    this.onBackgroundMessage,
    this.onForceUpdate,
    this.onInference,
  });

  final Identity identity;
  final Uri relayUrl;
  final List<Uri> fallbackUrls;
  final bool live;
  final void Function() onUpdate;
  final BlobStore? blobStore;
  final CandidateCache? candidateCache;

  /// Fired with a channelId when a message arrives in a non-active channel.
  final void Function(String channelId)? onBackgroundMessage;

  /// Fired when a peer provides a valid signed manifest proving a newer version
  /// exists. The app should show the update gate.
  final void Function(UpdateInfo info)? onForceUpdate;

  /// Fired when an inference request or response arrives from a channel's mesh,
  /// tagged with that channelId so the response goes back to the right channel.
  final void Function(String fromHex, String channelId, MeshControl control)?
  onInference;

  final Map<String, ChannelSession> _sessions = {};
  String? _activeId;

  /// Peers currently typing, per channel: channelId -> set of peerHex.
  final Map<String, Set<String>> typingPeers = {};

  Iterable<ChannelSession> get sessions => _sessions.values;
  String? get activeId => _activeId;
  ChannelSession? get active => _activeId == null ? null : _sessions[_activeId];

  /// Tells each connected peer which *other* peers are online **in that same
  /// channel**, so a channel's mesh can re-knit itself without the relay — two
  /// peers that both reach us but not each other get introduced and connect.
  ///
  /// Deliberately scoped to the shared channel: we never reveal who we're
  /// connected to in *other* channels, so a peer can't map our cross-channel
  /// social graph. This costs nothing — the receiver only acts on peers it
  /// already shares a channel with, and bridging only works within a channel
  /// we're both in, so the cross-channel spillover was leak, not function.
  void _broadcastContactsOnline() {
    for (final session in _sessions.values) {
      final mesh = session._mesh;
      if (mesh == null) continue;
      final peersHere = mesh.connections.keys.toList();
      for (final peerHex in peersHere) {
        final others = peersHere.where((p) => p != peerHex).toList();
        if (others.isNotEmpty) {
          mesh.sendControlTo(peerHex, ContactsOnlineControl(others));
        }
      }
    }
  }

  /// Handles a contacts-online message from a peer: if any listed pubkey is in a
  /// channel we have but aren't connected to, try reaching them through the
  /// sender's mesh. Capped to prevent a malicious peer from flooding us with
  /// connection attempts.
  void _handleContactsOnline(String fromHex, List<String> onlinePeers) {
    // Cap to 20 peers per message to prevent amplification attacks.
    final capped = onlinePeers.take(20);
    for (final peerHex in capped) {
      // Only reach for a peer we already know in some channel (candidate cache)
      // and aren't already connected to — punch through the sender's mesh.
      for (final session in _sessions.values) {
        final mesh = session._mesh;
        if (mesh == null) continue;
        final cached = candidateCache?.knownPeers(session.channelId) ?? {};
        if (cached.contains(peerHex) &&
            !mesh.connections.containsKey(peerHex)) {
          mesh.maybeInitiateVia(peerHex);
        }
      }
    }
  }

  /// Handles a peer-provided version manifest. Verifies the signature
  /// independently — the peer is just a courier, not a trust source.
  Future<void> _handleVersionControl(Map<String, Object?> manifest) async {
    if (releasePublicKeyHex.isEmpty || appVersion == 'dev') return;
    final version = manifest['version'] as String?;
    final seq = manifest['seq'] as int?;
    final sig = manifest['sig'] as String?;
    if (version == null || seq == null || sig == null) return;
    if (version == appVersion) return; // already up to date

    // Verify signature against the hardcoded release key.
    final payload = Map<String, Object?>.from(manifest)..remove('sig');
    final payloadBytes = utf8.encode(jsonEncode(payload));
    final valid = await Identity.verifySignature(
      payloadBytes,
      signature: _hexDecode(sig),
      publicKey: _hexDecode(releasePublicKeyHex),
    );
    if (!valid) return; // forged manifest — ignore

    // Downgrade protection: reject seq ≤ our persisted floor.
    final lastSeq = await getLastUpdateSeq();
    if (seq <= lastSeq) return;

    // Also propagate the manifest to our meshes so we relay it onward.
    for (final session in _sessions.values) {
      session._mesh?.versionManifest = manifest;
    }

    final assets = manifest['assets'] as Map<String, dynamic>? ?? {};
    onForceUpdate?.call(UpdateInfo(version: version, seq: seq, assets: assets));
  }

  void _handleTyping(String channelId, String peerHex, bool typing) {
    final set = typingPeers[channelId] ??= {};
    if (typing) {
      set.add(peerHex);
    } else {
      set.remove(peerHex);
    }
    onUpdate();
  }

  /// Opens (or focuses) a group channel given its [id] and encryption [key].
  Future<void> openGroup(String id, Uint8List key) async {
    if (!_sessions.containsKey(id)) {
      _sessions[id] = await ChannelSession.open(
        channelId: id,
        identity: identity,
        relayUrl: relayUrl,
        fallbackUrls: fallbackUrls,
        live: live,
        onUpdate: () => _onSessionUpdate(id),
        cipher: GroupChannelCipher(key),
        blobStore: blobStore,
        candidateCache: candidateCache,
        onPeerConnected: _broadcastContactsOnline,
        onContactsOnline: _handleContactsOnline,
        onVersionControl: _handleVersionControl,
        onTyping: (peerHex, typing) => _handleTyping(id, peerHex, typing),
        onInference: onInference,
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
        fallbackUrls: fallbackUrls,
        live: live,
        onUpdate: () => _onSessionUpdate(id),
        cipher: DmChannelCipher(identity, peerPubkey),
        peerPubkey: peerPubkey,
        blobStore: blobStore,
        candidateCache: candidateCache,
        onPeerConnected: _broadcastContactsOnline,
        onContactsOnline: _handleContactsOnline,
        onVersionControl: _handleVersionControl,
        onTyping: (peerHex, typing) => _handleTyping(id, peerHex, typing),
        onInference: onInference,
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

  void _onSessionUpdate(String channelId) {
    onUpdate();
    if (channelId != _activeId) {
      onBackgroundMessage?.call(channelId);
    }
  }

  /// Closes and forgets one channel, switching the active channel to another (or
  /// none). Callers also drop it from the registry.
  Future<void> leave(String channelId) async {
    final session = _sessions.remove(channelId);
    if (session == null) return;
    if (_activeId == channelId) {
      _activeId = _sessions.keys.isEmpty ? null : _sessions.keys.first;
    }
    await session.close();
    onUpdate();
  }

  Future<void> close() async {
    for (final session in _sessions.values.toList()) {
      await session.close();
    }
    _sessions.clear();
  }

  /// Kicks all sessions to re-announce to the relay (e.g. after relay recovers).
  void reconnect() {
    for (final session in _sessions.values) {
      session.reconnect();
    }
  }
}

List<int> _hexDecode(String h) {
  final out = <int>[];
  for (var i = 0; i < h.length; i += 2) {
    out.add(int.parse(h.substring(i, i + 2), radix: 16));
  }
  return out;
}
