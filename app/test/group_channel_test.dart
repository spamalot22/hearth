// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/group_channel.dart';

void main() {
  const inviterHex =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  group('GroupChannel', () {
    test('create makes a random id and a 32-byte key', () {
      final c = GroupChannel.create('My Room');
      expect(c.name, 'My Room');
      expect(c.key.length, 32);
      expect(c.id.length, 32); // 16 bytes as hex
    });

    test('two created channels have different ids (no collisions)', () {
      expect(GroupChannel.create('x').id, isNot(GroupChannel.create('x').id));
    });

    test('an invite round-trips channel + inviter + relay', () {
      final c = GroupChannel.create('Games');
      final back = GroupChannel.fromInvite(
        c.invite(
          inviterPubkeyHex: inviterHex,
          inviterName: 'Alice',
          relayUrl: 'https://relay.example.com',
        ),
      );
      expect(back, isNotNull);
      expect(back!.channel.id, c.id);
      expect(back.channel.key, c.key);
      expect(back.channel.name, 'Games');
      expect(back.channel.knownMembers, {inviterHex});
      expect(back.inviterPubkey, inviterHex);
      expect(back.inviterName, 'Alice');
      expect(back.relayUrl, 'https://relay.example.com');
      expect(back.channel.withName('Renamed').knownMembers, {inviterHex});
      expect(back.channel.epoch, c.epoch);
    });

    test('rotated key epochs survive registry encoding', () {
      final original = GroupChannel.create('Secure');
      final rotated = original.rotate(Uint8List(32)..fillRange(0, 32, 7), 1);
      expect(rotated.epoch, 1);
      expect(rotated.keys.keys, containsAll([0, 1]));
      expect(rotated.key, everyElement(7));
    });

    test('a malformed invite returns null', () {
      expect(GroupChannel.fromInvite('garbage'), isNull);
      expect(GroupChannel.fromInvite('hearth:not base64!!'), isNull);
      expect(
        GroupChannel.fromInvite(
          GroupChannel.create('bad').invite(inviterPubkeyHex: 'abcd'),
        ),
        isNull,
      );
      expect(GroupChannel.fromInvite('hearth:${'a' * (16 * 1024)}'), isNull);
    });
  });
}
