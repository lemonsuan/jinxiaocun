# 云推推库存管理

Offline-first Flutter inventory receiving app, with Android continuous barcode capture and local OCR.

## Android OCR

The packaged engine is **PP-OCRv6_small**, running official detector/recognizer models converted to FP32 ORT format on a reduced ARM64 CPU ONNX Runtime1.21.1. It replaces the earlier PP-OCRv5 LiteRT/TFLite path; the release APK ships only the selected OCR runtime/model pair. Model and runtime source pins, licenses and reproducible preparation commands are in [tools/ocr/README.md](tools/ocr/README.md).

`inventory_app/paddle_ocr.recognizeTable` accepts an absolute imagePath and optional rowMergeTolerance, returning `rows: List<List<String>>` and `rawText`. Structured native errors propagate as recoverable PlatformExceptions rather than product text. Native code recognizes text and groups rows; it does not provide a full table-structure model. Dart postprocessing still extracts product names/quantities and confirmed records use the local database.

The express camera keeps one Android CameraX session for barcode scanning and formal photos, shows the full locked tracking number, and signals capture success only after photo saving. Crop/OCR processing uses durable pending jobs in a bounded background pipeline. Ordinary receiving keeps editable OCR review; the existing express confirmation semantics are unchanged by the model migration.

## Validation

- `flutter analyze --no-pub` and `flutter test --no-pub`.
- Android Kotlin/native grouping and compilation checks.
- Real-model production-core host fixtures: see [test/native_ocr/README.md](test/native_ocr/README.md).
- `flutter build apk --release --no-pub --target-platform android-arm64`.

Before publishing any new APK, increment pubspec.yaml version and archive it as `../releases/app-v<version>.apk`. The current release build keeps the project's existing debug signing setup. No complete iOS project is included in this checkout.

Host-model tests and release compilation do not prove phone shutter/recognition speed, peak PSS or real-receipt accuracy; those need actual Android device acceptance.
