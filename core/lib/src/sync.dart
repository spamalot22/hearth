// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';

import 'blob.dart';
import 'frame.dart';
import 'message.dart';
import 'repository.dart';

/// Owns a channel's [MessageRepository] and one [SyncSession] per connected
/// peer. Spreads every newly-stored message to all peers (epidemic forwarding),
/// while each session backfills missing history when it connects. Frames are
/// parsed defensively; ingest rates, frame fanout, repository capacity, pending
/// wants, and blob assemblies are bounded.
///
/// This is the seam between the app and the mesh: the UI [publish]es and listens
/// to [updates]; the transport hands connected peers to [addPeer].
class SyncEngine {
  SyncEngine(
    this.repository,
    this.channel, {
    this.blobStore,
    this.isDeviceRevoked,
    this.messageAllowed,
    this.peerReceiptAllowed,
    this.blobRetryInterval = const Duration(seconds: 30),
    this.reconcileInterval = const Duration(minutes: 1),
  });

  final MessageRepository repository;

  /// The chat channel this engine reconciles. Messages for any other channel are
  /// dropped on receipt.
  final String channel;

  /// Optional content-addressed store for media blobs fetched from peers.
  final BlobStore? blobStore;
  final Duration blobRetryInterval;
  final Duration reconcileInterval;

  /// Optional callback: returns true if [deviceKeyHex] was revoked by its
  /// authorising [rootKeyHex]. Revocations are root-scoped so one identity
  /// cannot suppress an unrelated identity that uses a different device key.
  final bool Function(String rootKeyHex, String deviceKeyHex)? isDeviceRevoked;

  /// Optional channel-level author policy, used by DMs to reject otherwise
  /// valid messages signed by unrelated identities.
  final bool Function(Message message)? messageAllowed;

  /// Optional dynamic policy for accepting storage receipts from a peer. DMs
  /// admit both identities' devices to the mesh, but accept courier-suppressing
  /// receipts only from an active device owned by the remote identity.
  final bool Function(String peerHex)? peerReceiptAllowed;

  final Set<SyncSession> _sessions = {};
  final Set<String> _pendingBlobs = {};
  final _ingestLimiter = _IngestRateLimiter(1200, const Duration(minutes: 1));
  final StreamController<void> _updates = StreamController<void>.broadcast();
  final StreamController<Message> _stored =
      StreamController<Message>.broadcast();
  final StreamController<String> _blobArrived =
      StreamController<String>.broadcast();
  final StreamController<String> _peerStored =
      StreamController<String>.broadcast();

  /// Fires whenever a message is stored (locally published or gossiped in), so a
  /// UI can re-render.
  Stream<void> get updates => _updates.stream;

  /// Newly accepted durable messages only, never rejected input or duplicates.
  /// Optional transport bridges must still decrypt and apply their own scope.
  Stream<Message> get stored => _stored.stream;

  /// Fires with a blob's id once its bytes arrive from a peer.
  Stream<String> get blobArrived => _blobArrived.stream;

  /// Registers a peer's frame [link] and starts reconciling with it.
  SyncSession addPeer(FrameChannel link) {
    late final SyncSession session;
    session = SyncSession(
      repository: repository,
      channel: channel,
      link: link,
      onAdded: _onNewMessage,
      blobStore: blobStore,
      blobRetryInterval: blobRetryInterval,
      reconcileInterval: reconcileInterval,
      onBlob: _onBlob,
      isDeviceRevoked: isDeviceRevoked,
      messageAllowed: messageAllowed,
      allowIngest: _ingestLimiter.allow,
      onPeerStored: (idHex) {
        if (peerReceiptAllowed?.call(link.peerHex) ?? true) {
          _onPeerStored(idHex);
        }
      },
      onClosed: () => _sessions.remove(session),
    );
    _sessions.add(session);
    session.start();
    for (final hash in _pendingBlobs) {
      session.requestBlob(hash);
    }
    return session;
  }

  /// Drops a disconnected peer's [session].
  Future<void> removePeer(SyncSession session) async {
    _sessions.remove(session);
    await session.close();
  }

  /// Persists a locally-authored [message] and gossips it to every peer. For
  /// *local* messages only — they're trusted, so no signature check.
  ///
  /// When [peerConfirmationTimeout] is supplied and at least one peer is
  /// connected, waits until a peer confirms it durably accepted the message.
  /// Returns false when there were no peers or none confirmed before timeout.
  Future<bool> publish(
    Message message, {
    Duration? peerConfirmationTimeout,
  }) async {
    if (message.channel != channel) {
      throw ArgumentError.value(message.channel, 'message', 'wrong channel');
    }
    final confirmation = peerConfirmationTimeout != null && _sessions.isNotEmpty
        ? _waitForPeerStorage(message.idHex, peerConfirmationTimeout)
        : null;
    if (await repository.add(message)) _onNewMessage(message, null);
    return confirmation == null ? false : await confirmation;
  }

