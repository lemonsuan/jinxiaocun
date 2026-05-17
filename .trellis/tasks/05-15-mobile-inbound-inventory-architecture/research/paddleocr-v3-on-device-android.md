# PaddleOCR v3 On-Device Android Notes

Source: https://www.paddleocr.ai/main/version3.x/deployment/on_device_deployment.html

## Findings

The v3 on-device deployment guide points Android deployment at the PaddleX-Lite-Deploy style package: native C++ sources, Paddle Lite prediction libraries, OpenCV, bundled `.nb` models, config, and dictionaries. The app should load local files and run OCR fully offline.

For this project, Android must not load Paddle Lite in the Flutter main process because the target Xiaomi Android 16 device previously crashed inside `CreatePaddlePredictor`. OCR is therefore isolated in an Android service process named `:ocr`. If that process dies or times out, the Flutter UI gets empty OCR rows and keeps the receipt editable instead of losing the app session.

Bundled Android assets:

* `PP-OCRv5_mobile_det.nb`
* `PP-LCNet_x0_25_textline_ori.nb`
* `PP-OCRv5_mobile_rec.nb`
* `ch_ppstructure_mobile_v2.0_SLANet_v214.nb`
* `ppocr_keys_ocrv5.txt`
* `table_structure_dict_ch.txt`
* `config.txt`

Runtime choice:

* Use Paddle Lite 2.14 C++ runtime from `/private/tmp/paddle_lite_214/cxx` because the SLANet model is v214 and the previous packaged runtime build ID matched the user crash stack.
