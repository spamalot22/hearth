// SPDX-License-Identifier: AGPL-3.0-or-later
// Uses fllama (GPL-2.0, github.com/Telosnex/fllama) for llama.cpp FFI bindings.
import 'dart:async';
import 'dart:io';

import 'package:fllama/fllama.dart';
import 'package:path_provider/path_provider.dart';

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
  bool _busy = false;

  /// Whether the bot is currently processing a request.
  bool get busy => _busy;

  /// The default model filename (placed in app documents dir).
  static const String kModelFilename = 'hearth-model.gguf';

  /// Checks if a model file is available on disk.
  static Future<String?> modelPath() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/$kModelFilename';
    if (await File(path).exists()) return path;
    return null;
  }

  /// Creates a bot if a valid model file is present. Returns null if no model.
  static Future<InferenceBot?> tryCreate() async {
    final path = await modelPath();
    if (path == null) return null;
    // Validate GGUF magic bytes before loading (prevents native crash on corrupt files).
    try {
      final file = File(path);
      final size = await file.length();
      if (size < 1024 * 1024) return null; // < 1MB is definitely not a valid model
      final raf = await file.open();
      final magic = await raf.read(4);
      await raf.close();
      // GGUF magic: 0x47 0x47 0x55 0x46 ("GGUF")
      if (magic.length < 4 ||
          magic[0] != 0x47 ||
          magic[1] != 0x47 ||
          magic[2] != 0x55 ||
          magic[3] != 0x46) {
        return null;
      }
    } catch (_) {
      return null;
    }
    return InferenceBot._(path);
  }

  /// Runs inference on [prompt] and returns the response text.
  /// Returns null if busy or if inference fails.
  Future<String?> generate(String prompt, {int maxTokens = 256}) async {
    if (_busy) return null;
    _busy = true;
    try {
      // Reduce context size for large models to avoid OOM.
      final fileSize = await File(_modelPath).length();
      final ctx = fileSize > 4 * 1024 * 1024 * 1024 ? 1024 : 2048;
      final completer = Completer<String>();
      String result = '';
      unawaited(fllamaChat(
        OpenAiRequest(
          maxTokens: maxTokens,
          messages: [
            Message(Role.system, 'You are a helpful assistant in a group chat called Hearth. Keep responses concise.'),
            Message(Role.user, prompt),
          ],
          numGpuLayers: 99,
          modelPath: _modelPath,
          frequencyPenalty: 0.0,
          presencePenalty: 1.1,
          topP: 1.0,
          contextSize: ctx,
        ),
        (String partial, String jsonStr, bool done) {
          result = partial;
          if (done) completer.complete(result);
        },
      ));
      return await completer.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () => '',
      );
    } catch (_) {
      return null;
    } finally {
      _busy = false;
    }
  }
}
