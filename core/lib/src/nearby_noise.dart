// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

/// Fixed Noise_XX_25519_ChaChaPoly_SHA256, revision 34, sections 4-7.
/// No negotiation, early application data, fallback to plaintext, or PSKs.
/// The static key is per nearby activation, NOT a Hearth account identity.
/// Authenticating possession of that key does not establish contact trust.
class NearbyNoise {
  NearbyNoise({
    required this.initiator,
    required this.localStatic,
    required this.localEphemeral,
    List<int> prologue = const [],
  }) {
    final name = utf8.encode('Noise_XX_25519_ChaChaPoly_SHA256');
    _h = name.length <= 32
        ? (Uint8List(32)..setRange(0, name.length, name))
        : _hash(name);
    _ck = Uint8List.fromList(_h);
    _mixHash(prologue);
  }

  final bool initiator;
  final SimpleKeyPair localStatic;
  final SimpleKeyPair localEphemeral;
  static final _dh = X25519();
  late Uint8List _h;
  late Uint8List _ck;
  NearbyNoiseCipher _cipher = NearbyNoiseCipher(null);
  SimplePublicKey? _remoteEphemeral;
  SimplePublicKey? _remoteStatic;
  int _step = 0;
  bool _failed = false;
  NearbyNoiseCipher? sending;
  NearbyNoiseCipher? receiving;
  bool get complete => _step == 3 && !_failed;
  List<int> get remoteStatic {
    if (!complete) throw StateError('Handshake incomplete');
    return List.unmodifiable(_remoteStatic!.bytes);
  }

  static Uint8List _hash(List<int> bytes) =>
      Uint8List.fromList(hashes.sha256.convert(bytes).bytes);
  void _mixHash(List<int> bytes) => _h = _hash([..._h, ...bytes]);
  List<Uint8List> _hkdf(List<int> input) {
    Uint8List mac(List<int> key, List<int> data) =>
        Uint8List.fromList(hashes.Hmac(hashes.sha256, key).convert(data).bytes);
    final temp = mac(_ck, input);
    final first = mac(temp, [1]);
    return [
      first,
      mac(temp, [...first, 2]),
    ];
  }

  Future<void> _mixDh(SimpleKeyPair local, SimplePublicKey remote) async {
    final secret = await _dh.sharedSecretKey(
      keyPair: local,
      remotePublicKey: remote,
    );
    final bytes = await secret.extractBytes();
    if (bytes.every((b) => b == 0)) {
      secret.destroy();
      throw const FormatException('Invalid DH key');
    }
    final keys = _hkdf(bytes);
    secret.destroy();
    _ck = keys[0];
    _cipher.destroy();
    _cipher = NearbyNoiseCipher(SecretKey(keys[1]));
  }

  Future<Uint8List> _encrypt(List<int> bytes) async {
    final encrypted = await _cipher.encrypt(bytes, aad: _h);
    _mixHash(encrypted);
    return encrypted;
  }

  Future<Uint8List> _decrypt(List<int> bytes) async {
    final clear = await _cipher.decrypt(bytes, aad: _h);
    _mixHash(bytes);
    return clear;
  }

  void _finish() {
    _step++;
    if (_step != 3) return;
    final keys = _hkdf([]);
    sending = NearbyNoiseCipher(SecretKey(keys[initiator ? 0 : 1]));
    receiving = NearbyNoiseCipher(SecretKey(keys[initiator ? 1 : 0]));
    _ck.fillRange(0, _ck.length, 0);
    _cipher.destroy();
  }

