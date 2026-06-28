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
  static const _noiseKey = 'noiseSuppression';

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

  /// Whether enhanced noise suppression is enabled (off by default).
  bool get noiseSuppression => _box.get(_noiseKey) == 'true';

  Future<void> setNoiseSuppression(bool enabled) =>
      _box.put(_noiseKey, enabled.toString());

  static const _computeKey = 'contributeCompute';

  /// Whether this device serves as an AI bot for peers (on by default).
  /// The model runs locally on this device's CPU (and GPU if available via Metal/CUDA).
  bool get contributeCompute => _box.get(_computeKey) != 'false';

  Future<void> setContributeCompute(bool enabled) =>
      _box.put(_computeKey, enabled.toString());

  static const _activeModelKey = 'activeModel';

  /// The currently selected model id (null = legacy single file).
  String? get activeModel => _box.get(_activeModelKey);

  Future<void> setActiveModel(String id) => _box.put(_activeModelKey, id);
}
