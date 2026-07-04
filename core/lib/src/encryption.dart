// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:math' as dart_math;
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

/// Symmetric encryption with a shared 32-byte channel key — for invite-only
/// group channels, where the key travels in the invite (a capability: holding it
/// is membership). Everyone with the key reads everything. No forward secrecy or
/// per-member revocation yet (rotate the key + re-invite, or MLS later). Wire
/// form: `nonce(12) ‖ mac(16) ‖ ciphertext`.
class GroupCipher {
  /// Encrypts [plaintext] with the channel [key] (32 bytes).
  static Future<Uint8List> encrypt(
    List<int> plaintext, {
    required List<int> key,
  }) async {
    final box = await _aead.encrypt(plaintext, secretKey: SecretKey(key));
    return Uint8List.fromList([
      ...box.nonce,
      ...box.mac.bytes,
      ...box.cipherText,
    ]);
  }

  /// Decrypts a [boxed] message with the channel [key].
  static Future<Uint8List> decrypt(
    Uint8List boxed, {
    required List<int> key,
  }) async {
    if (boxed.length < 28) throw const FormatException('group box too short');
    final clear = await _aead.decrypt(
      SecretBox(
        boxed.sublist(28),
        nonce: boxed.sublist(0, 12),
        mac: Mac(boxed.sublist(12, 28)),
      ),
      secretKey: SecretKey(key),
    );
    return Uint8List.fromList(clear);
  }
}

/// Per-device DM encryption (Phase B). Encrypts a DM plaintext once, then wraps
/// the content key to each of the recipient's active device X25519 keys. Only
/// devices that receive a key-wrap can decrypt.
///
/// Wire format:
/// ```
/// version(1) ‖ numDevices(1) ‖ [devicePubX(32) ‖ wrappedKey(48)]* ‖ nonce(12) ‖ mac(16) ‖ ciphertext
/// ```
/// The content key is a fresh random 32-byte key encrypted with ChaCha20-Poly1305.
/// Each device's wrap uses ECDH(sender_device, recipient_device) as the key.
/// The nonce for wrapping is derived from sender+recipient device keys (deterministic,
/// since the content key is random and never reused).
class MultiDeviceBox {
  static const int _version = 1;

  /// Encrypts [plaintext] so that each device in [recipientDeviceKeys] (raw
  /// Ed25519 pubkeys, 32 bytes each) can decrypt it. [senderDevice] is the
  /// sender's device identity (for the ECDH with each recipient device).
  static Future<Uint8List> encrypt(
    List<int> plaintext, {
    required Identity senderDevice,
    required List<Uint8List> recipientDeviceKeys,
  }) async {
    if (recipientDeviceKeys.isEmpty) {
      throw ArgumentError('must have at least one recipient device');
    }
    // 1. Generate a random content key and encrypt the plaintext.
    final contentKey = SecretKey(List.generate(32, (_) => _secureRandom()));
    final contentBox = await _aead.encrypt(plaintext, secretKey: contentKey);
    final contentKeyBytes = await contentKey.extractBytes();

    // 2. Wrap the content key to each recipient device.
    final wraps = <Uint8List>[];
    for (final deviceEd in recipientDeviceKeys) {
      final deviceX = ed25519PublicToX25519(deviceEd);
      final shared = await senderDevice.x25519SharedSecret(deviceX);
      final senderX = await senderDevice.x25519PublicKey();
      final wrapKey = await _deriveWrapKey(shared, senderX, deviceX);
      final wrapped = await _aead.encrypt(contentKeyBytes, secretKey: wrapKey);
      wraps.add(Uint8List.fromList([
        ...deviceEd,
        ...wrapped.nonce,
        ...wrapped.mac.bytes,
        ...wrapped.cipherText,
      ]));
    }

    // 3. Assemble: version ‖ count ‖ wraps ‖ content nonce ‖ content mac ‖ ciphertext
    return Uint8List.fromList([
      _version,
      recipientDeviceKeys.length,
      for (final w in wraps) ...w,
      ...contentBox.nonce,
      ...contentBox.mac.bytes,
      ...contentBox.cipherText,
    ]);
  }

