// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:test/test.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('MessageStore', () {
    late Identity author;

    setUp(() async {
      author = await Identity.generate();
    });

    Future<Message> msg(
      String text, {
      List<Uint8List> prev = const [],
      int? ts,
    }) => Message.create(
      author: author,
      channel: 'c',
      payload: _b(text),
      prev: prev,
      timestampMs: ts,
    );

    test('add is idempotent by content id', () async {
      final store = MessageStore();
      final m = await msg('hi');
      expect(store.add(m), isTrue);
      expect(store.add(m), isFalse);
      expect(store.length, 1);
    });

    test('get / contains by id', () async {
      final store = MessageStore();
      final m = await msg('hi');
      store.add(m);
      expect(store.contains(m.id), isTrue);
      expect(store.get(m.id)!.idHex, m.idHex);
    });

    test('a lone message is the only head', () async {
      final store = MessageStore();
      final m = await msg('a');
      store.add(m);
      expect(store.heads(), [m.id]);
    });

    test('a chain collapses to one head, ordered parent-first', () async {
      final store = MessageStore();
      final a = await msg('a', ts: 1);
      final b = await msg('b', prev: [a.id], ts: 2);
      final c = await msg('c', prev: [b.id], ts: 3);
      // Insert out of causal order on purpose.
      for (final m in [c, a, b]) {
        store.add(m);
      }
      expect(store.heads(), [c.id]);
      expect(store.ordered().map((m) => utf8.decode(m.payload)).toList(), [
        'a',
        'b',
        'c',
      ]);
    });

    test('a fork yields two heads; a merge collapses them', () async {
      final store = MessageStore();
      final a = await msg('a', ts: 1);
      final b1 = await msg('b1', prev: [a.id], ts: 2);
      final b2 = await msg('b2', prev: [a.id], ts: 2);
      store
        ..add(a)
        ..add(b1)
        ..add(b2);
      expect(store.heads().length, 2);

      final merge = await msg('m', prev: [b1.id, b2.id], ts: 3);
      store.add(merge);
      expect(store.heads(), [merge.id]);

      final order = store.ordered().map((m) => utf8.decode(m.payload)).toList();
      expect(order.first, 'a'); // root always first
      expect(order.last, 'm'); // merge always last
      expect(order.toSet(), {'a', 'b1', 'b2', 'm'});
    });

    test(
      'ordering is independent of insertion order (deterministic CRDT)',
      () async {
        final a = await msg('a', ts: 1);
        // Same timestamp on the children forces the id tiebreak to decide.
        final b = await msg('b', prev: [a.id], ts: 1);
        final c = await msg('c', prev: [a.id], ts: 1);

        final s1 = MessageStore()
          ..add(a)
          ..add(b)
          ..add(c);
        final s2 = MessageStore()
          ..add(c)
          ..add(b)
          ..add(a);

        final o1 = s1.ordered().map((m) => m.idHex).toList();
        final o2 = s2.ordered().map((m) => m.idHex).toList();
        expect(o1, o2);
        expect(o1.first, a.idHex); // parent precedes both children
      },
    );
  });
}
