// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/channel.dart';
import 'package:hearth/content.dart';

import 'support/poll_logic_checks.dart';

void main() {
  test('poll codecs and deterministic single-choice tally', () {
    expect(checkPollLogic(), greaterThan(1500));
  });

  late Identity alice;
  late Identity bob;
  late ChannelSession left;
  late ChannelSession right;
  final revoked = <String>{};

  Future<ChannelSession> open(Identity self, {ChannelCipher? cipher}) =>
      ChannelSession.open(
        channelId: 'poll-room',
        identity: self,
        relayUrl: Uri.parse('https://relay.example'),
        live: false,
        onUpdate: () {},
        blobStore: null,
        cipher: cipher ?? GroupChannelCipher({0: Uint8List(32)}, 0),
        isDeviceRevoked: (_, device) => revoked.contains(device),
      );

  setUp(() async {
    revoked.clear();
    alice = await Identity.generate();
    bob = await Identity.generate();
    left = await open(alice);
    right = await open(bob);
  });
  tearDown(() async {
    await left.close();
    await right.close();
  });

  Future<Message> message(
    Identity author,
    Content content, {
    List<Uint8List> prev = const [],
    Identity? device,
    DeviceCert? cert,
  }) async => Message.create(
    author: author,
    channel: 'poll-room',
    payload: await left.encodePayload(content),
    prev: prev,
    signingDevice: device,
    deviceCert: cert,
  );

  test(
    'encrypted offline votes converge despite reversed arrival and replay',
    () async {
      final poll = await message(
        alice,
        PollContent('Lunch?', ['Pizza', 'Soup']),
      );
      final a = await message(
        alice,
        PollVoteContent(poll.idHex, 0),
        prev: [poll.id],
      );
      final b = await message(
        bob,
        PollVoteContent(poll.idHex, 0),
        prev: [poll.id],
      );
      final changed = await message(
        alice,
        PollVoteContent(poll.idHex, 1),
        prev: [a.id],
      );
      final messages = [poll, a, b, changed];
      for (final m in messages) {
        await left.engine.receive(m);
      }
      for (final m in messages.reversed) {
        await right.engine.receive(m);
      }
      await right.engine.receive(changed);
      await left.refreshContent();
      await right.refreshContent();
      expect(left.pollOf(poll.idHex)!.counts, [1, 1]);
      expect(right.pollOf(poll.idHex)!.votes, left.pollOf(poll.idHex)!.votes);
      expect(right.repository.length, 4);
      expect(right.contentOf(changed).isBookkeeping, isTrue);
      final withdrawn = await message(
        bob,
        PollVoteContent(poll.idHex, null),
        prev: [b.id],
      );
      await right.engine.receive(withdrawn);
      await right.refreshContent();
      expect(right.pollOf(poll.idHex)!.counts, [0, 1]);
    },
  );

  test(
    'signed devices share one root vote and revoked devices are excluded',
    () async {
      final device1 = await Identity.generate();
      final device2 = await Identity.generate();
      final cert1 = await DeviceCert.issue(
        root: bob,
        deviceKey: device1.publicKey,
        name: 'Phone',
      );
      final cert2 = await DeviceCert.issue(
        root: bob,
        deviceKey: device2.publicKey,
        name: 'Tablet',
      );
      final poll = await message(
        alice,
        PollContent('Day?', ['Friday', 'Saturday']),
      );
      final first = await message(
        bob,
        PollVoteContent(poll.idHex, 0),
        prev: [poll.id],
        device: device1,
        cert: cert1,
      );
      final second = await message(
        bob,
        PollVoteContent(poll.idHex, 1),
        prev: [first.id],
        device: device2,
        cert: cert2,
      );
      for (final m in [poll, first, second]) {
        await left.engine.receive(m);
      }
      await left.refreshContent();
      expect(left.pollOf(poll.idHex)!.votes, {bob.publicKeyHex: 1});
      revoked.add(device2.publicKeyHex);
      await left.refreshContent();
      expect(left.pollOf(poll.idHex)!.votes, {bob.publicKeyHex: 0});
    },
  );

  test('foreign deletion cannot remove a poll; creator deletion can', () async {
    final poll = await message(alice, PollContent('Q?', ['A', 'B']));
    await left.engine.receive(poll);
    await left.engine.receive(
      await message(bob, DeleteContent(poll.idHex), prev: [poll.id]),
    );
    await left.refreshContent();
    expect(left.pollOf(poll.idHex), isNotNull);
    await left.engine.receive(
      await message(alice, DeleteContent(poll.idHex), prev: [poll.id]),
    );
    await left.refreshContent();
    expect(left.pollOf(poll.idHex), isNull);
    expect(left.isDeleted(poll.idHex), isTrue);
  });

  test(
    'concurrent content refresh callers wait for decrypted poll state',
    () async {
      final gate = Completer<void>();
      final cipher = _DelayedCipher(
        GroupChannelCipher({0: Uint8List(32)}, 0),
        gate.future,
      );
      final session = await open(alice, cipher: cipher);
      addTearDown(session.close);
      final poll = await message(alice, PollContent('Q?', ['A', 'B']));
      await session.engine.receive(poll);
      final first = session.refreshContent();
      var finished = false;
      final second = session.refreshContent().then((_) => finished = true);
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      gate.complete();
      await first;
      await second;
      expect(session.pollOf(poll.idHex), isNotNull);
    },
  );
}

class _DelayedCipher implements ChannelCipher {
  _DelayedCipher(this.inner, this.gate);
  final ChannelCipher inner;
  final Future<void> gate;
  @override
  Future<Uint8List> encrypt(List<int> plaintext) => inner.encrypt(plaintext);
  @override
  Future<Uint8List> decrypt(Uint8List boxed, {Uint8List? senderDevice}) async {
    await gate;
    return inner.decrypt(boxed, senderDevice: senderDevice);
  }
}
