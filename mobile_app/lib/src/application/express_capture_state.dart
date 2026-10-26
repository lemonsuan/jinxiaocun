import '../platform/express_camera_channel.dart';

enum ExpressCapturePhase {
  initializing,
  scanning,
  locked,
  capturing,
  saving,
  saved,
  error
}

/// Immutable capture identity survives async hardware callbacks and retries.
class ExpressCaptureState {
  ExpressCapturePhase phase = ExpressCapturePhase.initializing;
  String? trackingNumber;
  String? captureId;
  SavedExpressCapture? savedCapture;
  bool get busy =>
      phase == ExpressCapturePhase.capturing ||
      phase == ExpressCapturePhase.saving;
  void ready() {
    if (trackingNumber == null) phase = ExpressCapturePhase.scanning;
  }

  bool lock(String tracking) {
    if (phase != ExpressCapturePhase.scanning) return false;
    trackingNumber = tracking;
    phase = ExpressCapturePhase.locked;
    return true;
  }

  bool begin(String id) {
    if (phase != ExpressCapturePhase.locked &&
        phase != ExpressCapturePhase.error) {
      return false;
    }
    if (trackingNumber == null || savedCapture != null) return false;
    captureId = id;
    phase = ExpressCapturePhase.capturing;
    return true;
  }

  bool accept(SavedExpressCapture capture) {
    if (phase != ExpressCapturePhase.capturing ||
        capture.captureId != captureId ||
        capture.trackingNumber != trackingNumber) {
      return false;
    }
    savedCapture = capture;
    phase = ExpressCapturePhase.saving;
    return true;
  }

  void failed() {
    phase = ExpressCapturePhase.error;
  }

  void committed() {
    phase = ExpressCapturePhase.saved;
  }

  void reset() {
    if (busy) return;
    trackingNumber = null;
    captureId = null;
    savedCapture = null;
    phase = ExpressCapturePhase.scanning;
  }
}
