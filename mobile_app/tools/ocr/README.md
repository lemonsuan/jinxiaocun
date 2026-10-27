# PP-OCRv6_small model and reduced runtime preparation

The Android application ships the official **PP-OCRv6_small** detector and recognizer,
converted to FP32 ORT format with ONNX Runtime **1.21.1**, plus a model-specific
**ARM64 CPU-only minimal runtime**. It does not ship the official demo's OpenCV
dependency or the previous LiteRT/TFLite models/runtime.

## Reproduce the checked-in assets

Use an isolated Python 3.12 environment. The tested preparation environment used
`onnx==1.17.0`, `onnxruntime==1.21.1`, `PyYAML==6.0.3`, `numpy==2.5.4`,
`flatbuffers==25.12.19`, `cmake==4.4.4`, and `ninja==1.13.2`.

```sh
uv venv /tmp/ocr-v6-build/venv
uv pip install --python /tmp/ocr-v6-build/venv/bin/python \
  onnx==1.17.0 onnxruntime==1.21.1 PyYAML==6.0.3 numpy==2.5.4 \
  flatbuffers==25.12.19 cmake==4.4.4 ninja==1.13.2
/tmp/ocr-v6-build/venv/bin/python tools/ocr/prepare_models.py \
  --work-dir /tmp/ocr-v6-build
PATH=/tmp/ocr-v6-build/venv/bin:$PATH \
  /tmp/ocr-v6-build/venv/bin/python tools/ocr/build_runtime.py \
  --work-dir /tmp/ocr-v6-build \
  --cmake /tmp/ocr-v6-build/venv/bin/cmake
```

Run these commands from `mobile_app/`. `prepare_models.py` verifies the downloaded
official tar SHA256 values, checks ONNX graphs, converts with `Fixed` optimizations
for **ARM**, generates the reduced operator/type configuration, and compares
original ONNX versus ORT outputs at five dynamic shapes. It only deletes the three
known v5 assets after successful conversion/comparison. Original ONNX files stay
in the external work directory for reference tests; only ORT files are packaged.

`build_runtime.py` currently supports an Apple Silicon host, Android API 28,
NDK `28.2.13676358`, and an installed CMake/Ninja. It pins ORT's released source tar,
downloads dependencies into ORT's supported local mirror layout, and checks the
upstream dependency SHA1 values. GitLab's generated Eigen ZIP has changed since
ORT recorded its hash; instead the script fetches and checks out the exact pinned
Git commit `1d8b82b0740839c0de7f1242a3585e3390ff5f33`.

The runtime uses a basic minimal build, required operator/type reduction,
`--disable_ml_ops`, `--disable_rtti`, shared Android libc++, no GPU/NNAPI provider,
and **keeps exceptions enabled**. Unit-test build targets are disabled in the
vendored runtime; application/native fixtures are validated separately. The final
library is stripped and its hash/build configuration recorded in
`android/app/src/main/cpp/onnxruntime/build-manifest.json`.

## Model contracts

- Detection: input `x`, FP32 NCHW `[N,3,H,W]`; output `fetch_name_0`, FP32
  `[N,1,H,W]`; original ONNX opset 14. BGR, scale `1/255`, mean
  `[0.485,0.456,0.406]`, std `[0.229,0.224,0.225]`. Official DB parameters:
  pixel threshold `0.2`, box threshold `0.45`, expansion ratio `1.4`.
- Recognition: input `x`, FP32 NCHW `[N,3,48,W]`; output `fetch_name_0`, FP32
  `[N,T,18710]`, with softmax already applied; original ONNX opset 11. At widths
  160/320/640, the observed output has 20/40/80 time steps.
- CTC: official YAML supplies **18,708** characters. Append one ordinary space
  to produce `keys_v6_small.txt` with **18,709** lines. Blank is output index 0
  and is not included in the text file; dictionary entry `i` is output index
  `i+1`; the final space is output index 18,709. Do not trim dictionary lines or
  reuse `keys_v5.txt`.

All shipped model, dictionary and runtime sizes/hashes are in their manifests.
Model bytes and host conversion timings are **not** phone peak-memory or latency
measurements. No Android device was connected during preparation.

## Sources and licensing

- [Official Android deployment](https://www.paddleocr.ai/latest/en/version3.x/inference_deployment/cross_platform/android_deployment.html)
- Official model source archives:
  `https://paddle-model-ecology.bj.bcebos.com/paddlex/official_inference_model/paddle3.0.0/PP-OCRv6_small_<det|rec>_onnx_infer.tar`
- [PaddleOCR repository/license](https://github.com/PaddlePaddle/PaddleOCR)
- [ONNX Runtime v1.21.1](https://github.com/microsoft/onnxruntime/tree/v1.21.1)
- [Reduced runtime build documentation](https://onnxruntime.ai/docs/build/custom.html)

The vendored ONNX Runtime directory contains its MIT `LICENSE` and upstream
`ThirdPartyNotices.txt`. Copies of both and the pinned PaddleOCR Apache-2.0
license are also shipped with the model assets. Preserve them when distributing.