  Future<bool> _waitForPeerStorage(String idHex, Duration timeout) async {
    if (timeout <= Duration.zero) return false;
    try {
      await _peerStored.stream
          .firstWhere((confirmedId) => confirmedId == idHex)
          .timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    } on StateError {
      return false; // The engine closed while waiting.
    }
  }

  void _onPeerStored(String idHex) {
    if (repository.getByHex(idHex) != null && !_peerStored.isClosed) {
      _peerStored.add(idHex);
    }
  }

  /// Ingests a message from an **untrusted** source (the relay courier) — it
  /// [Message.verify]s before storing, exactly like the P2P path
  /// ([SyncSession] verifies every GIVE), so we never trust the relay to have
  /// checked it. On success it's stored and gossiped onward like any message.
  Future<void> receive(Message message) async {
    if (!_ingestLimiter.allow()) return;
    if (message.channel != channel) return;
    if (!await message.verify()) return; // forged / invalid device-cert chain
    if (!(messageAllowed?.call(message) ?? true)) return;
    if (message.device != null && isDeviceRevoked != null) {
      if (isDeviceRevoked!(
        hex.encode(message.author),
        hex.encode(message.device!),
      )) {
        return;
      }
    }
    try {
      if (await repository.add(message)) _onNewMessage(message, null);
    } on RepositoryCapacityException {
      // Keep the app responsive under a valid-signature storage flood.
    }
  }

  void _onNewMessage(Message message, SyncSession? from) {
    if (!_stored.isClosed) _stored.add(message);
    if (!_updates.isClosed) _updates.add(null);
    for (final session in _sessions) {
      if (session != from) session.gossip(message);
    }
  }

  /// Asks every peer for the blob [hash]; arrivals surface on [blobArrived].
  /// Returns false when the id is malformed or the pending-request cap is full.
  bool requestBlob(String hash) {
    if (!_blobPattern.hasMatch(hash)) return false;
    if (!_pendingBlobs.contains(hash) &&
        _pendingBlobs.length >= _maxPendingBlobs) {
      return false;
    }
    _pendingBlobs.add(hash);
    for (final session in _sessions) {
      session.requestBlob(hash);
    }
    return true;
  }

  void _onBlob(String hash) {
    cancelBlobRequest(hash);
    if (!_blobArrived.isClosed) _blobArrived.add(hash);
  }

  /// Stops network retries when the shared local store acquired this blob by
  /// another path (for example a different channel).
  void cancelBlobRequest(String hash) {
    _pendingBlobs.remove(hash);
    for (final session in _sessions) {
      session.forgetBlob(hash);
    }
  }

  static const int _maxPendingBlobs = 1000;
  static final RegExp _blobPattern = RegExp(r'^1220[0-9a-f]{64}$');

  /// Closes every session and releases resources.
  Future<void> close() async {
    for (final session in _sessions.toList()) {
      await session.close();
    }
    _sessions.clear();
    await _updates.close();
    await _stored.close();
    await _blobArrived.close();
    await _peerStored.close();
  }
}

/// Drives gossip set-reconciliation with one peer over a [FrameChannel],
/// reconciling its DAG with our [MessageRepository].
///
/// On [start] we advertise our heads (HAVE). A peer's HAVE we answer with WANT
/// for the heads we lack; a WANT we answer with GIVE for each id we hold; a GIVE
/// we verify, persist, then WANT its still-missing parents — the recursion walks
/// the DAG backward and backfills exactly the missing history, nothing more.
///
/// Security: every GIVE is [Message.verify]-ed before it is stored — a peer
/// can't forge an author, alter content, or lie about an id, since verify
/// recomputes the id and checks the signature — and messages for a different
/// [channel] are dropped. Frames and ingest rates are bounded. A valid channel
/// member can still consume its share of the repository and processing limits.
class SyncSession {
  SyncSession({
    required this.repository,
    required this.channel,
    required this._link,
    required this.onAdded,
    this.blobStore,
    this.onBlob,
    this.isDeviceRevoked,
    this.messageAllowed,
    this.allowIngest,
    this.onPeerStored,
    this.onClosed,
    this.blobRetryInterval = const Duration(seconds: 30),
    this.reconcileInterval = const Duration(minutes: 1),
  }) {
    if (blobRetryInterval <= Duration.zero) {
      throw ArgumentError.value(blobRetryInterval, 'blobRetryInterval');
    }
    if (reconcileInterval <= Duration.zero) {
      throw ArgumentError.value(reconcileInterval, 'reconcileInterval');
    }
    _sub = _link.frames.listen(
      _enqueue,
      onError: (Object _, StackTrace _) {},
      onDone: () {
        _stop();
        onClosed?.call();
      },
    );
  }