  Future<Uint8List> write([List<int> payload = const []]) async {
    if (_failed || _step >= 3 || (_step.isEven != initiator)) {
      throw StateError('Unexpected Noise write');
    }
    try {
      final output = BytesBuilder(copy: false);
      if (_step < 2) {
        final e = (await localEphemeral.extractPublicKey()).bytes;
        output.add(e);
        _mixHash(e);
      }
      if (_step == 1) {
        await _mixDh(localEphemeral, _remoteEphemeral!);
        output.add(
          await _encrypt((await localStatic.extractPublicKey()).bytes),
        );
        await _mixDh(localStatic, _remoteEphemeral!);
      } else if (_step == 2) {
        output.add(
          await _encrypt((await localStatic.extractPublicKey()).bytes),
        );
        await _mixDh(localStatic, _remoteEphemeral!);
      }
      output.add(await _encrypt(payload));
      _finish();
      return output.takeBytes();
    } catch (_) {
      _failed = true;
      rethrow;
    }
  }

  Future<Uint8List> read(Uint8List bytes) async {
    if (_failed || _step >= 3 || (_step.isEven == initiator)) {
      throw StateError('Unexpected Noise read');
    }
    try {
      var offset = 0;
      Uint8List take(int count) {
        if (offset + count > bytes.length) {
          throw const FormatException('Short Noise message');
        }
        final value = Uint8List.sublistView(bytes, offset, offset + count);
        offset += count;
        return value;
      }

      if (_step < 2) {
        final e = take(32);
        _remoteEphemeral = SimplePublicKey(e, type: KeyPairType.x25519);
        _mixHash(e);
      }
      if (_step == 1) {
        await _mixDh(localEphemeral, _remoteEphemeral!);
        _remoteStatic = SimplePublicKey(
          await _decrypt(take(48)),
          type: KeyPairType.x25519,
        );
        await _mixDh(localEphemeral, _remoteStatic!);
      } else if (_step == 2) {
        _remoteStatic = SimplePublicKey(
          await _decrypt(take(48)),
          type: KeyPairType.x25519,
        );
        await _mixDh(localEphemeral, _remoteStatic!);
      }
      final payload = await _decrypt(Uint8List.sublistView(bytes, offset));
      _finish();
      return payload;
    } catch (_) {
      _failed = true;
      rethrow;
    }
  }

  void destroy() {
    _failed = true;
    _ck.fillRange(0, _ck.length, 0);
    _cipher.destroy();
    sending?.destroy();
    receiving?.destroy();
    localEphemeral.destroy();
  }
}

/// Ordered Noise transport: implicit per-direction nonce rejects replay and
/// reordering. A failed authentication permanently invalidates the cipher.
class NearbyNoiseCipher {
  NearbyNoiseCipher(this._key);
  final SecretKey? _key;
  static final _aead = Chacha20.poly1305Aead();
  int _nonce = 0;
  bool _failed = false;
  Uint8List _nextNonce() {
    // Conservative rekey bound, far below the protocol's 2^64 - 1 limit.
    if (_failed || _nonce >= 0xffffffff) {
      throw StateError('Noise cipher expired');
    }
    final bytes = Uint8List(12);
    ByteData.sublistView(bytes).setUint64(4, _nonce++, Endian.little);
    return bytes;
  }

  Future<Uint8List> encrypt(List<int> bytes, {List<int> aad = const []}) async {
    if (_key == null) return Uint8List.fromList(bytes);
    final box = await _aead.encrypt(
      bytes,
      secretKey: _key,
      nonce: _nextNonce(),
      aad: aad,
    );
    return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
  }

  Future<Uint8List> decrypt(List<int> bytes, {List<int> aad = const []}) async {
    if (_key == null) return Uint8List.fromList(bytes);
    try {
      if (bytes.length < 16) {
        throw const FormatException('Short Noise ciphertext');
      }
      final box = SecretBox(
        bytes.sublist(0, bytes.length - 16),
        nonce: _nextNonce(),
        mac: Mac(bytes.sublist(bytes.length - 16)),
      );
      return Uint8List.fromList(
        await _aead.decrypt(box, secretKey: _key, aad: aad),
      );
    } catch (_) {
      _failed = true;
      rethrow;
    }
  }

  void destroy() {
    _failed = true;
    _key?.destroy();
  }
}
