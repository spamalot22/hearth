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
/// while each session backfills missing history when it connects.
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
  });

  final MessageRepository repository;

  /// The chat channel this engine reconciles. Messages for any other channel are
  /// dropped on receipt.
  final String channel;

  /// Optional content-addressed store for media blobs fetched from peers.
  final BlobStore? blobStore;

  /// Optional callback: returns true if [deviceKeyHex] was revoked by its
  /// authorising [rootKeyHex]. Revocations are root-scoped so one identity
  /// cannot suppress an unrelated identity that uses a different device key.
  final bool Function(String rootKeyHex, String deviceKeyHex)? isDeviceRevoked;

  /// Optional channel-level author policy, used by DMs to reject otherwise
  /// valid messages signed by unrelated identities.
  final bool Function(Message message)? messageAllowed;

  final Set<SyncSession> _sessions = {};
  final Set<String> _pendingBlobs = {};
  final _ingestLimiter = _IngestRateLimiter(1200, const Duration(minutes: 1));
  final StreamController<void> _updates = StreamController<void>.broadcast();
  final StreamController<String> _blobArrived =
      StreamController<String>.broadcast();

  /// Fires whenever a message is stored (locally published or gossiped in), so a
  /// UI can re-render.
  Stream<void> get updates => _updates.stream;

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
      onBlob: _onBlob,
      isDeviceRevoked: isDeviceRevoked,
      messageAllowed: messageAllowed,
      allowIngest: _ingestLimiter.allow,
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
  Future<void> publish(Message message) async {
    if (message.channel != channel) {
      throw ArgumentError.value(message.channel, 'message', 'wrong channel');
    }
    if (await repository.add(message)) _onNewMessage(message, null);
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
    _pendingBlobs.remove(hash);
    if (!_blobArrived.isClosed) _blobArrived.add(hash);
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
    await _blobArrived.close();
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
/// [channel] are dropped. Frames are parsed defensively. This bounds, but does
/// not immunise against, a peer flooding validly-signed messages; rate-limiting
/// is a later hardening pass.
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
    this.onClosed,
  }) {
    _sub = _link.frames.listen(
      _enqueue,
      onError: (Object _, StackTrace _) {},
      onDone: onClosed,
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
  final void Function()? onClosed;

  /// Called after this session stores a *new* message, so the engine can spread
  /// it to other peers.
  final void Function(Message message, SyncSession from) onAdded;

  late final StreamSubscription<SyncFrame> _sub;
  final Set<String> _wanted = <String>{};
  final Set<String> _requestedBlobs = <String>{};
  final Map<String, _BlobAssembly> _blobAssemblies = {};
  int _blobAssemblyBytes = 0;
  Future<void> _tail = Future<void>.value();

  /// Advertises our current heads to begin reconciliation.
  void start() => _link.send(HaveFrame(_hex(repository.heads())));

  /// Sends [message] to this peer (a live send or an epidemic forward).
  void gossip(Message message) => _link.send(GiveFrame(message));

  /// Asks this peer for the blob [hash].
  void requestBlob(String hash) {
    if (!_blobPattern.hasMatch(hash) || !_requestedBlobs.add(hash)) return;
    _link.send(WantBlobFrame(hash, chunked: true));
  }

  Future<void> close() async {
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
    _tail = _tail.then((_) => _handle(frame)).catchError((Object _) {
      // A malformed peer frame must not poison the serial queue and prevent
      // every subsequent valid frame from being processed.
    });
  }

  Future<void> _handle(SyncFrame frame) async {
    switch (frame) {
      case HaveFrame(:final heads):
        _requestMissing(heads.take(_maxHaveHeads));
      case WantFrame(:final ids):
        // Cap responses to prevent amplification.
        for (final idHex in ids.take(_maxHaveHeads)) {
          final id = _idBytes(idHex);
          if (id == null) continue;
          final message = repository.get(id);
          if (message != null) _link.send(GiveFrame(message));
        }
      case GiveFrame(:final message):
        await _receive(message);
      case WantBlobFrame(:final hash, :final chunked):
        if (!_blobPattern.hasMatch(hash)) return;
        final bytes = await blobStore?.get(hash);
        if (bytes != null && bytes.length <= maxBlobBytes) {
          if (!chunked || bytes.length <= _blobChunkBytes) {
            _link.send(GiveBlobFrame(hash, bytes));
          } else {
            for (
              var offset = 0;
              offset < bytes.length;
              offset += _blobChunkBytes
            ) {
              final end = min(offset + _blobChunkBytes, bytes.length);
              _link.send(
                GiveBlobChunkFrame(
                  hash,
                  offset,
                  bytes.length,
                  Uint8List.sublistView(bytes, offset, end),
                ),
              );
            }
          }
        }
      case GiveBlobFrame(:final hash, :final bytes):
        if (!_requestedBlobs.contains(hash)) return;
        // Reject oversized blobs before spending CPU hashing them.
        if (bytes.length > maxBlobBytes) return;
        // Content-addressed: the bytes must hash to the requested id.
        if (await blobHash(bytes) != hash) return;
        final store = blobStore;
        if (store == null) return;
        await store.put(bytes);
        _discardBlobAssembly(hash);
        _requestedBlobs.remove(hash);
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
    if (!_requestedBlobs.contains(hash) ||
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
    if (assembly.length != totalBytes) return;

    _discardBlobAssembly(hash);
    final complete = assembly.takeBytes();
    if (await blobHash(complete) != hash) return;
    final store = blobStore;
    if (store == null) return;
    await store.put(complete);
    _requestedBlobs.remove(hash);
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
    _wanted.remove(message.idHex);
    try {
      if (await repository.add(message)) {
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
