// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

import 'contact_card.dart';

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

  /// Blob hash of your chosen avatar image, or null for none.
  String? get avatar {
    final value = _box.get('avatar');
    return (value == null || value.isEmpty) ? null : value;
  }

  Future<void> setAvatar(String? hash) => _box.put('avatar', hash ?? '');

  /// Your standing rendezvous capability — the unguessable id that rides in
  /// every contact card and that you listen on for first contact. Generated
  /// once and persisted (one per identity); rotating it means minting a new one
  /// and re-sharing your card, which invalidates old cards without touching any
  /// existing DM.
  String get rendezvousId {
    final existing = _box.get('rendezvous');
    if (existing != null && existing.isNotEmpty) return existing;
    final fresh = ContactCard.newRendezvousId();
    _box.put('rendezvous', fresh);
    return fresh;
  }
}

/// On-device list of DMs worth restoring on startup — peers you've actually
/// exchanged a message with (not every fleeting `openDm`). Mirrors
/// [ChannelRegistry] for groups: on launch the app re-opens a DM session per
/// entry so messages keep arriving without the user tapping in first.
class DmRegistry {
  DmRegistry._(this._box);

  final Box<String> _box;

  static Future<DmRegistry> open() async {
    await Hive.initFlutter();
    final box = await Hive.openBox<String>('hearth.dms');
    return DmRegistry._(box);
  }

  /// Every peer pubkey (hex) with an established DM.
  List<String> all() => _box.keys.cast<String>().toList();

  /// Records [peerPubkeyHex] as an established DM (idempotent).
  Future<void> save(String peerPubkeyHex) => _box.put(peerPubkeyHex, '1');

  Future<void> remove(String peerPubkeyHex) => _box.delete(peerPubkeyHex);
}
