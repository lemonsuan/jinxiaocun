# Actual PP-OCRv6_small native-core fixtures

These tests compile the same platform-independent C++ core used by Android JNI,
link a host ONNX Runtime1.21.1 library, and execute the **shipped** v6_small ORT
models. The PNG fixtures are synthetic clear,5-degree skewed,long-line,wired-table
and blank documents; no system font file is redistributed. expected.json declares
required words, SKUs and quantities, independently of model confidence scores.

From repository root, using an isolated Python environment with
`Pillow` and `onnxruntime==1.21.1` and an installed C++17 compiler:

```sh
python mobile_app/test/native_ocr/verify_v6.py \
  --det mobile_app/android/app/src/main/assets/models/ppocrv6_small_det.ort \
  --rec mobile_app/android/app/src/main/assets/models/ppocrv6_small_rec.ort \
  --keys mobile_app/android/app/src/main/assets/models/keys_v6_small.txt \
  --report /tmp/ocr-v6-fixtures.json
```

The verifier locates the Python wheel's host shared library or accepts
`--runtime-lib`. It checks actual text and blank output, exercises0/1/20ms
cancellation then a normal request using the same Engine, and records host peak
RSS/stage timing. Those resource measurements are **not Android benchmarks**.
The tests complement three Android Kotlin row-grouping regressions, including the
actual noisy5-degree fixture boxes. Real phone images, low light, PSS and cold/warm
Android latency are separate acceptance items.
