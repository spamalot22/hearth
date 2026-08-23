// SPDX-License-Identifier: AGPL-3.0-or-later
// Background fetch: polls the relay for new messages when the app is backgrounded
// (Android/iOS). Fires a local notification if new messages arrived.
// Uses background_fetch which leverages JobScheduler on Android (minimum 15 min).
import 'dart:async';
import 'dart:convert';

import 'package:background_fetch/background_fetch.dart';
import 'package:core/core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    hide Message;
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
  if (kIsWeb ||
      defaultTargetPlatform == TargetPlatform.windows ||
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
///
/// [cursors] seeds each channel's poll cursor with the relay seq the foreground
/// has already caught up to, so the background poll only counts genuinely-new
/// messages — never the whole backlog, never messages already read in-app. A
/// cursor is only rewound when [epochs] proves the in-memory relay restarted.
/// [selfAuthor] is the local identity's base64url author key, used to skip our
/// own echoed messages.
Future<void> saveBackgroundPollState({
  required String relayUrl,
  required List<String> channelIds,
  Map<String, int> cursors = const {},
  Map<String, String> epochs = const {},
  Map<String, String> names = const {},
  String? selfAuthor,
}) async {
  await Hive.initFlutter();
  final box = await Hive.openBox<String>('hearth.bg_poll');
  await box.put('relayUrl', relayUrl);
  await box.put('channels', channelIds.join(','));
  // Channel id -> local name, so per-channel notifications can be labelled.
  await box.put('names', jsonEncode(names));
  if (selfAuthor != null) await box.put('self', selfAuthor);
  if (cursors.isNotEmpty || epochs.isNotEmpty) {
    final cursorBox = await Hive.openBox<int>('hearth.bg_cursors');
    final epochBox = await Hive.openBox<String>('hearth.bg_epochs');
    for (final entry in epochs.entries) {
      final previous = epochBox.get(entry.key);
      if (previous != null && previous != entry.value) {
        await cursorBox.put(entry.key, cursors[entry.key] ?? 0);
      }
      await epochBox.put(entry.key, entry.value);
    }
    for (final entry in cursors.entries) {
      // Within one relay generation, only move forward.
      if (entry.value > (cursorBox.get(entry.key) ?? 0)) {
        await cursorBox.put(entry.key, entry.value);
      }
    }
  }
}

Future<Map<String, dynamic>?> _fetchPoll(
  Uri relay,
  String channelId,
  int since,
) async {
  final params = <String, String>{'channel': channelId, 'since': '$since'};
  final res = await http
      .get(relay.replace(path: '/poll', queryParameters: params))
      .timeout(const Duration(seconds: 10));
  if (res.statusCode != 200) return null;
  return jsonDecode(res.body) as Map<String, dynamic>;
}

/// Polls relay from Hive-stored state (works in headless isolate).
Future<void> _pollFromStorage() async {
  try {
    await Hive.initFlutter();
    final box = await Hive.openBox<String>('hearth.bg_poll');
    final relayUrl = box.get('relayUrl');
    final channelsRaw = box.get('channels');
    final selfAuthor = box.get('self');
    final namesRaw = box.get('names');
    final names = namesRaw != null
        ? (jsonDecode(namesRaw) as Map).cast<String, String>()
        : const <String, String>{};

    if (relayUrl == null || channelsRaw == null || channelsRaw.isEmpty) return;

    final relay = Uri.parse(relayUrl);
    final channels = channelsRaw.split(',').where((s) => s.isNotEmpty).toList();
    final cursorBox = await Hive.openBox<int>('hearth.bg_cursors');
    final epochBox = await Hive.openBox<String>('hearth.bg_epochs');

    // Per-channel new counts → one notification per group/DM (below).
    final newPerChannel = <String, int>{};
    for (final channelId in channels) {
      // First time we ever poll this channel in the background: establish the
      // baseline silently instead of notifying for the entire backlog.
      final hasBaseline = cursorBox.containsKey(channelId);
      var since = cursorBox.get(channelId) ?? 0;
      var body = await _fetchPoll(relay, channelId, since);
      if (body == null) continue;
      var responseEpoch = body['relayEpoch'];
      if (responseEpoch is String && responseEpoch.isNotEmpty) {
        final previousEpoch = epochBox.get(channelId);
        if (previousEpoch != null && previousEpoch != responseEpoch) {
          since = 0;
          await cursorBox.put(channelId, since);
          body = await _fetchPoll(relay, channelId, since);
          if (body == null) continue;
          responseEpoch = body['relayEpoch'];
        }
        if (responseEpoch is String && responseEpoch.isNotEmpty) {
          await epochBox.put(channelId, responseEpoch);
        }
      }
      final messages = body['messages'] as List? ?? [];
      final seqValue = body['seq'];
      final seq = seqValue is int && seqValue > since ? seqValue : since;
      final latestValue = body['latestSeq'];
      final latestSeq = latestValue is int && latestValue > seq
          ? latestValue
          : seq;
      if (!hasBaseline) {
        // Baseline directly at the channel head. Poll responses are paginated,
        // so using the first page cursor would notify old backlog later.
        await cursorBox.put(channelId, latestSeq);
      } else if (seq > since) {
        await cursorBox.put(channelId, seq);
      }
      if (!hasBaseline) continue; // baseline just set — nothing to report yet
      // Count new messages, excluding our own (the relay echoes them back).
      var count = 0;
      for (final raw in messages) {
        try {
          if (raw is! Map) continue;
          final message = Message.fromJson(raw.cast<String, Object?>());
          if (message.channel != channelId || !await message.verify()) continue;
          if (raw['author'] == selfAuthor) continue;
          count++;
        } catch (_) {
          // A relay is untrusted; malformed or forged entries never notify.
        }
      }
      if (count > 0) newPerChannel[channelId] = count;
    }

    if (newPerChannel.isNotEmpty) {
      final plugin = FlutterLocalNotificationsPlugin();
      await plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
      for (final entry in newPerChannel.entries) {
        await _showBgNotification(
          plugin,
          entry.key,
          names[entry.key] ?? 'New messages',
          entry.value,
        );
      }
    }
  } catch (_) {
    // Best-effort — don't crash the background isolate.
  }
}

/// Stable per-conversation id — must match `notificationIdFor` in main.dart so a
/// background notification and a later foreground one for the same channel
/// replace each other rather than doubling up.
int _bgNotificationId(String channelId) => channelId.hashCode & 0x7fffffff;

Future<void> _showBgNotification(
  FlutterLocalNotificationsPlugin plugin,
  String channelId,
  String name,
  int count,
) async {
  await plugin.show(
    id: _bgNotificationId(channelId), // per channel → stacks per group/DM
    title: name,
    body: '$count new message${count > 1 ? 's' : ''}',
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails(
        'hearth_messages',
        'Messages',
        importance: Importance.high,
        priority: Priority.high,
        groupKey: 'com.hearth.app.messages',
      ),
    ),
  );
}
