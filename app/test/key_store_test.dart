// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:convert/convert.dart';
import 'package:core/core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/key_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'synced credential label uses public identity, not secret seed bytes',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const channel = MethodChannel('hearth/credentials');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      MethodCall? written;
      messenger.setMockMethodCallHandler(channel, (call) async {
        written = call;
        return null;
      });
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        messenger.setMockMethodCallHandler(channel, null);
      });
      final seed = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final identity = await Identity.fromSeed(seed);
      await SyncedKeyStore().writeSeed(seed);
      expect(written?.method, 'write');
      final arguments = written!.arguments as Map<Object?, Object?>;
      expect(arguments['label'], 'Hearth #${identity.fingerprint}');
      expect(
        arguments['label'],
        isNot(contains(hex.encode(seed.sublist(0, 4)))),
      );
    },
  );
}
