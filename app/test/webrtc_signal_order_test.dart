// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/webrtc_signal_order.dart';

void main() {
  test(
    'SDP is delivered before candidates emitted during description setup',
    () async {
      final order = WebRtcSignalOrder();
      final sent = <String>[];
      final descriptionStarted = Completer<void>();
      final releaseDescription = Completer<void>();

      Future<void> send(String kind, Object? _) async {
        if (kind == 'offer') {
          descriptionStarted.complete();
          await releaseDescription.future;
        }
        sent.add(kind);
      }

      final description = order.sendDescription('offer', const {
        'sdp': 'offer',
      }, send);
      await descriptionStarted.future;
      order.addCandidate(const {'candidate': 'first'}, send);
      order.addCandidate(const {'candidate': 'second'}, send);
      expect(sent, isEmpty);

      releaseDescription.complete();
      await description;
      await order.drained;

      expect(sent, ['offer', 'ice', 'ice']);
    },
  );

  test('candidates emitted later remain serialized', () async {
    final order = WebRtcSignalOrder();
    final sent = <String>[];

    Future<void> send(String kind, Object? payload) async {
      final value = payload! as Map<String, Object?>;
      sent.add('$kind:${value.values.first}');
    }

    await order.sendDescription('answer', const {'sdp': 'answer'}, send);
    order.addCandidate(const {'candidate': 'one'}, send);
    order.addCandidate(const {'candidate': 'two'}, send);
    await order.drained;

    expect(sent, ['answer:answer', 'ice:one', 'ice:two']);
  });
}
