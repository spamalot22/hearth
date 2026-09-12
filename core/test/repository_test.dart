// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:test/test.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

class _FailOnceStorage extends InMemoryMessageStorage {
  bool failNext = true;

  @override
  Future<void> append(Message message) async {
    if (failNext) {
      failNext = false;
      throw StateError('simulated storage failure');
    }
    await super.append(message);
  }
}

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

    test(
      'concurrent duplicate deliveries append and account only once',
      () async {
        final storage = InMemoryMessageStorage();
        final repo = MessageRepository(storage);
        final message = await msg('duplicate');
        expect(await Future.wait([repo.add(message), repo.add(message)]), [
          true,
          false,
        ]);
        expect((await storage.loadAll()).length, 1);
        final reloaded = MessageRepository(storage);
        await reloaded.load();
        expect(repo.storedBytes, reloaded.storedBytes);
      },
    );

    test('concurrent writes cannot bypass capacity', () async {
      final storage = InMemoryMessageStorage();
      final repo = MessageRepository(storage, maxMessages: 1);
      final first = await msg('first');
      final second = await msg('second');
      final writing = repo.add(first);
      await expectLater(
        repo.add(second),
        throwsA(isA<RepositoryCapacityException>()),
      );
      expect(await writing, isTrue);
      expect(repo.length, 1);
      expect((await storage.loadAll()).length, 1);
    });

    test(
      'a failed append does not poison later writes or accounting',
      () async {
        final repo = MessageRepository(_FailOnceStorage());
        final message = await msg('retry');
        await expectLater(repo.add(message), throwsStateError);
        expect(repo.length, 0);
        expect(repo.storedBytes, 0);
        expect(await repo.add(message), isTrue);
        expect(repo.length, 1);
      },
    );

    test('a duplicate already in storage is de-duped on load', () async {
      final storage = InMemoryMessageStorage();
      final m = await msg('x');
      await storage.append(m);
      await storage.append(m); // storage somehow holds two copies

      final repo = MessageRepository(storage);
      await repo.load();
      expect(repo.length, 1);
    });

    test('rejects messages beyond the configured storage quota', () async {
      final repo = MessageRepository(InMemoryMessageStorage(), maxMessages: 1);
      expect(await repo.add(await msg('first')), isTrue);
      await expectLater(
        repo.add(await msg('second')),
        throwsA(isA<RepositoryCapacityException>()),
      );
    });
  });
}
