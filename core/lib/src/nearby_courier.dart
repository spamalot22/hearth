// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'nearby_packet.dart';
import 'nearby_queue.dart';

/// One framed link. Raw adapters enforce NearbyMux.maxWireBytes before
/// allocation/reassembly; the courier only receives decrypted maxFrameBytes.
/// Native adapters must also bound their send queues.
/// Peer handles are ephemeral transport IDs, never evidence of Hearth identity.
abstract interface class NearbyLink {
  String get id;
  Stream<Uint8List> get incoming;
  Future<void> send(Uint8List bytes);
  Future<void> close();
}

/// Epidemic, transport-independent couriering, not trusted channel sync.
/// There is deliberately no delivery ACK: accepting custody does not prove
/// that a recipient received, read, or decrypted an envelope.
class NearbyCourier {
  NearbyCourier({
    required this.queue,
    this.onPacket,
    this.maxLinks = 8,
    this.interval = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  static const maxFrameBytes = NearbyPacket.maxWireBytes + 1;
  static const _maxControlBytes = 4096;
  static const _batch = 32;
  final NearbyQueue queue;
  final Future<void> Function(NearbyPacket)? onPacket;
  final int maxLinks;
  final Duration interval;
  final DateTime Function() now;
  final Map<String, _Neighbor> _links = {};
  Timer? _timer;
  bool _closed = false;
  int _pending = 0;

  int get linkCount => _links.length;

  Future<void> attach(NearbyLink link) async {
    if (_closed || _links.length >= maxLinks || _links.containsKey(link.id)) {
      await link.close();
      return;
    }
    final peer = _Neighbor(link, now());
    _links[link.id] = peer;
    peer.sub = link.incoming.listen(
      (bytes) {
        if (_closed ||
            bytes.length > maxFrameBytes ||
            peer.pending >= 8 ||
            _pending >= 16 ||
            !peer.accept(bytes.length, now())) {
          unawaited(detach(link.id));
          return;
        }
        peer.pending++;
        _pending++;
        peer.readTail = peer.readTail
            .then((_) async {
              if (!_closed && _links[link.id] == peer) {
                await _receive(peer, bytes);
              }
            })
            .catchError((Object _) {
              unawaited(detach(link.id));
            })
            .whenComplete(() {
              peer.pending--;
              _pending--;
            });
      },
      onDone: () => unawaited(detach(link.id)),
      onError: (Object _) => unawaited(detach(link.id)),
    );
    _timer ??= Timer.periodic(interval, (_) {
      unawaited(reconcile().catchError((Object _) {}));
    });
    await _inventory(peer);
  }

  Future<void> detach(String id) async {
    final peer = _links.remove(id);
    if (peer == null) return;
    if (_links.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
    await peer.sub?.cancel();
    try {
      await peer.link.close();
    } catch (_) {}
  }

  /// Adds only an already sealed packet. Only local callers can reserve the
  /// owner's queue capacity; the wire protocol has no "local" flag.
  Future<NearbyAdmission> publish(NearbyPacket packet) async {
    if (_closed) throw StateError('nearby courier closed');
    final admission = await queue.add(packet, local: true);
    if (admission == NearbyAdmission.stored) await reconcile();
    return admission;
  }

  bool _reconciling = false;
  Future<void> reconcile() async {
    if (_closed || _reconciling) return;
    _reconciling = true;
    try {
      await queue.prune();
      for (final peer in _links.values.toList()) {
        await _inventory(peer);
      }
    } finally {
      _reconciling = false;
    }
  }

  Future<void> _inventory(_Neighbor peer) async {
    final packets = queue.packets;
    if (packets.isEmpty) {
      // Keep an idle local socket alive without advertising identities/routes.
      await _send(peer, _control('have', const []));
      return;
    }
    final start = peer.cursor % packets.length;
    final count = packets.length < _batch ? packets.length : _batch;
    final ids = List.generate(
      count,
      (i) => packets[(start + i) % packets.length].id,
    );
    peer.cursor = (start + count) % packets.length;
    await _send(peer, _control('have', ids));
  }

  Future<void> _receive(_Neighbor peer, Uint8List bytes) async {
    if (bytes.isEmpty) return;
    if (bytes[0] == 1) {
      final packet = await NearbyPacket.decode(bytes.sublist(1), now: now());
      if (packet == null || _closed) return;
      final admission = await queue.add(packet);
      if (admission != NearbyAdmission.stored) return;
      // Delivery failure does not discard a durably stored envelope. The app
      // can retry decrypting stored packets when channel/device keys change.
      try {
        await onPacket?.call(packet);
      } catch (_) {}
      await reconcile();
      return;
    }
    if (bytes[0] != 0 || bytes.length > _maxControlBytes) return;
    final raw = jsonDecode(utf8.decode(bytes.sublist(1)));
    if (raw is! Map<String, dynamic> || raw['v'] != 1 || raw['ids'] is! List) {
      return;
    }
    final ids = raw['ids'] as List;
    if (ids.length > _batch ||
        ids.any(
          (id) => id is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(id),
        )) {
      return;
    }
    final packets = {for (final p in queue.packets) p.id: p};
    if (raw['t'] == 'have') {
      final want = ids
          .cast<String>()
          .where((id) => !packets.containsKey(id))
          .toSet()
          .toList();
      if (want.isNotEmpty) await _send(peer, _control('want', want));
    } else if (raw['t'] == 'want') {
      for (final id in ids.toSet()) {
        final packet = packets[id];
        if (packet != null) {
          await _send(peer, Uint8List.fromList([1, ...packet.encode()]));
        }
      }
    }
  }

  static Uint8List _control(String type, List<String> ids) =>
      Uint8List.fromList([
        0,
        ...utf8.encode(jsonEncode({'v': 1, 't': type, 'ids': ids})),
      ]);

  Future<void> _send(_Neighbor peer, Uint8List bytes) async {
    if (_closed || _links[peer.link.id] != peer || peer.outstanding >= 8) {
      return;
    }
    peer.outstanding++;
    try {
      final operation = peer.writeTail.then((_) async {
        if (_closed ||
            _links[peer.link.id] != peer ||
            !peer.canSend(bytes.length, now())) {
          return;
        }
        // BLE at the minimum ATT MTU needs many acknowledged fragments.
        await peer.link.send(bytes).timeout(const Duration(seconds: 75));
      });
      peer.writeTail = operation.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
      await operation;
    } catch (_) {
      await detach(peer.link.id);
    } finally {
      peer.outstanding--;
    }
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    for (final id in _links.keys.toList()) {
      await detach(id);
    }
  }
}

class _Neighbor {
  _Neighbor(this.link, this.window);
  final NearbyLink link;
  StreamSubscription<Uint8List>? sub;
  Future<void> readTail = Future<void>.value();
  Future<void> writeTail = Future<void>.value();
  int pending = 0;
  int outstanding = 0;
  int cursor = 0;
  DateTime window;
  int received = 0;
  int receivedBytes = 0;
  int sentBytes = 0;

  void _reset(DateTime now) {
    if (now.difference(window) >= const Duration(minutes: 1)) {
      window = now;
      received = 0;
      receivedBytes = 0;
      sentBytes = 0;
    }
  }

  bool accept(int bytes, DateTime now) {
    _reset(now);
    received++;
    receivedBytes += bytes;
    return received <= 128 && receivedBytes <= 1024 * 1024;
  }

  bool canSend(int bytes, DateTime now) {
    _reset(now);
    if (sentBytes + bytes > 256 * 1024) return false;
    sentBytes += bytes;
    return true;
  }
}
