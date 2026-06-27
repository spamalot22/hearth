// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

/// Your own self-asserted display name — the one suggested to others when they
/// add you. Persisted locally; broadcast as signed `profile` messages.
class ProfileStore {
  ProfileStore._(this._box);

  final Box<String> _box;

  static Future<ProfileStore> open() async {
    await Hive.initFlutter();
    final box = await Hive.openBox<String>('hearth.profile');
    return ProfileStore._(box);
  }

  String? get name {
    final value = _box.get('name');
    return (value == null || value.isEmpty) ? null : value;
  }

  Future<void> setName(String name) => _box.put('name', name);
}
