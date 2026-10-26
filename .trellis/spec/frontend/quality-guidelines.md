# Quality Guidelines

> Code quality standards for frontend development.

---

## Overview

<!--
Document your project's quality standards here.

Questions to answer:
- What patterns are forbidden?
- What linting rules do you enforce?
- What are your testing requirements?
- What code review standards apply?
-->

Flutter changes must pass static analysis, unit tests, and the relevant platform build before being considered complete.

---

## Forbidden Patterns

<!-- Patterns that should never be used and why -->

Do not let raw OCR output update inventory directly. OCR and PP-Structure output must become an editable draft first; only a user-confirmed inbound receipt can write stock ledger rows.

Do not run OCR on outbound proof photos. Outbound orders are generated from the stock-total cart and confirmed quantities; photos are local evidence attachments displayed in history only.

Do not put SQLite statements, MethodChannel payload parsing, or OCR table cleanup inside Flutter widgets.

---

## Required Patterns

<!-- Patterns that must always be used -->

Run these commands from `mobile_app/` after code changes:

```bash
dart format lib test
flutter analyze
flutter test
```

For release validation, also run the platform build being changed:

```bash
flutter build apk --release
flutter build ios --release --no-codesign
```

---

## Testing Requirements

<!-- What level of testing is expected -->

Core inventory rules and OCR post-processing need unit coverage. At minimum, tests must cover duplicate tracking-number rejection, negative-stock rejection, settlement marker behavior, and PP-Structure row cleanup.

---

## Code Review Checklist

<!-- What reviewers should check -->

Check that UI state survives app restart through SQLite, native bridge failures surface as recoverable UI states, and release artifacts are not described as production-ready unless signing, icons, and launch assets are configured.

---

## Scenario: Native Offline OCR Bridge

### 1. Scope / Trigger

Use this contract when changing Flutter-to-native OCR, bundled OCR assets, PP-OCRv5 LiteRT/Paddle Lite/OpenCV integration, or product-list table post-processing.

### 2. Signatures

Flutter method channel: `inventory_app/paddle_ocr`.

Request: `recognizeTable` with `{"imagePath": "<absolute local image path>", "rowMergeTolerance": <double 0.20..0.60>}`. `rowMergeTolerance` controls native row grouping strictness; lower values make Android less likely to merge vertically adjacent product rows. Default is `0.30`.

Response: `{"rows": List<List<String>>, "rawText": String}` where each inner list is an editable draft row/cell sequence, not confirmed inventory. `rawText` is the native recognizer's full text output when available and may be empty; Flutter should show it in the editable OCR review box before or alongside any parsed product draft.

### 3. Contracts

Android owns bundled PP-OCRv5 LiteRT/TFLite OCR through `android/app/src/main/cpp`, `android/app/src/main/assets/models`, and the arm64 LiteRT runtime under `litert_cc_sdk`. iOS currently owns the local CocoaPods pod `ios/LocalPods/InventoryPaddleOcr`, including Paddle Lite, OpenCV, and `InventoryPaddleOcrResources.bundle`.

Native code may perform text recognition and row/cell grouping, returning editable draft rows and the raw recognizer text through the method channel. Dart remains responsible for custom product-row cleanup in `mobile_app/lib/src/ocr/pp_structure_post_processor.dart`, and SQLite remains responsible for confirmed stock writes. Android row grouping must consume the caller-provided `rowMergeTolerance` instead of hard-coding a single line-spacing threshold.

Product-list cleanup must treat each line that starts with a product code as a new editable draft item. If the line has no standalone quantity cell, default the draft quantity to `1` instead of merging the line into the previous product. OCR-recognized `订单号` text may prefill the inbound `商家单号` field only when the user has not already typed a value there.

OCR-recognized `订单号` is displayed as optional `商家单号`, not as the required inbound `快递单号`. Inbound `返利单号` and outbound `物流单号` are optional metadata fields; UI may show and search them, but confirmation must remain valid when they are empty.

Android must not load or package app-local Paddle Lite or OpenCV for OCR. Xiaomi Android 16 devices showed a non-catchable native crash in `CreatePaddlePredictor`; Android OCR should use the PP-OCRv5 LiteRT/TFLite path and keep the editable manual path when recognition returns no rows.

When Android OCR is implemented with PP-OCRv5 LiteRT, do not keep stale Paddle OCR `.nb` model assets, PaddleLite folders, or OpenCV folders in the Android app module. Verify the release APK has `ocr_det_fp16.tflite`, `ocr_rec_fp16.tflite`, `keys_v5.txt`, `libLiteRt.so`, `libLiteRtOpenClAccelerator.so`, and arm64 `libinventory_ocr.so`, with no `libpaddle_light_api_shared.so`, `PP-OCRv5_mobile`, or `SLANet` entries.

