// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:test/test.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('BlobStore', () {
    test('put then get round-trips the bytes', () async {
      final store = InMemoryBlobStore();
      final id = await store.put(_b('a sticker'));
      expect(await store.get(id), _b('a sticker'));
      expect(await store.has(id), isTrue);
    });

    test('is content-addressed: identical bytes share an id', () async {
      final store = InMemoryBlobStore();
      final a = await store.put(_b('same'));
      final b = await store.put(_b('same'));
      expect(a, b);
    });

    test('an unknown id is absent', () async {
      final store = InMemoryBlobStore();
      final missing = await blobHash(_b('never stored'));
      expect(await store.has(missing), isFalse);
      expect(await store.get(missing), isNull);
    });

    test('the id is a sha256 multihash (0x1220 + 32 bytes, hex)', () async {
      final id = await blobHash(_b('x'));
      expect(id.length, 68); // 34 bytes hex
      expect(id.startsWith('1220'), isTrue);
    });
  });
}
