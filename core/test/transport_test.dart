// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

void main() {
  group('RelayTransport', () {
    late Identity author;

    setUp(() async {
      author = await Identity.generate();
    });

    test('send POSTs the message envelope to /v2/messages', () async {
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
      expect(captured!.url.path, '/v2/messages');
      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['id'], m.toJson()['id']);
    });

    test('uses a private mailbox without changing signed channel', () async {
      final mailbox = 'a' * 64;
      final seen = <http.Request>[];
      final client = MockClient((request) async {
        seen.add(request);
        if (request.method == 'POST') {
          return http.Response('{"ok":true}', 200);
        }
        return http.Response('{"messages":[],"seq":0}', 200);
      });
      final transport = RelayTransport(
        baseUrl: Uri.parse('http://relay.test'),
        channel: 'logical-channel',
        mailbox: mailbox,
        client: client,
      );
      final message = await Message.create(
        author: author,
        channel: 'logical-channel',
        payload: _b('private'),
      );

      await transport.send(message);
      await transport.poll();

      expect(seen[0].headers[relayMailboxHeader], mailbox);
      expect(seen[1].headers[relayMailboxHeader], mailbox);
      expect(seen[0].url.queryParameters['mailbox'], isNull);
      expect(seen[1].url.queryParameters['channel'], isNull);
      expect(message.channel, 'logical-channel');
    });

    test('falls back to legacy mailbox URLs for an older relay', () async {
      final mailbox = 'c' * 64;
      final seen = <http.Request>[];
      final client = MockClient((request) async {
        seen.add(request);
        if (request.url.path.startsWith('/v2/')) {
          return http.Response('not found', 404);
        }
        if (request.method == 'POST') {
          return http.Response('{"ok":true}', 200);
        }
        return http.Response('{"messages":[],"seq":0}', 200);
      });
      final transport = RelayTransport(
        baseUrl: Uri.parse('http://relay.test'),
        channel: 'logical-channel',
        mailbox: mailbox,
        client: client,
      );
      final message = await Message.create(
        author: author,
        channel: 'logical-channel',
        payload: _b('legacy'),
      );

      await transport.send(message);
      await transport.poll();

      expect(seen.map((request) => request.url.path), [
        '/v2/messages',
        '/messages',
        '/v2/poll',
        '/poll',
      ]);
      expect(seen[1].url.queryParameters['mailbox'], mailbox);
      expect(seen[3].url.queryParameters['channel'], mailbox);
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

    test('poll resets its cursor when the relay process restarts', () async {
      final afterRestart = await Message.create(
        author: author,
        channel: 'general',
        payload: _b('after restart'),
      );
      final requestedSince = <int>[];
      var request = 0;
      final client = MockClient((req) async {
        final since = int.parse(req.url.queryParameters['since']!);
        requestedSince.add(since);
        request++;
        if (request == 1) {
          return http.Response(
            jsonEncode({
              'messages': <Object?>[],
              'seq': 100,
              'latestSeq': 100,
              'relayEpoch': 'before',
            }),
            200,
          );
        }
        if (since > 0) {
          return http.Response(
            jsonEncode({
              'messages': <Object?>[],
              'seq': since,
              'latestSeq': 1,
              'relayEpoch': 'after',
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'messages': [
              {'seq': 1, ...afterRestart.toJson()},
            ],
            'seq': 1,
            'latestSeq': 1,
            'relayEpoch': 'after',
          }),
          200,
        );
      });
      final transport = RelayTransport(
        baseUrl: Uri.parse('http://relay.test'),
        channel: 'general',
        client: client,
      );

      expect(await transport.poll(), isEmpty);
      final received = await transport.poll();

      expect(requestedSince, [0, 100, 0]);
      expect(received.map((message) => message.idHex), [afterRestart.idHex]);
      expect(transport.since, 1);
      expect(transport.relayEpoch, 'after');
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
      'poll skips malformed/wrong-channel entries and never rewinds',
      () async {
        final good = await Message.create(
          author: author,
          channel: 'general',
          payload: _b('good'),
        );
        final misplaced = await Message.create(
          author: author,
          channel: 'elsewhere',
          payload: _b('misplaced'),
        );
        var first = true;
        final client = MockClient((req) async {
          if (first) {
            first = false;
            return http.Response(
              jsonEncode({
                'messages': [123, misplaced.toJson(), good.toJson()],
                'seq': 5,
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({'messages': <Object?>[], 'seq': 3}),
            200,
          );
        });
        final transport = RelayTransport(
          baseUrl: Uri.parse('http://relay.test'),
          channel: 'general',
          client: client,
        );

        expect((await transport.poll()).map((m) => m.idHex), [good.idHex]);
        expect(transport.since, 5);
        await transport.poll();
        expect(transport.since, 5);
      },
    );

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

    test(
      'incoming drains consecutive backlog pages in one poll cycle',
      () async {
        final firstMessage = await Message.create(
          author: author,
          channel: 'general',
          payload: _b('first page'),
        );
        final secondMessage = await Message.create(
          author: author,
          channel: 'general',
          payload: _b('second page'),
        );
        final client = MockClient((req) async {
          final since = int.parse(req.url.queryParameters['since']!);
          if (since == 0) {
            return http.Response(
              jsonEncode({
                'messages': [
                  {'seq': 1, ...firstMessage.toJson()},
                ],
                'seq': 1,
                'latestSeq': 2,
                'more': true,
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'messages': [
                {'seq': 2, ...secondMessage.toJson()},
              ],
              'seq': 2,
              'latestSeq': 2,
              'more': false,
            }),
            200,
          );
        });
        final transport = RelayTransport(
          baseUrl: Uri.parse('http://relay.test'),
          channel: 'general',
          client: client,
          pollInterval: const Duration(milliseconds: 5),
        );

        final received = await transport.incoming
            .take(2)
            .toList()
            .timeout(const Duration(seconds: 2));

        expect(received.map((message) => message.idHex), [
          firstMessage.idHex,
          secondMessage.idHex,
        ]);
        expect(transport.since, 2);
        await transport.close();
      },
    );

    test('poll does not require a token (channel ID is the auth)', () async {
      var called = false;
      final client = MockClient((req) async {
        called = true;
        expect(req.headers['Authorization'], isNull);
        return http.Response(
          jsonEncode({'messages': <Object?>[], 'seq': 0}),
          200,
        );
      });
      final transport = RelayTransport(
        baseUrl: Uri.parse('http://relay.test'),
        channel: 'general',
        client: client,
      );

      await transport.poll();
      expect(called, isTrue);
    });

    test('times out when the relay stalls while streaming a body', () async {
      final client = _StreamingClient((request) async {
        return http.StreamedResponse(StreamController<List<int>>().stream, 200);
      });
      final transport = RelayTransport(
        baseUrl: Uri.parse('http://relay.test'),
        channel: 'general',
        client: client,
        requestTimeout: const Duration(milliseconds: 10),
      );

      await expectLater(transport.poll(), throwsA(isA<TimeoutException>()));
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
      expect(captured[0].path, '/v2/poll');
      expect(captured[1].host, 'fallback.test');
      expect(captured[1].path, '/v2/messages');
    });

    test(
      'switching relay endpoints resets the endpoint-local cursor',
      () async {
        var active = Uri.parse('http://primary.test');
        final requests = <String>[];
        final client = MockClient((req) async {
          final since = int.parse(req.url.queryParameters['since']!);
          requests.add('${req.url.host}:$since');
          if (req.url.host == 'primary.test') {
            return http.Response(
              jsonEncode({
                'messages': <Object?>[],
                'seq': 50,
                'relayEpoch': 'primary',
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'messages': <Object?>[],
              'seq': 0,
              'relayEpoch': 'fallback',
            }),
            200,
          );
        });
        final transport = RelayTransport(
          baseUrl: active,
          channel: 'ch1',
          client: client,
          baseUrlProvider: () => active,
        );

        await transport.poll();
        active = Uri.parse('http://fallback.test');
        await transport.poll();

        expect(requests, ['primary.test:0', 'fallback.test:0']);
        expect(transport.relayEpoch, 'fallback');
      },
    );

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

    test('probe polls and emits while routine polling is paused', () async {
      final message = await Message.create(
        author: author,
        channel: 'general',
        payload: _b('standby delivery'),
      );
      var polls = 0;
      final client = MockClient((request) async {
        polls++;
        return http.Response(
          jsonEncode({
            'messages': [message.toJson()],
            'seq': 1,
            'more': false,
          }),
          200,
        );
      });
      final transport = RelayTransport(
        baseUrl: Uri.parse('http://relay.test'),
        channel: 'general',
        client: client,
        pollInterval: const Duration(hours: 1),
      );
      final received = <Message>[];
      final subscription = transport.incoming.listen(received.add);
      transport.pause();

      await transport.probe();
      await Future<void>.delayed(Duration.zero);

      expect(polls, 1);
      expect(received.map((entry) => entry.idHex), [message.idHex]);
      await subscription.cancel();
      await transport.close();
    });
  });
}
