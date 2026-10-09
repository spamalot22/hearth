// SPDX-License-Identifier: AGPL-3.0-or-later
import { readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

// flutter_webrtc's desktop track lookup only scans legacy onAddStream entries.
// Unified Plan receivers (especially streamless ones) must be retained too, or
// setVolume/setEnable/addTrack cannot find the track exposed by onTrack.
export const patches = [
  {
    file: 'common/cpp/include/flutter_peerconnection.h',
    before: '  std::map<std::string, scoped_refptr<RTCMediaStream>> remote_streams_;',
    after: '  std::map<std::string, scoped_refptr<RTCMediaStream>> remote_streams_;\n' +
      '  std::mutex receiver_media_mutex_;\n' +
      '  std::map<std::string, scoped_refptr<RTCMediaTrack>> receiver_tracks_;\n' +
      '  std::map<std::string, scoped_refptr<RTCMediaStream>> receiver_streams_;',
  },
  {
    file: 'common/cpp/src/flutter_peerconnection.cc',
    before: '  auto receiver = transceiver->receiver();\n  EncodableMap params;',
    after: '  auto receiver = transceiver->receiver();\n' +
      '  {\n' +
      '    std::lock_guard<std::mutex> lock(receiver_media_mutex_);\n' +
      '    auto track = receiver->track();\n' +
      '    receiver_tracks_[track->id().std_string()] = track;\n' +
      '    auto streams = receiver->streams();\n' +
      '    for (auto stream : streams.std_vector()) {\n' +
      '      receiver_streams_[stream->id().std_string()] = stream;\n' +
      '    }\n' +
      '  }\n' +
      '  EncodableMap params;',
  },
  {
    file: 'common/cpp/src/flutter_peerconnection.cc',
    before: 'void FlutterPeerConnectionObserver::OnRemoveTrack(\n' +
      '    scoped_refptr<RTCRtpReceiver> receiver) {\n  auto track = receiver->track();',
    after: 'void FlutterPeerConnectionObserver::OnRemoveTrack(\n' +
      '    scoped_refptr<RTCRtpReceiver> receiver) {\n  auto track = receiver->track();\n' +
      '  {\n' +
      '    std::lock_guard<std::mutex> lock(receiver_media_mutex_);\n' +
      '    receiver_tracks_.erase(track->id().std_string());\n' +
      '  }',
  },
  {
    file: 'common/cpp/src/flutter_peerconnection.cc',
    before: 'void FlutterPeerConnectionObserver::OnRemoveStream(\n' +
      '    scoped_refptr<RTCMediaStream> stream) {\n  EncodableMap params;',
    after: 'void FlutterPeerConnectionObserver::OnRemoveStream(\n' +
      '    scoped_refptr<RTCMediaStream> stream) {\n' +
      '  {\n' +
      '    std::lock_guard<std::mutex> lock(receiver_media_mutex_);\n' +
      '    receiver_streams_.erase(stream->id().std_string());\n' +
      '  }\n  EncodableMap params;',
  },
  {
    file: 'common/cpp/src/flutter_peerconnection.cc',
    before: 'scoped_refptr<RTCMediaStream> FlutterPeerConnectionObserver::MediaStreamForId(\n' +
      '    const std::string& id) {\n  auto it = remote_streams_.find(id);',
    after: 'scoped_refptr<RTCMediaStream> FlutterPeerConnectionObserver::MediaStreamForId(\n' +
      '    const std::string& id) {\n' +
      '  {\n' +
      '    std::lock_guard<std::mutex> lock(receiver_media_mutex_);\n' +
      '    auto receiver = receiver_streams_.find(id);\n' +
      '    if (receiver != receiver_streams_.end()) return receiver->second;\n' +
      '  }\n  auto it = remote_streams_.find(id);',
  },
  {
    file: 'common/cpp/src/flutter_peerconnection.cc',
    before: 'scoped_refptr<RTCMediaTrack> FlutterPeerConnectionObserver::MediaTrackForId(\n' +
      '    const std::string& id) {\n  for (auto it = remote_streams_.begin();',
    after: 'scoped_refptr<RTCMediaTrack> FlutterPeerConnectionObserver::MediaTrackForId(\n' +
      '    const std::string& id) {\n' +
      '  {\n' +
      '    std::lock_guard<std::mutex> lock(receiver_media_mutex_);\n' +
      '    auto receiver = receiver_tracks_.find(id);\n' +
      '    if (receiver != receiver_tracks_.end()) return receiver->second;\n' +
      '  }\n  for (auto it = remote_streams_.begin();',
  },
];

export async function patchWebRtc(root) {
  const originals = new Map();
  const files = new Map();
  for (const patch of patches) {
    const source = files.get(patch.file) ?? await readFile(resolve(root, patch.file), 'utf8');
    if (!originals.has(patch.file)) originals.set(patch.file, source);
    if (source.includes(patch.after)) {
      files.set(patch.file, source);
      continue;
    }
    if (source.split(patch.before).length - 1 !== 1) {
      throw new Error(`WebRTC receiver patch no longer matches ${patch.file}`);
    }
    files.set(patch.file, source.replace(patch.before, patch.after));
  }
  for (const [file, content] of files) {
    if (content !== originals.get(file)) await writeFile(resolve(root, file), content);
  }
}

async function main() {
  const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
  const configUrl = pathToFileURL(resolve(repo, '.dart_tool/package_config.json'));
  const config = JSON.parse(await readFile(configUrl, 'utf8'));
  const dependency = config.packages.find(pkg => pkg.name === 'flutter_webrtc');
  if (!dependency) throw new Error('Resolve workspace dependencies first');
  const root = fileURLToPath(new URL(dependency.rootUri, configUrl));
  const manifest = await readFile(resolve(root, 'pubspec.yaml'), 'utf8');
  if (!/^version: 1\.6\.0\s*$/m.test(manifest)) {
    throw new Error('Review the receiver patch before changing flutter_webrtc 1.6.0');
  }
  await patchWebRtc(root);
  console.log('WebRTC desktop patch applied: Unified Plan receiver lookup');
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await main();
}