  final MessageRepository repository;
  final String channel;
  final FrameChannel _link;
  final BlobStore? blobStore;
  final void Function(String hash)? onBlob;
  final bool Function(String rootKeyHex, String deviceKeyHex)? isDeviceRevoked;
  final bool Function(Message message)? messageAllowed;
  final bool Function()? allowIngest;
  final void Function(String idHex)? onPeerStored;
  final void Function()? onClosed;
  final Duration blobRetryInterval;
  final Duration reconcileInterval;

  /// Called after this session stores a *new* message, so the engine can spread
  /// it to other peers.
  final void Function(Message message, SyncSession from) onAdded;

  late final StreamSubscription<SyncFrame> _sub;
  final Set<String> _wanted = <String>{};
  final Set<String> _requestedBlobs = <String>{};
  final Map<String, DateTime> _activeBlobs = {};
  Timer? _blobRetryTimer;
  Timer? _reconcileTimer;
  int _headOffset = 0;
  bool _closed = false;
  final Map<String, _BlobAssembly> _blobAssemblies = {};
  int _blobAssemblyBytes = 0;
  Future<void> _tail = Future<void>.value();
  int _queuedFrames = 0;
  int _queuedFrameBytes = 0;
  static const int _maxQueuedFrames = 2048;
  static const int _maxQueuedFrameBytes = 32 * 1024 * 1024;

  /// Advertises our current heads to begin reconciliation.
  void start() {
    if (_closed || _reconcileTimer != null) return;
    _advertiseHeads();
    _reconcileTimer = Timer.periodic(reconcileInterval, (_) {
      if (_closed) return;
      _advertiseHeads();
      final retry = _wanted.take(100).toList();
      if (retry.isEmpty) return;
      // Rotate unanswered wants so unavailable ids cannot starve later history.
      _wanted.removeAll(retry);
      _wanted.addAll(retry);
      _link.send(WantFrame(retry));
    });
  }

  void _advertiseHeads() {
    final heads = _hex(repository.heads());
    if (_headOffset >= heads.length) _headOffset = 0;
    final batch = heads.skip(_headOffset).take(_maxHaveHeads).toList();
    _headOffset += batch.length;
    _link.send(HaveFrame(batch));
  }

  /// Sends [message] to this peer (a live send or an epidemic forward).
  void gossip(Message message) => _link.send(GiveFrame(message));

  /// Asks this peer for the blob [hash].
  void requestBlob(String hash) {
    if (_closed ||
        !_blobPattern.hasMatch(hash) ||
        _requestedBlobs.length >= SyncEngine._maxPendingBlobs ||
        !_requestedBlobs.add(hash)) {
      return;
    }
    _pumpBlobRequests();
  }

  void forgetBlob(String hash) {
    _requestedBlobs.remove(hash);
    _activeBlobs.remove(hash);
    _discardBlobAssembly(hash);
    _pumpBlobRequests();
  }

  void _pumpBlobRequests() {
    if (_closed) return;
    if (_requestedBlobs.isEmpty) {
      _blobRetryTimer?.cancel();
      _blobRetryTimer = null;
      return;
    }
    for (final hash in _requestedBlobs) {
      if (_activeBlobs.length >= _maxBlobAssemblies) break;
      if (_activeBlobs.containsKey(hash)) continue;
      _activeBlobs[hash] = DateTime.now();
      _link.send(WantBlobFrame(hash, chunked: true));
    }
    _blobRetryTimer ??= Timer.periodic(blobRetryInterval, (_) {
      final now = DateTime.now();
      for (final hash in _activeBlobs.keys.toList()) {
        if (now.difference(_activeBlobs[hash]!) < blobRetryInterval) continue;
        _activeBlobs.remove(hash);
        _discardBlobAssembly(hash);
        // Move unavailable blobs behind waiting ones so they cannot starve them.
        _requestedBlobs.remove(hash);
        _requestedBlobs.add(hash);
      }
      _pumpBlobRequests();
    });
  }

