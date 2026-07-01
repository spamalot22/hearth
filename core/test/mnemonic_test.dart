// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:core/core.dart';
import 'package:test/test.dart';

void main() {
  group('BIP39 mnemonic codec', () {
    test('wordlist is the canonical 2048 words', () {
      expect(bip39Words, hasLength(2048));
      expect(bip39Words.first, 'abandon');
      expect(bip39Words.last, 'zoo');
    });

    // Official BIP39 English test vectors (entropy -> mnemonic).
    test('matches the all-zero 16-byte vector (12 words)', () async {
      final entropy = Uint8List(16); // all zeros
      expect(
        await seedToMnemonic(entropy),
        'abandon abandon abandon abandon abandon abandon '
        'abandon abandon abandon abandon abandon about',
      );
    });

    test('matches the all-zero 32-byte vector (24 words)', () async {
      final entropy = Uint8List(32); // all zeros
      final m = await seedToMnemonic(entropy);
      expect(m.split(' '), hasLength(24));
      expect(m.endsWith('art'), isTrue); // known 256-bit all-zero checksum word
    });

    test('matches the 0x7f... 32-byte vector', () async {
      final entropy = Uint8List.fromList(List<int>.filled(32, 0x7f));
      expect(
        await seedToMnemonic(entropy),
        'legal winner thank year wave sausage worth useful legal winner thank '
        'year wave sausage worth useful legal winner thank year wave sausage '
        'worth title',
      );
    });

    test('round-trips an arbitrary 32-byte seed', () async {
      final seed = Uint8List.fromList(
        hex.decode(
          'a1b2c3d4e5f6071819202122232425262728292a2b2c2d2e2f30313233343536',
        ),
      );
      final phrase = await seedToMnemonic(seed);
      expect(phrase.split(' '), hasLength(24));
      expect(await mnemonicToSeed(phrase), seed);
    });

    test('rejects a phrase with a bad checksum (one word changed)', () async {
      final seed = Uint8List(32);
      final words = (await seedToMnemonic(seed)).split(' ');
      // Flip the first word to a different valid word → checksum must fail.
      words[0] = words[0] == 'abandon' ? 'ability' : 'abandon';
      expect(await mnemonicToSeed(words.join(' ')), isNull);
    });

    test('rejects an unknown word', () async {
      final seed = Uint8List(32);
      final words = (await seedToMnemonic(seed)).split(' ');
      words[5] = 'notaword';
      expect(await mnemonicToSeed(words.join(' ')), isNull);
    });

    test('rejects a wrong-length phrase', () async {
      expect(await mnemonicToSeed('abandon abandon abandon'), isNull);
    });

    test('a valid 12-word phrase decodes to a 16-byte seed', () async {
      // Callers that need a 32-byte Ed25519 seed must check the length: a valid
      // shorter phrase (e.g. a 12-word wallet phrase) decodes fine but is not a
      // usable identity seed.
      final seed = await mnemonicToSeed(
        'abandon abandon abandon abandon abandon abandon '
        'abandon abandon abandon abandon abandon about',
      );
      expect(seed, isNotNull);
      expect(seed, hasLength(16));
    });

    test('is case- and whitespace-insensitive on decode', () async {
      final seed = Uint8List.fromList(List<int>.filled(32, 0x7f));
      final phrase = await seedToMnemonic(seed);
      final messy = '  ${phrase.toUpperCase().replaceAll(' ', '   ')}  ';
      expect(await mnemonicToSeed(messy), seed);
    });
  });
}
