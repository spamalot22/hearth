import 'package:chat_app/group_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

    test('an invite round-trips channel + inviter', () {
      final c = GroupChannel.create('Games');
      final back = GroupChannel.fromInvite(
        c.invite(inviterPubkeyHex: 'abcd', inviterName: 'Alice'),
      );
      expect(back, isNotNull);
      expect(back!.channel.id, c.id);
      expect(back.channel.key, c.key);
      expect(back.channel.name, 'Games');
      expect(back.inviterPubkey, 'abcd');
      expect(back.inviterName, 'Alice');
    });

    test('a malformed invite returns null', () {
      expect(GroupChannel.fromInvite('garbage'), isNull);
      expect(GroupChannel.fromInvite('hearth:not base64!!'), isNull);
    });
  });
}
