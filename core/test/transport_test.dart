// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('RelayTransport', () {
    late Identity author;

    setUp(() async {
      author = await Identity.generate();
    });

    test('send POSTs the message envelope to /messages', () async {
      http.Request? captured;
      final client = MockClient((req) async {
        captured = req;
        return http.Response(jsonEncode({'ok': true, 'seq': 1}), 200);
      });
      final transport = RelayTransport(
        baseUrl: Uri.parse('http://relay.test'),
        channel: 'general',
        client: client,
      );
      final m = await Message.create(
        author: author,
        channel: 'general',
        payload: _b('hi'),
      );

      await transport.send(m);

      expect(captured!.method, 'POST');
      expect(captured!.url.path, '/messages');
      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['id'], m.toJson()['id']);
    });

    test('send throws on a non-200 response', () async {
      final client = MockClient((req) async => http.Response('nope', 400));
      final transport = RelayTransport(
        baseUrl: Uri.parse('http://relay.test'),
        channel: 'general',
        client: client,
      );
      final m = await Message.create(
        author: author,
        channel: 'general',
        payload: _b('hi'),
      );

      expect(() => transport.send(m), throwsA(isA<TransportException>()));
    });

    test('poll returns verified messages and advances the cursor', () async {
      final m1 = await Message.create(
        author: author,
        channel: 'general',
        payload: _b('one'),
      );
      final client = MockClient((req) async {
        final since = int.parse(req.url.queryParameters['since']!);
        if (since == 0) {
          return http.Response(
            jsonEncode({
              'messages': [
                {'seq': 1, ...m1.toJson()},
              ],
              'seq': 1,
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({'messages': <Object?>[], 'seq': since}),
          200,
        );
      });
      final transport = RelayTransport(
        baseUrl: Uri.parse('http://relay.test'),
        channel: 'general',
        client: client,
      );

      final first = await transport.poll();
      expect(first.map((m) => m.idHex), [m1.idHex]);
      expect(transport.since, 1);

      final second = await transport.poll();
      expect(second, isEmpty); // cursor advanced; nothing new
    });

    test('poll drops messages that fail verification', () async {
      final good = await Message.create(
        author: author,
        channel: 'general',
        payload: _b('good'),
      );
      final forged = {
        ...good.toJson(),
        'payload': base64Url.encode(utf8.encode('evil')),
      };
      final client = MockClient(
        (req) async => http.Response(
          jsonEncode({
            'messages': [
              {'seq': 1, ...forged},
            ],
            'seq': 1,
          }),
          200,
        ),
      );
      final transport = RelayTransport(
        baseUrl: Uri.parse('http://relay.test'),
        channel: 'general',
        client: client,
      );

      expect(await transport.poll(), isEmpty); // forged dropped
    });

    test(
      'incoming stream emits verified messages as they are polled',
      () async {
        final m1 = await Message.create(
          author: author,
          channel: 'general',
          payload: _b('streamed'),
        );
        var served = false;
        final client = MockClient((req) async {
          if (!served) {
            served = true;
            return http.Response(
              jsonEncode({
                'messages': [
                  {'seq': 1, ...m1.toJson()},
                ],
                'seq': 1,
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({'messages': <Object?>[], 'seq': 1}),
            200,
          );
        });
        final transport = RelayTransport(
          baseUrl: Uri.parse('http://relay.test'),
          channel: 'general',
          client: client,
          pollInterval: const Duration(milliseconds: 5),
        );

        final first = await transport.incoming.first.timeout(
          const Duration(seconds: 2),
        );
        expect(first.idHex, m1.idHex);
        await transport.close();
      },
    );
  });
}
