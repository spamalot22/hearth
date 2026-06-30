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
  static const _fallbackRelaysKey = 'fallbackRelays';
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

  /// Fallback relay URLs (tried if the primary is unreachable).
  List<String> get fallbackRelays {
    final v = _box.get(_fallbackRelaysKey);
    if (v == null || v.trim().isEmpty) return [];
    return v.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  }

  Future<void> setFallbackRelays(List<String> urls) => urls.isEmpty
      ? _box.delete(_fallbackRelaysKey)
      : _box.put(_fallbackRelaysKey, urls.join(','));

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

  // --- Blocked users (global, persistent) ---
  static const _blockedKey = 'blockedUsers';

  /// All globally blocked pubkey hexes.
  Set<String> get blockedUsers {
    final v = _box.get(_blockedKey);
    if (v == null || v.trim().isEmpty) return {};
    return v.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toSet();
  }

  Future<void> setBlockedUsers(Set<String> pubkeys) => pubkeys.isEmpty
      ? _box.delete(_blockedKey)
      : _box.put(_blockedKey, pubkeys.join(','));

  Future<void> blockUser(String pubkeyHex) async {
    final current = blockedUsers;
    current.add(pubkeyHex);
    await setBlockedUsers(current);
  }

  Future<void> unblockUser(String pubkeyHex) async {
    final current = blockedUsers;
    current.remove(pubkeyHex);
    await setBlockedUsers(current);
  }

  // --- Per-channel preferences ---
  // Stored as "channel:<channelId>:<key>" for clean namespacing.

  static String _channelKey(String channelId, String key) =>
      'channel:$channelId:$key';

  /// Whether read receipts are disabled for [channelId].
  bool readReceiptsDisabled(String channelId) =>
      _box.get(_channelKey(channelId, 'noReadReceipts')) == 'true';

  Future<void> setReadReceiptsDisabled(String channelId, bool disabled) =>
      disabled
          ? _box.put(_channelKey(channelId, 'noReadReceipts'), 'true')
          : _box.delete(_channelKey(channelId, 'noReadReceipts'));

  /// All channel IDs with read receipts disabled.
  Set<String> get allReadReceiptsDisabled {
    final result = <String>{};
    for (final key in _box.keys) {
      if (key is String && key.endsWith(':noReadReceipts')) {
        final parts = key.split(':');
        if (parts.length == 3 && _box.get(key) == 'true') {
          result.add(parts[1]);
        }
      }
    }
    return result;
  }

  /// Generic per-channel string preference (for future expansion).
  String? channelPref(String channelId, String key) =>
      _box.get(_channelKey(channelId, key));

  Future<void> setChannelPref(String channelId, String key, String? value) =>
      value == null
          ? _box.delete(_channelKey(channelId, key))
          : _box.put(_channelKey(channelId, key), value);

  /// All channel IDs where [key] is set to 'true'.
  Set<String> channelIdsWithPref(String key) {
    final suffix = ':$key';
    final result = <String>{};
    for (final k in _box.keys) {
      if (k is String && k.endsWith(suffix) && _box.get(k) == 'true') {
        final parts = k.split(':');
        if (parts.length == 3) result.add(parts[1]);
      }
    }
    return result;
  }
}