  /// Decrypts a [boxed] MultiDeviceBox using [recipientDevice]'s key and the
  /// sender's device key [senderDeviceEd] (known from the message envelope).
  static Future<Uint8List> decrypt(
    Uint8List boxed, {
    required Identity recipientDevice,
    required Uint8List senderDeviceEd,
  }) async {
    if (boxed.isEmpty || boxed[0] != _version) {
      throw const FormatException('unsupported MultiDeviceBox version');
    }
    final numDevices = boxed[1];
    const wrapSize = 32 + 12 + 16 + 32; // devicePub + nonce + mac + wrappedKey
    final wrapsEnd = 2 + numDevices * wrapSize;
    if (boxed.length < wrapsEnd + 28) {
      throw const FormatException('MultiDeviceBox too short');
    }

    // Find our device's wrap.
    final myKey = recipientDevice.publicKey;
    Uint8List? contentKeyBytes;
    for (var i = 0; i < numDevices; i++) {
      final offset = 2 + i * wrapSize;
      final devicePub = boxed.sublist(offset, offset + 32);
      if (!_bytesEqual(devicePub, myKey)) continue;
      // This wrap is ours — unwrap the content key.
      final wrapNonce = boxed.sublist(offset + 32, offset + 44);
      final wrapMac = boxed.sublist(offset + 44, offset + 60);
      final wrappedKey = boxed.sublist(offset + 60, offset + 92);

      final senderX = ed25519PublicToX25519(senderDeviceEd);
      final shared = await recipientDevice.x25519SharedSecret(senderX);
      final recipientX = await recipientDevice.x25519PublicKey();
      final wrapKey = await _deriveWrapKey(shared, senderX, recipientX);
      contentKeyBytes = Uint8List.fromList(await _aead.decrypt(
        SecretBox(wrappedKey, nonce: wrapNonce, mac: Mac(wrapMac)),
        secretKey: wrapKey,
      ));
      break;
    }
    if (contentKeyBytes == null) {
      throw const FormatException('no wrap found for this device');
    }

    // Decrypt the content.
    final nonce = boxed.sublist(wrapsEnd, wrapsEnd + 12);
    final mac = boxed.sublist(wrapsEnd + 12, wrapsEnd + 28);
    final cipherText = boxed.sublist(wrapsEnd + 28);
    final clear = await _aead.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
      secretKey: SecretKey(contentKeyBytes),
    );
    return Uint8List.fromList(clear);
  }

  static Future<SecretKey> _deriveWrapKey(
    List<int> shared,
    List<int> senderX,
    List<int> recipientX,
  ) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    return hkdf.deriveKey(
      secretKey: SecretKey(shared),
      nonce: [...senderX, ...recipientX],
      info: utf8.encode('hearth/multidevicebox/v1'),
    );
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

int _secureRandom() {
  // Dart's Random.secure() backed by OS CSPRNG.
  return _rng.nextInt(256);
}

final _rng = _SecureRng();

class _SecureRng {
  final _r = List.generate(256, (_) => 0);
  int _pos = 256;

  int nextInt(int max) {
    if (_pos >= 256) {
      // Refill from OS.
      final gen = SecureRandom(256);
      for (var i = 0; i < 256; i++) {
        _r[i] = gen.bytes[i];
      }
      _pos = 0;
    }
    return _r[_pos++] % max;
  }
}

class SecureRandom {
  SecureRandom(int length) : bytes = Uint8List(length) {
    final r = dart_math.Random.secure();
    for (var i = 0; i < length; i++) {
      bytes[i] = r.nextInt(256);
    }
  }
  final Uint8List bytes;
}
