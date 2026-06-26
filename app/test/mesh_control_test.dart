import 'dart:convert';

import 'package:chat_app/mesh_control.dart';
import 'package:flutter_test/flutter_test.dart';

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

    test('gossip frames are tagged and pass through untouched', () {
      final syncBytes = utf8.encode('a-sync-frame');
      final split = splitFrame(wrapGossip(syncBytes));
      expect(split.isControl, isFalse);
      expect(split.body, syncBytes);
    });

    test('a malformed control body decodes to null, not a throw', () {
      expect(MeshControl.decodeBody(utf8.encode('not json {')), isNull);
      expect(MeshControl.decodeBody(utf8.encode('{"t":"unknown"}')), isNull);
    });
  });
}
