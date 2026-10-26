# Execution Plan

## Gate

- Task stays planning until the user explicitly approves the latest final planning summary.
- Implement/check use Trellis sub-agents with curated context; parent coordinates, handles spec updates, commits and wrap-up.

## Ordered Work

1. Record baseline timing hooks at scan lock, camera ready, shutter request, saved-photo callback, receipt committed and ready-for-next; exclude private image/text payloads from logs. Capture hardware baseline before removal of the old path if a device is available.
2. Implement project-owned Android continuous CameraX capture + barcode bridge and preview lifecycle, aligning existing dependencies. Add immutable capture IDs, state transitions, explicit release completion, failure recovery and trustworthy saved-photo feedback. Verify supported stream combination on device.
3. Integrate the express page with one continuous session; retain manual shutter, touch focus, crop guide and persisted torch behavior. Show the full locked tracking number in a fixed top area throughout capture/save, wrapping long values; test next-receipt and cancel/rescan replacement. Do not regress ordinary inbound camera callers.
4. Extract JPEG processing/storage into a service, implement bounded background crop/OCR scheduling with durable pending receipt recovery, guarded stale-task updates and safe file replacement. Preserve existing business semantics.
5. Replace per-receipt full-home refresh with local recent updates and a coalesced refresh on exit. Add focused state/bridge/queue recovery tests, crop-orientation fixtures and ordinary-flow regressions.
6. Dispatch Trellis check review; address new findings, inspect cross-layer file/receipt consistency. Record existing static-analysis baseline separately from new issues.
7. Run dart format on touched files, flutter analyze --no-pub, flutter test --no-pub; platform build required for native changes. Increment pubspec version before release compilation and archive the version-named APK in root releases/. Check APK native dependencies. Do not build or claim iOS validation because the full iOS project is absent.
8. When a device is available, run baseline/comparison at least 20 samples, continuous 20 receipts, light/dark cases, immediate movement after success feedback, cancel/deny/error, duplicate tracking, navigation and background/restart. Report median/P95 and image quality with evidence; otherwise mark device acceptance pending.
9. Update relevant specs to describe final feedback/ownership contracts, commit only this task's changes under the project automatic commit rules, and finish with artifact and validation status. Preserve unrelated existing Trellis changes.

## Validation Baseline

Earlier in this chat: 22 Flutter tests passed; analyzer reported 33 issues (1 warning, no errors). Inventory unit tests mostly cover the in-memory service, so new persistence/queue behavior needs independent coverage.

## Risk and Rollback Points

Keep the old flow callable until native binding and lifecycle are verified. Before deleting any image, verify a durable replacement and live receipt reference. Never report latency/blur goals met from unit tests alone. Avoid unrelated cleanup of the currently modified Trellis infrastructure.

## Execution Status

Implementation, independent Flutter checks and final Android arm64 release compilation are complete. 40 tests pass; analyzer has 28 pre-existing issues (no new issues). The versioned APK is archived in releases/. Physical-device acceptance remains pending; do not archive this task as fully accepted until those checks pass. See research/validation-results.md and research/device-validation.md.
