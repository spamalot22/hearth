import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:hive_ce_flutter/hive_ce_flutter.dart';

/// A joined group channel: a random capability [id] (used for rendezvous *and*
/// as the access secret — only people you invite know it), the symmetric [key]
/// that encrypts its messages, and a local [name] you chose (yours only, never
/// shared). Two people who create "games" get different ids — no collisions.
class GroupChannel {
  GroupChannel({required this.id, required this.key, required this.name});

  final String id; // 16 random bytes, hex
  final Uint8List key; // 32 random bytes
  final String name; // local display name

  /// Creates a brand-new channel (random id + key) with local [name].
  factory GroupChannel.create(String name) {
    final rng = Random.secure();
    return GroupChannel(
      id: _hex(rng, 16),
      key: Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256))),
      name: name,
    );
  }

  /// The invite string others paste to join — carries id + key + a suggested
  /// name, the **inviter's pubkey** (a mandatory contact on accept + the cold-start
  /// bootstrap peer), and the **relay URL** (so a new joiner auto-adopts it and
  /// never has to type one). Anyone holding it can join and read.
  String invite({
    required String inviterPubkeyHex,
    String? inviterName,
    String? relayUrl,
  }) =>
      'hearth:${base64Url.encode(utf8.encode(jsonEncode({'id': id, 'k': base64Url.encode(key), 'n': name, 'inv': inviterPubkeyHex, if (inviterName != null && inviterName.isNotEmpty) 'in': inviterName, if (relayUrl != null && relayUrl.isNotEmpty) 'r': relayUrl})))}';

  /// Parses an [invite] string into the channel + inviter, or null if malformed.
  static Invite? fromInvite(String invite) {
    try {
      final body = invite.trim().replaceFirst('hearth:', '');
      final json = (jsonDecode(utf8.decode(base64Url.decode(body))) as Map)
          .cast<String, Object?>();
      final id = json['id'] as String?;
      final k = json['k'] as String?;
      if (id == null || k == null || id.isEmpty) return null;
      String? nonEmpty(String key) {
        final v = json[key] as String?;
        return (v != null && v.trim().isNotEmpty) ? v : null;
      }

      return Invite(
        channel: GroupChannel(
          id: id,
          key: base64Url.decode(k),
          name: nonEmpty('n') ?? id,
        ),
        inviterPubkey: nonEmpty('inv'),
        inviterName: nonEmpty('in'),
        relayUrl: nonEmpty('r'),
      );
    } catch (_) {
      return null;
    }
  }

  GroupChannel withName(String newName) =>
      GroupChannel(id: id, key: key, name: newName);

  Map<String, Object?> _toRegistry() => {'k': base64Url.encode(key), 'n': name};

  static GroupChannel _fromRegistry(String id, Map<String, Object?> m) =>
      GroupChannel(
        id: id,
        key: base64Url.decode(m['k']! as String),
        name: m['n'] as String? ?? id,
      );

  static String _hex(Random rng, int bytes) => List.generate(
    bytes,
    (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

/// A parsed invite: the [channel] to join, the inviter (added as a mandatory
/// contact on accept — keeping the invite-tree contact graph connected — and used
/// as the cold-start bootstrap peer), and the [relayUrl] the channel uses (a new
/// joiner adopts it). Fields are null for older invites that omit them.
class Invite {
  Invite({
    required this.channel,
    this.inviterPubkey,
    this.inviterName,
    this.relayUrl,
  });

  final GroupChannel channel;
  final String? inviterPubkey; // hex
  final String? inviterName;
  final String? relayUrl;
}

/// On-device list of the group channels you've created or joined (Hive), so they
/// survive restart. Keyed by channel id → {key, local name}.
class ChannelRegistry {
  ChannelRegistry._(this._box);

  final Box<String> _box;

  static Future<ChannelRegistry> open() async {
    await Hive.initFlutter();
    final box = await Hive.openBox<String>('hearth.channels');
    return ChannelRegistry._(box);
  }

  List<GroupChannel> all() => _box.keys
      .cast<String>()
      .map(
        (id) => GroupChannel._fromRegistry(
          id,
          (jsonDecode(_box.get(id)!) as Map).cast<String, Object?>(),
        ),
      )
      .toList();

  Future<void> save(GroupChannel channel) =>
      _box.put(channel.id, jsonEncode(channel._toRegistry()));

  Future<void> remove(String id) => _box.delete(id);
}
