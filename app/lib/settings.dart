// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

/// On-device app settings (Hive). Currently just the **relay URL override** — the
/// rendezvous + media-proxy endpoint — so you can point Hearth at your own
/// self-hosted relay instead of the bundled default. Returns null when unset (use
/// the default).
class SettingsStore {
  SettingsStore._(this._box);

  final Box<String> _box;

  static const _relayKey = 'relayUrl';

  static Future<SettingsStore> open() async {
    await Hive.initFlutter();
    final box = await Hive.openBox<String>('hearth.settings');
    return SettingsStore._(box);
  }

  /// The saved relay URL override, or null to fall back to the app default.
  String? get relayUrl {
    final v = _box.get(_relayKey);
    return (v != null && v.trim().isNotEmpty) ? v : null;
  }

  /// Saves (or, for null/empty, clears) the relay URL override.
  Future<void> setRelayUrl(String? url) => (url == null || url.trim().isEmpty)
      ? _box.delete(_relayKey)
      : _box.put(_relayKey, url.trim());
}
