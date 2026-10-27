# Verified Research: PP-OCRv6_small Replacement

## Official Sources

- Android deployment and model download links: https://www.paddleocr.ai/latest/en/version3.x/inference_deployment/cross_platform/android_deployment.html
- Official SDK build file (reference, not to copy all dependencies blindly): https://raw.githubusercontent.com/PaddlePaddle/PaddleOCR/main/deploy/ppocr-android/ppocr-sdk/build.gradle.kts
- Runtime custom builds and operator/type reduction: https://onnxruntime.ai/docs/build/custom.html

Official Android demo uses ONNX Runtime 1.21.1 and OpenCV. This project's current Android spec forbids reintroducing OpenCV/Paddle Lite after past device crashes; the planned replacement uses a reduced ONNX Runtime and project-owned lightweight image/DB/CTC post-processing instead. Updating the v5/LiteRT-only spec contract is part of this explicitly approved replacement task, not permission to alter inventory rules.

## Downloaded Model Evidence

Both official BOS tar downloads succeeded to /tmp/ocr-v6-small-research. The detector ONNX is 9,880,512 bytes; recognizer ONNX is 21,159,378 bytes (31,039,890 total). Full member hashes are in official-models.json. These are original official artifacts, not quantified phone RAM or a verified FP16 conversion.

Detector inference.yml names PP-OCRv6_small_det, uses BGR preprocessing, CHW layout, mean [0.485,0.456,0.406], std [0.229,0.224,0.225], scale 1/255, dynamic spatial dimensions, DB postprocessing (threshold0.2, box0.45, unclip1.4). Recognizer inference.yml names PP-OCRv6_small_rec, uses CTCLabelDecode with its own character_dict and 3x48x320 baseline image shape; model config describes dynamic widths up to3200. The actual ONNX graph's tensor signatures and operator list must be inspected and checked during implementation before runtime conversion. Do not reuse the current 18,383-character v5 dictionary.

## Existing App Boundary

MainActivity -> OcrService -> PaddleOcrEngine -> JNI/C++ LiteRT currently produces grouped rows/rawText. Dart callers require inventory_app/paddle_ocr.recognizeTable(imagePath,rowMergeTolerance) -> {rows,rawText}; preserve this compatibility. Grouping tolerance bounds are0.20..0.60/default0.30.

OcrService currently serializes requests but stopSelf after each idle request destroys engine state. New lifecycle should reuse sessions within a burst, then release after a bounded idle timeout; no unbounded persistent allocation. The new native errors must surface as recoverable channel errors/empty output, never stack traces passed into product parsing.

Current APK1.0.5+7 has about8.7MB of OCR-specific arm64 LiteRT/OpenCL/inventory native libraries (excluding shared C++), and10.8MB of FP16 models; total APK51.3MB. Raw small models are larger, so no honest promise that small alone shrinks the package. Avoid shipping both runtimes/models. Compare final APK and model/runtime sizes against these measured baseline figures.

## Implementation Verification Needed

Inspect actual ONNX signatures/operators, generate ORT models and reduced-operator config, build a release-tag-pinned ARM64 CPU runtime retaining exceptions, verify reference inference on controlled Chinese/English/quantity samples, and test dynamic line widths. Configure single-image/single-line batch and bounded threads; profile device PSS, cold/warm timing and throughput when a phone is connected. There is presently no adb device, so CPU desktop comparisons are explicitly not phone-performance acceptance.
