// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'nearby_courier.dart';
import 'nearby_noise.dart';
import 'nearby_policy.dart';

enum NearbyLinkEvent { secure, handshakeTimeout, rejected, writeFailed }

/// Coalesces radios after proof of possession of the same activation key.
/// Nearby keys are NOT verified Hearth identities or membership credentials.
class NearbyMux {
  NearbyMux({required this.onPeer, this.onChanged, this.onEvent});
  final Future<void> Function(NearbyLink) onPeer;
  final void Function()? onChanged;
  final void Function(NearbyMedium, NearbyLinkEvent)? onEvent;
  final _key = X25519().newKeyPair();
  final _radios = <String, _Radio>{};
  final _peers = <String, _Peer>{};
  final _clock = Stopwatch()..start();
  int _window = 0;
  int _frames = 0;
  int _bytes = 0;
  bool _closed = false;
  static const maxWireBytes = NearbyCourier.maxFrameBytes + 17;
  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  String? peerFor(String radioId) => _radios[radioId]?.peer?.id;
  Map<String, NearbyMedium> get peers => {
    for (final peer in _peers.values)
      if (peer.radios.isNotEmpty) peer.id: peer.best.medium,
  };

  Future<void> add(NearbyLink link, NearbyMedium medium) async {
    if (_closed || _radios.length >= 16 || _radios.containsKey(link.id)) {
      await link.close();
      return;
    }
    final radio = _Radio(link, medium);
    _radios[link.id] = radio;
    radio.timeout = Timer(const Duration(seconds: 25), () {
      onEvent?.call(medium, NearbyLinkEvent.handshakeTimeout);
      unawaited(remove(link.id));
    });
    radio.sub = link.incoming.listen(
      (bytes) {
        if (_closed || _radios[link.id] != radio) return;
        if (bytes.isEmpty ||
            bytes.length > maxWireBytes ||
            radio.pending >= 8 ||
            !_accept(radio, bytes.length) ||
            (radio.noise?.complete != true && bytes.length > 256)) {
          onEvent?.call(medium, NearbyLinkEvent.rejected);
          unawaited(remove(link.id));
          return;
        }
        radio.pending++;
        final copy = Uint8List.fromList(bytes);
        radio.tail = radio.tail
            .then((_) async {
              if (_radios[link.id] == radio) await _receive(radio, copy);
            })
            .catchError((Object _) async {
              if (_radios[link.id] == radio) {
                onEvent?.call(medium, NearbyLinkEvent.rejected);
              }
              await remove(link.id);
            })
            .whenComplete(() => radio.pending--);
      },
      onDone: () => unawaited(remove(link.id)),
      onError: (Object _) => unawaited(remove(link.id)),
    );
    try {
      await link.send(radio.hello).timeout(const Duration(seconds: 10));
    } catch (_) {
      await remove(link.id);
    }
  }

  bool _accept(_Radio radio, int length) {
    final now = _clock.elapsedMilliseconds;
    if (now - _window >= 60000) {
      _window = now;
      _frames = 0;
      _bytes = 0;
    }
    if (now - radio.window >= 60000) {
      radio.window = now;
      radio.frames = 0;
      radio.bytes = 0;
    }
    _frames++;
    _bytes += length;
    radio.frames++;
    radio.bytes += length;
    return _frames <= 256 &&
        _bytes <= 2 * 1024 * 1024 &&
        radio.frames <= 128 &&
        radio.bytes <= 1024 * 1024;
  }

