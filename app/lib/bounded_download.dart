// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Downloads an HTTP(S) resource without allowing the response to exceed
/// [maxBytes]. The streamed check still applies when Content-Length is missing
/// or dishonest, so an untrusted media URL cannot exhaust client memory.
Future<Uint8List> downloadBytesBounded(
  Uri uri, {
  required int maxBytes,
  http.Client? client,
  Duration timeout = const Duration(seconds: 20),
}) async {
  if (maxBytes < 0) throw ArgumentError.value(maxBytes, 'maxBytes');
  if (uri.scheme != 'https') {
    throw ArgumentError.value(uri, 'uri', 'must use HTTPS');
  }
  final ownedClient = client == null;
  final c = client ?? http.Client();
  try {
    final response = await c.send(http.Request('GET', uri)).timeout(timeout);
    if (response.statusCode != 200) {
      throw http.ClientException(
        'download failed: HTTP ${response.statusCode}',
        uri,
      );
    }
    final declared = response.contentLength;
    if (declared != null && declared > maxBytes) {
      throw StateError('download is larger than the safety limit');
    }
    final chunks = BytesBuilder(copy: false);
    var received = 0;
    await for (final chunk in response.stream.timeout(timeout)) {
      received += chunk.length;
      if (received > maxBytes) {
        throw StateError('download exceeded the safety limit');
      }
      chunks.add(chunk);
    }
    return chunks.takeBytes();
  } finally {
    if (ownedClient) c.close();
  }
}

/// Reads an already-open HTTP response with a hard byte ceiling.
Future<Uint8List> readResponseBytesBounded(
  http.StreamedResponse response, {
  required int maxBytes,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final declared = response.contentLength;
  if (declared != null && declared > maxBytes) {
    throw StateError('response is larger than the safety limit');
  }
  final chunks = BytesBuilder(copy: false);
  var received = 0;
  await for (final chunk in response.stream.timeout(timeout)) {
    received += chunk.length;
    if (received > maxBytes) {
      throw StateError('response exceeded the safety limit');
    }
    chunks.add(chunk);
  }
  return chunks.takeBytes();
}

Future<Map<String, dynamic>> readJsonObjectBounded(
  http.StreamedResponse response, {
  required int maxBytes,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final bytes = await readResponseBytesBounded(
    response,
    maxBytes: maxBytes,
    timeout: timeout,
  );
  return (jsonDecode(utf8.decode(bytes)) as Map).cast<String, dynamic>();
}
