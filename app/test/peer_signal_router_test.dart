// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/mesh_control.dart';
import 'package:hearth/peer_signal_router.dart';
import 'package:hearth/signal_auth.dart';

Future<SignalControl> _signedSignal({
  required Identity from,
  required String to,
  required String channel,
  String kind = 'offer',
  Map<String, Object?> data = const {'sdp': 'v=0', 'type': 'offer'},
  Uint8List? channelKey,
  String? namespace,
  int hops = kDefaultSignalRouteHops,
}) async {
  final signed = <String, Object?>{
    ...data,
    'sig': await signSignal(from, channel, kind, to, data),
  };
  if (channelKey != null) {
    signed[signalCapabilityField] = createSignalCapabilityProof(
      channelKey,
      from.publicKeyHex,
      to,
      channel,
      kind,
      data,
    );
  }
  return SignalControl(
    to: to,
    from: from.publicKeyHex,
    kind: kind,
    data: signed,
    namespace: namespace,
    hopsRemaining: hops,
  );
}

void main() {
  test('prefers a learned next hop and forgets it when the link closes', () {
    final self = '0' * 64;
    final bridge = '1' * 64;
    final other = '2' * 64;
    final target = '3' * 64;
    final router = PeerSignalRouter(selfPeer: self, channel: 'channel');

    router.learnRoute(target, bridge);
    expect(router.nextHops(destination: target, openPeers: [other, bridge]), [
      bridge,
    ]);

    router.removeNextHop(bridge);
    expect(router.nextHops(destination: target, openPeers: [other, bridge]), [
      bridge,
      other,
    ]);
  });

  test('fallback flooding is deterministic, bounded, and excludes ingress', () {
    final router = PeerSignalRouter(selfPeer: '0' * 64, channel: 'channel');

    expect(
      router.nextHops(
        destination: 'f' * 64,
        openPeers: ['4' * 64, '2' * 64, '3' * 64, '1' * 64],
        exclude: '2' * 64,
        maxFanout: 2,
      ),
      ['1' * 64, '3' * 64],
    );
  });

  test(
    'deduplicates across hop changes and accepts again after expiry',
    () async {
      final sender = await Identity.generate();
      final recipient = await Identity.generate();
      var now = DateTime.utc(2026);
      final router = PeerSignalRouter(
        selfPeer: recipient.publicKeyHex,
        channel: 'channel',
        seenTtl: const Duration(minutes: 1),
        now: () => now,
      );
      final signal = await _signedSignal(
        from: sender,
        to: recipient.publicKeyHex,
        channel: 'channel',
      );

      expect(router.remember(signal), isTrue);
      expect(router.remember(signal.forwarded()), isFalse);
      now = now.add(const Duration(minutes: 2));
      expect(router.remember(signal), isTrue);
    },
  );

  test('authenticates routed signals end to end', () async {
    final sender = await Identity.generate();
    final recipient = await Identity.generate();
    final key = Uint8List.fromList(List<int>.generate(32, (index) => index));
    final router = PeerSignalRouter(selfPeer: 'f' * 64, channel: 'group');
    final signal = await _signedSignal(
      from: sender,
      to: recipient.publicKeyHex,
      channel: 'group',
      channelKey: key,
    );

    expect(await router.authenticate(signal, channelAuthKey: key), isTrue);
    expect(
      await router.authenticate(signal, channelAuthKey: Uint8List(32)),
      isFalse,
    );

    final forged = SignalControl(
      to: signal.to,
      from: signal.from,
      kind: signal.kind,
      data: {...signal.data, 'sdp': 'substituted'},
    );
    expect(await router.authenticate(forged, channelAuthKey: key), isFalse);
  });

  test('allows only the parent channel voice namespace', () async {
    final sender = await Identity.generate();
    final recipient = await Identity.generate();
    final key = Uint8List.fromList(List<int>.generate(32, (index) => index));
    final router = PeerSignalRouter(
      selfPeer: recipient.publicKeyHex,
      channel: 'group',
    );
    final voice = await _signedSignal(
      from: sender,
      to: recipient.publicKeyHex,
      channel: 'voice:group',
      channelKey: key,
      namespace: 'voice:group',
    );
    final unrelated = await _signedSignal(
      from: sender,
      to: recipient.publicKeyHex,
      channel: 'voice:other-group',
      channelKey: key,
      namespace: 'voice:other-group',
    );

    expect(await router.authenticate(voice, channelAuthKey: key), isTrue);
    expect(await router.authenticate(unrelated, channelAuthKey: key), isFalse);
  });

  test('rejects malformed, oversized, and over-hopped signals', () async {
    final sender = await Identity.generate();
    final recipient = await Identity.generate();
    final router = PeerSignalRouter(
      selfPeer: recipient.publicKeyHex,
      channel: 'channel',
    );

    final badKind = await _signedSignal(
      from: sender,
      to: recipient.publicKeyHex,
      channel: 'channel',
      kind: 'delete-everything',
      data: const {},
    );
    expect(await router.authenticate(badKind), isFalse);

    final overHopped = await _signedSignal(
      from: sender,
      to: recipient.publicKeyHex,
      channel: 'channel',
      hops: kDefaultSignalRouteHops + 1,
    );
    expect(await router.authenticate(overHopped), isFalse);

    final oversized = await _signedSignal(
      from: sender,
      to: recipient.publicKeyHex,
      channel: 'channel',
      data: {
        'sdp': 'x' * (PeerSignalRouter.maxRoutedSignalBytes + 1),
        'type': 'offer',
      },
    );
    expect(await router.authenticate(oversized), isFalse);
  });
}
