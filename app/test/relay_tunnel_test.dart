// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:core/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/relay_tunnel.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('uses refreshed auth tokens for subsequent requests', () async {
    final authorizations = <String?>[];
    var token = 'first';
    final client = MockClient((request) async {
      authorizations.add(request.headers['authorization']);
      return request.method == 'GET'
          ? http.Response(jsonEncode({'frames': <String>[]}), 200)
          : http.Response('{}', 200);
    });
    final tunnel = RelayTunnel(
      baseUrl: Uri.parse('https://relay.example'),
      selfPubkeyHex: List.filled(64, 'a').join(),
      peerPubkeyHex: List.filled(64, 'b').join(),
      authTokenProvider: () => token,
      client: client,
    );

    tunnel.send(const HaveFrame([]));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    token = 'second';
    tunnel.send(const HaveFrame([]));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(
      authorizations,
      containsAllInOrder(['Bearer first', 'Bearer second']),
    );
    await tunnel.close();
  });

  test('becomes ready only after receiving a valid peer frame', () async {
    var readyCalls = 0;
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode({
          'frames': [123, const HaveFrame([]).encode()],
        }),
        200,
      ),
    );
    final tunnel = RelayTunnel(
      baseUrl: Uri.parse('https://relay.example'),
      selfPubkeyHex: List.filled(64, 'a').join(),
      peerPubkeyHex: List.filled(64, 'b').join(),
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

    expect(tunnel.isReady, isTrue);
    expect(readyCalls, 1);
    expect(frames, isNotEmpty);
    await sub.cancel();
    await tunnel.close();
  });
}
