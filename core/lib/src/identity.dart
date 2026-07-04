// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:cryptography/cryptography.dart';

final Ed25519 _ed25519 = Ed25519();
final X25519 _x25519 = X25519();
final Sha256 _sha256 = Sha256();
final Sha512 _sha512 = Sha512();

/// SHA-256 of [bytes]. Used for content-addressing message ids.
Future<Uint8List> sha256Digest(List<int> bytes) async {
  final h = await _sha256.hash(bytes);
  return Uint8List.fromList(h.bytes);
}

/// A Hearth identity: an Ed25519 keypair whose **public key is the user id**.
///
/// No account, no server — possessing the private seed *is* being this user.
/// The secret seed is persisted by the app through a [KeyStore]; `core` never
/// touches platform storage directly, so it stays Flutter-free.
class Identity {
  final SimpleKeyPair? _keyPair;

  /// The 32-byte Ed25519 public key — this identity's canonical id.
  final Uint8List publicKey;

  Identity._(this._keyPair, this.publicKey);

  /// Creates a pubkey-only identity (no signing capability). Used when the root
  /// seed is offline — you know *who* you are (pubkey from cert) but can't sign
  /// as root. Calling [sign] or [x25519SharedSecret] throws [StateError].
  Identity.fromPublicKey(this.publicKey) : _keyPair = null;

  /// Whether this identity holds the private key (can sign).
  bool get canSign => _keyPair != null;

  /// Creates a brand-new random identity.
  static Future<Identity> generate() async {
    final kp = await _ed25519.newKeyPair();
    final pub = await kp.extractPublicKey();
    return Identity._(kp, Uint8List.fromList(pub.bytes));
  }

  /// Restores an identity from a stored 32-byte [seed] (the private material).
  static Future<Identity> fromSeed(List<int> seed) async {
    final kp = await _ed25519.newKeyPairFromSeed(seed);
    final pub = await kp.extractPublicKey();
    return Identity._(kp, Uint8List.fromList(pub.bytes));
  }

  /// Loads the persisted identity from [store], or generates and persists a new
  /// one on first run. This is the app's identity bootstrap.
  static Future<Identity> loadOrCreate(KeyStore store) async {
    final seed = await store.readSeed();
    if (seed != null) return fromSeed(seed);
    final identity = await generate();
    await store.writeSeed(await identity.extractSeed());
    return identity;
  }

  /// The 32-byte seed to persist via a [KeyStore]. Treat as a secret.
  Future<Uint8List> extractSeed() async {
    final kp = _keyPair;
    if (kp == null) throw StateError('pubkey-only identity has no seed');
    return Uint8List.fromList(await kp.extractPrivateKeyBytes());
  }

  /// Ed25519 signature (64 bytes) over [message].
  Future<Uint8List> sign(List<int> message) async {
    final kp = _keyPair;
    if (kp == null) throw StateError('pubkey-only identity cannot sign');
    final sig = await _ed25519.sign(message, keyPair: kp);
    return Uint8List.fromList(sig.bytes);
  }

  /// Short, human-comparable label (first 4 public-key bytes as hex), e.g.
  /// for "sam#a1b2c3d4"-style display. Not a security boundary.
  String get fingerprint => hex.encode(publicKey.sublist(0, 4));

  /// The full public key as a hex string.
  String get publicKeyHex => hex.encode(publicKey);

  /// This identity's X25519 public key — its Ed25519 key mapped to Curve25519,
  /// so anyone holding the Ed25519 id can encrypt to it with no separate key
  /// exchange. Used by `SealedBox`.
  Future<Uint8List> x25519PublicKey() async {
    final pub = await (await _deriveX25519()).extractPublicKey();
    return Uint8List.fromList(pub.bytes);
  }

  /// ECDH shared secret between this identity's X25519 key and [peerX25519Pub].
  Future<Uint8List> x25519SharedSecret(List<int> peerX25519Pub) async {
    final secret = await _x25519.sharedSecretKey(
      keyPair: await _deriveX25519(),
      remotePublicKey: SimplePublicKey(peerX25519Pub, type: KeyPairType.x25519),
    );
    return Uint8List.fromList(await secret.extractBytes());
  }

  /// Derives this identity's X25519 keypair from the Ed25519 seed — the standard
  /// `sk_to_curve25519`: SHA-512 of the seed, first 32 bytes, clamped.
  Future<SimpleKeyPair> _deriveX25519() async {
    final kp = _keyPair;
    if (kp == null) throw StateError('pubkey-only identity has no X25519 key');
    final seed = await kp.extractPrivateKeyBytes();
    final h = await _sha512.hash(seed);
    final priv = Uint8List.fromList(h.bytes.sublist(0, 32));
    priv[0] &= 0xf8;
    priv[31] = (priv[31] & 0x7f) | 0x40;
    return _x25519.newKeyPairFromSeed(priv);
  }

  /// Verifies that [signature] is a valid Ed25519 signature by [publicKey]
  /// over [message]. Static because you verify *other people's* messages.
  static Future<bool> verifySignature(
    List<int> message, {
    required List<int> signature,
    required List<int> publicKey,
  }) async {
    final pub = SimplePublicKey(publicKey, type: KeyPairType.ed25519);
    return _ed25519.verify(
      message,
      signature: Signature(signature, publicKey: pub),
    );
  }
}

/// Where an [Identity]'s secret seed is persisted.
///
/// Implemented in the app (Keychain on Apple, Keystore on Android, DPAPI on
/// Windows — via `flutter_secure_storage`). `core` depends only on this
/// interface so it remains pure Dart and portable.
abstract interface class KeyStore {
  Future<void> writeSeed(Uint8List seed);
  Future<Uint8List?> readSeed();
  Future<void> deleteSeed();
}

/// In-memory [KeyStore] for tests and the local dev backend. Not persistent.
class InMemoryKeyStore implements KeyStore {
  Uint8List? _seed;

  @override
  Future<void> writeSeed(Uint8List seed) async => _seed = seed;

  @override
  Future<Uint8List?> readSeed() async => _seed;

  @override
  Future<void> deleteSeed() async => _seed = null;
}
