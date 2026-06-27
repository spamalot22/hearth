// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:test/test.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('MessageRepository', () {
    late Identity author;

    setUp(() async {
      author = await Identity.generate();
    });

    Future<Message> msg(String text, {List<Uint8List> prev = const []}) =>
        Message.create(
          author: author,
          channel: 'c',
          payload: _b(text),
          prev: prev,
        );

    test('add persists and is idempotent by content id', () async {
      final storage = InMemoryMessageStorage();
      final repo = MessageRepository(storage);
      final m = await msg('hi');

      expect(await repo.add(m), isTrue);
      expect(await repo.add(m), isFalse); // duplicate: no-op
      expect(repo.length, 1);
      expect((await storage.loadAll()).length, 1); // persisted exactly once
    });

    test('load rehydrates the DAG from storage', () async {
      final storage = InMemoryMessageStorage();
      final a = await msg('a');
      final b = await msg('b', prev: [a.id]);
      final writer = MessageRepository(storage);
      await writer.add(a);
      await writer.add(b);

      // A fresh repository over the same storage recovers the full history.
      final reloaded = MessageRepository(storage);
      await reloaded.load();
      expect(reloaded.length, 2);
      expect(reloaded.ordered().map((m) => utf8.decode(m.payload)).toList(), [
        'a',
        'b',
      ]);
      expect(reloaded.heads(), [b.id]);
    });

    test('a duplicate already in storage is de-duped on load', () async {
      final storage = InMemoryMessageStorage();
      final m = await msg('x');
      await storage.append(m);
      await storage.append(m); // storage somehow holds two copies

      final repo = MessageRepository(storage);
      await repo.load();
      expect(repo.length, 1);
    });
  });
}
