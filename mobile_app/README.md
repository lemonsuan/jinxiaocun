# 云推推库存管理

Offline-first Flutter app for single-device inventory receiving.

## MVP Scope

- Native Android/iOS tracking-code scanning through `MethodChannel`.
- Android PP-OCRv5 LiteRT/TFLite OCR and iOS native OCR through `MethodChannel`.
- Dart-side OCR post-processing rules for product name and quantity extraction.
- Local inventory ledger as the authority for stock totals.
- Inbound settlement marker, inbound history, stock total, and outbound query.

## Native Bridge Contracts

- `inventory_app/scanner.scanTrackingNumber` returns a tracking number string.
- `inventory_app/paddle_ocr.recognizeTable` receives an image path and returns `rows: List<List<String>>` plus `rawText`.

Android OCR keeps recognition isolated behind the native bridge. OCR output is always an editable draft; confirmed inventory is written only after user review.
