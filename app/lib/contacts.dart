// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

/// Local, private petnames: a map from a peer's public key (hex) to the name
/// *you* chose for them.
///
/// Each user names contacts on their own device — there is no global registry
/// (Zooko's triangle: we keep names secure + decentralised and give up only
/// global agreement). A name is a private label, never broadcast. Until you name
/// someone they show as `hearth#fingerprint`.
class ContactBook {
  ContactBook._(this._box);

  final Box<String> _box;

  /// Opens the on-device contacts box (Hive: IndexedDB on web, files native).
  static Future<ContactBook> open() async {
    await Hive.initFlutter();
    final box = await Hive.openBox<String>('hearth.contacts');
    return ContactBook._(box);
  }

  /// The petname you assigned to [pubkeyHex], or null if unnamed.
  String? nameFor(String pubkeyHex) => _box.get(pubkeyHex);

  /// Every contact you've added: pubkey (hex) → name.
  Map<String, String> entries() => {
    for (final id in _box.keys.cast<String>()) id: _box.get(id)!,
  };

  /// Sets (or, for an empty [name], clears) the petname for [pubkeyHex].
  Future<void> setName(String pubkeyHex, String name) {
    final trimmed = name.trim();
    return trimmed.isEmpty
        ? _box.delete(pubkeyHex)
        : _box.put(pubkeyHex, trimmed);
  }
}
