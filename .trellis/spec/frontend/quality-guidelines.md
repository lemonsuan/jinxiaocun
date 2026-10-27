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

Applies to Android OCR, bundled model/runtime assets, the Flutter native bridge and product-list postprocessing. The active Android implementation is **PP-OCRv6_small with a reduced ARM64 CPU ONNX Runtime 1.21.1**. The earlier PP-OCRv5 LiteRT implementation is a historical rollback version, not the current packaged engine. No complete iOS project exists in this checkout; do not claim iOS verification.

### 2. Signatures

Channel: `inventory_app/paddle_ocr`; method `recognizeTable`; request `{"imagePath":"<absolute local path>","rowMergeTolerance":0.30}`. Tolerance is clamped to0.20..0.60, default0.30. Response remains `{"rows":List<List<String>>,"rawText":String}`; a failure is a recoverable PlatformException, never an exception stack trace returned as OCR text.

### 3. Contracts

- Assets: `ppocrv6_small_det.ort`, `ppocrv6_small_rec.ort`, `keys_v6_small.txt`, and versioned `models/manifest.json` with actual size/SHA256. Model files are official FP32 small models optimized offline for ARM using ORT1.21.1; do not relabel v5 or silently substitute tiny/quantized weights.
- Detector input is BGR FP32 NCHW `[1,3,H,W]`, bounded maxside960, dimensions aligned32, normalization scale1/255, mean[0.485,0.456,0.406], std[0.229,0.224,0.225]. DB defaults come from the actual model config: pixel0.2, box0.45, expansion1.4. Detection returns boxes in source-image coordinates.
- Recognizer input is BGR FP32 NCHW `[1,3,48,W]`, batch1 and dynamic width up to3200. Output is softmax `[1,T,18710]`. Official18708characters plus a trailing ordinary space produce18709dictionary lines; blank is outputindex0 and dictionaryline i maps to class i+1. Never trim away the space or reuse v5 keys.
- Runtime: `cpp/onnxruntime/lib/arm64-v8a/libonnxruntime.so`, CPU-only basicminimal and reduced operator/types, exceptions retained,16KB LOADalignment. Preserve exact build manifest, license/notices, required-operator config and reproducible `tools/ocr` scripts. Do not disable exceptions/abort on recoverable errors, add a full GPU runtime, or reintroduce PaddleLite/OpenCV for this path.
- Kotlin owns row grouping with caller tolerance and deskewed source coordinates. A model recognizing each cell correctly is not sufficient: assert that SKU/name/quantity stay in the same row, including tilted documents. Native OCR is text/geometry, not a full table-structure model.
- OcrService has one CPU lane with2pending slots, reuses sessions within a burst and releases after10s idle. MainActivity's45s request deadline propagates as remaining time to core (max35s); per-request ORT RunOptions and a joined watchdog terminate timed-out work. Check cancellation before preprocessing/detection/each line; late results deliver at most once.
- Core enforces bounded dimensions/boxes/line width; more than1000accepted boxes or normalized line width over3200 fails recoverably instead of silently returning a truncated receipt. Release detector output before per-line recognition.
- Keep SQL and product parsing out of widgets/native code. Dart owns `pp_structure_post_processor.dart`; SQLite owns confirmed stock writes. Product parsing still treats a new code-prefixed line as a new draft and defaults missing quantity to1 under the existing business contract. Any change to this heuristic needs its own sample-backed requirement.
- OCR `订单号` may prefill optional `商家单号` only if the field is empty; it is not the required快递单号. Optional inbound返利单号/outbound物流单号 must not block confirmation. Outbound proof photos are evidence only, not OCR inputs.
- Raw OCR remains editable review material. Do not expand the existing express workflow's legacy direct-stock behavior while replacing the engine; inventory workflow changes require separate scope.

### 4. Validation & Error Matrix

- Missing/unreadable/corrupt image or model, manifest/hash mismatch -> structured recoverable error, retained image/manual path; no diagnostic text as a product.
- Valid image with no text -> empty rows/rawText; allow manual entry and the existing valid-SF empty-item path.
- Timeout/queue full -> OCR_TIMEOUT/OCR_BUSY or other structured platform error; cancelled native work must free the serial lane and allow the next request.
- Width/box bounds exceeded -> recoverable error; do not partially confirm a clipped list.
- Invalid tolerance -> clamp and continue. Recognized text with no product draft -> preserve rawText for editing.
- Pure text boxes without table structure -> deskew/group rows by source geometry and sort columns; do not invent merged-cell HTML or silently add another model.
- Model bytes/runtime linkage/class-count mismatch -> fail before recognition; do not fall back to a stale v5 cache.

### 5. Good / Base / Bad Cases

Good: image -> bounded v6det -> source-coordinate boxes -> dynamic-width v6rec -> correct CTC dictionary -> skew-aware row/cell grouping -> Dart editable fields -> existing confirmation workflow.

Base: text is readable but product cleanup fails -> editable rawText/manual corrections remain available. Forms may need separate structure extraction; PP-OCRv6 alone does not eliminate column matching or field validation.

Bad: using a v5 dictionary for v6; outputting an error stack as rawText; clipping long lines/large tables and reporting success; freeing an engine while Run is active; returning timeout but leaving Run to block the queue.

### 6. Tests Required

Run Flutter formatting/analyzer/tests and Kotlin/native checks, plus an ARM64 release build. Native fixture harness must link the **production** C++ core and execute the shipped ORT models on Chinese/English/numeric clear/skewed/long-line/wired-table/blank fixtures. Test0/1/20ms cancellation and subsequent same-engine recovery. Model preparation compares original ONNX and ORT outputs at multiple dynamic sizes. Kotlin grouping tests must include actual noisy v6 detections, not only ideal equal-angle boxes.

Inspect the final APK: only the selected v6models/keys and `libonnxruntime.so`/`libinventory_ocr.so` for OCR; no old v5TFLite/keys, LiteRT/OpenCL, PaddleLite/OpenCV or accidental extraABIs. Runtime source pin, artifact hashes and licenses must be available. Host correctness/timing/RSS is not Android latency/PSS; no connected phone means physical performance and receipt acceptance remain pending.

### 7. Wrong vs Correct

Wrong: blindly copy the official demo with full runtime/OpenCV, keep old LiteRT packaged, and assume a new model fixes all quantity rules.

Correct: keep the bridge stable, package a model-specific reduced runtime and matching dictionary, verify actual inference/row association, then separately evaluate business parsing on real receipts.

Wrong: hard-code640x640/320-wide v5 assumptions or report model storage as phone RAM.

Correct: derive layout/classes from verified v6 assets, bound dynamic processing explicitly, and attach real measurement scope to every resource claim.

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

## Online Shop Sync Verification

See [Shared Shop Sync](../backend/shop-incremental-sync.md) for the shared executable contract. Check Flutter `ShopSyncService` against real SQLite persistence and an injected HTTP client; test lost responses, scope changes, pause/drain before local resolution, and individual bad images not starving valid records. Default tests must not contact a real backend. Use opt-in `shop_sync_live_test.dart` only against a disposable server with randomly created test accounts/shops. Visible pending/conflict/media failures must never read as all-complete.

Register home timers/queue listeners only after initialization awaits confirm `mounted`; dispose the exact registered queue rather than creating one during disposal. Keep online deletion labels explicitly device-local. Web pictures must use authenticated blob requests and revoke them on scope change/unmount; never put tokens into URLs.
