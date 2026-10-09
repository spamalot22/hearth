// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

typedef InferenceOutput = void Function(String text, String json, bool done);
typedef InferenceStart =
    Future<int> Function(
      String modelPath,
      String prompt,
      int maxTokens,
      InferenceOutput output,
    );

/// fllama's start future returns a queue id, not an inference result. Only the
/// final callback permits another job, including after timeout/cancellation.
class InferenceJob {
  InferenceJob({
    required this.start,
    required this.cancel,
    this.timeout = const Duration(seconds: 120),
    this.onEvent,
  });

  final InferenceStart start;
  final FutureOr<void> Function(int) cancel;
  final Duration timeout;
  final void Function(String)? onEvent;
  _RunningInference? _active;

  // With one native slot, reserve room in the 2048-token context for the system
  // template and up to 256 output tokens even for byte-fallback tokenizers.
  static const maxPromptBytes = 1536;
  static const maxResponseCharacters = 16000;
  bool get busy => _active != null;

  static bool validPrompt(String prompt) =>
      prompt.trim().isNotEmpty &&
      prompt.length <= maxPromptBytes &&
      utf8.encode(prompt).length <= maxPromptBytes;

  Future<String?> generate(
    String modelPath,
    String prompt, {
    int maxTokens = 256,
  }) async {
    if (!validPrompt(prompt)) {
      throw ArgumentError('AI prompt must be 1-$maxPromptBytes UTF-8 bytes');
    }
    if (maxTokens < 1 || maxTokens > 256) {
      throw ArgumentError('AI output limit must be 1-256 tokens');
    }
    if (busy) return null;
    final job = _RunningInference();
    _active = job;
    onEvent?.call('ai inference starting (cpu, single job)');
    void finish({String? result, Object? error, StackTrace? stack}) {
      if (!identical(_active, job)) return;
      _active = null;
      onEvent?.call(
        error == null ? 'ai inference finished' : 'ai inference failed',
      );
      if (job.result.isCompleted) return;
      if (error != null) {
        job.result.completeError(error, stack);
      } else {
        job.result.complete(result);
      }
    }

    // Attach the timeout/error consumer before starting: injected/native
    // implementations can finish synchronously or fail while being queued.
    final result = job.result.future.timeout(
      timeout,
      onTimeout: () {
        job.cancelRequested = true;
        _cancel(job);
        onEvent?.call('ai inference timed out; waiting for native shutdown');
        throw TimeoutException('AI inference timed out', timeout);
      },
    );
    unawaited(() async {
      try {
        job.id = await start(modelPath, prompt, maxTokens, (text, json, done) {
          if (!identical(_active, job)) return;
          if (text.length > maxResponseCharacters) {
            job.cancelRequested = true;
            job.error = StateError('AI response exceeded its size limit');
            _cancel(job);
          }
          if (!done) return;
          // Native load/template failures are delivered as text, not thrown.
          final error =
              job.error ??
              (json.isEmpty && text.startsWith('Error:')
                  ? StateError('AI engine failed to load or run the model')
                  : null);
          finish(result: text, error: error);
        });
        if (job.cancelRequested) _cancel(job);
        // Do NOT release the job here: this is only queue admission.
      } catch (error, stack) {
        finish(error: error, stack: stack);
      }
    }());
    return result;
  }

  void cancelCurrent() {
    final job = _active;
    if (job == null) return;
    job.cancelRequested = true;
    job.error = StateError('AI request cancelled');
    _cancel(job);
  }

  void _cancel(_RunningInference job) {
    if (!identical(_active, job)) return;
    final id = job.id;
    if (id == null || job.cancelSent) return;
    job.cancelSent = true;
    unawaited(
      Future<void>.sync(() => cancel(id)).catchError((Object _) {
        onEvent?.call('ai inference cancellation failed');
      }),
    );
  }
}

class _RunningInference {
  final result = Completer<String?>();
  int? id;
  bool cancelRequested = false;
  bool cancelSent = false;
  Object? error;
}
