// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:convert/convert.dart';
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

    group('relay presence', () {
      test('signed channel-capability presence verifies', () async {
        final now = DateTime.now().toUtc();
        final ts = now.millisecondsSinceEpoch;
        final channelKey = List<int>.generate(32, (index) => index);
        final signature = hex.encode(
          await alice.sign(
            presenceSigningBytes('room', alice.publicKeyHex, ts),
          ),
        );
        final capability = createPresenceCapabilityProof(
          channelKey,
          alice.publicKeyHex,
          'room',
          ts,
        );

        expect(
          await verifyRelayPresenceClaim(
            channel: 'room',
            pubkey: alice.publicKeyHex,
            timestampMs: ts,
            signatureHex: signature,
            channelKey: channelKey,
            capability: capability,
            now: now,
          ),
          isTrue,
        );
      });

      test('forged, stale, or wrong-channel presence is rejected', () async {
        final now = DateTime.now().toUtc();
        final ts = now.millisecondsSinceEpoch;
        final signature = hex.encode(
          await mallory.sign(
            presenceSigningBytes('room', alice.publicKeyHex, ts),
          ),
        );

        expect(
          await verifyRelayPresenceClaim(
            channel: 'room',
            pubkey: alice.publicKeyHex,
            timestampMs: ts,
            signatureHex: signature,
            now: now,
          ),
          isFalse,
        );

        final validSignature = hex.encode(
          await alice.sign(
            presenceSigningBytes('room', alice.publicKeyHex, ts),
          ),
        );
        expect(
          await verifyRelayPresenceClaim(
            channel: 'another-room',
            pubkey: alice.publicKeyHex,
            timestampMs: ts,
            signatureHex: validSignature,
            now: now,
          ),
          isFalse,
        );
        expect(
          await verifyRelayPresenceClaim(
            channel: 'room',
            pubkey: alice.publicKeyHex,
            timestampMs: ts,
            signatureHex: validSignature,
            now: now.add(const Duration(minutes: 1)),
          ),
          isFalse,
        );
      });
    });

    test('a correctly signed offer verifies', () async {
      final data = offer('v=0 ... a=fingerprint:sha-256 AB:CD');
      data['sig'] = await signSignal(
        alice,
        'room',
        'offer',
        bob.publicKeyHex,
        data,
      );

      expect(
        await verifySignal(
          alice.publicKeyHex,
          bob.publicKeyHex,
          'room',
          'offer',
          data,
        ),
        isTrue,
      );
    });

    test('a swapped DTLS fingerprint is rejected (the MITM case)', () async {
      final data = offer('v=0 ... a=fingerprint:sha-256 AB:CD');
      data['sig'] = await signSignal(
        alice,
        'room',
        'offer',
        bob.publicKeyHex,
        data,
      );
      data['sdp'] = 'v=0 ... a=fingerprint:sha-256 EV:IL'; // attacker swap

      expect(
        await verifySignal(
          alice.publicKeyHex,
          bob.publicKeyHex,
          'room',
          'offer',
          data,
        ),
        isFalse,
      );
    });

    test('impersonation (signed by another key) is rejected', () async {
      final data = offer('v=0 ...');
      // Mallory signs but the signal claims to be from Alice.
      data['sig'] = await signSignal(
        mallory,
        'room',
        'offer',
        bob.publicKeyHex,
        data,
      );

      expect(
        await verifySignal(
          alice.publicKeyHex,
          bob.publicKeyHex,
          'room',
          'offer',
          data,
        ),
        isFalse,
      );
    });

    test('replay to a different recipient is rejected', () async {
      final data = offer('v=0 ...');
      data['sig'] = await signSignal(
        alice,
        'room',
        'offer',
        bob.publicKeyHex,
        data,
      );

      // Relay redirects Alice's offer-for-Bob to Mallory instead.
      expect(
        await verifySignal(
          alice.publicKeyHex,
          mallory.publicKeyHex,
          'room',
          'offer',
          data,
        ),
        isFalse,
      );
    });

    test('replay into a different channel is rejected', () async {
      final data = offer('v=0 ...');
      data['sig'] = await signSignal(
        alice,
        'room-a',
        'offer',
        bob.publicKeyHex,
        data,
      );

      // Relay moves Alice's offer from room-a's mailbox into room-b's.
      expect(
        await verifySignal(
          alice.publicKeyHex,
          bob.publicKeyHex,
          'room-b',
          'offer',
          data,
        ),
        isFalse,
      );
    });

    test('a missing signature is rejected', () async {
      final data = offer('v=0 ...');
      expect(
        await verifySignal(
          alice.publicKeyHex,
          bob.publicKeyHex,
          'room',
          'offer',
          data,
        ),
        isFalse,
      );
    });

    test('ICE candidates are signed and verified too', () async {
      final data = <String, Object?>{
        'candidate': 'candidate:1 1 udp 2122260223 192.168.0.2 54321 typ host',
        'sdpMid': '0',
        'sdpMLineIndex': 0,
      };
      data['sig'] = await signSignal(
        alice,
        'room',
        'ice',
        bob.publicKeyHex,
        data,
      );
      expect(
        await verifySignal(
          alice.publicKeyHex,
          bob.publicKeyHex,
          'room',
          'ice',
          data,
        ),
        isTrue,
      );

      data['candidate'] = 'candidate:evil';
      expect(
        await verifySignal(
          alice.publicKeyHex,
          bob.publicKeyHex,
          'room',
          'ice',
          data,
        ),
        isFalse,
      );
    });

    group('channel capability', () {
      final channelKey = List<int>.generate(32, (index) => index);

      test('a peer possessing the channel key verifies', () {
        final data = offer('v=0 ... a=fingerprint:sha-256 AB:CD');
        data[signalCapabilityField] = createSignalCapabilityProof(
          channelKey,
          alice.publicKeyHex,
          bob.publicKeyHex,
          'room',
          'offer',
          data,
        );

        expect(
          verifySignalCapabilityProof(
            channelKey,
            alice.publicKeyHex,
            bob.publicKeyHex,
            'room',
            'offer',
            data,
          ),
          isTrue,
        );
      });

      test(
        'identity authentication alone is not a channel capability',
        () async {
          final data = offer('v=0 ...');
          data['sig'] = await signSignal(
            mallory,
            'room',
            'offer',
            bob.publicKeyHex,
            data,
          );

          expect(
            await verifySignal(
              mallory.publicKeyHex,
              bob.publicKeyHex,
              'room',
              'offer',
              data,
            ),
            isTrue,
          );
          expect(
            verifySignalCapabilityProof(
              channelKey,
              mallory.publicKeyHex,
              bob.publicKeyHex,
              'room',
              'offer',
              data,
            ),
            isFalse,
          );
        },
      );

      test('proof is bound to the sender, recipient, channel, and payload', () {
        final data = offer('v=0 ... a=fingerprint:sha-256 AB:CD');
        data[signalCapabilityField] = createSignalCapabilityProof(
          channelKey,
          alice.publicKeyHex,
          bob.publicKeyHex,
          'room',
          'offer',
          data,
        );

        bool verifies({
          String? from,
          String? to,
          String? channel,
          String? kind,
        }) => verifySignalCapabilityProof(
          channelKey,
          from ?? alice.publicKeyHex,
          to ?? bob.publicKeyHex,
          channel ?? 'room',
          kind ?? 'offer',
          data,
        );

        expect(verifies(from: mallory.publicKeyHex), isFalse);
        expect(verifies(to: mallory.publicKeyHex), isFalse);
        expect(verifies(channel: 'another-room'), isFalse);
        expect(verifies(kind: 'answer'), isFalse);
        data['sdp'] = 'v=0 ... a=fingerprint:sha-256 EV:IL';
        expect(verifies(), isFalse);
      });

      test('a proof made with another channel key is rejected', () {
        final data = offer('v=0 ...');
        data[signalCapabilityField] = createSignalCapabilityProof(
          List<int>.filled(32, 255),
          alice.publicKeyHex,
          bob.publicKeyHex,
          'room',
          'offer',
          data,
        );

        expect(
          verifySignalCapabilityProof(
            channelKey,
            alice.publicKeyHex,
            bob.publicKeyHex,
            'room',
            'offer',
            data,
          ),
          isFalse,
        );
      });
    });
  });
}
