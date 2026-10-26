# OCR Model Follow-up (Informational, Not a Camera Scope Change)

User asked on 2026-10-27 which current mobile on-device PaddleOCR models offer low resource use and better recognition. No OCR replacement was requested or implemented in this camera task.

## Verified Current App

`android/app/src/main/assets/models/manifest.json` labels current models PP-OCRv5 FP16/TFLite. Detection is 2,444,316 bytes, recognition 8,324,208 bytes; both and dictionary hashes match the manifest. Model weights total about 10.8 MB, which is not runtime peak memory.

Detector fixes input at 640x640 (`cpp/text_detector.cpp`, kDetInputSize); recognizer fixes 48x320 and clamps target width (`cpp/text_recognizer.cpp`, CropAndRotate). Dense-document small text, long lines and row/quantity post-processing are independent potential bottlenecks; no test images have established their respective error contribution. The current TFLite conversion's equivalence to original model output also needs sample-based validation.

## Official Current Evidence

- PaddleOCR 3.7.0 release dated 2026-06-11 introduced PP-OCRv6 tiny/small/medium: https://github.com/PaddlePaddle/PaddleOCR/releases/tag/v3.7.0
- Official model tables: https://www.paddleocr.ai/latest/en/version3.x/pipeline_usage/OCR.html
  - tiny detector 1.9 MB + recognizer 4.4 MB = 6.3 MB official storage size.
  - small detector 9.6 MB + recognizer 20.4 MB = 30.0 MB official storage size.
  - These are official artifact storage figures, not Android resident/peak memory; do not compare them as like-for-like FP16 package or phone latency benchmarks. Official v6 and v5 headline accuracy sets differ and are not directly comparable.
- Official Android SDK/demo supports PP-OCRv6 tiny, small and v5 mobile via ONNX Runtime, with an AAR integration option: https://www.paddleocr.ai/latest/en/version3.x/inference_deployment/cross_platform/android_deployment.html
  - This is not a drop-in replacement for current LiteRT/TFLite static model input/dictionary/decoder contracts. Existing project Android guidelines also prohibit reintroducing OpenCV/Paddle Lite in the current OCR runtime without a separately reviewed architecture/spec change.

## Recommendation

Treat v6_small as the first accuracy/efficiency upgrade candidate and v6_tiny as the low-resource comparison, alongside current v5 as baseline. No blanket claim that latest is more stable or tiny is more accurate. Evaluate the same clear source photos and a set of real product receipts, separately scoring missed text boxes, character errors, row alignment, quantity errors, warm/cold latency and peak memory. First fix blur/image quality in capture, then isolate recognition versus structure errors. Prefer actual quantity correctness over generic OCR headline scores.
