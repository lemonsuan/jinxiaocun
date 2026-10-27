#!/usr/bin/env python3
"""Download pinned official PP-OCRv6_small models and generate ARM CPU ORT assets.

Run in an isolated environment with onnx==1.17.0, onnxruntime==1.21.1,
PyYAML==6.0.3 and numpy installed. No Android device timing is inferred here.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile

import numpy as np
import onnx
import onnxruntime as ort
import yaml

MODEL_BASE = "https://paddle-model-ecology.bj.bcebos.com/paddlex/official_inference_model/paddle3.0.0/"
ARCHIVES = {
    "det": "d218f6fbf0f1c23d2161bd6ac7f5eaa6104fa89955c09290497e31008e2618e4",
    "rec": "d267ab077a44a0eedb1ea8f8c542d263f211de8e9d7a029bf9fcfff7e5a88fb1",
}
RUNTIME_VERSION = "1.21.1"
PADDLE_LICENSE_URL = "https://raw.githubusercontent.com/PaddlePaddle/PaddleOCR/v3.7.0/LICENSE"
PADDLE_LICENSE_SHA256 = "3840c5c0c61c294264d2dd77b8777be6ddd90121ef4e0e64abcd22edea581d6e"
MOBILE_ROOT = Path(__file__).resolve().parents[2]


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def signature(value: onnx.ValueInfoProto) -> dict:
    tensor = value.type.tensor_type
    if tensor.elem_type != onnx.TensorProto.FLOAT:
        raise ValueError("Only verified FP32 models are supported")
    return {
        "name": value.name,
        "dtype": "float32",
        "shape": [d.dim_param or d.dim_value for d in tensor.shape.dim],
    }


def prepare(work: Path) -> None:
    if ort.__version__ != RUNTIME_VERSION:
        raise ValueError(f"Use onnxruntime=={RUNTIME_VERSION}, not {ort.__version__}")
    models = work / "models"
    models.mkdir(parents=True, exist_ok=True)
    configs = {}
    graphs = {}
    for stage, expected in ARCHIVES.items():
        url = f"{MODEL_BASE}PP-OCRv6_small_{stage}_onnx_infer.tar"
        archive = work / f"{stage}.tar"
        if not archive.exists():
            subprocess.run(["curl", "-fL", "--retry", "2", "-o", str(archive), url], check=True)
        if digest(archive) != expected:
            raise ValueError(f"Official {stage} archive hash mismatch")
        prefix = f"PP-OCRv6_small_{stage}_onnx_infer/"
        with tarfile.open(archive) as tar:
            model = models / f"ppocrv6_small_{stage}.onnx"
            model.write_bytes(tar.extractfile(prefix + "inference.onnx").read())
            configs[stage] = yaml.safe_load(tar.extractfile(prefix + "inference.yml").read())
        graph = onnx.load(model)
        onnx.checker.check_model(graph)
        graphs[stage] = {
            "inputs": [signature(v) for v in graph.graph.input],
            "outputs": [signature(v) for v in graph.graph.output],
        }
    converted = work / "converted"
    subprocess.run([
        sys.executable, "-m", "onnxruntime.tools.convert_onnx_models_to_ort",
        str(models), "--optimization_style", "Fixed", "--enable_type_reduction",
        "--target_platform", "arm", "--output_dir", str(converted),
    ], check=True)
    comparisons = []
    for stage, shapes in (
        ("det", [(1, 3, 192, 256), (1, 3, 320, 320)]),
        ("rec", [(1, 3, 48, 160), (1, 3, 48, 320), (1, 3, 48, 640)]),
    ):
        options = ort.SessionOptions()
        options.intra_op_num_threads = 2
        options.inter_op_num_threads = 1
        original = ort.InferenceSession(str(models / f"ppocrv6_small_{stage}.onnx"), options,
                                        providers=["CPUExecutionProvider"])
        optimized = ort.InferenceSession(str(converted / f"ppocrv6_small_{stage}.ort"), options,
                                         providers=["CPUExecutionProvider"])
        for shape in shapes:
            data = np.random.default_rng(20261027).normal(0, .6, shape).astype(np.float32)
            before = original.run(None, {"x": data})[0]
            after = optimized.run(None, {"x": data})[0]
            np.testing.assert_allclose(before, after, rtol=1e-4, atol=1e-5)
            comparisons.append({"stage": stage, "input": shape, "output": before.shape,
                                "max_abs_delta": float(np.max(np.abs(before - after)))})
    (work / "conversion-equivalence.json").write_text(json.dumps(comparisons, indent=2) + "\n")
    dictionary = configs["rec"]["PostProcess"]["character_dict"]
    classes = graphs["rec"]["outputs"][0]["shape"][-1]
    # Official CTC decoding appends a space; blank is a separate leading output class.
    if len(dictionary) != 18708 or " " in dictionary or classes != len(dictionary) + 2:
        raise ValueError("Unexpected official v6_small CTC dictionary/output contract")
    assets = MOBILE_ROOT / "android/app/src/main/assets/models"
    assets.mkdir(parents=True, exist_ok=True)
    license_file = work / "PADDLEOCR_LICENSE_v3.7.0"
    if not license_file.exists():
        subprocess.run(["curl", "-fL", "--retry", "2", "-o", str(license_file), PADDLE_LICENSE_URL], check=True)
    if digest(license_file) != PADDLE_LICENSE_SHA256:
        raise ValueError("PaddleOCR license hash mismatch")
    shutil.copy2(license_file, assets / "LICENSE-PaddleOCR.txt")
    keys = assets / "keys_v6_small.txt"
    keys.write_text("\n".join(dictionary + [" "]) + "\n", encoding="utf-8")
    entries = []
    for stage, name in (("det", "ocr_detection"), ("rec", "ocr_recognition")):
        filename = f"ppocrv6_small_{stage}.ort"
        target = assets / filename
        shutil.copy2(converted / filename, target)
        entries.append({
            "name": name, "type": "ort", "assetPath": "models/" + filename,
            "targetPath": filename, "sha256": digest(target), "sizeBytes": target.stat().st_size,
            "required": True, "precision": "FP32",
            "description": f"Official PP-OCRv6_small_{stage}, FP32, Fixed ARM optimized ORT",
            "source": f"{MODEL_BASE}PP-OCRv6_small_{stage}_onnx_infer.tar", **graphs[stage],
        })
    entries.append({
        "name": "ocr_dictionary", "type": "dictionary", "assetPath": "models/" + keys.name,
        "targetPath": keys.name, "sha256": digest(keys), "sizeBytes": keys.stat().st_size,
        "required": True, "characterCount": 18709, "blankIndex": 0, "spaceIndex": 18709,
        "description": "18708 official dictionary entries + trailing space; CTC blank is not a dictionary line",
        "source": "Official PP-OCRv6_small_rec inference.yml PostProcess.character_dict",
    })
    manifest = {"version": 4, "modelName": "PP-OCRv6_small", "license": "Apache-2.0",
                "licenseSource": PADDLE_LICENSE_URL, "runtime": "ONNX Runtime reduced CPU",
                "runtimeVersion": RUNTIME_VERSION, "precision": "FP32", "layout": "NCHW", "models": entries}
    (assets / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    for old in ("ocr_det_fp16.tflite", "ocr_rec_fp16.tflite", "keys_v5.txt"):
        (assets / old).unlink(missing_ok=True)
    config = converted / "required_operators_and_types.config"
    lines = [line for line in config.read_text().splitlines() if not line.startswith("#")]
    (Path(__file__).parent / config.name).write_text(
        "# PP-OCRv6_small detector + recognizer; ORT 1.21.1 Fixed ARM, FP32.\n" + "\n".join(lines) + "\n")
    print(json.dumps({"model": manifest["modelName"], "files": len(entries),
                      "bytes": sum(v["sizeBytes"] for v in entries)}, ensure_ascii=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=Path, required=True)
    args = parser.parse_args()
    args.work_dir.mkdir(parents=True, exist_ok=True)
    prepare(args.work_dir.resolve())
