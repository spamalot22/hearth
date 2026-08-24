// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/relay_tunnel.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition was not reached before the deadline');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('uses refreshed auth tokens for subsequent requests', () async {
    final self = await Identity.generate();
    final peer = await Identity.generate();
    final authorizations = <String?>[];
    var token = 'first';
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        authorizations.add(request.headers['authorization']);
      }
      return request.method == 'GET'
          ? http.Response(jsonEncode({'frames': <String>[]}), 200)
          : http.Response('{}', 200);
    });
    final tunnel = RelayTunnel(
      baseUrl: Uri.parse('https://relay.example'),
      identity: self,
      peerPubkeyHex: peer.publicKeyHex,
      authTokenProvider: () => token,
      client: client,
    );

    tunnel.send(const HaveFrame([]));
    await _waitUntil(() => authorizations.length == 1);
    token = 'second';
    tunnel.send(const HaveFrame([]));
    await _waitUntil(() => authorizations.length == 2);

    expect(authorizations, ['Bearer first', 'Bearer second']);
    await tunnel.close();
  });

  test('follows relay URL changes for uploads and polling', () async {
    final self = await Identity.generate();
    final peer = await Identity.generate();
    final requests = <String>[];
    var relayUrl = Uri.parse('https://primary.example');
    final client = MockClient((request) async {
      requests.add('${request.method} ${request.url.host}');
      return request.method == 'GET'
          ? http.Response(jsonEncode({'frames': <String>[]}), 200)
          : http.Response('{}', 200);
    });
    final tunnel = RelayTunnel(
      baseUrl: relayUrl,
      baseUrlProvider: () => relayUrl,
      identity: self,
      peerPubkeyHex: peer.publicKeyHex,
      authToken: 'token',
      pollInterval: const Duration(milliseconds: 5),
      client: client,
    );

    tunnel.start();
    tunnel.send(const HaveFrame([]));
    await _waitUntil(
      () =>
          requests.contains('POST primary.example') &&
          requests.contains('GET primary.example'),
    );

    relayUrl = Uri.parse('https://fallback.example');
    tunnel.send(const HaveFrame([]));
    await _waitUntil(
      () =>
          requests.contains('POST fallback.example') &&
          requests.contains('GET fallback.example'),
    );

    await tunnel.close();
  });

  test('rejects unauthenticated plaintext tunnel frames', () async {
    final self = await Identity.generate();
    final peer = await Identity.generate();
    var readyCalls = 0;
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'frames': [123, const HaveFrame([]).encode()],
        }),
        200,
      ),
    );
    final tunnel = RelayTunnel(
      baseUrl: Uri.parse('https://relay.example'),
      identity: self,
      peerPubkeyHex: peer.publicKeyHex,
      authToken: 'token',
      pollInterval: const Duration(milliseconds: 5),
      onReady: () => readyCalls++,
      client: client,
    );
    final frames = <SyncFrame>[];
    final sub = tunnel.frames.listen(frames.add);

    expect(tunnel.isReady, isFalse);
    tunnel.start();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(tunnel.isReady, isFalse);
    expect(readyCalls, 0);
    expect(frames, isEmpty);
    await sub.cancel();
    await tunnel.close();
  });

  test('encrypts, fragments, and reconstructs a large blob frame', () async {
    final alice = await Identity.generate();
    final bob = await Identity.generate();
    final mailbox = <String>[];
    final requestSizes = <int>[];
    final postedData = <String>[];

    Future<http.Response> relay(http.Request request) async {
      if (request.method == 'POST') {
        requestSizes.add(utf8.encode(request.body).length);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final data = body['data'] as String;
        postedData.add(data);
        mailbox.add(data);
        return http.Response('{}', 200);
      }
      final count = mailbox.length < 32 ? mailbox.length : 32;
      final batch = mailbox.take(count).toList();
      mailbox.removeRange(0, count);
      return http.Response(jsonEncode({'frames': batch}), 200);
    }

    final sender = RelayTunnel(
      baseUrl: Uri.parse('https://relay.example'),
      identity: alice,
      peerPubkeyHex: bob.publicKeyHex,
      authToken: 'alice-token',
      client: MockClient(relay),
    );
    final receiver = RelayTunnel(
      baseUrl: Uri.parse('https://relay.example'),
      identity: bob,
      peerPubkeyHex: alice.publicKeyHex,
      authToken: 'bob-token',
      pollInterval: const Duration(milliseconds: 5),
      client: MockClient(relay),
    );
    final bytes = Uint8List.fromList(
      List<int>.generate(200 * 1024, (index) => index & 0xff),
    );
    final received = receiver.frames.first;
    receiver.start();

    sender.send(GiveBlobFrame('1220${List.filled(64, 'a').join()}', bytes));
    final frame = await received.timeout(const Duration(seconds: 5));

    expect(frame, isA<GiveBlobFrame>());
    expect((frame as GiveBlobFrame).bytes, bytes);
    expect(postedData.length, greaterThan(1));
    expect(postedData, everyElement(startsWith('e1:')));
    expect(requestSizes, everyElement(lessThan(64 * 1024)));
    final recognizablePlaintext = base64.encode(bytes.sublist(0, 48));
    expect(postedData, everyElement(isNot(contains(recognizablePlaintext))));
    await sender.close();
    await receiver.close();
  });

  test('group tunnels require both peers to possess the channel key', () async {
    final alice = await Identity.generate();
    final bob = await Identity.generate();
    final mailbox = <String>[];
    var posts = 0;
    var deliveries = 0;

    Future<http.Response> relay(http.Request request) async {
      if (request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        mailbox.add(body['data'] as String);
        posts++;
        return http.Response('{}', 200);
      }
      final batch = mailbox.toList();
      mailbox.clear();
      if (batch.isNotEmpty) deliveries++;
      return http.Response(jsonEncode({'frames': batch}), 200);
    }

    final sender = RelayTunnel(
      baseUrl: Uri.parse('https://relay.example'),
      identity: alice,
      peerPubkeyHex: bob.publicKeyHex,
      authToken: 'alice-token',
      channelAuthKey: Uint8List.fromList(List<int>.generate(32, (i) => i)),
      client: MockClient(relay),
    );
    final receiver = RelayTunnel(
      baseUrl: Uri.parse('https://relay.example'),
      identity: bob,
      peerPubkeyHex: alice.publicKeyHex,
      authToken: 'bob-token',
      channelAuthKey: Uint8List(32),
      pollInterval: const Duration(milliseconds: 5),
      client: MockClient(relay),
    );
    final frames = <SyncFrame>[];
    final sub = receiver.frames.listen(frames.add);
    receiver.start();
    sender.send(const HaveFrame([]));

    await _waitUntil(() => posts == 1 && deliveries == 1);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(receiver.isReady, isFalse);
    expect(frames, isEmpty);

    await sub.cancel();
    await sender.close();
    await receiver.close();
  });

  test('group tunnels work when both peers possess the channel key', () async {
    final alice = await Identity.generate();
    final bob = await Identity.generate();
    final mailbox = <String>[];
    final key = Uint8List.fromList(List<int>.generate(32, (i) => i));

    Future<http.Response> relay(http.Request request) async {
      if (request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        mailbox.add(body['data'] as String);
        return http.Response('{}', 200);
      }
      final batch = mailbox.toList();
      mailbox.clear();
      return http.Response(jsonEncode({'frames': batch}), 200);
    }

    final sender = RelayTunnel(
      baseUrl: Uri.parse('https://relay.example'),
      identity: alice,
      peerPubkeyHex: bob.publicKeyHex,
      authToken: 'alice-token',
      channelAuthKey: key,
      client: MockClient(relay),
    );
    final receiver = RelayTunnel(
      baseUrl: Uri.parse('https://relay.example'),
      identity: bob,
      peerPubkeyHex: alice.publicKeyHex,
      authToken: 'bob-token',
      channelAuthKey: key,
      pollInterval: const Duration(milliseconds: 5),
      client: MockClient(relay),
    );
    final received = receiver.frames.first;
    receiver.start();
    sender.send(const HaveFrame([]));

    expect(
      await received.timeout(const Duration(seconds: 2)),
      isA<HaveFrame>(),
    );
    expect(receiver.isReady, isTrue);

    await sender.close();
    await receiver.close();
  });
}
