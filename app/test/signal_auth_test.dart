// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:core/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/signal_auth.dart';

void main() {
  group('authenticated signalling', () {
    late Identity alice;
    late Identity bob;
    late Identity mallory;

    setUp(() async {
      alice = await Identity.generate();
      bob = await Identity.generate();
      mallory = await Identity.generate();
    });

    Map<String, Object?> offer(String sdp) => {'sdp': sdp, 'type': 'offer'};

    test('a correctly signed offer verifies', () async {
      final data = offer('v=0 ... a=fingerprint:sha-256 AB:CD');
      data['sig'] = await signSignal(alice, 'offer', bob.publicKeyHex, data);

      expect(
        await verifySignal(alice.publicKeyHex, bob.publicKeyHex, 'offer', data),
        isTrue,
      );
    });

    test('a swapped DTLS fingerprint is rejected (the MITM case)', () async {
      final data = offer('v=0 ... a=fingerprint:sha-256 AB:CD');
      data['sig'] = await signSignal(alice, 'offer', bob.publicKeyHex, data);
      data['sdp'] = 'v=0 ... a=fingerprint:sha-256 EV:IL'; // attacker swap

      expect(
        await verifySignal(alice.publicKeyHex, bob.publicKeyHex, 'offer', data),
        isFalse,
      );
    });

    test('impersonation (signed by another key) is rejected', () async {
      final data = offer('v=0 ...');
      // Mallory signs but the signal claims to be from Alice.
      data['sig'] = await signSignal(mallory, 'offer', bob.publicKeyHex, data);

      expect(
        await verifySignal(alice.publicKeyHex, bob.publicKeyHex, 'offer', data),
        isFalse,
      );
    });

    test('replay to a different recipient is rejected', () async {
      final data = offer('v=0 ...');
      data['sig'] = await signSignal(alice, 'offer', bob.publicKeyHex, data);

      // Relay redirects Alice's offer-for-Bob to Mallory instead.
      expect(
        await verifySignal(
          alice.publicKeyHex,
          mallory.publicKeyHex,
          'offer',
          data,
        ),
        isFalse,
      );
    });

    test('a missing signature is rejected', () async {
      final data = offer('v=0 ...');
      expect(
        await verifySignal(alice.publicKeyHex, bob.publicKeyHex, 'offer', data),
        isFalse,
      );
    });

    test('ICE candidates are signed and verified too', () async {
      final data = <String, Object?>{
        'candidate': 'candidate:1 1 udp 2122260223 192.168.0.2 54321 typ host',
        'sdpMid': '0',
        'sdpMLineIndex': 0,
      };
      data['sig'] = await signSignal(alice, 'ice', bob.publicKeyHex, data);
      expect(
        await verifySignal(alice.publicKeyHex, bob.publicKeyHex, 'ice', data),
        isTrue,
      );

      data['candidate'] = 'candidate:evil';
      expect(
        await verifySignal(alice.publicKeyHex, bob.publicKeyHex, 'ice', data),
        isFalse,
      );
    });
  });
}
