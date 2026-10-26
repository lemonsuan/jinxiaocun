# Validation Results

## Baseline

- Previous chat audit: `flutter test --no-pub`: 22 tests passed.
- `flutter analyze --no-pub`: 33 issues, including 1 warning and no errors.
- Device discovery: `adb devices -l`: no device connected. Physical shutter delay, motion blur, autofocus and 20-receipt device acceptance remain pending.

## Native Implementation

- `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn ./gradlew :app:compileDebugKotlin`: passed (native worker, log `/tmp/express-native-compile.log`). Mirror used after Google storage TLS failure; no SDK/NDK upgrade.
- `git diff --check -- mobile_app/android`: passed.
- Installed camera_android_camerax resolves CameraX 1.6.0; explicit native dependencies match resolved version.

## Integrated Checks

- Independent reviewer: `flutter test --no-pub`: **40/40 passed** (22 baseline + 18 new, including 8 real SQLite persistence tests and navigation regression).
- Independent reviewer: `flutter analyze --no-pub`: **28 pre-existing issues, 1 warning, 0 errors**, no new issues versus baseline 33. Static analysis is not fully clean; remaining unrelated deprecated APIs/context/unused helper are recorded, not suppressed.
- Formatting and `git diff --check`: passed.
- Initial integrated `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn flutter build apk --release --no-pub`: passed, 103.2 MB; final build will be rerun after native review fixes and target arm64 only.
- Initial APK inspection: PP-OCRv5 detector/recognizer/keys, arm64 libLiteRt, OpenCL accelerator, libinventory_ocr and bundled barcode assets present; no old Paddle/SLANet assets.
- Existing runtime dependency lock versions retained. Only host-test dev dependencies sqflite_common_ffi 2.3.6 and sqlite3 2.9.4 were added; final lock keeps original pub.dev URLs. Mirror artifacts used locally due pub.dev TLS connectivity, then `flutter pub get --offline` passed.
- Final arm64 `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn flutter build apk --release --no-pub --target-platform android-arm64`: **passed**, 51.3 MB (30.5s final incremental Gradle build).
- APK inspection caught Flutter build-type defaults retaining extra dependency ABIs despite defaultConfig filters/target-platform; release build-type filters now explicitly clear defaults and select arm64-v8a. Final assertions passed: only arm64 native libraries, required PP-OCRv5 models/dictionary, LiteRT/OpenCL/inventory OCR and bundled barcode runtime; no old Paddle/SLANet assets.
- Archive: `releases/app-v1.0.5+7.apk`; bytes: 51330352; SHA256: `32ef385175c0c882eba964213e38fc15641e77019254313b4ad16aaf5d259455`.
- Native final permission-denial loop prevention and minimum negotiated 1280x720-equivalent stream checks compiled successfully; parent inspected final code after native owner freeze. No low-resolution analysis-frame fallback.
- Build uses the repository's existing debug signing configuration; it is not a production-signing setup.

## Known Physical/Operational Limits

- No connected Android device: same-device median/P95 shutter measurements, motion-after-completion readability, autofocus, low-light and 20-receipt stream compatibility are **not verified**. The task stays open for device acceptance.
- Unexpected process termination after native durable JPEG save but before pending-receipt SQLite commit retains the raw JPEG, but does not automatically recover the tracking context. Once the pending receipt commits, recovery is durable and covered by tests.
- CameraX unsupported stream combination or below-high negotiated resolution must surface a recoverable error; ordinary receiving remains available. No preview-frame substitute is permitted.

- Final APK signature verification passed; certificate SHA256 matches archived 1.0.4+6 (same Android Debug certificate), and manifest confirms versionName 1.0.5/versionCode 7, minSdk28.
