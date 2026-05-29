# Technical Design Notes

The user confirmed execution with “开始执行”.

Primary plan: `plans/移动扫码入库库存架构_20260515.md`
Research: `research/scanning-ocr-options.md`

## Implementation Notes

* Flutter source scaffold: `mobile_app/`
* Core rules implemented in Dart:
  * Inventory ledger service with inbound/outbound history and settlement markers
  * Negative-stock protection for outbound operations
  * PaddleOCR + PP-Structure post-processing pipeline for table rows
  * Flutter `MethodChannel` contract for PaddleOCR/PP-Structure native bridge
  * Camera barcode scanning through `mobile_scanner`
* Local SQLite persistence is wired into the Flutter UI through `LocalInventoryDatabase`.
* Android no longer loads or packages Paddle Lite native libraries because Xiaomi Android 16 reported a non-catchable crash inside `libpaddle_light_api_shared.so` during `CreatePaddlePredictor`. Android `recognizeTable` now returns empty OCR rows and keeps the inbound draft manually editable.
* iOS native OCR now links Paddle Lite + OpenCV through a local CocoaPods pod (`InventoryPaddleOcr`) and runs the same PP-OCRv5 det/cls/rec plus PP-Structure SLANet pipeline from bundled resources.
* The Flutter UI now uses four bottom tabs: scan inbound, inbound history, stock totals, and outbound query.
* iOS table support predicts SLANet table cells, assigns OCR text boxes into cells, reconstructs tab-separated rows from table structure tokens, and falls back to OCR text-box row grouping when SLANet has no usable cells.

## Verification And Build Notes

* Flutter SDK installed at `/Users/xcy/Development/flutter`.
* CocoaPods installed through Homebrew, version `1.16.2`.
* `dart format lib test`: passed, 0 files changed after final run.
* `flutter analyze`: passed, no issues.
* `flutter test`: passed, 5 tests.
* `flutter build apk --release`: passed, produced Android APK without Paddle Lite native libraries for crash avoidance.
* `flutter build ios --release --no-codesign`: passed, produced unsigned device `.app` with native PaddleOCR + PP-Structure SLANet.
* `flutter build ipa --release --no-codesign`: produced `Runner.xcarchive`; IPA export was skipped because code signing is disabled.
* Android build intentionally avoids the app-local Paddle Lite CMake build after Xiaomi Android 16 crashed during Paddle predictor initialization.

## Build Artifacts

* Android APK: `mobile_app/build/releases/inventory_mobile_app-android-release.apk`
  * SHA256: `7c4d8826940de42d3aabc39a6835297b8b930442589a4eb2f50a00ce26269c32`
* iOS unsigned app zip: `mobile_app/build/releases/inventory_mobile_app-ios-release-unsigned.zip`
  * SHA256: `ab6d378008d3cef98d739eda1a52eb1a90b4565d1a94ce31c24b3c65ad8db50b`
* iOS unsigned archive: `mobile_app/build/releases/inventory_mobile_app-ios-release-unsigned.xcarchive.zip`
  * SHA256: `7d9ddebe769c3d15cbdb02bd242dcb9fe7892655901e2ecbc641ff233d376606`
