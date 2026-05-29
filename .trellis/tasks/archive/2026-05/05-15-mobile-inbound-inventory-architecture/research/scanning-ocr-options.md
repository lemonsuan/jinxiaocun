# Research: Mobile Scanning and OCR Options

Date: 2026-05-15

## Findings

* The product direction is now App-only, single-user/single-device, not PWA/PC-first.
* iOS has native VisionKit `DataScannerViewController` for live camera scanning of text and machine-readable codes. Source: https://developer.apple.com/documentation/visionkit/datascannerviewcontroller
* Google ML Kit Barcode Scanning supports on-device barcode scanning on Android/iOS. Google recommends specifying barcode formats instead of scanning every format for performance. Sources: https://developers.google.cn/ml-kit/vision/barcode-scanning/android?hl=en and https://developers.google.cn/ml-kit/vision/barcode-scanning/ios?hl=en
* Google ML Kit Text Recognition v2 is suitable for on-device OCR in mobile apps; script-specific recognizers are available for Chinese/Japanese/Korean/Devanagari. Sources: https://developers.google.cn/ml-kit/vision/text-recognition/v2/android and https://developers.google.cn/ml-kit/vision/text-recognition/v2/ios
* The user selected PaddleOCR Mobile + PP-Structure for offline table recognition of product names and quantities, followed by custom post-processing rules. PaddleOCR 3.x documents on-device deployment with PP-OCRv5 mobile models, while older PaddleOCR/Paddle-Lite docs include Android and iOS ARM deployment libraries. PP-Structure is PaddleOCR's document analysis/table structure direction and should be wrapped behind a platform bridge so Android/iOS implementation details do not leak into Flutter business logic. Sources: https://www.paddleocr.ai/v3.0.2/en/version3.x/deployment/on_device_deployment.html and https://www.paddleocr.ai/v2.10.0/en/ppocr/infer_deploy/lite.html
* PP-Structure table recognition is not a single OCR call: official docs describe a pipeline with DB text detection, CRNN text recognition, and SLANet table structure/cell coordinate prediction, then combining cell text and structure into table output. Mobile table models exist, including `ch_ppstructure_mobile_v2.0_SLANet` at about 9.3 MB. Sources: https://www.paddleocr.ai/latest/en/version2.x/ppstructure/model_train/train_table.html and https://www.paddleocr.ai/v3.0.2/en/version2.x/ppstructure/models_list.html
* Flutter is a viable cross-platform app route; local persistence can be backed by SQLite through packages such as sqflite. Sources: https://docs.flutter.dev/ and https://pub.dev/packages/sqflite
* Cloud OCR providers can remain optional online fallback providers, but they cannot satisfy the user's offline-first requirement by themselves. Sources: https://cloud.google.com/vision/docs/ocr, https://aws.amazon.com/documentation-overview/textract/, https://learn.microsoft.com/en-us/azure/ai-services/document-intelligence/

## Architecture Implication

Recommended MVP path: build a cross-platform native app with local SQLite, native barcode scanning, PaddleOCR Mobile + PP-Structure through Android/iOS native bridges, and a Dart-side post-processing pipeline for stable row extraction. Treat cloud sync as a secondary backup layer, not as a prerequisite for receiving goods or querying stock.

The current generated app keeps the PaddleOCR/PP-Structure boundary as a native MethodChannel, implements Dart post-processing/tests, and now bundles Paddle Lite + OpenCV with PP-OCRv5 mobile det/cls/rec models on Android and iOS. The implemented mobile table path groups detected OCR text boxes into rows before Dart post-processing. Completing full PP-Structure table recognition still requires adding a mobile SLANet table-structure model and mapping its cell structure output behind the same channel.
