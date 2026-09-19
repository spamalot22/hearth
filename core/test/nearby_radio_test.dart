// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 19);
  test('bridge stream exposes only newly accepted durable messages', () async {
    final identity = await Identity.generate();
    final repository = MessageRepository(InMemoryMessageStorage());
    var allowed = false;
    final engine = SyncEngine(
      repository,
      'channel',
      messageAllowed: (_) => allowed,
    );
    final events = <Message>[];
    final subscription = engine.stored.listen(events.add);
    final message = await Message.create(
      author: identity,
      channel: 'channel',
      payload: Uint8List(1),
    );
    await engine.receive(message);
    await _tick();
    expect(events, isEmpty);
    allowed = true;
    await engine.receive(message);
    await engine.receive(message);
    await _tick();
    expect(events.single.idHex, message.idHex);
    expect(repository.getByHex(message.idHex), isNotNull);
    await subscription.cancel();
    await engine.close();
  });
  test('GATT framing round trips min/max MTU and maximum-size envelopes', () {
    for (final mtu in [20, 185, 512]) {
      for (final size in [1, 17, 512, NearbyMux.maxWireBytes]) {
        final frame = Uint8List.fromList(List.generate(size, (i) => i % 251));
        final reader = NearbyFragmentReader();
        Uint8List? decoded;
        for (final chunk in nearbyFragments(frame, mtu, 65537)) {
          expect(chunk.length, lessThanOrEqualTo(mtu));
          decoded = reader.add(chunk, now);
        }
        expect(decoded, frame);
      }
    }
  });
  test(
    'GATT rejects huge, truncated, reordered, interleaved and expired input',
    () {
      final chunks = nearbyFragments(Uint8List(100), 20, 1).toList();
      expect(
        () => NearbyFragmentReader().add(Uint8List(6), now),
        throwsFormatException,
      );
      expect(
        () => NearbyFragmentReader().add(Uint8List(513), now),
        throwsFormatException,
      );
      expect(
        () => NearbyFragmentReader().add(chunks[1], now),
        throwsFormatException,
      );
      final oversized = Uint8List.fromList(chunks.first);
      ByteData.sublistView(oversized).setUint16(4, 65535);
      expect(
        () => NearbyFragmentReader().add(oversized, now),
        throwsFormatException,
      );
      final reader = NearbyFragmentReader()..add(chunks.first, now);
      expect(() => reader.add(chunks.first, now), throwsFormatException);
      expect(
        () => reader.add(chunks[1], now.add(const Duration(seconds: 91))),
        throwsFormatException,
      );
    },
  );
  test('GATT frames cannot exceed the encoder bound', () {
    expect(
      () => nearbyFragments(
        Uint8List(NearbyMux.maxWireBytes + 1),
        20,
        0,
      ).toList(),
      throwsArgumentError,
    );
    expect(
      () => nearbyFragments(Uint8List(10), 19, 0).toList(),
      throwsArgumentError,
    );
  });
  test(
    'proximity filters missing RSSI, smooths noise, expires stale samples',
    () {
      final signal = ProximityObservation('ephemeral', now);
      expect(signal.band, ProximityBand.unknown);
      expect(signal.update(127, now), isFalse);
      expect(signal.update(0, now), isFalse);
      expect(signal.update(-120, now), isFalse);
      expect(signal.update(-50, now), isTrue);
      expect(signal.band, ProximityBand.near);
      signal.update(-80, now);
      expect(signal.rssi, -59);
      expect(signal.band, ProximityBand.near);
      expect(signal.stale(now.add(const Duration(seconds: 46))), isTrue);
    },
  );
  test(
    'multipath prefers Wi-Fi, falls back to BLE and coalesces one peer',
    () async {
      NearbyLink? received;
      var count = 0;
      final events = <NearbyLinkEvent>[];
      final mux = NearbyMux(
        onEvent: (_, event) => events.add(event),
        onPeer: (link) async {
          received = link;
          count++;
        },
      );
      final bluetooth = _Radio('ble');
      final wifi = _Radio('wifi');
      final remoteBle = _Radio('ble-remote');
      final remoteWifi = _Radio('wifi-remote');
      bluetooth.remote = remoteBle;
      remoteBle.remote = bluetooth;
      wifi.remote = remoteWifi;
      remoteWifi.remote = wifi;
      final incoming = <Uint8List>[];
      final remote = NearbyMux(
        onPeer: (link) async {
          link.incoming.listen(incoming.add);
        },
      );
      addTearDown(remote.close);
      addTearDown(mux.close);
      await mux.add(bluetooth, NearbyMedium.bluetooth);
      await remote.add(remoteBle, NearbyMedium.bluetooth);
      await _until(() => mux.peers.isNotEmpty && remote.peers.isNotEmpty);
      await mux.add(wifi, NearbyMedium.wifiAware);
      await remote.add(remoteWifi, NearbyMedium.wifiAware);
      await _until(
        () =>
            mux.peers.values.single == NearbyMedium.wifiAware &&
            remote.peers.values.single == NearbyMedium.wifiAware,
      );
      expect(count, 1);
      expect(events.where((e) => e == NearbyLinkEvent.secure), hasLength(2));
      expect(mux.peers.values.single, NearbyMedium.wifiAware);
      final payload = Uint8List.fromList([0, 1, 2]);
      final bleBefore = bluetooth.sent.length;
      await received!.send(payload);
      await _until(() => incoming.length == 1);
      expect(incoming.last, payload);
      expect(wifi.sent.last, isNot(payload));
      expect(wifi.sent.last.first, 4);
      expect(bluetooth.sent, hasLength(bleBefore));
      wifi.fail = true;
      await received!.send(payload);
      await _until(() => incoming.length == 2);
      expect(incoming.last, payload);
      expect(bluetooth.sent.last, isNot(payload));
      expect(mux.peers.values.single, NearbyMedium.bluetooth);
      expect(wifi.closed, isTrue);
      expect(events, contains(NearbyLinkEvent.writeFailed));
      final largest = Uint8List(NearbyCourier.maxFrameBytes)..[0] = 1;
      await received!.send(largest);
      await _until(() => incoming.length == 3);
      expect(incoming.last, largest);
      expect(bluetooth.sent.last.length, NearbyMux.maxWireBytes);
      remoteBle.input.add(Uint8List.fromList(bluetooth.sent.last));
      await _until(() => remoteBle.closed);
      expect(
        incoming,
        hasLength(3),
      ); // Replayed ciphertext never reaches courier.
      await mux.remove(bluetooth.id);
      expect(mux.peers, isEmpty);
    },
  );
  test(
    'mux rejects pre-handshake payloads and closes all radios on stop',
    () async {
      var count = 0;
      final mux = NearbyMux(
        onPeer: (_) async {
          count++;
        },
      );
      final link = _Radio('unknown');
      await mux.add(link, NearbyMedium.bluetooth);
      link.input.add(Uint8List.fromList([1, 2, 3]));
      await _tick();
      expect(count, 0);
      expect(link.closed, isTrue);
      final pending = _Radio('pending');
      await mux.add(pending, NearbyMedium.wifiAware);
      await mux.close();
      expect(pending.closed, isTrue);
    },
  );
  test(
    'mux snapshots submitted plaintext before asynchronous encryption',
    () async {
      NearbyLink? sender;
      final incoming = <Uint8List>[];
      final local = NearbyMux(
        onPeer: (link) async {
          sender = link;
        },
      );
      final remote = NearbyMux(
        onPeer: (link) async {
          link.incoming.listen(incoming.add);
        },
      );
      addTearDown(local.close);
      addTearDown(remote.close);
      final a = _Radio('a');
      final b = _Radio('b');
      a.remote = b;
      b.remote = a;
      await local.add(a, NearbyMedium.bluetooth);
      await remote.add(b, NearbyMedium.bluetooth);
      await _until(() => sender != null && remote.peers.isNotEmpty);
      final payload = Uint8List.fromList([0, 12, 34]);
      final sent = sender!.send(payload);
      payload[1] = 99;
      await sent;
      await _until(() => incoming.isNotEmpty);
      expect(incoming.single, [0, 12, 34]);
    },
  );
  test('mux bounds plaintext queued before a listener attaches', () async {
    NearbyLink? sender;
    final local = NearbyMux(
      onPeer: (link) async {
        sender = link;
      },
    );
    final remote = NearbyMux(onPeer: (_) async {});
    addTearDown(local.close);
    addTearDown(remote.close);
    final a = _Radio('a');
    final b = _Radio('b');
    a.remote = b;
    b.remote = a;
    await local.add(a, NearbyMedium.bluetooth);
    await remote.add(b, NearbyMedium.bluetooth);
    await _until(() => sender != null && remote.peers.isNotEmpty);
    for (var i = 0; i < 8; i++) {
      await sender!.send(Uint8List.fromList([0, i]));
      await _tick();
    }
    expect(b.closed, isFalse);
    await sender!.send(Uint8List.fromList([0, 8]));
    await _until(() => b.closed);
    expect(remote.peers, isEmpty);
  });
  test(
    'mux refuses loopback and oversized frames before courier ingestion',
    () async {
      var count = 0;
      final mux = NearbyMux(
        onPeer: (_) async {
          count++;
        },
      );
      addTearDown(mux.close);
      final self = _Radio('self');
      await mux.add(self, NearbyMedium.bluetooth);
      self.input.add(self.sent.single);
      await _tick();
      expect(self.closed, isTrue);
      final large = _Radio('large');
      await mux.add(large, NearbyMedium.bluetooth);
      large.input.add(Uint8List(NearbyMux.maxWireBytes + 1));
      await _tick();
      expect(large.closed, isTrue);
      expect(count, 0);
    },
  );
}

Future<void> _tick() => Future<void>.delayed(const Duration(milliseconds: 5));

Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 600 && !ready(); i++) {
    await _tick();
  }
  expect(ready(), isTrue, reason: 'Encrypted link did not become ready');
}

class _Radio implements NearbyLink {
  _Radio(this.id);
  @override
  final String id;
  final input = StreamController<Uint8List>();
  final sent = <Uint8List>[];
  bool closed = false;
  bool fail = false;
  _Radio? remote;
  @override
  Stream<Uint8List> get incoming => input.stream;
  @override
  Future<void> send(Uint8List bytes) async {
    if (fail || closed) throw StateError('Radio lost');
    sent.add(bytes);
    remote?.input.add(Uint8List.fromList(bytes));
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    unawaited(input.close());
  }
}
