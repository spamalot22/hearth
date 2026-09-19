// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:test/test.dart';

class _Storage implements NearbyQueueStorage {
  List<NearbyQueueEntry> entries = [];
  bool fail = false;
  @override
  Future<List<NearbyQueueEntry>> read() async => entries;
  @override
  Future<void> replace(List<NearbyQueueEntry> value) async {
    if (fail) throw StateError('disk unavailable');
    entries = List.of(value);
  }
}

class _Link implements NearbyLink {
  _Link(this.id);
  @override
  final String id;
  final stream = StreamController<Uint8List>();
  late _Link other;
  bool closed = false;
  @override
  Stream<Uint8List> get incoming => stream.stream;
  @override
  Future<void> send(Uint8List bytes) async {
    if (!closed && !other.closed) other.stream.add(bytes);
  }

  @override
  Future<void> close() async {
    closed = true;
    unawaited(stream.close());
  }
}

Future<void> _connect(NearbyCourier a, NearbyCourier b, String label) async {
  final left = _Link('$label-left');
  final right = _Link('$label-right');
  left.other = right;
  right.other = left;
  await a.attach(left);
  await b.attach(right);
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}

void main() {
  final start = DateTime.utc(2026, 9, 17);
  late Identity sender;
  setUp(() async => sender = await Identity.generate());

  Future<NearbyPacket> packet(int value, {DateTime? at}) => NearbyPacket.create(
    sender: sender,
    route: 'a' * 64,
    encryptedBody: Uint8List.fromList(List.filled(40, value)),
    now: at ?? start,
  );

  test('intranet activates automatic mode; disabling always wins', () {
    final policy = NearbyActivationPolicy();
    NearbyActivation evaluate(
      int seconds,
      InternetReachability internet, {
      bool enabled = true,
      bool permitted = true,
    }) => policy.evaluate(
      enabled: enabled,
      automatic: true,
      internet: internet,
      permitted: permitted,
      now: start.add(Duration(seconds: seconds)),
    );
    expect(evaluate(0, InternetReachability.offline), NearbyActivation.standby);
    expect(evaluate(10, InternetReachability.offline), NearbyActivation.active);
    expect(evaluate(11, InternetReachability.unknown), NearbyActivation.active);
    expect(evaluate(12, InternetReachability.online), NearbyActivation.active);
    expect(evaluate(42, InternetReachability.online), NearbyActivation.standby);
    expect(
      evaluate(43, InternetReachability.offline),
      NearbyActivation.standby,
    );
    expect(
      evaluate(53, InternetReachability.offline, permitted: false),
      NearbyActivation.waitingForPermission,
    );
    expect(
      evaluate(54, InternetReachability.offline, enabled: false),
      NearbyActivation.disabled,
    );
  });

  test(
    'manual nearby mode works with Internet; unknown does not auto-start',
    () {
      final policy = NearbyActivationPolicy();
      expect(
        policy.evaluate(
          enabled: true,
          automatic: true,
          internet: InternetReachability.unknown,
          permitted: true,
          now: start,
        ),
        NearbyActivation.standby,
      );
      expect(
        policy.evaluate(
          enabled: true,
          automatic: false,
          internet: InternetReachability.online,
          permitted: true,
          now: start,
        ),
        NearbyActivation.active,
      );
    },
  );

  test('usable Aware preferred, unavailable Aware does not displace BLE', () {
    const ble = NearbyRoute(
      id: 'ble',
      medium: NearbyMedium.bluetooth,
      usable: true,
    );
    const lan = NearbyRoute(
      id: 'lan',
      medium: NearbyMedium.wifiAware,
      usable: false,
    );
    const direct = NearbyRoute(
      id: 'p2p',
      medium: NearbyMedium.wifiAware,
      usable: true,
    );
    expect(NearbyRoute.preferred([lan, ble]), same(ble));
    expect(NearbyRoute.preferred([ble, lan, direct]), same(direct));
    expect(NearbyRoute.preferred([lan]), isNull);
  });

  test('signed envelope round trips and has immutable bytes', () async {
    final p = await packet(1);
    final decoded = await NearbyPacket.decode(p.encode(), now: start);
    expect(decoded?.id, p.id);
    expect(decoded?.body, p.body);
    expect(() => p.body[0] = 42, throwsUnsupportedError);
    expect(() => p.sender[0] = 42, throwsUnsupportedError);
  });

  test(
    'tampering with route, body, identity, id, or expiry is rejected',
    () async {
      final p = await packet(1);
      for (final change in <String, Object>{
        'route': 'b' * 64,
        'body': base64Url.encode(List.filled(40, 2)),
        'sender': base64Url.encode((await Identity.generate()).publicKey),
        'expires': p.expiresMs - 1,
        'created': p.createdMs - 1,
        'id': '0' * 64,
        'v': 2,
      }.entries) {
        final json =
            jsonDecode(utf8.decode(p.encode())) as Map<String, dynamic>;
        json[change.key] = change.value;
        expect(
          await NearbyPacket.decode(utf8.encode(jsonEncode(json)), now: start),
          isNull,
          reason: change.key,
        );
      }
    },
  );

  test(
    'expired, far future, malformed and oversized packets are rejected',
    () async {
      final p = await packet(1);
      expect(
        await NearbyPacket.decode(
          p.encode(),
          now: start.add(const Duration(days: 1)),
        ),
        isNull,
      );
      expect(
        await NearbyPacket.decode(
          p.encode(),
          now: start.subtract(const Duration(minutes: 6)),
        ),
        isNull,
      );
      for (final raw in [
        'null',
        '[]',
        '{',
        '{"v":1}',
        'x' * (NearbyPacket.maxWireBytes + 1),
      ]) {
        expect(await NearbyPacket.decode(utf8.encode(raw), now: start), isNull);
      }
      await expectLater(
        NearbyPacket.create(
          sender: sender,
          route: 'a' * 64,
          encryptedBody: Uint8List(NearbyPacket.maxBodyBytes + 1),
          now: start,
        ),
        throwsArgumentError,
      );
      await expectLater(
        NearbyPacket.create(
          sender: sender,
          route: 'a' * 64,
          encryptedBody: Uint8List(40),
          now: start,
          lifetime: const Duration(days: 2),
        ),
        throwsArgumentError,
      );
    },
  );

  test('duplicates serialize; capacity leaves room for owner', () async {
    final storage = _Storage();
    final q = NearbyQueue(storage, maxEntries: 4, now: () => start);
    final first = await packet(1);
    expect(await Future.wait([q.add(first), q.add(first)]), [
      NearbyAdmission.stored,
      NearbyAdmission.duplicate,
    ]);
    expect(await q.add(await packet(2)), NearbyAdmission.stored);
    expect(await q.add(await packet(3)), NearbyAdmission.stored);
    expect(await q.add(await packet(4)), NearbyAdmission.full);
    expect(await q.add(await packet(4), local: true), NearbyAdmission.stored);
    expect(q.packets.length, 4);
    expect(await q.add(await packet(5), local: true), NearbyAdmission.stored);
    expect(q.packets.map((p) => p.id), isNot(contains(first.id)));
  });

  test('per-sender and byte caps apply independently of count', () async {
    final q = NearbyQueue(_Storage(), maxPerSender: 1, now: () => start);
    expect(await q.add(await packet(1)), NearbyAdmission.stored);
    expect(await q.add(await packet(2)), NearbyAdmission.full);
    final bytes = NearbyQueue(
      _Storage(),
      maxBytes: NearbyPacket.maxWireBytes,
      now: () => start,
    );
    final large = await NearbyPacket.create(
      sender: sender,
      route: 'a' * 64,
      encryptedBody: Uint8List(NearbyPacket.maxBodyBytes),
      now: start,
    );
    expect(await bytes.add(large), NearbyAdmission.full); // foreign byte quota
    expect(await bytes.add(large, local: true), NearbyAdmission.stored);
    expect(await bytes.add(await packet(1)), NearbyAdmission.stored);
    expect(bytes.byteCount, lessThanOrEqualTo(NearbyPacket.maxWireBytes));
  });

  test(
    'storage failure never reports custody and subsequent writes recover',
    () async {
      final storage = _Storage()..fail = true;
      final q = NearbyQueue(storage, now: () => start);
      final p = await packet(1);
      await expectLater(q.add(p), throwsStateError);
      expect(q.packets, isEmpty);
      storage.fail = false;
      expect(await q.add(p), NearbyAdmission.stored);
      final reload = NearbyQueue(storage, now: () => start);
      await reload.load();
      expect(reload.packets.single.id, p.id);
    },
  );

  test('expiry is not extended by forwarding or reloading', () async {
    final storage = _Storage();
    var now = start;
    final q = NearbyQueue(storage, now: () => now);
    final p = await packet(1);
    await q.add(p);
    now = now.add(const Duration(days: 1));
    expect(q.packets, isEmpty);
    expect(await q.add(p), NearbyAdmission.expired);
    await q.prune();
    expect(storage.entries, isEmpty);
    expect(q.byteCount, 0);
  });

  test(
    'encrypted text crosses different links via a restarted stranger courier',
    () async {
      final key = Uint8List.fromList(List.generate(32, (i) => i));
      final body = await GroupCipher.encrypt(
        utf8.encode('private text'),
        key: key,
      );
      final p = await NearbyPacket.create(
        sender: sender,
        route: 'a' * 64,
        encryptedBody: body,
        now: start,
      );
      final middleStorage = _Storage();
      final qa = NearbyQueue(_Storage(), now: () => start);
      final qb = NearbyQueue(middleStorage, now: () => start);
      final qc = NearbyQueue(_Storage(), now: () => start);
      final a = NearbyCourier(queue: qa, now: () => start);
      final b = NearbyCourier(queue: qb, now: () => start);
      final received = <NearbyPacket>[];
      final c = NearbyCourier(
        queue: qc,
        now: () => start,
        onPacket: (p) async {
          received.add(p);
        },
      );
      addTearDown(a.close);
      addTearDown(b.close);
      addTearDown(c.close);
      await a.publish(p);
      await _connect(a, b, 'wifi-direct');
      await _until(() => qb.packets.length == 1);
      // The sender is gone before the destination encounters the carrier.
      await a.close();
      await b.close();
      final restored = NearbyQueue(middleStorage, now: () => start);
      await restored.load();
      final carrier = NearbyCourier(queue: restored, now: () => start);
      addTearDown(carrier.close);
      await _connect(carrier, c, 'bluetooth');
      await _until(() => received.length == 1);
      expect(
        utf8.decode(await GroupCipher.decrypt(received.single.body, key: key)),
        'private text',
      );
      expect(received.single.id, p.id);
      await carrier.reconcile();
      await c.reconcile();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(received, hasLength(1));
    },
  );

  test(
    'malformed or oversized radio traffic cannot enter the courier queue',
    () async {
      final queue = NearbyQueue(_Storage(), now: () => start);
      final courier = NearbyCourier(queue: queue, now: () => start);
      addTearDown(courier.close);
      final a = _Link('a');
      final b = _Link('b');
      a.other = b;
      b.other = a;
      addTearDown(b.close);
      await courier.attach(a);
      await b.send(Uint8List.fromList([1, ...utf8.encode('{}')]));
      await b.send(Uint8List(NearbyCourier.maxFrameBytes + 1));
      await _until(() => courier.linkCount == 0);
      expect(queue.packets, isEmpty);
    },
  );
}
