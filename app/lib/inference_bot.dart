// SPDX-License-Identifier: AGPL-3.0-or-later
// Uses fllama (GPL-2.0, github.com/Telosnex/fllama) for llama.cpp FFI bindings.
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fllama/fllama.dart';
import 'package:path_provider/path_provider.dart';

import 'diagnostics.dart';
import 'inference_job.dart';

/// A local LLM inference bot. Runs a GGUF model via fllama (llama.cpp FFI).
/// Any peer with a model file and the AI toggle enabled can serve inference
/// requests from other peers in the mesh. The model runs entirely on ONE
/// device — this is not distributed computation, but decentralised hosting
/// (no central server; any peer can volunteer as the bot).
///
/// Easy to rip out: this file + the control frame + a few lines in main.dart.
class InferenceBot {
  InferenceBot._(this._modelPath);

  final String _modelPath;
  // All model selections share one native engine. Replacing this bot must not
  // permit another model load while an earlier request is still shutting down.
  static final _job = InferenceJob(
    start: (path, prompt, maxTokens, output) => fllamaChat(
      OpenAiRequest(
        maxTokens: maxTokens,
        messages: [
          Message(
            Role.system,
            'You are a helpful assistant in a group chat called Hearth. Keep responses concise.',
          ),
          Message(Role.user, prompt),
        ],
        numGpuLayers: 0,
        modelPath: path,
        frequencyPenalty: 0.0,
        presencePenalty: 1.1,
        topP: 1.0,
        contextSize: 2048,
      ),
      output,
    ),
    cancel: fllamaCancelInference,
    onEvent: HearthDiagnostics.log,
  );

  /// Whether the bot is currently processing a request.
  bool get busy => _job.busy;

  void cancel() => _job.cancelCurrent();

  /// The default model filename (placed in app documents dir).
  static const String kModelFilename = 'hearth-model.gguf';

  /// Checks if a model file is available on disk.
  static Future<String?> modelPath() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/$kModelFilename';
    if (await File(path).exists()) return path;
    return null;
  }

  /// Returns the path for a specific model id.
  static Future<String> pathFor(String modelId) async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/hearth-$modelId.gguf';
  }

  /// Returns which model ids have been downloaded.
  static Future<Set<String>> downloadedModels(
    Map<String, String> expectedHashes,
  ) async {
    final result = <String>{};
    for (final entry in expectedHashes.entries) {
      final id = entry.key;
      final path = await pathFor(id);
      final marker = File('$path.sha256');
      if (await File(path).exists() &&
          await marker.exists() &&
          (await marker.readAsString()).trim() == entry.value) {
        result.add(id);
      }
    }
    return result;
  }

  /// Creates a bot if a valid model file is present. Returns null if no model.
  static Future<InferenceBot?> tryCreate({
    String? modelId,
    String? expectedSha256,
  }) async {
    try {
      String? path;
      if (modelId != null) {
        path = await pathFor(modelId);
        if (!await File(path).exists()) path = null;
        if (path != null && expectedSha256 != null) {
          final marker = File('$path.sha256');
          if (!await marker.exists() ||
              (await marker.readAsString()).trim() != expectedSha256) {
            path = null;
          } else if ((await sha256.bind(File(path).openRead()).first)
                  .toString() !=
              expectedSha256) {
            HearthDiagnostics.log('ai model checksum verification failed');
            path = null;
          }
        }
      }
      // Do not replace a missing/corrupt selected model with an unrelated file.
      if (modelId == null) path ??= await modelPath();
      if (path == null) return null;
      final file = File(path);
      final size = await file.length();
      if (size < 1024 * 1024) {
        return null; // < 1MB is definitely not a valid model
      }
      final raf = await file.open();
      late final List<int> magic;
      try {
        magic = await raf.read(4);
      } finally {
        await raf.close();
      }
      // GGUF magic: 0x47 0x47 0x55 0x46 ("GGUF")
      if (magic.length < 4 ||
          magic[0] != 0x47 ||
          magic[1] != 0x47 ||
          magic[2] != 0x55 ||
          magic[3] != 0x46) {
        return null;
      }
      return InferenceBot._(path);
    } catch (_) {
      HearthDiagnostics.log('ai model verification could not read the file');
      return null;
    }
  }

  /// Runs inference on [prompt] and returns the response text.
  /// Returns null if busy; failures are surfaced to the caller for diagnostics.
  Future<String?> generate(String prompt, {int maxTokens = 256}) async {
    return _job.generate(_modelPath, prompt, maxTokens: maxTokens);
  }
}
