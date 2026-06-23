import 'package:core/core.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;

import 'media_library.dart';

const _audioExt = ['.mp3', '.wav', '.ogg', '.m4a', '.aac'];

/// Loads any CC0 clips bundled under `assets/sounds/` into the blob store +
/// media library on startup. Idempotent (blobs are content-addressed and
/// [MediaLibrary.add] skips known hashes), and a no-op when the folder holds no
/// audio — so it's safe to ship before any clips are added. The file name
/// becomes the clip name; see `assets/sounds/README.md`.
Future<void> loadStarterSounds(BlobStore store, MediaLibrary library) async {
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final clips = manifest.listAssets().where(
    (asset) =>
        asset.startsWith('assets/sounds/') &&
        _audioExt.any((ext) => asset.toLowerCase().endsWith(ext)),
  );
  for (final asset in clips) {
    final data = await rootBundle.load(asset);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final hash = await store.put(bytes);
    final name = asset.split('/').last.split('.').first;
    await library.add(hash, MediaKind.sound, name: name);
  }
}
