// SPDX-License-Identifier: AGPL-3.0-or-later
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

    test('ScreenShareControl round-trips sharer + active flag', () {
      final wire = const ScreenShareControl(
        sharer: 'abcd',
        active: true,
      ).encode();
      final split = splitFrame(wire);
      expect(split.isControl, isTrue);

      final back = MeshControl.decodeBody(split.body);
      expect(back, isA<ScreenShareControl>());
      final s = back! as ScreenShareControl;
      expect(s.sharer, 'abcd');
      expect(s.active, isTrue);

      // And the stop signal.
      final stop = MeshControl.decodeBody(
        splitFrame(
          const ScreenShareControl(sharer: 'abcd', active: false).encode(),
        ).body,
      );
      expect((stop! as ScreenShareControl).active, isFalse);
    });

    test('YoutubeControl round-trips host/video/playing/position', () {
      final wire = const YoutubeControl(
        host: 'beef',
        videoId: 'dQw4w9WgXcQ',
        playing: true,
        position: 42.5,
      ).encode();

      final back = MeshControl.decodeBody(splitFrame(wire).body);
      expect(back, isA<YoutubeControl>());
      final y = back! as YoutubeControl;
      expect(y.host, 'beef');
      expect(y.videoId, 'dQw4w9WgXcQ');
      expect(y.playing, isTrue);
      expect(y.position, 42.5);
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
