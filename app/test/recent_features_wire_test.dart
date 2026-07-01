// SPDX-License-Identifier: AGPL-3.0-or-later
// Wire-format coverage for the recent feature batch: reactions + replies
// (content envelope) and read receipts + voice presence (mesh control). These
// exercise the exact encode/decode paths the real app uses on send/receive.
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/content.dart';
import 'package:hearth/mesh_control.dart';

void main() {
  group('content envelope — reactions & replies', () {
    test('ReactionContent round-trips target + emoji', () {
      final back = parseContent(
        const ReactionContent('deadbeef', '🔥').encode(),
      );
      expect(back, isA<ReactionContent>());
      final r = back as ReactionContent;
      expect(r.targetId, 'deadbeef');
      expect(r.emoji, '🔥');
    });

    test('a reply carries replyTo through encode/decode', () {
      final back = parseContent(
        const TextContent('nice one', replyTo: 'abc123').encode(),
      );
      expect(back, isA<TextContent>());
      final t = back as TextContent;
      expect(t.text, 'nice one');
      expect(t.replyTo, 'abc123');
    });

    test('a non-reply text message has a null replyTo', () {
      final back = parseContent(const TextContent('hi').encode());
      expect((back as TextContent).replyTo, isNull);
    });
  });

  group('mesh control — read receipts & voice presence', () {
    test('ReadWatermarkControl round-trips channel + message id', () {
      final wire = ReadWatermarkControl(
        channelId: 'chan1',
        messageId: 'msghex',
      ).encode();
      final split = splitFrame(wire);
      expect(split.isControl, isTrue);

      final back = MeshControl.decodeBody(split.body);
      expect(back, isA<ReadWatermarkControl>());
      final w = back! as ReadWatermarkControl;
      expect(w.channelId, 'chan1');
      expect(w.messageId, 'msghex');
    });

    test('VoicePresenceControl round-trips the channel (join)', () {
      final back = MeshControl.decodeBody(
        splitFrame(VoicePresenceControl(channelId: 'vchan').encode()).body,
      );
      expect(back, isA<VoicePresenceControl>());
      expect((back! as VoicePresenceControl).channelId, 'vchan');
    });

    test('VoicePresenceControl with an empty channel signals leave', () {
      final back = MeshControl.decodeBody(
        splitFrame(VoicePresenceControl(channelId: '').encode()).body,
      );
      expect((back! as VoicePresenceControl).channelId, isEmpty);
    });

    test('VoiceLeaveControl round-trips', () {
      final back = MeshControl.decodeBody(
        splitFrame(VoiceLeaveControl().encode()).body,
      );
      expect(back, isA<VoiceLeaveControl>());
    });
  });
}