  void _stop() {
    _closed = true;
    _blobRetryTimer?.cancel();
    _reconcileTimer?.cancel();
    _blobRetryTimer = null;
    _requestedBlobs.clear();
    _activeBlobs.clear();
    _blobAssemblies.clear();
    _blobAssemblyBytes = 0;
  }

  Future<void> close() async {
    _stop();
    await _sub.cancel();
    await _tail;
  }

  /// Maximum pending wants per peer (prevents OOM from a malicious HAVE flood).
  static const int _maxPendingWants = 10000;

  /// Maximum heads accepted per HAVE frame (bounds a single frame's impact).
  static const int _maxHaveHeads = 1000;

  /// 24 KiB of raw data encodes to a JSON frame below 40 KiB. That fits common
  /// WebRTC/SCTP limits and remains one encrypted relay-tunnel fragment.
  static const int _blobChunkBytes = 24 * 1024;
  static const int _maxBlobAssemblies = 4;
  static const int _maxBlobAssemblyBytes = 32 * 1024 * 1024;

  // Serialise handling so concurrent gives don't race on _wanted or add().
  void _enqueue(SyncFrame frame) {
    if (_closed) return;
    final int bytes;
    try {
      bytes = frame.encode().length * 2;
    } catch (_) {
      return;
    }
    if (_queuedFrames >= _maxQueuedFrames ||
        _queuedFrameBytes + bytes > _maxQueuedFrameBytes) {
      _stop();
      onClosed?.call();
      unawaited(_link.close().catchError((Object _) {}));
      return;
    }
    _queuedFrames++;
    _queuedFrameBytes += bytes;
    _tail = _tail.then((_) async {
      try {
        await _handle(frame);
      } catch (_) {
        // One malformed frame must not poison subsequent valid frames.
      } finally {
        _queuedFrames--;
        _queuedFrameBytes -= bytes;
      }
    });
  }

  Future<void> _handle(SyncFrame frame) async {
    if (_closed) return;
    switch (frame) {
      case HaveFrame(:final heads):
        _requestMissing(heads.take(_maxHaveHeads));
      case WantFrame(:final ids):
        // Cap responses to prevent amplification.
        var sent = 0;
        for (final idHex in ids.take(_maxHaveHeads)) {
          if (_closed) return;
          final id = _idBytes(idHex);
          if (id == null) continue;
          final message = repository.get(id);
          if (message != null) {
            _link.send(GiveFrame(message));
            if (++sent % 16 == 0) await _link.flush();
          }
        }
      case GiveFrame(:final message):
        await _receive(message);
      case AckFrame(:final id):
        if (_idBytes(id) != null) onPeerStored?.call(id.toLowerCase());
      case WantBlobFrame(:final hash, :final chunked):
        if (!_blobPattern.hasMatch(hash)) return;
        final bytes = await blobStore?.get(hash);
        if (_closed) return;
        if (bytes != null && bytes.length <= maxBlobBytes) {
          if (!chunked || bytes.length <= _blobChunkBytes) {
            _link.send(GiveBlobFrame(hash, bytes));
          } else {
            for (
              var offset = 0;
              offset < bytes.length;
              offset += _blobChunkBytes
            ) {
              if (_closed) return;
              final end = min(offset + _blobChunkBytes, bytes.length);
              _link.send(
                GiveBlobChunkFrame(
                  hash,
                  offset,
                  bytes.length,
                  Uint8List.sublistView(bytes, offset, end),
                ),
              );
              if (end == bytes.length || end % (_blobChunkBytes * 8) == 0) {
                await _link.flush();
              }
            }
          }
        }
      case GiveBlobFrame(:final hash, :final bytes):
        if (!_activeBlobs.containsKey(hash)) return;
        // Reject oversized blobs before spending CPU hashing them.
        if (bytes.length > maxBlobBytes) return;
        // Content-addressed: the bytes must hash to the requested id.
        if (await blobHash(bytes) != hash) return;
        final store = blobStore;
        if (store == null) return;
        await store.put(bytes);
        forgetBlob(hash);
        onBlob?.call(hash);
      case GiveBlobChunkFrame(
        :final hash,
        :final offset,
        :final totalBytes,
        :final bytes,
      ):
        await _receiveBlobChunk(hash, offset, totalBytes, bytes);
    }
  }

