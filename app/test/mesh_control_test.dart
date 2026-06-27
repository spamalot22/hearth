import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/mesh_control.dart';

void main() {
  group('MeshControl', () {
    test('PeersControl round-trips through the control envelope', () {
      final wire = const PeersControl(['aa', 'bb']).encode();
      final split = splitFrame(wire);
      expect(split.isControl, isTrue);

      final back = MeshControl.decodeBody(split.body);
      expect(back, isA<PeersControl>());
      expect((back! as PeersControl).peers, ['aa', 'bb']);
    });

    test('SignalControl round-trips with its signed payload', () {
      final wire = const SignalControl(
        to: 'x',
        from: 'y',
        kind: 'offer',
        data: {'sdp': '...', 'sig': 'deadbeef'},
      ).encode();

      final back = MeshControl.decodeBody(splitFrame(wire).body);
      expect(back, isA<SignalControl>());
      final s = back! as SignalControl;
      expect([s.to, s.from, s.kind], ['x', 'y', 'offer']);
      expect(s.data['sig'], 'deadbeef');
    });

    test('gossip frames are tagged and unwrap to the original text', () {
      const sync = '{"t":"have","ids":["a"]}';
      final split = splitFrame(wrapGossip(sync));
      expect(split.isControl, isFalse);
      expect(split.body, sync);
    });

    test('an untagged legacy JSON frame is treated as gossip, intact', () {
      const legacy = '{"t":"have"}'; // starts with '{', not a tag char
      final split = splitFrame(legacy);
      expect(split.isControl, isFalse);
      expect(split.body, legacy);
    });

    test('a malformed control body decodes to null, not a throw', () {
      expect(MeshControl.decodeBody('not json {'), isNull);
      expect(MeshControl.decodeBody('{"t":"unknown"}'), isNull);
    });
  });
}
