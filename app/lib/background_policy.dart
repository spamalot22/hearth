// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:core/core.dart';

/// Notification policy only; callers must also verify the message signature
/// and channel. Revocations remain scoped to the root that issued them.
bool backgroundSenderAllowed(
  Message message, {
  required Set<String> allowedAuthors,
  required Set<String> revokedDevices,
  String? selfAuthor,
}) {
  final author = base64Url.encode(message.author);
  if (author == selfAuthor || !allowedAuthors.contains(author)) return false;
  final device = message.device;
  return device == null ||
      !revokedDevices.contains('$author:${base64Url.encode(device)}');
}
