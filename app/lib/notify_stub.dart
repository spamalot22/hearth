// SPDX-License-Identifier: AGPL-3.0-or-later
// Stub for non-web platforms (native notifications handled by flutter_local_notifications).

Future<bool> requestWebNotificationPermission() async => false;

bool showWebNotification(String title, String body) => false;
