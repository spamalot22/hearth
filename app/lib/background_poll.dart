// SPDX-License-Identifier: AGPL-3.0-or-later
// Background fetch: polls the relay for new messages when the app is backgrounded
// (Android/iOS). Fires a local notification if new messages arrived.
// Uses background_fetch which leverages JobScheduler on Android (minimum 15 min).
import 'dart:convert';

import 'package:background_fetch/background_fetch.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:http/http.dart' as http;

/// Headless callback — runs in a separate isolate when the app is terminated.
/// Must be a top-level function.
@pragma('vm:entry-point')
void backgroundFetchHeadlessTask(HeadlessEvent event) async {
  if (event.timeout) {
    await BackgroundFetch.finish(event.taskId);
    return;
  }
  await _pollFromStorage();
  await BackgroundFetch.finish(event.taskId);
}

/// Configures background fetch. Call once on app startup (Android/iOS only).
Future<void> initBackgroundFetch() async {
  if (kIsWeb || defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS) {
    return;
  }

  await BackgroundFetch.configure(
    BackgroundFetchConfig(
      minimumFetchInterval: 15,
      stopOnTerminate: false,
      startOnBoot: true,
      enableHeadless: true,
      requiredNetworkType: NetworkType.ANY,
    ),
    (String taskId) async {
      await _pollFromStorage();
      await BackgroundFetch.finish(taskId);
    },
    (String taskId) async {
      await BackgroundFetch.finish(taskId);
    },
  );

  await BackgroundFetch.registerHeadlessTask(backgroundFetchHeadlessTask);
}

/// Saves relay state so the headless isolate can poll independently.
/// Call this whenever channels or relay URL change.
Future<void> saveBackgroundPollState({
  required String relayUrl,
  required List<String> channelIds,
  String? token,
}) async {
  await Hive.initFlutter();
  final box = await Hive.openBox<String>('hearth.bg_poll');
  await box.put('relayUrl', relayUrl);
  await box.put('channels', channelIds.join(','));
  if (token != null) {
    await box.put('token', token);
  } else {
    await box.delete('token');
  }
}

/// Polls relay from Hive-stored state (works in headless isolate).
Future<void> _pollFromStorage() async {
  try {
    await Hive.initFlutter();
    final box = await Hive.openBox<String>('hearth.bg_poll');
    final relayUrl = box.get('relayUrl');
    final channelsRaw = box.get('channels');
    final token = box.get('token');

    if (relayUrl == null || channelsRaw == null || channelsRaw.isEmpty) return;

    final relay = Uri.parse(relayUrl);
    final channels = channelsRaw.split(',').where((s) => s.isNotEmpty).toList();
    final cursorBox = await Hive.openBox<int>('hearth.bg_cursors');

    var totalNew = 0;
    for (final channelId in channels) {
      final since = cursorBox.get(channelId) ?? 0;
      final params = <String, String>{
        'channel': channelId,
        'since': '$since',
      };
      final headers = <String, String>{};
      if (token != null) headers['Authorization'] = 'Bearer $token';

      final res = await http.get(
        relay.replace(path: '/poll', queryParameters: params),
        headers: headers,
      );
      if (res.statusCode != 200) continue;

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final messages = body['messages'] as List? ?? [];
      final seq = body['seq'] as int? ?? since;
      await cursorBox.put(channelId, seq);
      totalNew += messages.length;
    }

    if (totalNew > 0) {
      await _showBgNotification(totalNew);
    }
  } catch (_) {
    // Best-effort — don't crash the background isolate.
  }
}

Future<void> _showBgNotification(int count) async {
  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );
  await plugin.show(
    id: 99, // fixed ID for background notifications (overwrite previous)
    title: 'Hearth',
    body: '$count new message${count > 1 ? 's' : ''} waiting',
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails(
        'hearth_messages',
        'Messages',
        importance: Importance.high,
        priority: Priority.high,
      ),
    ),
  );
}
