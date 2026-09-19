// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:core/src/nearby_noise.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

Uint8List unhex(String value) => Uint8List.fromList(hex.decode(value));

void main() {
  // Independent reference: noise-c/tests/vector/noise-c-basic.txt (MIT),
  // https://github.com/rweather/noise-c. Covers all three XX messages and
  // bidirectional transport, not merely a self-consistent round trip.
  test('Noise XX matches noise-c reference bytes', () async {
    final local = File('test/fixtures/noise_xx.json');
    final file = local.existsSync()
        ? local
        : File('core/test/fixtures/noise_xx.json');
    final vector =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    Future<NearbyNoise> side(String prefix, bool initiator) async =>
        NearbyNoise(
          initiator: initiator,
          localStatic: await X25519().newKeyPairFromSeed(
            unhex(vector['${prefix}_static'] as String),
          ),
          localEphemeral: await X25519().newKeyPairFromSeed(
            unhex(vector['${prefix}_ephemeral'] as String),
          ),
          prologue: unhex(vector['${prefix}_prologue'] as String),
        );
    final a = await side('init', true);
    final b = await side('resp', false);
    addTearDown(a.destroy);
    addTearDown(b.destroy);
    final messages = (vector['messages'] as List).cast<Map<String, dynamic>>();
    for (var i = 0; i < messages.length; i++) {
      final sender = i.isEven ? a : b;
      final receiver = i.isEven ? b : a;
      final payload = unhex(messages[i]['payload'] as String);
      final encrypted = i < 3
          ? await sender.write(payload)
          : await sender.sending!.encrypt(payload);
      expect(
        hex.encode(encrypted),
        messages[i]['ciphertext'],
        reason: 'reference message $i',
      );
      final decoded = i < 3
          ? await receiver.read(encrypted)
          : await receiver.receiving!.decrypt(encrypted);
      expect(decoded, payload);
    }
    expect(a.remoteStatic, (await b.localStatic.extractPublicKey()).bytes);
    expect(b.remoteStatic, (await a.localStatic.extractPublicKey()).bytes);
  });

  test(
    'cipher rejects replay, reordering and modified ciphertext permanently',
    () async {
      for (final failure in ['replay', 'reorder', 'modify']) {
        final key = SecretKey(List.generate(32, (i) => i));
        final sender = NearbyNoiseCipher(key);
        final receiver = NearbyNoiseCipher(key);
        final first = await sender.encrypt([1, 2]);
        final second = await sender.encrypt([3, 4]);
        var bad = first;
        if (failure == 'replay') {
          await receiver.decrypt(first);
        }
        if (failure == 'reorder') {
          bad = second;
        }
        if (failure == 'modify') {
          bad = Uint8List.fromList(first)..[0] ^= 1;
        }
        await expectLater(receiver.decrypt(bad), throwsA(isA<Exception>()));
        await expectLater(receiver.decrypt(second), throwsStateError);
      }
    },
  );

  test(
    'wrong prologue and low-order public keys cannot complete handshake',
    () async {
      Future<NearbyNoise> side(bool initiator, List<int> prologue) async =>
          NearbyNoise(
            initiator: initiator,
            localStatic: await X25519().newKeyPair(),
            localEphemeral: await X25519().newKeyPair(),
            prologue: prologue,
          );
      final a = await side(true, [1]);
      final b = await side(false, [2]);
      addTearDown(a.destroy);
      addTearDown(b.destroy);
      await b.read(await a.write());
      await expectLater(a.read(await b.write()), throwsA(anything));
      expect(a.complete, isFalse);
      final low = await side(false, []);
      addTearDown(low.destroy);
      await low.read(Uint8List(32));
      await expectLater(low.write(), throwsA(anything));
      expect(low.complete, isFalse);
    },
  );
}
