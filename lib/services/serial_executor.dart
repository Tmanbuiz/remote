import 'dart:async';

/// One ordered queue for selection, pairing and commands. An error never poisons
/// the next operation. Callers must not recursively enqueue from inside a job.
class SerialExecutor {
  Future<void> _tail = Future.value();
  Future<T> run<T>(Future<T> Function() job) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await job());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }
}
