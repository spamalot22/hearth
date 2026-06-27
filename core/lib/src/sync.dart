// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
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
  SyncEngine(this.repository, this.channel, {this.blobStore});

  final MessageRepository repository;

  /// The chat channel this engine reconciles. Messages for any other channel are
  /// dropped on receipt.
  final String channel;

  /// Optional content-addressed store for media blobs fetched from peers.
  final BlobStore? blobStore;

  final Set<SyncSession> _sessions = {};
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
    final session = SyncSession(
      repository: repository,
      channel: channel,
      link: link,
      onAdded: _onNewMessage,
      blobStore: blobStore,
      onBlob: _onBlob,
    );
    _sessions.add(session);
    session.start();
    return session;
  }

  /// Drops a disconnected peer's [session].
  Future<void> removePeer(SyncSession session) async {
    _sessions.remove(session);
    await session.close();
  }

  /// Persists a locally-authored [message] and gossips it to every peer.
  Future<void> publish(Message message) async {
    if (await repository.add(message)) _onNewMessage(message, null);
  }

  void _onNewMessage(Message message, SyncSession? from) {
    if (!_updates.isClosed) _updates.add(null);
    for (final session in _sessions) {
      if (session != from) session.gossip(message);
    }
  }

  /// Asks every peer for the blob [hash]; arrivals surface on [blobArrived].
  void requestBlob(String hash) {
    for (final session in _sessions) {
      session.requestBlob(hash);
    }
  }

  void _onBlob(String hash) {
    if (!_blobArrived.isClosed) _blobArrived.add(hash);
  }

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
  }) {
    _sub = _link.frames.listen(_enqueue);
  }

  final MessageRepository repository;
  final String channel;
  final FrameChannel _link;
  final BlobStore? blobStore;
  final void Function(String hash)? onBlob;

  /// Called after this session stores a *new* message, so the engine can spread
  /// it to other peers.
  final void Function(Message message, SyncSession from) onAdded;

  late final StreamSubscription<SyncFrame> _sub;
  final Set<String> _wanted = <String>{};
  Future<void> _tail = Future<void>.value();

  /// Advertises our current heads to begin reconciliation.
  void start() => _link.send(HaveFrame(_hex(repository.heads())));

  /// Sends [message] to this peer (a live send or an epidemic forward).
  void gossip(Message message) => _link.send(GiveFrame(message));

  /// Asks this peer for the blob [hash].
  void requestBlob(String hash) => _link.send(WantBlobFrame(hash));

  Future<void> close() => _sub.cancel();

  // Serialise handling so concurrent gives don't race on _wanted or add().
  void _enqueue(SyncFrame frame) {
    _tail = _tail.then((_) => _handle(frame));
  }

  Future<void> _handle(SyncFrame frame) async {
    switch (frame) {
      case HaveFrame(:final heads):
        _requestMissing(heads);
      case WantFrame(:final ids):
        for (final idHex in ids) {
          final message = repository.get(_bytes(idHex));
          if (message != null) _link.send(GiveFrame(message));
        }
      case GiveFrame(:final message):
        await _receive(message);
      case WantBlobFrame(:final hash):
        final bytes = await blobStore?.get(hash);
        if (bytes != null) _link.send(GiveBlobFrame(hash, bytes));
      case GiveBlobFrame(:final hash, :final bytes):
        // Content-addressed: the bytes must hash to the requested id.
        if (await blobHash(bytes) != hash) return;
        final store = blobStore;
        if (store == null) return;
        await store.put(bytes);
        onBlob?.call(hash);
    }
  }

  Future<void> _receive(Message message) async {
    if (message.channel != channel) return; // not our channel
    if (!await message.verify()) return; // forged or tampered
    _wanted.remove(message.idHex);
    if (await repository.add(message)) {
      onAdded(message, this); // new → the engine spreads it onward
      _requestMissing(message.prev.map(hex.encode)); // backfill its parents
    }
  }

  /// WANTs every id we neither hold nor have already asked this peer for.
  void _requestMissing(Iterable<String> ids) {
    final missing = <String>[];
    for (final idHex in ids) {
      if (repository.contains(_bytes(idHex)) || !_wanted.add(idHex)) continue;
      missing.add(idHex);
    }
    if (missing.isNotEmpty) _link.send(WantFrame(missing));
  }

  static List<String> _hex(List<Uint8List> ids) =>
      ids.map(hex.encode).toList(growable: false);

  static Uint8List _bytes(String idHex) =>
      Uint8List.fromList(hex.decode(idHex));
}
