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
  Future<Uint8List> decrypt(Uint8List boxed, {Uint8List? senderDevice});
}

class GroupChannelCipher implements ChannelCipher {
  GroupChannelCipher(this._key);

  final Uint8List _key;

  @override
  Future<Uint8List> encrypt(List<int> plaintext) =>
      GroupCipher.encrypt(plaintext, key: _key);

  @override
  Future<Uint8List> decrypt(Uint8List boxed, {Uint8List? senderDevice}) =>
      GroupCipher.decrypt(boxed, key: _key);
}

/// Per-device DM cipher. Encrypts to each of the peer's active device keys
/// (via `MultiDeviceBox`) and includes our own device keys for self-read.
/// Requires both peers to have published a device bundle.
class MultiDeviceDmCipher implements ChannelCipher {
  MultiDeviceDmCipher({
    required this.selfDevice,
    required this.peerBundleLookup,
    required this.ownDeviceKeys,
  });

  /// This device's identity (for ECDH in MultiDeviceBox).
  final Identity selfDevice;

  /// Looks up the peer's current device bundle. If null, the peer hasn't
  /// published one yet and DMs can't be encrypted to them.
  final DeviceBundle? Function() peerBundleLookup;

  /// Our own active device keys (so we can encrypt to ourselves for self-read
  /// on other devices).
  final List<Uint8List> Function() ownDeviceKeys;

  @override
  Future<Uint8List> encrypt(List<int> plaintext) async {
    final peerBundle = peerBundleLookup();
    if (peerBundle == null) {
      throw StateError(
        'cannot encrypt DM: peer has no device bundle (they must update)',
      );
    }
    // Encrypt to all peer devices + our own devices.
    final recipientKeys = <Uint8List>[
      ...peerBundle.devices,
      ...ownDeviceKeys(),
    ];
    final seen = <String>{};
    final deduped = <Uint8List>[];
    for (final k in recipientKeys) {
      if (seen.add(hex.encode(k))) deduped.add(k);
    }
    return MultiDeviceBox.encrypt(
      plaintext,
      senderDevice: selfDevice,
      recipientDeviceKeys: deduped,
    );
  }

  @override
  Future<Uint8List> decrypt(Uint8List boxed, {Uint8List? senderDevice}) async {
    // Use sender device key directly when available (O(1)).
    if (senderDevice != null) {
      try {
        return await MultiDeviceBox.decrypt(
          boxed,
          recipientDevice: selfDevice,
          senderDeviceEd: senderDevice,
        );
      } catch (_) {
        // Stale sender device — try others below.
      }
    }
    // Fallback: iterate peer bundle devices.
    final peerBundle = peerBundleLookup();
    if (peerBundle != null) {
      for (final dev in peerBundle.devices) {
        try {
          return await MultiDeviceBox.decrypt(
            boxed,
            recipientDevice: selfDevice,
            senderDeviceEd: dev,
          );
        } catch (_) {
          continue;
        }
      }
    }
    // Try our own devices (self-sent message from another device).
    for (final ownKey in ownDeviceKeys()) {
      try {
        return await MultiDeviceBox.decrypt(
          boxed,
          recipientDevice: selfDevice,
          senderDeviceEd: ownKey,
        );
      } catch (_) {
        continue;
      }
    }
    throw const FormatException('cannot decrypt DM (no matching device key)');
  }
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
  final Map<String, Content> _content = <String, Content>{};
  static const int _maxContentCache = 5000;
  bool _refreshing = false;
  bool _refreshDirty = false;
  final Map<String, Uint8List> _blobs = {};
  final Set<String> _requested = {};
  // Device pubkey hex → root pubkey hex, populated from device-signed messages.
  final Map<String, String> _deviceRoots = {};
  // Certs seen from messages (for populating the device store).
  final Map<String, DeviceCert> _seenCerts = {};
  // Revision index, rebuilt by refreshContent: the winning (topologically last)
  // valid edit per target id, and the set of validly tombstoned ids. "Valid"
  // means the edit/delete author matches the target's author — an edit from
  // anyone else is ignored, so only you can rewrite or remove your messages.
  final Map<String, EditContent> _edits = {};
  final Set<String> _deleted = {};
  // Validation verdicts by revision-message id. Once valid, always valid
  // (authors are immutable); invalid may flip to valid when the target syncs,
  // so only positives are cached.
  final Set<String> _validRevisions = {};
  StreamSubscription<Message>? _courierSub;

  bool get isDm => peerPubkey != null;

  /// Device pubkey hex → root pubkey hex, learned from device-signed messages.
  Map<String, String> get deviceRoots => _deviceRoots;

  /// Certs seen from device-signed messages (keyed by device hex).
  Map<String, DeviceCert> get seenCerts => _seenCerts;

