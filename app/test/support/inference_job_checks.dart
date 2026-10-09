// SPDX-License-Identifier: AGPL-3.0-or-later
// Pure Dart checks: safe to run outside the Flutter package/native hooks.
// ignore_for_file: avoid_relative_lib_imports
import 'dart:async';

import '../../lib/inference_job.dart';

Future<int> checkInferenceJob() async {
  var checks = 0;
  void check(bool value, String label) {
    checks++;
    if (!value) throw StateError(label);
  }

  Future<void> rejects(Future<Object?> future, Type type) async {
    Object? caught;
    try {
      await future;
    } catch (error) {
      caught = error;
    }
    check(caught?.runtimeType == type, 'expected $type, got $caught');
  }

  final callbacks = <InferenceOutput>[];
  final cancelled = <int>[];
  final events = <String>[];
  final job = InferenceJob(
    start: (_, _, _, output) async {
      callbacks.add(output);
      return callbacks.length;
    },
    cancel: cancelled.add,
    onEvent: events.add,
  );
  final first = job.generate('model', 'private prompt');
  var completed = false;
  unawaited(first.then((_) => completed = true));
  await Future<void>.delayed(Duration.zero);
  check(job.busy && !completed, 'queue admission is not completion');
  check(
    await job.generate('other model', 'hi') == null,
    'reserve engine across model selections',
  );
  callbacks.first('private answer', '{}', false);
  await Future<void>.delayed(Duration.zero);
  check(job.busy && !completed, 'partial output does not release engine');
  callbacks.first('private answer', '{}', true);
  check(
    await first == 'private answer' && !job.busy,
    'final callback returns answer',
  );
  check(
    !events.join().contains('private'),
    'diagnostics exclude prompt and response',
  );

  final second = job.generate('model', 'second');
  callbacks.first('duplicate', '{}', true);
  check(job.busy, 'old callbacks cannot release next job');
  callbacks.last('second answer', '{}', true);
  check(
    await second == 'second answer',
    'old callbacks cannot overwrite answer',
  );

  final delayedQueue = Completer<int>();
  late InferenceOutput timeoutOutput;
  final timeoutJob = InferenceJob(
    start: (_, _, _, output) {
      timeoutOutput = output;
      return delayedQueue.future;
    },
    cancel: cancelled.add,
    timeout: const Duration(milliseconds: 5),
  );
  await rejects(timeoutJob.generate('model', 'hi'), TimeoutException);
  check(timeoutJob.busy, 'timeout retains lock until native completion');
  check(
    await timeoutJob.generate('model', 'hi') == null,
    'no native overlap after timeout',
  );
  delayedQueue.complete(77);
  await Future<void>.delayed(Duration.zero);
  check(
    cancelled.where((id) => id == 77).length == 1,
    'late queue admission is cancelled once',
  );
  timeoutOutput('', '', true);
  check(!timeoutJob.busy, 'cancel completion releases lock');

  final failedJob = InferenceJob(
    start: (_, _, _, _) => Future<int>.error(StateError('queue failed')),
    cancel: (_) {},
  );
  await rejects(failedJob.generate('model', 'hi'), StateError);
  check(!failedJob.busy, 'queue failure releases lock');

  final backendError = job.generate('model', 'hi');
  callbacks.last('Error: Failed to create inference context', '', true);
  await rejects(backendError, StateError);
  check(!job.busy, 'backend error is not a chat answer');

  final bounded = job.generate('model', 'hi');
  await Future<void>.delayed(Duration.zero);
  callbacks.last('x' * 16001, '{}', false);
  callbacks.last('x' * 16001, '{}', false);
  check(job.busy, 'oversized output waits for native cancellation');
  check(
    cancelled.where((id) => id == callbacks.length).length == 1,
    'oversized output cancels once',
  );
  callbacks.last('', '', true);
  await rejects(bounded, StateError);

  final cancelledResult = job.generate('model', 'hi');
  job.cancelCurrent();
  await Future<void>.delayed(Duration.zero);
  callbacks.last('partial after cancel', '{}', true);
  await rejects(cancelledResult, StateError);
  check(!job.busy, 'explicit cancellation never publishes partial answer');

  await rejects(job.generate('model', ''), ArgumentError);
  await rejects(job.generate('model', 'x' * 1537), ArgumentError);
  await rejects(
    job.generate('model', String.fromCharCode(0x20ac) * 513),
    ArgumentError,
  );
  await rejects(job.generate('model', 'hi', maxTokens: 0), ArgumentError);
  await rejects(job.generate('model', 'hi', maxTokens: 257), ArgumentError);
  check(InferenceJob.validPrompt('x' * 1536), 'ASCII boundary is accepted');
  check(
    InferenceJob.validPrompt(String.fromCharCode(0x20ac) * 512),
    'UTF-8 boundary is accepted',
  );
  check(!job.busy, 'invalid requests never acquire native engine');
  return checks;
}
