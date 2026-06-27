import 'dart:convert';

import 'package:core/core.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:http/http.dart' as http;

/// The app's build version, injected at compile time via --dart-define.
/// Falls back to 'dev' for local runs without a tag.
const String appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

/// Ed25519 public key (hex) of the release signer. Hardcoded — only the holder
/// of the corresponding private key can produce valid update manifests.
/// Generate with: tsx backend/src/sign-release.ts keygen
const String releasePublicKeyHex = String.fromEnvironment(
  'RELEASE_PUBLIC_KEY',
  defaultValue: '',
);

/// Result of an update check.
class UpdateInfo {
  final String version;
  final int seq;
  final Map<String, dynamic> assets;

  UpdateInfo({required this.version, required this.seq, required this.assets});
}

/// Checks the relay for a signed update manifest.
///
/// Returns [UpdateInfo] if a valid, newer release is available; null if
/// up-to-date, unverifiable, or unreachable. Never throws — update checks are
/// best-effort and must not disrupt the app.
Future<UpdateInfo?> checkForUpdate(Uri relayUrl, {http.Client? client}) async {
  if (releasePublicKeyHex.isEmpty || appVersion == 'dev') return null;
  final c = client ?? http.Client();
  try {
    final res = await c.get(relayUrl.replace(path: '/version')).timeout(
      const Duration(seconds: 5),
    );
    if (res.statusCode != 200) return null;
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final version = body['version'] as String?;
    final seq = body['seq'] as int?;
    final sig = body['sig'] as String?;
    final assets = body['assets'] as Map<String, dynamic>?;
    if (version == null || seq == null || sig == null || assets == null) {
      return null;
    }

    // Verify signature: sig covers the JSON of everything except `sig` itself.
    final payload = Map<String, dynamic>.from(body)..remove('sig');
    final payloadBytes = utf8.encode(jsonEncode(payload));
    final sigBytes = _hexDecode(sig);
    final pubBytes = _hexDecode(releasePublicKeyHex);
    final valid = await Identity.verifySignature(
      payloadBytes,
      signature: sigBytes,
      publicKey: pubBytes,
    );
    if (!valid) return null;

    // Downgrade protection: reject seq ≤ our last-seen seq.
    final lastSeq = await _getLastSeq();
    if (seq <= lastSeq) return null;

    // Is this actually newer than what we're running?
    if (version == appVersion) {
      // We're already on this version — persist its seq as the downgrade floor.
      await _setLastSeq(seq);
      return null;
    }

    return UpdateInfo(version: version, seq: seq, assets: assets);
  } catch (_) {
    return null;
  } finally {
    if (client == null) c.close();
  }
}

// --- seq persistence (Hive) ---

const _boxName = 'hearth.updates';
const _seqKey = 'lastSeq';

/// The last-seen update seq (monotonic floor for downgrade protection).
Future<int> getLastUpdateSeq() async {
  final box = await Hive.openBox<int>(_boxName);
  return box.get(_seqKey, defaultValue: 0)!;
}

Future<int> _getLastSeq() => getLastUpdateSeq();

Future<void> _setLastSeq(int seq) async {
  final box = await Hive.openBox<int>(_boxName);
  await box.put(_seqKey, seq);
}

List<int> _hexDecode(String h) {
  final out = <int>[];
  for (var i = 0; i < h.length; i += 2) {
    out.add(int.parse(h.substring(i, i + 2), radix: 16));
  }
  return out;
}
