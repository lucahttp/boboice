/// Simple abort signal for cancellation.
class AbortSignal {
  bool _aborted = false;

  void abort() {
    _aborted = true;
  }

  bool get isAborted => _aborted;
}