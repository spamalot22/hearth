// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/foundation.dart';

/// Small privacy-safe session log for connection troubleshooting.
///
/// Callers must not include peer ids, channel ids, addresses, SDP, keys, or
/// message content. The bounded buffer is memory-only and disappears when the
/// process exits.
class HearthDiagnostics {
  static const int _maxEvents = 300;
  static final List<String> _events = <String>[];

  static void log(String message) {
    final line = '${DateTime.now().toUtc().toIso8601String()} $message';
    debugPrint(line);
    _events.add(line);
    if (_events.length > _maxEvents) {
      _events.removeRange(0, _events.length - _maxEvents);
    }
  }

  static String snapshot() => _events.join('\n');
}
