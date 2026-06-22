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

    test('an invite round-trips id, key and name', () {
      final c = GroupChannel.create('Games');
      final back = GroupChannel.fromInvite(c.invite());
      expect(back, isNotNull);
      expect(back!.id, c.id);
      expect(back.key, c.key);
      expect(back.name, 'Games');
    });

    test('a malformed invite returns null', () {
      expect(GroupChannel.fromInvite('garbage'), isNull);
      expect(GroupChannel.fromInvite('hearth:not base64!!'), isNull);
    });
  });
}
