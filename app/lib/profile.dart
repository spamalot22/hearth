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

/// One outbound first-contact attempt: the [ownerPubkeyHex] you're reaching and
/// the [rendezvousId] from their card, plus when you accepted it.
class PendingContact {
  PendingContact(this.ownerPubkeyHex, this.rendezvousId, this.acceptedMs);

  final String ownerPubkeyHex;
  final String rendezvousId;
  final int acceptedMs;
}

/// Outbound contact-card attempts that haven't connected yet. Persisted so a
/// first contact keeps retrying across network drops *and* app restarts —
/// resumed on startup, dropped once the DM connects (or after [_expiryMs] as a
/// backstop, so a card to someone who never comes back doesn't linger forever).
/// This stays purely *outbound* (people you chose to reach), never an inbound
/// listen-for-anyone inbox. Keyed by owner pubkey hex → `rendezvousId|acceptedMs`.
class PendingContactStore {
  PendingContactStore._(this._box);

  final Box<String> _box;

  static const int _expiryMs = 7 * 24 * 60 * 60 * 1000; // 7 days

  static Future<PendingContactStore> open() async {
    await Hive.initFlutter();
    final box = await Hive.openBox<String>('hearth.pending_contacts');
    return PendingContactStore._(box);
  }

  /// Live (non-expired) pending contacts; prunes any that have aged out.
  Future<List<PendingContact>> live() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final result = <PendingContact>[];
    for (final key in _box.keys.cast<String>().toList()) {
      final raw = _box.get(key);
      if (raw == null) continue;
      final sep = raw.indexOf('|');
      final rv = sep < 0 ? raw : raw.substring(0, sep);
      final ts = sep < 0 ? 0 : int.tryParse(raw.substring(sep + 1)) ?? 0;
      if (now - ts > _expiryMs) {
        await _box.delete(key);
        continue;
      }
      result.add(PendingContact(key, rv, ts));
    }
    return result;
  }

  Future<void> save(String ownerPubkeyHex, String rendezvousId) => _box.put(
    ownerPubkeyHex,
    '$rendezvousId|${DateTime.now().millisecondsSinceEpoch}',
  );

  Future<void> remove(String ownerPubkeyHex) => _box.delete(ownerPubkeyHex);
}
