// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:core/core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/channel.dart';
import 'package:hearth/content.dart';

void main() {
  test(
    'history and bookkeeping survive the former 5000-item cache limit',
    () async {
      final identity = await Identity.generate();
      final cipher = _CountingCipher();
      final session = await ChannelSession.open(
        channelId: 'history',
        identity: identity,
        relayUrl: Uri.parse('https://relay.example'),
        live: false,
        onUpdate: () {},
        blobStore: null,
        cipher: cipher,
      );
      addTearDown(session.close);
      Message? first;
      Message? edit;
      for (var i = 0; i < 5002; i++) {
        final id = Uint8List(34)
          ..[0] = 0x12
          ..[1] = 0x20;
        ByteData.sublistView(id).setUint32(30, i);
        final content = i == 1
            ? EditContent(first!.idHex, 'corrected')
            : TextContent('message $i');
        // Repository fixtures are already-admitted records: this test exercises
        // content retention, not the separately tested wire signature verifier.
        final message = Message.fromJson({
          'v': 1,
          'author': base64Url.encode(identity.publicKey),
          'channel': 'history',
          'prev': <String>[],
          'timestamp': i,
          'payload': base64Url.encode(content.encode()),
          'sig': base64Url.encode(Uint8List(64)),
          'id': base64Url.encode(id),
        });
        await session.repository.add(message);
        if (i == 0) first = message;
        if (i == 1) edit = message;
      }
      await session.refreshContent();
      expect((session.contentOf(first!) as TextContent).text, 'message 0');
      expect(session.contentOf(edit!).isBookkeeping, isTrue);
      expect(session.editOf(first.idHex)?.text, 'corrected');
      final decryptions = cipher.decryptions;
      await session.refreshContent();
      expect(cipher.decryptions, decryptions);
      expect(session.contentOf(edit).isBookkeeping, isTrue);
    },
  );
}

class _CountingCipher implements ChannelCipher {
  int decryptions = 0;
  @override
  Future<Uint8List> encrypt(List<int> plaintext) async =>
      Uint8List.fromList(plaintext);
  @override
  Future<Uint8List> decrypt(Uint8List boxed, {Uint8List? senderDevice}) async {
    decryptions++;
    return boxed;
  }
}
