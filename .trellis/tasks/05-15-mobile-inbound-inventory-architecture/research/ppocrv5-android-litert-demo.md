# PPOCRv5 Android LiteRT Demo Research

Source: https://github.com/iFleey/PPOCRv5-Android

## What The Demo Provides

* Native Android OCR app using Jetpack Compose, CameraX, Kotlin, JNI, and C++17.
* PP-OCRv5 detection and recognition models converted to FP16 TFLite:
  * `ocr_det_fp16.tflite` about 2.3 MB
  * `ocr_rec_fp16.tflite` about 7.9 MB
  * `keys_v5.txt` about 76 KB, 18,383 CJK/Latin/symbol characters
* LiteRT native runtime libraries for arm64:
  * `libLiteRt.so` about 4.9 MB
  * `libLiteRtOpenClAccelerator.so` about 2.6 MB
* C++ OCR pipeline:
  * pure C++ image preprocessing, no OpenCV dependency
  * DBNet-style detection postprocess
  * rotated crop recognition
  * CTC recognition decode
  * reading-order sort by `centerY` then `centerX`
  * GPU/NPU/CPU accelerator fallback

## Relevant Files

* `/tmp/PPOCRv5-Android/app/src/main/java/me/fleey/ppocrv5/ocr/OcrEngine.kt`
* `/tmp/PPOCRv5-Android/app/src/main/java/me/fleey/ppocrv5/data/GalleryOcrService.kt`
* `/tmp/PPOCRv5-Android/app/src/main/cpp/CMakeLists.txt`
* `/tmp/PPOCRv5-Android/app/src/main/cpp/ppocrv5_jni.cpp`
* `/tmp/PPOCRv5-Android/app/src/main/cpp/ocr_engine.cpp`
* `/tmp/PPOCRv5-Android/app/src/main/cpp/text_detector.cpp`
* `/tmp/PPOCRv5-Android/app/src/main/cpp/text_recognizer.cpp`
* `/tmp/PPOCRv5-Android/app/src/main/cpp/postprocess.cpp`

## Comparison With Current App

Current Android OCR uses Paddle Lite `.nb` models, OpenCV image loading, and `libpaddle_light_api_shared.so`. The existing PRD notes real-device instability around Paddle Lite predictor creation, so the app already isolates OCR in `OcrService`.

The reference demo avoids Paddle Lite and OpenCV by using LiteRT/TFLite and decoding images into `Bitmap` before JNI processing. This is a better base for the Android OCR engine replacement while preserving the existing Flutter inventory workflows.

## Recommended Direction

Keep the existing Flutter inventory app and MethodChannel contract, but replace Android OCR internals with the reference demo's LiteRT pipeline:

1. Copy/adapt the demo's LiteRT C++ OCR engine into Android native sources.
2. Bundle the TFLite models and LiteRT libraries under Android assets/native libs.
3. Replace `PaddleOcrEngine` internals so `recognize(imagePath)` decodes ARGB_8888 bitmap and returns rows/rawText to Flutter.
4. Preserve `OcrService` process isolation and timeout behavior.
5. Keep Dart-side `PpStructurePostProcessor` as the product-list parser, adding tests for Chinese product-list OCR rows.

This minimizes rewrite blast radius while directly addressing the user's goal: correctly recognizing Chinese product lists.

## Risks

* The reference repository is Apache-2.0 licensed; copied source files must retain license headers.
* The demo uses recent Android/Gradle/JDK versions. The current Flutter Android wrapper should stay compatible with the local Flutter toolchain unless a build error proves an upgrade is required.
* The demo does text OCR, not table-structure recognition. Product-list row reconstruction must rely on OCR box coordinates plus Dart post-processing and manual confirmation.
* Full native Compose rewrite would drop current Flutter/iOS inventory work and should only happen if explicitly confirmed.
