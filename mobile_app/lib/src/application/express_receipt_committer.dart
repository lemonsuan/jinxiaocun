/// Camera unlock failures cannot turn retries into duplicate receipt inserts.
/// Concurrent taps share the same in-flight persistence operation.
class ExpressReceiptCommitter {
  String? _savedCaptureId;
  String? _savingCaptureId;
  Future<void>? _saving;
  bool isSaved(String captureId) => _savedCaptureId == captureId;
  Future<void> saveOnce(String captureId, Future<void> Function() save) {
    if (isSaved(captureId)) return Future.value();
    if (_saving != null) {
      if (_savingCaptureId == captureId) return _saving!;
      return Future.error(StateError('Previous capture is still saving'));
    }
    _savingCaptureId = captureId;
    return _saving = Future.sync(save).then((_) {
      _savedCaptureId = captureId;
    }).whenComplete(() {
      _saving = null;
      _savingCaptureId = null;
    });
  }
}
