// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:core/core.dart';
import 'package:test/test.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

MessageRepository _repo() => MessageRepository(InMemoryMessageStorage());

/// An in-memory [FrameChannel]: a [partner]'s sends arrive on our stream.
/// Single-subscription, so frames sent before the session subscribes are
/// buffered rather than dropped.
class _Link implements FrameChannel {
  _Link([this.peerHex = 'peer']);

  @override
  final String peerHex;

  final StreamController<SyncFrame> incoming = StreamController<SyncFrame>();
  final List<SyncFrame> sent = [];
  _Link? partner;

  @override
  void send(SyncFrame frame) {
    sent.add(frame);
    partner?.incoming.add(frame);
  }

  @override
  Stream<SyncFrame> get frames => incoming.stream;
}

(_Link, _Link) _pair() {
  final a = _Link('b');
  final b = _Link('a');
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

    test('a live peer confirms only after durable receipt', () async {
      final a = _repo();
      final b = _repo();
      final engA = SyncEngine(a, 'general');
      final engB = SyncEngine(b, 'general');
      final (la, lb) = _pair();
      engA.addPeer(la);
      engB.addPeer(lb);

      final confirmed = await engA.publish(
        await msg('confirmed'),
        peerConfirmationTimeout: const Duration(seconds: 1),
      );

      expect(confirmed, isTrue);
      expect(b.length, 1);
      await engA.close();
      await engB.close();
    });

    test('publish times out when a connected peer does not confirm', () async {
      final engine = SyncEngine(_repo(), 'general');
      engine.addPeer(_Link());

      final confirmed = await engine.publish(
        await msg('unconfirmed'),
        peerConfirmationTimeout: const Duration(milliseconds: 5),
      );

      expect(confirmed, isFalse);
      await engine.close();
    });

    test('an ACK from a disallowed receipt peer is ignored', () async {
      final a = _repo();
      final b = _repo();
      final engA = SyncEngine(a, 'general', peerReceiptAllowed: (_) => false);
      final engB = SyncEngine(b, 'general');
      final (la, lb) = _pair();
      engA.addPeer(la);
      engB.addPeer(lb);

      final confirmed = await engA.publish(
        await msg('receipt rejected'),
        peerConfirmationTimeout: const Duration(milliseconds: 20),
      );

      expect(confirmed, isFalse);
      expect(b.length, 1);
      await engA.close();
      await engB.close();
    });

    test('a peer does not confirm a message it cannot store', () async {
      final full = MessageRepository(InMemoryMessageStorage(), maxMessages: 0);
      final link = _Link();
      final engine = SyncEngine(full, 'general');
      engine.addPeer(link);

      link.incoming.add(GiveFrame(await msg('over capacity')));
      await _pump();

      expect(full.length, 0);
      expect(link.sent.whereType<AckFrame>(), isEmpty);
      await engine.close();
    });

    test('a closed peer session is retired from future gossip', () async {
      final repository = _repo();
      final engine = SyncEngine(repository, 'general');
      final link = _Link();
      engine.addPeer(link);
      await link.incoming.close();
      await _pump();
      link.sent.clear();

      await engine.publish(await msg('after disconnect'));

      expect(link.sent, isEmpty);
      await engine.close();
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
      expect(link.sent.whereType<AckFrame>(), isEmpty);
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

    test('a malformed id does not poison subsequent peer frames', () async {
      final b = _repo();
      final link = _Link();
      SyncEngine(b, 'general').addPeer(link);

      link.incoming.add(const HaveFrame(['not-a-message-id']));
      link.incoming.add(GiveFrame(await msg('still delivered')));

      await _settle(() => b.length == 1);
      expect(utf8.decode(b.ordered().single.payload), 'still delivered');
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

    test('large blobs transfer in bounded chunks', () async {
      final sourceBytes = Uint8List.fromList(
        List<int>.generate(256 * 1024, (index) => index % 251),
      );
      final sourceBlobs = InMemoryBlobStore();
      final targetBlobs = InMemoryBlobStore();
      final hash = await sourceBlobs.put(sourceBytes);
      final source = SyncEngine(_repo(), 'general', blobStore: sourceBlobs);
      final target = SyncEngine(_repo(), 'general', blobStore: targetBlobs);
      final (sourceLink, targetLink) = _pair();
      source.addPeer(sourceLink);
      target.addPeer(targetLink);

      String? arrived;
      final arrivedSub = target.blobArrived.listen((value) => arrived = value);
      target.requestBlob(hash);

      await _settle(() => arrived == hash);
      expect(await targetBlobs.get(hash), sourceBytes);
      final chunks = sourceLink.sent.whereType<GiveBlobChunkFrame>().toList();
      expect(chunks.length, greaterThan(1));
      expect(
        chunks.every((chunk) => chunk.encode().length < 64 * 1024),
        isTrue,
      );
      expect(sourceLink.sent.whereType<GiveBlobFrame>(), isEmpty);
      await arrivedSub.cancel();
      await source.close();
      await target.close();
    });

    test('legacy blob requests still receive a single frame', () async {
      final sourceBytes = Uint8List(64 * 1024);
      final sourceBlobs = InMemoryBlobStore();
      final hash = await sourceBlobs.put(sourceBytes);
      final source = SyncEngine(_repo(), 'general', blobStore: sourceBlobs);
      final link = _Link();
      source.addPeer(link);

      link.incoming.add(WantBlobFrame(hash));
      await _settle(() => link.sent.whereType<GiveBlobFrame>().isNotEmpty);

      expect(link.sent.whereType<GiveBlobChunkFrame>(), isEmpty);
      expect(link.sent.whereType<GiveBlobFrame>().single.bytes, sourceBytes);
      await source.close();
      await link.incoming.close();
    });

    test('out-of-order blob chunks are ignored', () async {
      final targetBlobs = InMemoryBlobStore();
      final target = SyncEngine(_repo(), 'general', blobStore: targetBlobs);
      final link = _Link();
      target.addPeer(link);
      final bytes = _b('ordered bytes');
      final hash = await blobHash(bytes);
      target.requestBlob(hash);

      link.incoming.add(GiveBlobChunkFrame(hash, 1, bytes.length, bytes));
      await _pump();

      expect(await targetBlobs.has(hash), isFalse);
      await target.close();
      await link.incoming.close();
    });

    test('bytes that do not match the requested id are dropped', () async {
      final bBlobs = InMemoryBlobStore();
      final engB = SyncEngine(_repo(), 'general', blobStore: bBlobs);
      final link = _Link();
      engB.addPeer(link);

      final claimed = await blobHash(_b('what was asked for'));
      engB.requestBlob(claimed);
      link.incoming.add(GiveBlobFrame(claimed, _b('evil different bytes')));

      await _pump();
      expect(await bBlobs.has(claimed), isFalse);
    });

    test('an unsolicited blob is dropped', () async {
      final targetBlobs = InMemoryBlobStore();
      final engine = SyncEngine(_repo(), 'general', blobStore: targetBlobs);
      final link = _Link();
      engine.addPeer(link);
      final bytes = _b('not requested');
      final hash = await blobHash(bytes);

      link.incoming.add(GiveBlobFrame(hash, bytes));
      await _pump();

      expect(await targetBlobs.has(hash), isFalse);
      await engine.close();
      await link.incoming.close();
    });

    test(
      'malformed and excessive pending blob requests are rejected',
      () async {
        final engine = SyncEngine(_repo(), 'general');
        expect(engine.requestBlob('not-a-hash'), isFalse);
        for (var i = 0; i < 1000; i++) {
          final hash = '1220${i.toRadixString(16).padLeft(64, '0')}';
          expect(engine.requestBlob(hash), isTrue);
        }
        expect(
          engine.requestBlob('1220${List.filled(64, 'f').join()}'),
          isFalse,
        );
        await engine.close();
      },
    );

    test(
      'a blob requested before peers connect is retried on connect',
      () async {
        final sourceBlobs = InMemoryBlobStore();
        final targetBlobs = InMemoryBlobStore();
        final hash = await sourceBlobs.put(_b('late peer blob'));
        final source = SyncEngine(_repo(), 'general', blobStore: sourceBlobs);
        final target = SyncEngine(_repo(), 'general', blobStore: targetBlobs);
        var arrived = false;
        final arrivedSub = target.blobArrived.listen((value) {
          if (value == hash) arrived = true;
        });

        target.requestBlob(hash);
        final (sourceLink, targetLink) = _pair();
        source.addPeer(sourceLink);
        target.addPeer(targetLink);

        await _settle(() => arrived);
        expect(await targetBlobs.get(hash), _b('late peer blob'));
        await arrivedSub.cancel();
        await source.close();
        await target.close();
      },
    );
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

    test('drops a valid message for another channel', () async {
      final r = _repo();
      final m = await Message.create(
        author: await Identity.generate(),
        channel: 'elsewhere',
        payload: _b('valid but misplaced'),
      );
      await SyncEngine(r, 'general').receive(m);
      expect(r.length, 0);
    });

    test('applies a channel-level author policy', () async {
      final r = _repo();
      final allowed = await Identity.generate();
      final outsider = await Identity.generate();
      final engine = SyncEngine(
        r,
        'general',
        messageAllowed: (message) =>
            hex.encode(message.author) == allowed.publicKeyHex,
      );
      await engine.receive(
        await Message.create(
          author: outsider,
          channel: 'general',
          payload: _b('outsider'),
        ),
      );
      await engine.receive(
        await Message.create(
          author: allowed,
          channel: 'general',
          payload: _b('allowed'),
        ),
      );
      expect(r.length, 1);
      expect(utf8.decode(r.ordered().single.payload), 'allowed');
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

    test(
      'a revoked device messages are rejected via isDeviceRevoked',
      () async {
        final r = _repo();
        final root = await Identity.generate();
        final device = await Identity.generate();
        final cert = await DeviceCert.issue(
          root: root,
          deviceKey: device.publicKey,
          name: 'phone',
        );
        final m = await Message.create(
          author: root,
          channel: 'general',
          payload: _b('should be dropped'),
          signingDevice: device,
          deviceCert: cert,
        );
        // The device is revoked — the callback says so.
        final revokedSet = {
          '${root.publicKeyHex}:${hex.encode(device.publicKey)}',
        };
        final engine = SyncEngine(
          r,
          'general',
          isDeviceRevoked: (rootHex, deviceHex) =>
              revokedSet.contains('$rootHex:$deviceHex'),
        );
        await engine.receive(m);
        expect(r.length, 0, reason: 'revoked device message should be dropped');
      },
    );

    test('a revocation from another root cannot suppress a device', () async {
      final r = _repo();
      final root = await Identity.generate();
      final otherRoot = await Identity.generate();
      final device = await Identity.generate();
      final cert = await DeviceCert.issue(
        root: root,
        deviceKey: device.publicKey,
        name: 'phone',
      );
      final message = await Message.create(
        author: root,
        channel: 'general',
        payload: _b('allowed'),
        signingDevice: device,
        deviceCert: cert,
      );
      final engine = SyncEngine(
        r,
        'general',
        isDeviceRevoked: (rootHex, deviceHex) =>
            rootHex == otherRoot.publicKeyHex &&
            deviceHex == device.publicKeyHex,
      );

      await engine.receive(message);
      expect(r.length, 1);
    });
  });
}
