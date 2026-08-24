// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/profile.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

void main() {
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('hearth-dm-registry-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => temp.path);
    Hive.init(temp.path);
  });

  tearDown(() async {
    await Hive.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    await temp.delete(recursive: true);
  });

  test('mailbox claims converge on the lowest signed message id', () async {
    final registry = await DmRegistry.open();
    final peer = '1' * 64;
    final laterClaim = 'f' * 68;
    final winningClaim = '0' * 68;

    expect(await registry.setMailbox(peer, 'a' * 64, laterClaim), isTrue);
    expect(await registry.setMailbox(peer, 'b' * 64, winningClaim), isTrue);
    expect(await registry.setMailbox(peer, 'c' * 64, laterClaim), isFalse);
    expect(registry.mailboxFor(peer), 'b' * 64);
    expect(registry.mailboxClaimFor(peer), winningClaim);

    await registry.save(peer);
    expect(registry.mailboxFor(peer), 'b' * 64);
  });
}