  /// The underlying WebRTC mesh (for peer count / connectivity status).
  WebRtcMesh? get mesh => _mesh;

  /// The relay poll cursor (seq) the courier has caught up to, or null if this
  /// session has no live courier. Used to seed the background poller's baseline.
  int? get relaySince => _relayCourier?.since;

  static Future<ChannelSession> open({
    required String channelId,
    required Identity identity,
    Identity? meshIdentity,
    required Uri relayUrl,
    List<Uri> fallbackUrls = const [],
    required bool live,
    required void Function() onUpdate,
    required ChannelCipher cipher,
    required BlobStore? blobStore,
    bool Function(String deviceKeyHex)? isDeviceRevoked,
    CandidateCache? candidateCache,
    List<int>? peerPubkey,
    void Function()? onPeerConnected,
    void Function(String peerHex)? onPeerConnectedHex,
    void Function(String fromHex, List<String> peers)? onContactsOnline,
    void Function(Map<String, Object?> manifest)? onVersionControl,
    void Function(String peerHex, bool typing)? onTyping,
    bool Function(String peerHex)? peerAllowed,
    void Function(String fromHex, String channelId, MeshControl control)?
    onInference,
  }) async {
    final storage = live
        ? await HiveMessageStorage.open(channelId)
        : InMemoryMessageStorage();
    final repository = MessageRepository(storage);
    await repository.load();
    final engine = SyncEngine(
      repository,
      channelId,
      blobStore: blobStore,
      isDeviceRevoked: isDeviceRevoked,
    );
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
        identity: meshIdentity ?? identity,
        candidateCache: candidateCache,
        peerAllowed: peerAllowed,
        onPeerConnectedHex: onPeerConnectedHex,
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
              control is InferenceResponse ||
              control is VoicePresenceControl ||
              control is DeviceRevocationControl ||
              control is ReadWatermarkControl) {
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

    // Feed relay-couriered messages into the sync engine — via receive() so
    // they're signature-verified (we don't trust the relay), same as P2P GIVEs.
    // Dedup is handled by the repository (add() returns false for known ids).
    if (courier != null) {
      session._courierSub = courier.incoming.listen((message) {
        unawaited(engine.receive(message));
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

  /// Decrypts + parses any not-yet-cached messages, makes sure any blob
  /// (sticker/sound) they reference is fetched into the local cache, and
  /// rebuilds the edit/tombstone revision index.
  Future<void> refreshContent() async {
    // Prevent overlapping calls from clearing each other's revision index.
    // If a call arrives while refreshing, mark dirty and re-run after.
    if (_refreshing) {
      _refreshDirty = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _refreshDirty = false;
        await _refreshContentInner();
      } while (_refreshDirty);
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _refreshContentInner() async {
    _edits.clear();
    _deleted.clear();
    for (final message in repository.ordered()) {
      // Build device→root mapping from device-signed messages.
      if (message.device != null && message.cert != null) {
        final devHex = hex.encode(message.device!);
        _deviceRoots[devHex] = hex.encode(message.author);
        _seenCerts[devHex] = message.cert!;
      }
      if (!_content.containsKey(message.idHex)) {
        try {
          _content[message.idHex] = parseContent(
            await cipher.decrypt(message.payload, senderDevice: message.device),
          );
        } catch (_) {
          _content[message.idHex] = const TextContent('🔒 unreadable');
        }
        // Evict oldest entries if cache exceeds threshold. LinkedHashMap
        // preserves insertion order, so we remove from the front.
        while (_content.length > _maxContentCache) {
          _content.remove(_content.keys.first);
        }
      }
      final content = _content[message.idHex]!;
      await _ensureBlob(content);
      // ordered() is a deterministic topological sort, so overwriting here
      // makes the last valid edit the winner on every device.
      switch (content) {
        case EditContent(:final targetId):
          if (_validRevision(message, targetId)) _edits[targetId] = content;
        case DeleteContent(:final targetId):
          if (_validRevision(message, targetId)) _deleted.add(targetId);
        default:
          break;
      }
    }
  }

  /// True if [revision]'s target exists locally and shares its author — checked
  /// once per revision message, then cached (this runs on every refresh).
  bool _validRevision(Message revision, String targetIdHex) {
    if (_validRevisions.contains(revision.idHex)) return true;
    final target = repository.getByHex(targetIdHex);
    if (target == null || !_bytesEqual(target.author, revision.author)) {
      return false; // may flip to valid once the target syncs — don't cache
    }
    _validRevisions.add(revision.idHex);
    return true;
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// The winning edit for message [idHex], or null if it was never validly
  /// edited. Deletion trumps edits — check [isDeleted] first.
  EditContent? editOf(String idHex) => _edits[idHex];

  /// True if [idHex] carries a valid tombstone from its own author.
  bool isDeleted(String idHex) => _deleted.contains(idHex);

  /// Loads a referenced blob from the store, or asks peers for it once.
  Future<void> _ensureBlob(Content content) async {
    final hash = switch (content) {
      GifContent(:final blob) => blob,
      StickerContent(:final blob) => blob,
      SoundContent(:final blob) => blob,
      FileContent(:final blob) => blob,
      VoiceContent(:final blob) => blob,
      ProfileContent(:final avatar) => avatar,
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
    this.meshIdentity,
    required this.relayUrl,
    this.fallbackUrls = const [],
    required this.live,
    required this.onUpdate,
    this.blobStore,
    this.candidateCache,
    this.onBackgroundMessage,
    this.onForceUpdate,
    this.onInference,
    this.onDmConnected,
    this.isBlocked,
    this.isDeviceRevoked,
    this.peerBundleLookup,
    this.ownDeviceKeys,
    this.versionManifest,
  });

  final Identity identity;

  /// The device subkey used for mesh announce/signalling. When set, each device
  /// appears as a distinct node in the P2P mesh (concurrent multi-device).
  /// Falls back to [identity] (root) for pre-device-key compat.
  final Identity? meshIdentity;

  final Uri relayUrl;
  List<Uri> fallbackUrls;
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

  /// Fired with a peer's pubkey (hex) when a **DM** connects to them — used to
  /// retire a pending first-contact once it lands.
  final void Function(String peerHex)? onDmConnected;

  /// Whether a peer (hex) is blocked. When set, [openDm] refuses blocked peers,
  /// so a blocked DM never opens (and thus never receives/stores messages).
  final bool Function(String peerHex)? isBlocked;

  /// Whether a device key (hex) has been revoked. Passed to each channel's
  /// [SyncEngine] so messages from revoked devices are dropped on receipt.
  final bool Function(String deviceKeyHex)? isDeviceRevoked;

  /// Looks up a peer's device bundle by root hex. Used by MultiDeviceDmCipher.
  final DeviceBundle? Function(String rootHex)? peerBundleLookup;

  /// Returns this identity's active device keys (for self-encryption in DMs).
  final List<Uint8List> Function()? ownDeviceKeys;

  /// Last GitHub-verified release manifest, forwarded to connected peers.
  Map<String, Object?>? versionManifest;

  final Map<String, ChannelSession> _sessions = {};
  // DM ids currently being opened — guards the await window in [openDm] so two
  // concurrent opens for the same peer don't both build a session (leaking one).
  final Set<String> _opening = {};
  String? _activeId;

  /// Peers currently typing, per channel: channelId -> set of peerHex.
  final Map<String, Set<String>> typingPeers = {};

  /// Maps device pubkey hex → root pubkey hex. Populated from received messages
  /// that carry a device cert. Allows the UI to resolve a mesh peer's device key
  /// back to their root identity (for display name lookup, presence, etc.).
  final Map<String, String> deviceToRoot = {};

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
  /// independently — the peer is just a courier, not a trust source — through
  /// the *same* [verifyManifest] the GitHub-check path uses, so the two can't
  /// drift onto different signing formats.
  Future<void> _handleVersionControl(Map<String, Object?> manifest) async {
    if (releasePublicKeyHex.isEmpty || appVersion == 'dev') return;

    final info = await verifyManifest(
      manifest.cast<String, dynamic>(),
      releasePublicKeyHex,
    );
    if (info == null) return; // missing fields / forged
    if (!isNewerRelease(info.version, appVersion)) return;

    // Downgrade protection: reject seq ≤ our persisted floor.
    final lastSeq = await getLastUpdateSeq();
    if (info.seq <= lastSeq) return;

    // Also propagate the manifest to our meshes so we relay it onward.
    versionManifest = manifest;
    for (final session in _sessions.values) {
      session._mesh?.versionManifest = manifest;
    }

    onForceUpdate?.call(info);
  }

  void _handleTyping(String channelId, String peerHex, bool typing) {
    // Resolve device key to root identity for UI attribution.
    final resolved = deviceToRoot[peerHex] ?? peerHex;
    final set = typingPeers[channelId] ??= {};
    if (typing) {
      set.add(resolved);
    } else {
      set.remove(resolved);
    }
    onUpdate();
  }

  /// Opens (or focuses) a group channel given its [id] and encryption [key].
  Future<void> openGroup(String id, Uint8List key) async {
    if (!_sessions.containsKey(id)) {
      _sessions[id] = await ChannelSession.open(
        channelId: id,
        identity: identity,
        meshIdentity: meshIdentity,
        relayUrl: relayUrl,
        fallbackUrls: fallbackUrls,
        live: live,
        onUpdate: () => _onSessionUpdate(id),
        cipher: GroupChannelCipher(key),
        blobStore: blobStore,
        isDeviceRevoked: isDeviceRevoked,
        candidateCache: candidateCache,
        onPeerConnected: _broadcastContactsOnline,
        onContactsOnline: _handleContactsOnline,
        onVersionControl: _handleVersionControl,
        onTyping: (peerHex, typing) => _handleTyping(id, peerHex, typing),
        onInference: onInference,
      );
      _sessions[id]!.mesh?.versionManifest = versionManifest;
    }
    _activeId = id;
    onUpdate();
  }

  /// Builds the appropriate DM cipher for [peerPubkey]. Uses MultiDeviceDmCipher
  /// when we have a meshIdentity (device key) and the lookup functions; falls
  /// back to the legacy PairBox-only cipher otherwise.
  ChannelCipher _dmCipher(List<int> peerPubkey) {
    final device = meshIdentity ?? identity;
    final bundleFn = peerBundleLookup;
    final ownKeysFn = ownDeviceKeys;
    final peerHex = hex.encode(peerPubkey);
    return MultiDeviceDmCipher(
      selfDevice: device,
      peerBundleLookup: () => bundleFn?.call(peerHex),
      ownDeviceKeys: ownKeysFn ?? () => [device.publicKey],
    );
  }

  bool _dmPeerAllowed(String peerRootHex, String peerHex) {
    if (peerHex == identity.publicKeyHex || peerHex == peerRootHex) return true;
    if ((ownDeviceKeys?.call() ?? const <Uint8List>[]).any(
      (key) => hex.encode(key) == peerHex,
    )) {
      return true;
    }
    return peerBundleLookup
            ?.call(peerRootHex)
            ?.devices
            .any((key) => hex.encode(key) == peerHex) ??
        false;
  }

  /// Whether [peerHex] is authorised to participate in [channelId]. Group ids
  /// are capabilities; DMs additionally admit only either root's active keys.
  bool isPeerAllowedForChannel(String channelId, String peerHex) {
    final session = _sessions[channelId];
    final peer = session?.peerPubkey;
    if (peer == null) return session != null;
    return _dmPeerAllowed(hex.encode(peer), peerHex);
  }

  /// Opens (or focuses) the encrypted DM with [peerPubkey]. A blocked peer is
  /// refused, so no DM session — hence no ingestion — exists for them.
  Future<void> openDm(List<int> peerPubkey) async {
    if (isBlocked?.call(hex.encode(peerPubkey)) ?? false) return;
    final id = await dmChannelId(identity.publicKeyHex, hex.encode(peerPubkey));
    // Reserve synchronously so a concurrent open for the same peer bails here
    // rather than building a second (leaked) session across the await below.
    if (!_sessions.containsKey(id) && _opening.add(id)) {
      try {
        _sessions[id] = await ChannelSession.open(
          channelId: id,
          identity: identity,
          meshIdentity: meshIdentity,
          relayUrl: relayUrl,
          fallbackUrls: fallbackUrls,
          live: live,
          onUpdate: () => _onSessionUpdate(id),
          cipher: _dmCipher(peerPubkey),
          peerPubkey: peerPubkey,
          blobStore: blobStore,
          isDeviceRevoked: isDeviceRevoked,
          candidateCache: candidateCache,
          peerAllowed: (peerHex) =>
              _dmPeerAllowed(hex.encode(peerPubkey), peerHex),
          onPeerConnected: _broadcastContactsOnline,
          // For DMs we know the peer's root identity; fire with that (not the
          // connecting device's mesh key) so DM persistence resolves correctly.
          onPeerConnectedHex: onDmConnected != null
              ? (_) => onDmConnected!(hex.encode(peerPubkey))
              : null,
          onContactsOnline: _handleContactsOnline,
          onVersionControl: _handleVersionControl,
          onTyping: (peerHex, typing) => _handleTyping(id, peerHex, typing),
          onInference: onInference,
        );
        _sessions[id]!.mesh?.versionManifest = versionManifest;
      } finally {
        _opening.remove(id);
      }
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
    // Merge device→root mappings from this session's messages.
    final session = _sessions[channelId];
    if (session != null) deviceToRoot.addAll(session.deviceRoots);
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
  /// Updates the fallback relay URLs on all live sessions.
  void updateFallbackUrls(List<Uri> urls) {
    fallbackUrls = urls;
    for (final session in _sessions.values) {
      session.mesh?.fallbackUrls = urls;
    }
  }

  void updateVersionManifest(Map<String, Object?> manifest) {
    versionManifest = manifest;
    for (final session in _sessions.values) {
      session.mesh?.versionManifest = manifest;
    }
  }

  void reconnect() {
    for (final session in _sessions.values) {
      session.reconnect();
    }
  }
}
