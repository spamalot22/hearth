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

const String githubManifestUrl =
    'https://github.com/spamalot22/hearth/releases/latest/download/manifest.json';

/// Result of an update check.
class UpdateInfo {
  final String version;
  final int seq;
  final Map<String, dynamic> assets;
  final String? signature;

  UpdateInfo({
    required this.version,
    required this.seq,
    required this.assets,
    this.signature,
  });

  Map<String, Object?>? get signedManifest => signature == null
      ? null
      : {'version': version, 'seq': seq, 'assets': assets, 'sig': signature};
}

/// Outcome of an update check.
sealed class UpdateState {
  const UpdateState();
}

/// On the current version (or check skipped on a dev build).
class UpToDate extends UpdateState {
  const UpToDate([this.verifiedRelease]);

  final UpdateInfo? verifiedRelease;
}

/// A valid, newer signed release is available.
class UpdateAvailable extends UpdateState {
  const UpdateAvailable(this.info);
  final UpdateInfo info;
}

/// GitHub could not provide a valid signed release manifest.
class UpdateCheckUnavailable extends UpdateState {
  const UpdateCheckUnavailable();
}

/// A release tag accepted by CI: `X.Y.Z`, optionally prefixed with `v`.
class ReleaseVersion implements Comparable<ReleaseVersion> {
  const ReleaseVersion(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  static final _pattern = RegExp(
    r'^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$',
  );

  static ReleaseVersion? tryParse(String value) {
    final match = _pattern.firstMatch(value);
    if (match == null) return null;
    return ReleaseVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }

  @override
  int compareTo(ReleaseVersion other) {
    final majorResult = major.compareTo(other.major);
    if (majorResult != 0) return majorResult;
    final minorResult = minor.compareTo(other.minor);
    if (minorResult != 0) return minorResult;
    return patch.compareTo(other.patch);
  }
}

bool isNewerRelease(String candidate, String current) {
  final candidateVersion = ReleaseVersion.tryParse(candidate);
  final currentVersion = ReleaseVersion.tryParse(current);
  return candidateVersion != null &&
      currentVersion != null &&
      candidateVersion.compareTo(currentVersion) > 0;
}

/// Verifies a peer- or GitHub-provided manifest's Ed25519 signature against
/// [publicKeyHex], over the **canonical** signing bytes ([manifestSigningBytes]).
/// Returns its fields as [UpdateInfo] when valid, else null (missing fields,
/// bad shape, or forged/garbled signature).
///
/// This is the single verification both the GitHub check ([checkForUpdate]) and
/// the peer-to-peer path (`ChannelManager._handleVersionControl`) call, so the
/// two can never drift onto different signing formats.
Future<UpdateInfo?> verifyManifest(
  Map<String, dynamic> manifest,
  String publicKeyHex,
) async {
  try {
    final version = manifest['version'];
    final seq = manifest['seq'];
    final sig = manifest['sig'];
    final assetsValue = manifest['assets'];
    if (version is! String ||
        version.isEmpty ||
        seq is! int ||
        seq < 0 ||
        sig is! String ||
        !RegExp(r'^[0-9a-fA-F]{128}$').hasMatch(sig) ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(publicKeyHex) ||
        assetsValue is! Map ||
        assetsValue.isEmpty ||
        assetsValue.length > 16) {
      return null;
    }
    final assets = <String, dynamic>{};
    for (final entry in assetsValue.entries) {
      final name = entry.key;
      final value = entry.value;
      if (name is! String ||
          name.isEmpty ||
          name.length > 64 ||
          value is! Map) {
        return null;
      }
      final file = value['file'];
      final hash = value['sha256'];
      if (file is! String ||
          file.isEmpty ||
          file.length > 128 ||
          hash is! String ||
          !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hash)) {
        return null;
      }
      assets[name] = {'file': file, 'sha256': hash};
    }
    final valid = await Identity.verifySignature(
      manifestSigningBytes(version, seq, assets),
      signature: _hexDecode(sig),
      publicKey: _hexDecode(publicKeyHex),
    );
    if (!valid) return null;
    return UpdateInfo(
      version: version,
      seq: seq,
      assets: assets,
      signature: sig,
    );
  } catch (_) {
    return null;
  }
}

/// Checks GitHub Releases for the latest signed update manifest.
///
/// Returns a typed outcome for a newer release, the current release, or a check
/// that could not be completed. Never throws or blocks normal app operation.
Future<UpdateState> checkForUpdate({
  Uri? manifestUrl,
  http.Client? client,
  String currentVersion = appVersion,
  String publicKeyHex = releasePublicKeyHex,
  Future<int> Function()? readLastSeq,
  Future<void> Function(int)? writeLastSeq,
}) async {
  // Dev builds (and any build without the release key baked in) never enforce.
  if (publicKeyHex.isEmpty || currentVersion == 'dev') {
    return const UpToDate();
  }
  final current = ReleaseVersion.tryParse(currentVersion);
  if (current == null) return const UpdateCheckUnavailable();

  final c = client ?? http.Client();
  try {
    final res = await c
        .get(manifestUrl ?? Uri.parse(githubManifestUrl))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return const UpdateCheckUnavailable();
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final info = await verifyManifest(body, publicKeyHex);
    if (info == null) return const UpdateCheckUnavailable();

    final candidate = ReleaseVersion.tryParse(info.version);
    if (candidate == null) return const UpdateCheckUnavailable();
    final comparison = candidate.compareTo(current);

    // Seeing our own signed manifest establishes the downgrade floor. An older
    // signed release is never an update, even on a fresh installation.
    if (comparison <= 0) {
      if (comparison == 0) {
        final lastSeq = await (readLastSeq ?? _getLastSeq)();
        if (info.seq > lastSeq) {
          await (writeLastSeq ?? _setLastSeq)(info.seq);
        }
      }
      return UpToDate(comparison == 0 ? info : null);
    }

    // Downgrade protection: reject seq ≤ our last-seen seq.
    final lastSeq = await (readLastSeq ?? _getLastSeq)();
    if (info.seq <= lastSeq) return const UpdateCheckUnavailable();

    return UpdateAvailable(info);
  } on TimeoutException {
    return const UpdateCheckUnavailable();
  } on http.ClientException {
    return const UpdateCheckUnavailable();
  } catch (_) {
    return const UpdateCheckUnavailable();
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
