# Implementation Plan

## Gate

Task remains planning until the user approves the final summary of these artifacts. Camera task remains independently open for physical validation. No product OCR code changes during planning.

## Ordered Steps

1. Inspect both actual ONNX graphs, dynamic axes, operators and dictionary config; pin asset hashes and source retrieval metadata. Build reference inference and controlled text/quantity/geometry fixtures.
2. Pin a released ONNX Runtime compatible with the model; convert/optimize to ORT and generate required ops/types config. Build ARM64 reduced runtime with exceptions; record reproducible commands and inspect size/link dependencies. No SDK/NDK upgrades without concrete build need.
3. Implement the model-specific C++/JNI preprocessing, detector postprocessing, geometry/line resize and CTC decoder using own lightweight utilities; remove LiteRT loading/flags/runtime packaging from actual Android build. Keep source license notices.
4. Adapt Kotlin wrapper and OcrService for new models, schema/config checks, row grouping and burst session reuse/idle cleanup. Surface recoverable errors, not stack traces as OCR text. Preserve Dart bridge and job/stock behavior.
5. Add actual-model reference and native fixtures plus Flutter bridge/error regressions. Run existing40-test baseline; cover dynamic long lines, Chinese/numbers, thresholds, damaged input, consecutive requests, idle cleanup and timeouts.
6. Dispatch Trellis check review of whole data flow/ownership and actual shipped model/engine; resolve in-scope findings. Update executable mobile spec and source/model/runtime provenance.
7. Increment version (next available after1.0.5+7), run formatting/analyzer/tests and ARM64 release build; inspect APK for onlyv6/newengine assets and verify signature/version. Archive releases/app-v<version>.apk and exact SHA256.
8. When a phone is connected, compare same sample set cold/warm latency/P95, PSS/peak memory, throughput and name/quantity accuracy. Without a device record explicit pending acceptance, never infer phone speed from desktop CPU.
9. Commit only task files automatically per repository rules, record journal. Do not archive as accepted until required actual-model and device evidence is satisfied; keep unrelated Trellis modifications untouched.

## Checks and Rollback

Commands: dart format touched Dart files; flutter analyze --no-pub (baseline28 pre-existing issues); flutter test --no-pub (baseline40); required native fixture/reference tests; flutter build apk --release --no-pub --target-platform android-arm64. Existing release1.0.5+7 is rollback artifact, no database changes planned.

## Execution Status

Implementation, independent review, automated checks, conversion/production-core proof and ARM64 release archive are complete.41 Flutter tests,3 Kotlin tests and5 actual-model host fixtures pass; analysis retains28 pre-existing issues. APK1.0.6+8 was inspected and signature verified. Device performance and real-receipt acceptance remain pending, so keep the task in_progress. See research/validation-results.md.
