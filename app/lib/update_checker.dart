import 'dart:async';
import 'dart:convert';

import 'package:core/core.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:http/http.dart' as http;

/// The app's build version, injected at compile time via --dart-define.
/// Falls back to 'dev' for local runs without a tag.
const String appVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: 'dev',
);

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

/// Outcome of an update check.
sealed class UpdateState {
  const UpdateState();
}

/// On the current version (or check skipped on a dev build).
class UpToDate extends UpdateState {
  const UpToDate();
}

/// A valid, newer signed release is available.
class UpdateAvailable extends UpdateState {
  const UpdateAvailable(this.info);
  final UpdateInfo info;
}

/// Couldn't reach the relay to verify the version — released builds block on this
/// (you must connect to a relay to confirm you're current / get the update).
class RelayUnreachable extends UpdateState {
  const RelayUnreachable();
}

/// Checks the relay for a signed update manifest.
///
/// Returns [UpdateInfo] if a valid, newer release is available; null if
/// up-to-date, unverifiable, or unreachable. Never throws — update checks are
/// best-effort and must not disrupt the app.
Future<UpdateState> checkForUpdate(Uri relayUrl, {http.Client? client}) async {
  // Dev builds (and any build without the release key baked in) never enforce.
  if (releasePublicKeyHex.isEmpty || appVersion == 'dev') {
    return const UpToDate();
  }
  final c = client ?? http.Client();
  try {
    final res = await c
        .get(relayUrl.replace(path: '/version'))
        .timeout(const Duration(seconds: 5));
    // Any HTTP response means the relay is reachable — only a connection failure
    // counts as "down". A reachable relay with no manifest (404) is up to date.
    if (res.statusCode != 200) return const UpToDate();
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final version = body['version'] as String?;
    final seq = body['seq'] as int?;
    final sig = body['sig'] as String?;
    final assets = body['assets'] as Map<String, dynamic>?;
    if (version == null || seq == null || sig == null || assets == null) {
      return const UpToDate();
    }

    // Verify signature: sig covers the JSON of everything except `sig` itself.
    final payload = Map<String, dynamic>.from(body)..remove('sig');
    final valid = await Identity.verifySignature(
      utf8.encode(jsonEncode(payload)),
      signature: _hexDecode(sig),
      publicKey: _hexDecode(releasePublicKeyHex),
    );
    if (!valid) return const UpToDate(); // forged/garbled — ignore

    // Downgrade protection: reject seq ≤ our last-seen seq.
    final lastSeq = await _getLastSeq();
    if (seq <= lastSeq) return const UpToDate();

    // Already on this version — persist its seq as the downgrade floor.
    if (version == appVersion) {
      await _setLastSeq(seq);
      return const UpToDate();
    }

    return UpdateAvailable(
      UpdateInfo(version: version, seq: seq, assets: assets),
    );
  } on TimeoutException {
    return const RelayUnreachable();
  } on http.ClientException {
    return const RelayUnreachable();
  } catch (_) {
    // Malformed response etc. — relay's reachable, just nothing actionable.
    return const UpToDate();
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
