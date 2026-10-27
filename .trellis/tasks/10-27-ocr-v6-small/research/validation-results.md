# Validation Results: PP-OCRv6_small

## Implementation and Independent Review

- Official FP32 small detector/recognizer optimized to ARM ORT format. Dictionary:18,709 lines plus CTC blank class, giving18,710 output classes. Manifest version4 records actual tensor signatures, sizes and hashes.
- Model-specific ARM64 CPU runtime:2,509,408 bytes. Native wrapper in final APK:74,560 bytes. Exceptions retained;16KB LOAD alignment; dependencies limited to system libraries and shared C++ runtime. Preparation and runtime build scripts were actually executed.
- Original ONNX versus ORT compared at five dynamic input shapes: maximum absolute output difference0.0. This is numerical conversion evidence, not document accuracy.
- Review fixes: refined row baseline using actual noisy5-degree boxes; added propagated deadlines and joined ORT termination watchdog; released detector output before line recognition; return a recoverable error above1,000 accepted boxes instead of partial success.
- No remaining in-scope production findings after review. Existing Dart quantity/default/filter heuristics remain unchanged; see postprocessing-audit.md.

## Automated Checks

- Independent reviewer: `flutter test --no-pub` —41 passed (40 baseline plus native-error propagation regression).
- Independent reviewer: `flutter analyze --no-pub` —28 pre-existing issues,1 warning,0 errors; no new issues. Analysis is not fully clean; no warning suppression added.
- Native: `./gradlew :app:compileDebugKotlin :app:testDebugUnitTest :app:externalNativeBuildDebug` —passed. Three JUnit grouping regressions include actual noisy v6 detections. Log:/tmp/ocr-v6-native-check-final.log.
- Production C++ core linked to host ORT:5/5 actual-model fixtures passed (clear, skewed, long line, blank, wired table). Tests assert exact SKU/name/quantity cells, not just digits found inside SKU strings.0/1/20ms cancellation followed by a normal request on the same Engine passed. Final core rerun passed after the overflow guard.
- Host peak RSS was approximately143–186 MB using the full host runtime. This is not Android PSS or a comparison against v5 on a phone. Synthetic fixtures are correctness evidence, not a representative real-receipt benchmark.
- C++/touched Dart formatting and git whitespace checks passed.
- Final ARM64 release build passed (full44.3s build, final incremental3.7s) using `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn flutter build apk --release --no-pub --target-platform android-arm64`.

## Artifact

- `releases/app-v1.0.6+8.apk`:60,622,440 bytes. Previous1.0.5+7:51,330,352 bytes; increase9,292,088 bytes.
- SHA256:`5c55816c06192eeda802b72fc98471cf82b06de592604875fa30a3e09e18d675`.
- Packaged model hashes match manifest. v6 models/dictionary/licenses and libonnxruntime/libinventory_ocr are present. Old v5 TFLite/keys, LiteRT/OpenCL, PaddleLite/OpenCV/SLANet are absent. Native ABI is arm64-v8a only.
- Manifest:versionName1.0.6, versionCode8, minSdk28. ZIP alignment and16KB native page alignment passed. APK signature verification passed, with the same Android Debug certificate as1.0.5+7. Existing debug signing is not production signing.
- Detailed inspection:apk-inspection.json. Model/runtime source pins, hashes and licenses are checked in.

## Pending Acceptance and Limits

- `adb devices -l` is empty. Android cold/warm/P95 latency, peak PSS, real-receipt accuracy, capture interference and low-light behavior remain **pending**. Keep task in_progress; do not claim fastest inference or lowest phone RAM.
- Normalized line widths over3,200 and more than1,000 accepted boxes return recoverable errors instead of truncated success.
- No separate table-structure model is packaged. User confirmed regular SKU/name/quantity columns without merged cells. Native row geometry is tested; field heuristics need real receipt comparison before simplification. SLANet_plus is a possible separate extension, outside this approved engine replacement.

Dictionary whitespace note: the final line is a required ordinary-space class, not a formatting defect. A model-directory .gitattributes entry preserves exact bytes and exempts only this dictionary data from end-of-line/end-of-file whitespace checks. Model hashes remain unchanged.
