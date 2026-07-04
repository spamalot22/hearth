// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:test/test.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

MessageRepository _repo() => MessageRepository(InMemoryMessageStorage());

/// An in-memory [FrameChannel]: a [partner]'s sends arrive on our stream.
/// Single-subscription, so frames sent before the session subscribes are
/// buffered rather than dropped.
class _Link implements FrameChannel {
  final StreamController<SyncFrame> incoming = StreamController<SyncFrame>();
  _Link? partner;

  @override
  void send(SyncFrame frame) => partner?.incoming.add(frame);

  @override
  Stream<SyncFrame> get frames => incoming.stream;
}

(_Link, _Link) _pair() {
  final a = _Link();
  final b = _Link();
  a.partner = b;
  b.partner = a;
  return (a, b);
}

/// Pumps the event loop until [done] (the protocol is finite, so it converges),
/// bailing out after a bounded number of turns.
Future<void> _settle(bool Function() done) async {
  for (var i = 0; i < 2000 && !done(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Pumps a fixed number of turns — for asserting something does *not* happen.
Future<void> _pump([int turns = 100]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('gossip sync', () {
    late Identity alice;

    setUp(() async {
      alice = await Identity.generate();
    });

    Future<Message> msg(String text, {List<Uint8List> prev = const []}) =>
        Message.create(
          author: alice,
          channel: 'general',
          payload: _b(text),
          prev: prev,
        );

    test('backfills a peer with the whole chain from heads alone', () async {
      final a = _repo();
      final b = _repo();
      final m1 = await msg('one');
      final m2 = await msg('two', prev: [m1.id]);
      final m3 = await msg('three', prev: [m2.id]);
      for (final m in [m1, m2, m3]) {
        await a.add(m);
      }

      final (la, lb) = _pair();
      SyncEngine(a, 'general').addPeer(la);
      SyncEngine(b, 'general').addPeer(lb);

      await _settle(() => b.length == 3);
      expect(b.length, 3);
      expect(b.ordered().map((m) => utf8.decode(m.payload)).toList(), [
        'one',
        'two',
        'three',
      ]);
    });

    test('merges disjoint histories both ways', () async {
      final a = _repo();
      final b = _repo();
      await a.add(await msg('a'));
      await b.add(await msg('b'));

      final (la, lb) = _pair();
      SyncEngine(a, 'general').addPeer(la);
      SyncEngine(b, 'general').addPeer(lb);

      await _settle(() => a.length == 2 && b.length == 2);
      expect(a.length, 2);
      expect(b.length, 2);
    });

    test('a live publish reaches a connected peer', () async {
      final a = _repo();
      final b = _repo();
      final engA = SyncEngine(a, 'general');
      final (la, lb) = _pair();
      engA.addPeer(la);
      SyncEngine(b, 'general').addPeer(lb);

      await engA.publish(await msg('live'));

      await _settle(() => b.length == 1);
      expect(b.ordered().map((m) => utf8.decode(m.payload)), ['live']);
    });

    test('epidemic: A→B→C delivers without A ever talking to C', () async {
      final a = _repo();
      final b = _repo();
      final c = _repo();
      final engA = SyncEngine(a, 'general');
      final engB = SyncEngine(b, 'general');
      final engC = SyncEngine(c, 'general');

      // A<->B and B<->C; A and C are never linked.
      final (labA, labB) = _pair();
      final (lbcB, lbcC) = _pair();
      engA.addPeer(labA);
      engB.addPeer(labB);
      engB.addPeer(lbcB);
      engC.addPeer(lbcC);

      await engA.publish(await msg('relayed'));

      await _settle(() => c.length == 1);
      expect(c.ordered().map((m) => utf8.decode(m.payload)), ['relayed']);
    });

    test('drops a forged message (tampered payload)', () async {
      final b = _repo();
      final link = _Link();
      SyncEngine(b, 'general').addPeer(link);

      final good = await msg('hi');
      final forged = Message.fromJson({
        ...good.toJson(),
        'payload': base64Url.encode(_b('evil')), // breaks signature + id
      });
      link.incoming.add(GiveFrame(forged));

      await _pump();
      expect(b.length, 0);
    });

    test('drops a message addressed to another channel', () async {
      final b = _repo();
      final link = _Link();
      SyncEngine(b, 'general').addPeer(link);

      final elsewhere = await Message.create(
        author: alice,
        channel: 'secret',
        payload: _b('x'),
      );
      link.incoming.add(GiveFrame(elsewhere));

      await _pump();
      expect(b.length, 0);
    });
  });

  group('blob transfer', () {
    test('a peer fetches a blob it lacks via want/give', () async {
      final aBlobs = InMemoryBlobStore();
      final bBlobs = InMemoryBlobStore();
      final hash = await aBlobs.put(_b('sticker bytes')); // A holds it
      final engA = SyncEngine(_repo(), 'general', blobStore: aBlobs);
      final engB = SyncEngine(_repo(), 'general', blobStore: bBlobs);
      final (la, lb) = _pair();
      engA.addPeer(la);
      engB.addPeer(lb);

      String? arrived;
      engB.blobArrived.listen((h) => arrived = h);
      engB.requestBlob(hash);

      await _settle(() => arrived != null);
      expect(arrived, hash);
      expect(await bBlobs.get(hash), _b('sticker bytes'));
    });

    test('bytes that do not match the requested id are dropped', () async {
      final bBlobs = InMemoryBlobStore();
      final engB = SyncEngine(_repo(), 'general', blobStore: bBlobs);
      final link = _Link();
      engB.addPeer(link);

      final claimed = await blobHash(_b('what was asked for'));
      link.incoming.add(GiveBlobFrame(claimed, _b('evil different bytes')));

      await _pump();
      expect(await bBlobs.has(claimed), isFalse);
    });
  });

  group('receive (untrusted courier ingestion)', () {
    test('stores a valid message', () async {
      final r = _repo();
      final m = await Message.create(
        author: await Identity.generate(),
        channel: 'general',
        payload: _b('hi'),
      );
      await SyncEngine(r, 'general').receive(m);
      expect(r.length, 1);
    });

    test('drops a tampered message (unlike publish)', () async {
      final r = _repo();
      final author = await Identity.generate();
      final m = await Message.create(
        author: author,
        channel: 'general',
        payload: _b('hi'),
      );
      final forged = Message.fromJson({
        ...m.toJson(),
        'payload': base64Url.encode(_b('evil')),
      });
      await SyncEngine(r, 'general').receive(forged);
      expect(r.length, 0, reason: 'receive verifies before storing');
    });

    test('drops a device-signed message with an invalid cert', () async {
      final r = _repo();
      final root = await Identity.generate();
      final device = await Identity.generate();
      final wrongRoot = await Identity.generate();
      // Cert issued by the wrong root — the chain does not verify.
      final badCert = await DeviceCert.issue(
        root: wrongRoot,
        deviceKey: device.publicKey,
        name: 'x',
      );
      final m = await Message.create(
        author: root,
        channel: 'general',
        payload: _b('hi'),
        signingDevice: device,
        deviceCert: badCert,
      );
      await SyncEngine(r, 'general').receive(m);
      expect(r.length, 0);
    });
  });
}
