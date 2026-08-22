// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/bounded_download.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('streams a response within the configured limit', () async {
    final client = MockClient.streaming((_, _) async {
      return http.StreamedResponse(
        Stream.fromIterable([
          Uint8List.fromList([1, 2]),
          Uint8List.fromList([3]),
        ]),
        200,
      );
    });

    expect(
      await downloadBytesBounded(
        Uri.parse('https://media.example/test'),
        maxBytes: 3,
        client: client,
      ),
      [1, 2, 3],
    );
  });

  test('aborts a streamed response that exceeds the limit', () async {
    final client = MockClient.streaming((_, _) async {
      return http.StreamedResponse(
        Stream.fromIterable([
          Uint8List.fromList([1, 2]),
          Uint8List.fromList([3, 4]),
        ]),
        200,
      );
    });

    await expectLater(
      downloadBytesBounded(
        Uri.parse('https://media.example/test'),
        maxBytes: 3,
        client: client,
      ),
      throwsStateError,
    );
  });

  test('rejects insecure media URLs before making a request', () async {
    var requested = false;
    final client = MockClient((_) async {
      requested = true;
      return http.Response('unexpected', 200);
    });

    await expectLater(
      downloadBytesBounded(
        Uri.parse('http://media.example/test'),
        maxBytes: 3,
        client: client,
      ),
      throwsArgumentError,
    );
    expect(requested, isFalse);
  });
}
