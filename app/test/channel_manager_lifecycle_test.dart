// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/channel.dart';

void main() {
  late ChannelManager manager;
  final key = Uint8List(32);

  setUp(() async {
    manager = ChannelManager(
      identity: await Identity.generate(),
      relayUrl: Uri.parse('https://relay.example'),
      live: false,
      onUpdate: () {},
    );
  });
  tearDown(() => manager.close());

  test('simultaneous group opens share one session', () async {
    final first = manager.openGroup('room', key);
    ChannelSession? observed;
    final second = manager
        .openGroup('room', key)
        .then((_) => observed = manager.active);
    await first;
    final original = manager.active;
    await second;
    expect(identical(original, observed), isTrue);
    expect(manager.sessions, hasLength(1));
  });

  test('leave queued during opening cannot resurrect the channel', () async {
    final opening = manager.openGroup('room', key);
    final leaving = manager.leave('room');
    await opening;
    await leaving;
    expect(manager.sessions, isEmpty);
    expect(manager.activeId, isNull);
  });

  test(
    'replacement queued during opening installs the latest group key',
    () async {
      final opening = manager.openGroup('room', key);
      final newKey = Uint8List.fromList(List<int>.filled(32, 7));
      final replacing = manager.openGroup(
        'room',
        newKey,
        epoch: 1,
        replace: true,
      );
      await opening;
      final original = manager.active;
      await replacing;
      expect(identical(manager.active, original), isFalse);
      final plaintext = Uint8List.fromList([1, 2, 3]);
      final cipher = GroupChannelCipher({1: newKey}, 1);
      expect(
        await manager.active!.cipher.decrypt(await cipher.encrypt(plaintext)),
        plaintext,
      );
    },
  );

  test('shutdown while channels are opening leaves no sessions', () async {
    final peer = await Identity.generate();
    final opening = manager.openGroup('room', key);
    final dm = manager.openDm(peer.publicKey);
    await Future<void>.value();
    await manager.close();
    await opening;
    await dm;
    await manager.openGroup('later', key);
    expect(manager.sessions, isEmpty);
    expect(manager.activeId, isNull);
  });
}