The real Android OCR runtime is arm64-only. Inspect the final APK native library directories: Flutter can seed build-type ABI filters that override `defaultConfig` filters, so an arm64 release must explicitly clear/select the release build-type filters; `--target-platform android-arm64` alone can leave other dependency ABIs packaged. If Flutter/Gradle still configures `armeabi-v7a` or `x86_64`, those ABIs may compile a no-op JNI stub so the APK builds, but only `arm64-v8a` devices should be treated as OCR-capable.

When adding source files to the iOS local pod, rerun `pod install` from `mobile_app/ios`; otherwise Xcode may compile stale pod project files and fail at link time with missing C++ symbols.

### 4. Validation & Error Matrix

* Missing or unreadable `imagePath` -> return empty rows or a recoverable platform error; do not write stock.
* Missing OCR model/resource files -> return empty rows or a recoverable platform error; do not write stock.
* Missing or out-of-range `rowMergeTolerance` -> clamp to the supported range and continue OCR.
* OCR succeeds but rows are empty -> return `rawText` if available, keep the receipt editable for manual entry, and do not block inbound when a valid SF tracking number exists.
* PP-OCRv5 returns text boxes without table structure -> native code must group tokens into rows/cells; do not fail the whole receipt if text exists.
* Native OCR returns `rawText` but product cleanup finds no rows -> Flutter must put `rawText` into the editable text field and let the user correct it manually.
* Android Paddle Lite crashes in `libpaddle_light_api_shared.so` on a device family -> do not reintroduce Android Paddle OCR; use PP-OCRv5 LiteRT/TFLite and return empty rows while keeping manual editable input if recognition still fails.
* OCR rows parse into invalid quantities -> keep the draft editable and require user correction.

### 5. Good/Base/Bad Cases

* Good: camera image -> native PP-OCRv5 LiteRT text rows/cells -> Dart post-processing -> editable inbound draft -> user confirmation writes ledger.
* Base: PP-OCRv5 has no explicit table structure but text exists -> native row/cell grouping fallback -> editable draft.
* Base: native OCR text exists but product-row parsing fails -> editable text box contains raw OCR text and the user can press "生成商品草稿" after correction.
* Base: OCR returns no rows, user manually enters product rows, then confirms inbound normally.
* Bad: native OCR output directly inserts `inbound_items`, `stock_ledger`, or `warehouse_stock`.

### 6. Tests Required

Run `dart format lib test`, `flutter analyze`, `flutter test`, and the platform build touched by the change. Post-processing tests must cover header/footer filtering, quantity extraction, and multiline product names. MethodChannel tests must assert `rawText` is preserved for editable review and falls back to joined rows when absent. Native bridge changes require at least a release build for the changed platform.

### 7. Wrong vs Correct

Wrong: upgrading Android NDK/CMake because a plugin recommends it without verifying LiteRT native links and APK contents.

Correct: keep the pinned NDK/CMake until `flutter build apk --release` proves `libinventory_ocr.so` links with LiteRT and the APK contains the expected arm64 runtime libraries.

Wrong: leaving Android Paddle OCR `.nb` assets, PaddleLite SDK, or OpenCV SDK packaged after switching to PP-OCRv5 LiteRT.

Correct: remove Android Paddle OCR native build/resources and verify the release APK contains LiteRT OCR assets but no Paddle/OpenCV OCR artifacts.

Wrong: adding PP-Structure/SLANet output parsing inside a Flutter widget.

Correct: keep native payload parsing under `src/platform` and product cleanup under `src/ocr`, then show only editable draft rows in UI.

Wrong: only returning grouped `rows` from native OCR, so users see an empty text box when grouping or product parsing fails.

Correct: return `rawText` plus grouped `rows`, show `rawText` in the editable OCR review field, and treat parsed product rows as a convenience draft only.

## Scenario: Continuous Express Camera and Trustworthy Capture Feedback

### 1. Scope / Trigger

Applies to Android express receiving, project-owned CameraX preview/capture, image processing and durable pending-receipt jobs. Keep ordinary receiving and existing stock/OCR business semantics compatible; do not widen this camera work into an inventory workflow change.

### 2. Signatures

Platform view: `inventory_app/express_camera`; per-view method channel: `inventory_app/express_camera/<viewId>`. Creation parameters include an absolute app-private `outputDirectory` and `torchEnabled: bool`. Commands are `capture`, `reset`, `setTorch`, `focus`, `pause`, `resume`, and `dispose`. `capture` binds an immutable `captureId`, locked `trackingNumber`, and normalized preview `crop` (`left`, `top`, `right`, `bottom`).

