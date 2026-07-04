// SPDX-License-Identifier: AGPL-3.0-or-later
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

/// Verifies a peer- or relay-provided manifest's Ed25519 signature against
/// [publicKeyHex], over the **canonical** signing bytes ([manifestSigningBytes]).
/// Returns its fields as [UpdateInfo] when valid, else null (missing fields,
/// bad shape, or forged/garbled signature).
///
/// This is the single verification both the relay check ([checkForUpdate]) and
/// the peer-to-peer path (`ChannelManager._handleVersionControl`) call, so the
/// two can never drift onto different signing formats again — the drift that
/// silently broke P2P propagation when only the relay path was migrated.
Future<UpdateInfo?> verifyManifest(
  Map<String, dynamic> manifest,
  String publicKeyHex,
) async {
  final version = manifest['version'] as String?;
  final seq = manifest['seq'] as int?;
  final sig = manifest['sig'] as String?;
  final assets = manifest['assets'] as Map<String, dynamic>?;
  if (version == null || seq == null || sig == null || assets == null) {
    return null;
  }
  final valid = await Identity.verifySignature(
    manifestSigningBytes(version, seq, assets),
    signature: _hexDecode(sig),
    publicKey: _hexDecode(publicKeyHex),
  );
  if (!valid) return null;
  return UpdateInfo(version: version, seq: seq, assets: assets);
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
    final info = await verifyManifest(body, releasePublicKeyHex);
    if (info == null) return const UpToDate(); // missing fields / forged

    // Downgrade protection: reject seq ≤ our last-seen seq.
    final lastSeq = await _getLastSeq();
    if (info.seq <= lastSeq) return const UpToDate();

    // Already on this version — persist its seq as the downgrade floor.
    if (info.version == appVersion) {
      await _setLastSeq(info.seq);
      return const UpToDate();
    }

    return UpdateAvailable(info);
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

/// Canonical bytes signed for a release manifest — mirrors `manifestSigningBytes`
/// in `backend/src/manifest.ts`. A fixed-field, newline-joined form (not JSON) so
/// the TS signer and this client agree byte-for-byte regardless of JSON key order
/// or whitespace. Asset keys are sorted.
List<int> manifestSigningBytes(
  String version,
  int seq,
  Map<String, dynamic> assets,
) {
  final lines = <String>['hearth/manifest/v1', version, '$seq'];
  for (final name in assets.keys.toList()..sort()) {
    final a = assets[name] as Map;
    lines
      ..add(name)
      ..add(a['file'] as String)
      ..add(a['sha256'] as String);
  }
  return utf8.encode(lines.join('\n'));
}

List<int> _hexDecode(String h) {
  final out = <int>[];
  for (var i = 0; i < h.length; i += 2) {
    out.add(int.parse(h.substring(i, i + 2), radix: 16));
  }
  return out;
}