  Future<void> _receiveBlobChunk(
    String hash,
    int offset,
    int totalBytes,
    Uint8List bytes,
  ) async {
    if (!_activeBlobs.containsKey(hash) ||
        !_blobPattern.hasMatch(hash) ||
        offset < 0 ||
        totalBytes <= 0 ||
        totalBytes > maxBlobBytes ||
        bytes.isEmpty ||
        bytes.length > _blobChunkBytes ||
        offset + bytes.length > totalBytes) {
      return;
    }

    var assembly = _blobAssemblies[hash];
    if (assembly == null) {
      if (offset != 0 ||
          _blobAssemblies.length >= _maxBlobAssemblies ||
          _blobAssemblyBytes + totalBytes > _maxBlobAssemblyBytes) {
        return;
      }
      assembly = _BlobAssembly(totalBytes);
      _blobAssemblies[hash] = assembly;
      _blobAssemblyBytes += totalBytes;
    }
    if (assembly.totalBytes != totalBytes || offset != assembly.length) {
      _discardBlobAssembly(hash);
      return;
    }

    assembly.add(bytes);
    _activeBlobs[hash] = DateTime.now();
    if (assembly.length != totalBytes) return;

    _discardBlobAssembly(hash);
    final complete = assembly.takeBytes();
    if (await blobHash(complete) != hash) return;
    final store = blobStore;
    if (store == null) return;
    await store.put(complete);
    forgetBlob(hash);
    onBlob?.call(hash);
  }

  void _discardBlobAssembly(String hash) {
    final removed = _blobAssemblies.remove(hash);
    if (removed != null) _blobAssemblyBytes -= removed.totalBytes;
  }

  Future<void> _receive(Message message) async {
    if (message.channel != channel) return; // not our channel
    if (!(allowIngest?.call() ?? true)) return;
    if (!await message.verify()) return; // forged or tampered
    if (!(messageAllowed?.call(message) ?? true)) return;
    // Reject messages from revoked devices.
    if (message.device != null && isDeviceRevoked != null) {
      if (isDeviceRevoked!(
        hex.encode(message.author),
        hex.encode(message.device!),
      )) {
        return;
      }
    }
    try {
      final added = await repository.add(message);
      _wanted.remove(message.idHex);
      // Acknowledge only after the verified message is durably present. This is
      // deliberately sent for duplicates too: already having the message is a
      // valid custody confirmation.
      _link.send(AckFrame(message.idHex));
      if (added) {
        onAdded(message, this); // new → the engine spreads it onward
        _requestMissing(message.prev.map(hex.encode)); // backfill its parents
      }
    } on RepositoryCapacityException {
      // Do not let one peer's signed history consume unbounded local storage.
    }
  }

  /// WANTs every id we neither hold nor have already asked this peer for.
  /// Capped at [_maxPendingWants] to prevent memory exhaustion from a malicious
  /// peer flooding fake HAVE IDs.
  void _requestMissing(Iterable<String> ids) {
    final missing = <String>[];
    for (final idHex in ids) {
      if (_wanted.length >= _maxPendingWants) break;
      final id = _idBytes(idHex);
      if (id == null) continue;
      if (repository.contains(id) || !_wanted.add(idHex)) continue;
      missing.add(idHex);
    }
    if (missing.isNotEmpty) _link.send(WantFrame(missing));
  }

  static List<String> _hex(List<Uint8List> ids) =>
      ids.map(hex.encode).toList(growable: false);

  static final RegExp _idPattern = RegExp(r'^[0-9a-fA-F]{68}$');
  static final RegExp _blobPattern = RegExp(r'^1220[0-9a-f]{64}$');

  static Uint8List? _idBytes(String idHex) =>
      _idPattern.hasMatch(idHex) ? Uint8List.fromList(hex.decode(idHex)) : null;
}

class _IngestRateLimiter {
  _IngestRateLimiter(this.limit, this.window);

  final int limit;
  final Duration window;
  final List<DateTime> _accepted = <DateTime>[];

  bool allow() {
    final now = DateTime.now();
    final cutoff = now.subtract(window);
    var expired = 0;
    while (expired < _accepted.length && _accepted[expired].isBefore(cutoff)) {
      expired++;
    }
    if (expired > 0) _accepted.removeRange(0, expired);
    if (_accepted.length >= limit) return false;
    _accepted.add(now);
    return true;
  }
}

class _BlobAssembly {
  _BlobAssembly(this.totalBytes);

  final int totalBytes;
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  int get length => _bytes.length;

  void add(Uint8List bytes) => _bytes.add(bytes);

  Uint8List takeBytes() => _bytes.takeBytes();
}