Events: `onReady`, `onTracking`, `onCaptured`, `onError`. `onCaptured` carries `captureId`, `trackingNumber`, durable JPEG `imagePath`, `shutterToSavedMs`, and normalized saved-image crop. Attach the Dart event handler before requesting `resume` so an initial ready event cannot be missed.

Durable job key: `app_settings.key = express_image_job:<receiptId>`, with JSON `receiptId`, `imagePath`, `token`, `crop`. `LocalInventoryDatabase.confirmInbound(..., expressCrop: CaptureCrop?, expressToken: String?)` inserts the receipt and job in one transaction. `nextExpressImageJob()` reconciles restored paths; `isExpressImageJobCurrent(job)` checks receipt status, source and exact encoded generation. `updateInboundOcrResult(..., expectedImagePath:, processedImagePath:, expectedExpressJobValue:)` guards late writes. `retryExpressImageJob(receiptId)` uses the live receipt source and a fresh token, including recovery from malformed metadata.

### 3. Contracts

- Keep one CameraX session for preview, barcode analysis and formal JPEG capture. Do not use a barcode analysis/preview frame as the inventory evidence photo. Stop barcode submissions while a tracking number is locked, without rebuilding the camera per receipt.
- A shutter press means a capture request, not completion. Success flash, success vibration and “可以移开” require the saved-photo event. Do not describe the file-save callback as an exact sensor exposure callback. “已录入” additionally requires the SQLite receipt commit.
- Show the complete locked tracking number in a fixed top region throughout capture and receipt saving; wrap long values. UI header, capture event and stored receipt must use the same immutable capture identity. Ignore stale/mismatched callbacks and reject duplicate shutter submissions.
- Use the actual bound preview ViewPort/transform, current rotation and dimensions for crop mapping. If mapping cannot be validated, preserve the full photo rather than guessing a destructive crop. Match output encoding and extension; decode once and process off the UI isolate.
- Close and durably save a photo before committing its pending receipt and allowing the next scan. Run crop/OCR with bounded workers and durable pending metadata; do not make full-history refresh part of each capture's critical path. A background result may commit only if the receipt, source reference and job generation are still current.
- Replace image references only after the new file is completely saved. Delete only unreferenced files; preserve the original on failure. Recovery after restart/backup restore must resolve the receipt's current local image path, not an absolute path from another device.
- Release and rebind camera resources on lifecycle events using actual completion signals, not fixed sleeps. Performance logs contain stage durations, not full tracking numbers, OCR text or image contents.

### 4. Validation & Error Matrix

- Permission denied/session binding failure -> recoverable error and explicit retry; no successful capture or automatic permission-request loop.
- Capture/save failure -> keep the current tracking context retryable; no success event and no successful receipt claim.
- Saved photo followed by receipt commit failure -> preserve retry context or safely remove an unreferenced file; do not unlock into a mismatched next receipt.
- Stale native callback or background job after cancel/delete/manual replacement -> ignore it; do not overwrite current data.
- Crop transform unavailable -> full-frame preservation. Processing/OCR failure -> keep accessible evidence and retryable state.
- Background/rotation/resize -> invalidate old geometry and in-flight callbacks as appropriate; no permanently locked scanner or crop based on stale preview geometry.

### 5. Good/Base/Bad Cases

Good: lock tracking -> formal still capture -> durable photo success signal -> pending receipt commit -> next scan, while crop/OCR proceeds in a bounded background pipeline.

Base: unsupported CameraX stream combination -> surface a recoverable camera error and allow ordinary receiving; do not silently substitute a low-resolution frame.

Bad: flash white immediately on button press, then expose later; use fixed 500ms sleeps to guess camera release; process a PNG and retain a `.jpg` name; let an old job rewrite a user-edited receipt.

### 6. Tests Required

Test delayed success, capture/save failure, duplicate/mismatched callbacks, cancellation and next-tracking replacement; verify no success before the saved event. Cover JPEG signature/dimensions, EXIF orientation, crop edges, bounded processing and restart/stale-job behavior. Native changes require an Android build. Same-device release comparisons and immediate movement after the real success signal must be recorded separately from unit tests; no connected device means physical latency and blur acceptance remain pending.

### 7. Wrong vs Correct

Wrong: `onTap -> success flash -> await takePicture -> decode twice -> PNG overwrite -> sleep -> reopen scanner`.

Correct: `onTap -> capturing -> saved-photo callback -> trustworthy completion feedback -> durable receipt -> next scan`, with one camera session and deferred, guarded image processing.
