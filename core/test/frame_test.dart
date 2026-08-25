// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:test/test.dart';

void main() {
  group('SyncFrame encode/decode', () {
    test('HaveFrame round-trips', () {
      final frame = HaveFrame(['abc123', 'def456']);
      final decoded = SyncFrame.decode(frame.encode());
      expect(decoded, isA<HaveFrame>());
      expect((decoded! as HaveFrame).heads, ['abc123', 'def456']);
    });

    test('WantFrame round-trips', () {
      final frame = WantFrame(['id1', 'id2', 'id3']);
      final decoded = SyncFrame.decode(frame.encode());
      expect(decoded, isA<WantFrame>());
      expect((decoded! as WantFrame).ids, ['id1', 'id2', 'id3']);
    });

    test('GiveFrame round-trips', () async {
      final identity = await Identity.generate();
      final message = await Message.create(
        author: identity,
        channel: 'ch1',
        payload: Uint8List.fromList(
          utf8.encode('{"type":"text","text":"hello"}'),
        ),
      );
      final frame = GiveFrame(message);
      final decoded = SyncFrame.decode(frame.encode());
      expect(decoded, isA<GiveFrame>());
      final give = decoded! as GiveFrame;
      expect(give.message.channel, 'ch1');
      expect(await give.message.verify(), isTrue);
    });

    test('AckFrame round-trips', () {
      const id =
          '1220aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final decoded = SyncFrame.decode(const AckFrame(id).encode());
      expect(decoded, isA<AckFrame>());
      expect((decoded! as AckFrame).id, id);
    });

    test('WantBlobFrame round-trips', () {
      final frame = WantBlobFrame('blobhash123');
      final decoded = SyncFrame.decode(frame.encode());
      expect(decoded, isA<WantBlobFrame>());
      final want = decoded! as WantBlobFrame;
      expect(want.hash, 'blobhash123');
      expect(want.chunked, isFalse);
    });

    test('WantBlobFrame negotiates chunk support', () {
      final frame = WantBlobFrame('blobhash123', chunked: true);
      final decoded = SyncFrame.decode(frame.encode())! as WantBlobFrame;
      expect(decoded.hash, 'blobhash123');
      expect(decoded.chunked, isTrue);
    });

    test('GiveBlobFrame round-trips', () {
      final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
      final frame = GiveBlobFrame('blobhash', bytes);
      final decoded = SyncFrame.decode(frame.encode());
      expect(decoded, isA<GiveBlobFrame>());
      final give = decoded! as GiveBlobFrame;
      expect(give.hash, 'blobhash');
      expect(give.bytes, bytes);
    });

    test('GiveBlobChunkFrame round-trips', () {
      final bytes = Uint8List.fromList([6, 7, 8, 9]);
      final frame = GiveBlobChunkFrame('blobhash', 32, 100, bytes);
      final decoded = SyncFrame.decode(frame.encode());
      expect(decoded, isA<GiveBlobChunkFrame>());
      final chunk = decoded! as GiveBlobChunkFrame;
      expect(chunk.hash, 'blobhash');
      expect(chunk.offset, 32);
      expect(chunk.totalBytes, 100);
      expect(chunk.bytes, bytes);
    });

    test('empty heads HaveFrame', () {
      final frame = HaveFrame([]);
      final decoded = SyncFrame.decode(frame.encode());
      expect(decoded, isA<HaveFrame>());
      expect((decoded! as HaveFrame).heads, isEmpty);
    });

    test('malformed JSON returns null', () {
      expect(SyncFrame.decode('not json'), isNull);
    });

    test('unknown type returns null', () {
      expect(SyncFrame.decode('{"t":"unknown"}'), isNull);
    });

    test('missing required fields returns null', () {
      expect(SyncFrame.decode('{"t":"have"}'), isNull);
      expect(SyncFrame.decode('{"t":"want"}'), isNull);
      expect(SyncFrame.decode('{"t":"ack"}'), isNull);
      expect(SyncFrame.decode('{"t":"wantblob"}'), isNull);
      expect(SyncFrame.decode('{"t":"blobchunk","h":"x"}'), isNull);
    });

    test('empty string returns null', () {
      expect(SyncFrame.decode(''), isNull);
    });
  });
}
