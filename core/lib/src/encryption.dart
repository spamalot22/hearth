import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'identity.dart';

final X25519 _x25519 = X25519();
final Chacha20 _aead = Chacha20.poly1305Aead();

/// The Curve25519 field prime, 2^255 − 19.
final BigInt _p = (BigInt.one << 255) - BigInt.from(19);

/// Maps an Ed25519 public key to the equivalent X25519 (Montgomery `u`) public
/// key: `u = (1 + y) / (1 − y) mod p`, where `y` is the Edwards y-coordinate the
/// Ed25519 key encodes (little-endian, sign bit cleared). This is what lets you
/// encrypt to a peer knowing only their Ed25519 identity — no key exchange.
Uint8List ed25519PublicToX25519(List<int> ed25519PublicKey) {
  if (ed25519PublicKey.length != 32) {
    throw ArgumentError('Ed25519 public key must be 32 bytes');
  }
  var y = BigInt.zero;
  for (var i = 31; i >= 0; i--) {
    final b = i == 31 ? ed25519PublicKey[i] & 0x7f : ed25519PublicKey[i];
    y = (y << 8) | BigInt.from(b);
  }
  final denom = (BigInt.one - y) % _p;
  final u = ((BigInt.one + y) % _p * denom.modInverse(_p)) % _p;

  final out = Uint8List(32);
  var v = u;
  final mask = BigInt.from(0xff);
  for (var i = 0; i < 32; i++) {
    out[i] = (v & mask).toInt();
    v = v >> 8;
  }
  return out;
}

/// Anonymous public-key encryption to a recipient identity — "sealed box".
///
/// A fresh ephemeral X25519 keypair does ECDH with the recipient's (identity-
/// derived) X25519 key; an HKDF-derived key drives ChaCha20-Poly1305. The wire
/// form is `ephemeralPub(32) ‖ nonce(12) ‖ mac(16) ‖ ciphertext`. The box itself
/// carries no sender identity — in Hearth the enclosing [Message] is already
/// Ed25519-signed, so the recipient learns the author from the signature and
/// reads the plaintext from the box. Dart↔Dart only (no cross-language contract),
/// so the format is ours to choose.
class SealedBox {
  /// Encrypts [plaintext] so only the holder of [recipientEd25519PublicKey] can
  /// read it.
  static Future<Uint8List> seal(
    List<int> plaintext, {
    required List<int> recipientEd25519PublicKey,
  }) async {
    final recipientX = ed25519PublicToX25519(recipientEd25519PublicKey);
    final ephemeral = await _x25519.newKeyPair();
    final ephemeralPub = Uint8List.fromList(
      (await ephemeral.extractPublicKey()).bytes,
    );
    final shared = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: SimplePublicKey(recipientX, type: KeyPairType.x25519),
    );
    final key = await _deriveKey(
      await shared.extractBytes(),
      ephemeralPub,
      recipientX,
    );
    final box = await _aead.encrypt(plaintext, secretKey: key);
    return Uint8List.fromList([
      ...ephemeralPub,
      ...box.nonce,
      ...box.mac.bytes,
      ...box.cipherText,
    ]);
  }

  /// Decrypts a [sealed] box for [recipient]. Throws if it wasn't sealed to this
  /// identity or has been tampered with.
  static Future<Uint8List> open(
    Uint8List sealed, {
    required Identity recipient,
  }) async {
    if (sealed.length < 60) {
      throw const FormatException('sealed box too short');
    }
    final ephemeralPub = sealed.sublist(0, 32);
    final nonce = sealed.sublist(32, 44);
    final mac = sealed.sublist(44, 60);
    final cipherText = sealed.sublist(60);

    final recipientX = await recipient.x25519PublicKey();
    final shared = await recipient.x25519SharedSecret(ephemeralPub);
    final key = await _deriveKey(shared, ephemeralPub, recipientX);
    final clear = await _aead.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
      secretKey: key,
    );
    return Uint8List.fromList(clear);
  }

  static Future<SecretKey> _deriveKey(
    List<int> shared,
    List<int> ephemeralPub,
    List<int> recipientX,
  ) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    return hkdf.deriveKey(
      secretKey: SecretKey(shared),
      nonce: [...ephemeralPub, ...recipientX],
      info: utf8.encode('hearth/sealedbox/v1'),
    );
  }
}

/// Symmetric encryption between two identities, keyed by their *static* ECDH
/// shared secret — so both parties (and only they) read every message, including
/// their own. This is what a 1:1 DM uses: a sealed box would stop the sender
/// reading back what they sent. No forward secrecy (the key is static) — fine for
/// a first cut; ratchet later. Wire form: `nonce(12) ‖ mac(16) ‖ ciphertext`.
class PairBox {
  /// Encrypts [plaintext] for the DM between [self] and [peerEd25519PublicKey].
  static Future<Uint8List> encrypt(
    List<int> plaintext, {
    required Identity self,
    required List<int> peerEd25519PublicKey,
  }) async {
    final key = await _pairKey(self, peerEd25519PublicKey);
    final box = await _aead.encrypt(plaintext, secretKey: key);
    return Uint8List.fromList([
      ...box.nonce,
      ...box.mac.bytes,
      ...box.cipherText,
    ]);
  }

  /// Decrypts a DM [boxed] message between [self] and [peerEd25519PublicKey].
  static Future<Uint8List> decrypt(
    Uint8List boxed, {
    required Identity self,
    required List<int> peerEd25519PublicKey,
  }) async {
    if (boxed.length < 28) throw const FormatException('pair box too short');
    final nonce = boxed.sublist(0, 12);
    final mac = boxed.sublist(12, 28);
    final cipherText = boxed.sublist(28);
    final key = await _pairKey(self, peerEd25519PublicKey);
    final clear = await _aead.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
      secretKey: key,
    );
    return Uint8List.fromList(clear);
  }

  /// The shared key. Direction-independent (ECDH is symmetric; salt/info fixed),
  /// so both parties derive the same one.
  static Future<SecretKey> _pairKey(
    Identity self,
    List<int> peerEd25519PublicKey,
  ) async {
    final shared = await self.x25519SharedSecret(
      ed25519PublicToX25519(peerEd25519PublicKey),
    );
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    return hkdf.deriveKey(
      secretKey: SecretKey(shared),
      nonce: const [],
      info: utf8.encode('hearth/pairbox/v1'),
    );
  }
}
