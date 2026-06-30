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

    test('poll passes token in Authorization header when tokenProvider returns a value',
        () async {
      String? capturedAuth;
      final client = MockClient((req) async {
        capturedAuth = req.headers['Authorization'];
        return http.Response(
          jsonEncode({'messages': <Object?>[], 'seq': 0}),
          200,
        );
      });
      final transport = RelayTransport(
        baseUrl: Uri.parse('http://relay.test'),
        channel: 'general',
        client: client,
        tokenProvider: () => 'test-token-123',
      );

      await transport.poll();
      expect(capturedAuth, 'Bearer test-token-123');
    });

    test('poll skips when tokenProvider is set but returns null', () async {
      var called = false;
      final client = MockClient((req) async {
        called = true;
        return http.Response(
          jsonEncode({'messages': <Object?>[], 'seq': 0}),
          200,
        );
      });
      final transport = RelayTransport(
        baseUrl: Uri.parse('http://relay.test'),
        channel: 'general',
        client: client,
        tokenProvider: () => null,
      );

      final result = await transport.poll();
      expect(result, isEmpty);
      expect(called, isFalse);
    });

    test('baseUrlProvider overrides baseUrl for poll and send', () async {
      final captured = <Uri>[];
      final client = MockClient((req) async {
        captured.add(req.url);
        if (req.method == 'POST') {
          return http.Response(jsonEncode({'ok': true, 'seq': 1}), 200);
        }
        return http.Response(
          jsonEncode({'messages': <Object?>[], 'seq': 0}),
          200,
        );
      });
      final fallback = Uri.parse('http://fallback.test');
      final transport = RelayTransport(
        baseUrl: Uri.parse('http://primary.test'),
        channel: 'ch1',
        client: client,
        baseUrlProvider: () => fallback,
      );

      await transport.poll();
      final m = await Message.create(
        author: author,
        channel: 'ch1',
        payload: _b('hi'),
      );
      await transport.send(m);

      expect(captured[0].host, 'fallback.test');
      expect(captured[0].path, '/poll');
      expect(captured[1].host, 'fallback.test');
      expect(captured[1].path, '/messages');
    });

    test('baseUrlProvider null falls back to baseUrl', () async {
      Uri? capturedUrl;
      final client = MockClient((req) async {
        capturedUrl = req.url;
        return http.Response(
          jsonEncode({'messages': <Object?>[], 'seq': 0}),
          200,
        );
      });
      final transport = RelayTransport(
        baseUrl: Uri.parse('http://primary.test'),
        channel: 'ch1',
        client: client,
        baseUrlProvider: null,
      );

      await transport.poll();
      expect(capturedUrl!.host, 'primary.test');
    });
  });
}