  Future<void> _receive(_Radio radio, Uint8List bytes) async {
    var noise = radio.noise;
    if (noise == null) {
      if (bytes.length != 34 || bytes[0] != 72 || bytes[1] != 2) {
        throw const FormatException('Unsupported nearby handshake');
      }
      final order = _hex(radio.hello).compareTo(_hex(bytes));
      if (order == 0) throw const FormatException('Reflected nearby hello');
      final key = await _key;
      final ephemeral = await X25519().newKeyPair();
      if (_radios[radio.link.id] != radio) {
        ephemeral.destroy();
        return;
      }
      noise = NearbyNoise(
        initiator: order < 0,
        localStatic: key,
        localEphemeral: ephemeral,
        prologue: [
          ...utf8.encode('hearth/nearby/noise/v2'),
          ...(order < 0 ? radio.hello : bytes),
          ...(order < 0 ? bytes : radio.hello),
        ],
      );
      radio.noise = noise;
      if (noise.initiator) await radio.handshake(await noise.write());
      return;
    }
    if (!noise.complete) {
      if (bytes[0] != 3) {
        throw const FormatException('Expected Noise handshake');
      }
      final payload = await noise.read(Uint8List.sublistView(bytes, 1));
      if (payload.isNotEmpty) {
        throw const FormatException('Early application data');
      }
      if (!noise.complete) await radio.handshake(await noise.write());
      if (noise.complete) await radio.send(Uint8List.fromList([2]));
      return;
    }
    if (bytes[0] != 4) throw const FormatException('Expected encrypted frame');
    final clear = await noise.receiving!.decrypt(
      Uint8List.sublistView(bytes, 1),
    );
    if (_radios[radio.link.id] != radio) return;
    if (radio.peer == null) {
      if (clear.length != 1 || clear[0] != 2) {
        throw const FormatException('Missing key confirmation');
      }
      final id = _hex(noise.remoteStatic);
      final ownId = _hex((await (await _key).extractPublicKey()).bytes);
      if (_radios[radio.link.id] != radio) return;
      if (id == ownId || (!_peers.containsKey(id) && _peers.length >= 8)) {
        throw const FormatException('Invalid or excess peer');
      }
      radio.timeout?.cancel();
      final existing = _peers[id];
      final peer = existing ?? _Peer(id, this);
      _peers[id] = peer;
      radio.peer = peer;
      peer.radios.add(radio);
      onEvent?.call(radio.medium, NearbyLinkEvent.secure);
      if (existing == null) {
        unawaited(onPeer(peer).catchError((Object _) => peer.close()));
      }
      onChanged?.call();
    } else {
      if (clear.isEmpty ||
          clear.length > NearbyCourier.maxFrameBytes ||
          clear[0] > 1) {
        throw const FormatException('Invalid courier frame');
      }
      final peer = radio.peer!;
      if (!peer.input.hasListener && ++peer.unclaimed > 8) {
        throw const FormatException('Unclaimed nearby input');
      }
      peer.input.add(clear);
    }
  }

  Future<void> remove(String id) async {
    final radio = _radios.remove(id);
    if (radio == null) return;
    radio.timeout?.cancel();
    radio.noise?.destroy();
    final peer = radio.peer;
    peer?.radios.remove(radio);
    if (peer != null && peer.radios.isEmpty) {
      _peers.remove(peer.id);
      unawaited(peer.input.close());
    }
    onChanged?.call();
    await radio.sub?.cancel();
    try {
      await radio.link.close();
    } catch (_) {}
  }

  Future<void> close() async {
    _closed = true;
    for (final id in _radios.keys.toList()) {
      await remove(id);
    }
    (await _key).destroy();
  }
}

class _Radio {
  _Radio(this.link, this.medium) {
    final random = Random.secure();
    hello = Uint8List.fromList([
      72,
      2,
      ...List.generate(32, (_) => random.nextInt(256)),
    ]);
  }
  final NearbyLink link;
  final NearbyMedium medium;
  late final Uint8List hello;
  NearbyNoise? noise;
  StreamSubscription<Uint8List>? sub;
  Timer? timeout;
  _Peer? peer;
  Future<void> tail = Future.value();
  Future<void> sending = Future.value();
  int pending = 0;
  int pendingSends = 0;
  int window = 0;
  int frames = 0;
  int bytes = 0;
  Future<void> handshake(Uint8List bytes) => link
      .send(Uint8List.fromList([3, ...bytes]))
      .timeout(const Duration(seconds: 10));
  Future<void> send(Uint8List bytes) {
    if (pendingSends >= 8 ||
        bytes.isEmpty ||
        bytes.length > NearbyCourier.maxFrameBytes) {
      return Future.error(StateError('Invalid or excessive nearby sends'));
    }
    pendingSends++;
    final clear = Uint8List.fromList(bytes);
    final operation = sending.then((_) async {
      final encrypted = await noise!.sending!.encrypt(clear);
      await link
          .send(Uint8List.fromList([4, ...encrypted]))
          .timeout(const Duration(seconds: 60));
    });
    // A failed write may have partially arrived; never reuse that cipher/link.
    sending = operation;
    unawaited(operation.then<void>((_) {}, onError: (Object _) {}));
    return operation.whenComplete(() => pendingSends--);
  }
}

class _Peer implements NearbyLink {
  _Peer(this.id, this.mux);
  @override
  final String id;
  final NearbyMux mux;
  final radios = <_Radio>[];
  final input = StreamController<Uint8List>();
  int unclaimed = 0;
  _Radio get best =>
      (radios.toList()..sort((a, b) {
            final rank = a.medium.index.compareTo(b.medium.index);
            return rank == 0 ? a.link.id.compareTo(b.link.id) : rank;
          }))
          .first;
  @override
  Stream<Uint8List> get incoming => input.stream;
  @override
  Future<void> send(Uint8List bytes) async {
    final clear = Uint8List.fromList(bytes);
    while (radios.isNotEmpty) {
      final radio = best;
      try {
        await radio.send(clear);
        return;
      } catch (_) {
        mux.onEvent?.call(radio.medium, NearbyLinkEvent.writeFailed);
        await mux.remove(radio.link.id);
      }
    }
    throw StateError('No usable nearby radio');
  }

  @override
  Future<void> close() async {
    for (final radio in radios.toList()) {
      await mux.remove(radio.link.id);
    }
  }
}
