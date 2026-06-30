// SPDX-License-Identifier: AGPL-3.0-or-later
// Web-only: browser Notification API.
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Requests notification permission (call once on user gesture).
Future<bool> requestWebNotificationPermission() async {
  final result = await web.Notification.requestPermission().toDart;
  return result.toDart == 'granted';
}

/// Shows a browser notification. Returns false if permission not granted.
bool showWebNotification(String title, String body) {
  final perm = web.Notification.permission;
  // NotificationPermission is a JSString typedef.
  // ignore: invalid_runtime_check_with_js_interop_types
  if ((perm as JSAny).dartify() != 'granted') return false;
  web.Notification(title, web.NotificationOptions(body: body));
  return true;
}
