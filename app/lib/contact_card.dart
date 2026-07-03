// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:math';

/// A shareable "contact card" — the person-level analogue of a channel invite.
/// It carries your public [pubkey] (the identity to DM), a suggested [name], an
/// unguessable [rendezvous] capability you listen on for first contact, and your
/// home [relayUrl]. Handed out externally (QR, paste, another app); whoever
/// accepts it can reach you *once* over the rendezvous, after which the
/// conversation moves to the normal derived + PairBox DM.
///
/// The rendezvous id is **random, not derived from the pubkey** — that's what
/// makes it a capability (only people you gave a card to know it) rather than an
/// enumerable inbox anyone could dial by knowing your key. Leak/spam → mint a
/// new one; existing DMs are unaffected (they live on their own derived channel).
///
/// Wire form mirrors the channel invite (`group_channel.dart`): a distinct
/// `hearth-contact:` prefix so the app routes it to add-contact rather than
/// join-channel, and so it can never be confused with the recovery-phrase QR
/// (which encodes the whole secret seed).
class ContactCard {
  ContactCard({
    required this.pubkey,
    required this.rendezvous,
    this.name,
    this.relayUrl,
  });

  final String pubkey; // ed25519 public key, hex
  final String rendezvous; // unguessable capability id, hex
  final String? name; // suggested display name
  final String? relayUrl;

  static const _prefix = 'hearth-contact:';

  /// A fresh unguessable rendezvous id (16 random bytes, hex) — the same shape
  /// as a channel capability id, so it's just as unguessable.
  static String newRendezvousId() {
    final rng = Random.secure();
    return List.generate(
      16,
      (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  /// The `hearth-contact:` code to share.
  String encode() =>
      '$_prefix${base64Url.encode(utf8.encode(jsonEncode({'pk': pubkey, 'rv': rendezvous, if (name != null && name!.trim().isNotEmpty) 'n': name, if (relayUrl != null && relayUrl!.isNotEmpty) 'r': relayUrl})))}';

  /// Parses a `hearth-contact:` code, or null if it isn't one / is malformed.
  static ContactCard? decode(String code) {
    final trimmed = code.trim();
    if (!trimmed.startsWith(_prefix)) return null;
    try {
      final json =
          (jsonDecode(
                    utf8.decode(
                      base64Url.decode(trimmed.substring(_prefix.length)),
                    ),
                  )
                  as Map)
              .cast<String, Object?>();
      final pk = json['pk'] as String?;
      final rv = json['rv'] as String?;
      if (pk == null || pk.isEmpty || rv == null || rv.isEmpty) return null;
      String? nonEmpty(String key) {
        final v = json[key] as String?;
        return (v != null && v.trim().isNotEmpty) ? v : null;
      }

      return ContactCard(
        pubkey: pk,
        rendezvous: rv,
        name: nonEmpty('n'),
        relayUrl: nonEmpty('r'),
      );
    } catch (_) {
      return null;
    }
  }
}
