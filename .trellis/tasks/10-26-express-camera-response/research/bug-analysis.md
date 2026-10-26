# Bug Analysis: Premature Shutter Success and Serial Capture Work

## 1. Root Cause Category

Cross-layer contract and implicit assumption: the old UI treated a shutter request animation as if the camera had captured a frame. Repository code proves the success-like flash preceded the awaited takePicture result; the current Android plugin resolves that future after file saving, not at exact sensor exposure. Actual contribution of autofocus/exposure/movement to the reported blur remains unmeasured without a phone.

## 2. Why Earlier Design Was Insufficient

A 70ms animation and immediate haptic feedback changed perceived completion, without reducing hardware capture time. Two complete decodes, PNG encoding and forced write completion blocked navigation after capture. Separate scan/capture controllers then paid camera handoff plus a fixed 500ms delay every receipt. These are code-observable costs, not device timing measurements.

## 3. Prevention Mechanisms

- Done: immutable capture ID + tracking context across native events and receipt commit.
- Done: success allowed only after durable saved-photo callback; receipt-saved is a separate state.
- Done: one persistent native scan/capture session and bounded durable background processing.
- Done: regression tests for delayed success/failure, commit retry coalescing, route navigation and real SQLite generation/source guards.
- Done: executable frontend spec contracts and APK ABI inspection rule.
- Pending: physical-device shutter distribution and move-after-success image readability checks.

## 4. Systematic Expansion

Ordinary CustomCameraPage had the same early flash and duplicate decode/PNG behavior; its success feedback and single-decode JPEG processing were corrected while retaining the public return contract. Permission lifecycle, missed initial channel events, crop geometry and commit/reset races were caught during review and fixed in their owning layers.

## 5. Knowledge Capture

Updated .trellis/spec/frontend/quality-guidelines.md (camera contract and release ABI override). This repository has no src/templates/markdown/spec tree to synchronize. Physical acceptance remains explicitly open; neither a successful compile nor a mocked camera test proves zero motion blur.
