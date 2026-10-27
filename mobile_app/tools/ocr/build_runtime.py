#!/usr/bin/env python3
"""Rebuild the checked-in reduced ARM64 ONNX Runtime 1.21.1 on an Apple Silicon host.

The large source/build tree stays outside the repository. Source dependencies are
checked against upstream ORT hashes; Eigen uses its exact Git commit because the
GitLab-generated ZIP no longer matches ORT's historical archive hash.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tarfile

VERSION = "1.21.1"
SOURCE_URL = f"https://codeload.github.com/microsoft/onnxruntime/tar.gz/refs/tags/v{VERSION}"
SOURCE_SHA256 = "afd53e380d534c5285598f0010b9fe99c6c05ea83de11bddf3b9d51686746a03"
PROTOC_URL = "https://repo.maven.apache.org/maven2/com/google/protobuf/protoc/3.21.12/protoc-3.21.12-osx-aarch_64.exe"
PROTOC_SHA256 = "9f40368c858666e7036df0b9b58a4acd085fed58ab531294c3e5b5820f8af360"
EIGEN_COMMIT = "1d8b82b0740839c0de7f1242a3585e3390ff5f33"
DEPS = {"abseil_cpp", "re2", "utf8_range", "protobuf", "date", "mp11", "json",
        "pytorch_cpuinfo", "microsoft_gsl", "safeint", "flatbuffers", "onnx"}
MOBILE_ROOT = Path(__file__).resolve().parents[2]


def run(arguments: list[str], **kwargs) -> None:
    subprocess.run([str(a) for a in arguments], check=True, **kwargs)


def download(url: str, target: Path, expected: str, algorithm: str = "sha256") -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists():
        run(["curl", "-fL", "--retry", "2", "--connect-timeout", "15", "--max-time", "300",
             "-o", str(target), url])
    actual = hashlib.new(algorithm, target.read_bytes()).hexdigest()
    if actual != expected:
        raise ValueError(f"Hash mismatch for {target.name}: {actual}")


def build(work: Path, sdk: Path, ndk: Path, cmake: Path, jobs: int) -> None:
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise RuntimeError("This pinned protoc recipe currently supports Apple Silicon hosts only")
    source = work / f"onnxruntime-{VERSION}"
    archive = work / "ort.tar.gz"
    download(SOURCE_URL, archive, SOURCE_SHA256)
    if not source.exists():
        with tarfile.open(archive) as tar:
            tar.extractall(work, filter="data")
    protoc = work / "protoc"
    download(PROTOC_URL, protoc, PROTOC_SHA256)
    protoc.chmod(0o755)
    eigen = work / "eigen-source"
    if not (eigen / ".git").exists():
        eigen.mkdir(exist_ok=True)
        run(["git", "-C", str(eigen), "init", "-q"])
        run(["git", "-C", str(eigen), "fetch", "--depth", "1",
             "https://gitlab.com/libeigen/eigen.git", EIGEN_COMMIT])
        run(["git", "-C", str(eigen), "checkout", "--detach", "FETCH_HEAD"])
    commit = subprocess.check_output(["git", "-C", str(eigen), "rev-parse", "HEAD"], text=True).strip()
    if commit != EIGEN_COMMIT:
        raise ValueError("Eigen source is not the pinned commit")

    def fetch_dep(line: str) -> None:
        name, url, sha1 = line.split(";")
        target = source / "mirror" / url.removeprefix("https://")
        match = re.fullmatch(r"https://github.com/([^/]+)/([^/]+)/archive/(.+)\.zip", url)
        fetch = f"https://codeload.github.com/{match[1]}/{match[2]}/zip/{match[3]}" if match else url
        download(fetch, target, sha1, "sha1")

    deps = [line for line in (source / "cmake/deps.txt").read_text().splitlines()
            if line and not line.startswith("#") and line.split(";")[0] in DEPS]
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as executor:
        list(executor.map(fetch_dep, deps))
    config = Path(__file__).parent / "required_operators_and_types.config"
    command = [
        sys.executable, str(source / "tools/ci_build/build.py"), "--update", "--build",
        "--config", "Release", "--build_dir", str(work / "android"), "--cmake_generator", "Ninja",
        "--cmake_path", str(cmake), "--android", "--android_sdk_path", str(sdk),
        "--android_ndk_path", str(ndk), "--android_abi", "arm64-v8a", "--android_api", "28",
        "--minimal_build", "--include_ops_by_config", str(config), "--enable_reduced_operator_type_support",
        "--disable_ml_ops", "--disable_rtti", "--android_cpp_shared", "--skip_tests",
        "--skip_submodule_sync", "--parallel", str(jobs), "--build_shared_lib", "--cmake_extra_defines",
        f"ONNX_CUSTOM_PROTOC_EXECUTABLE={protoc}", f"FETCHCONTENT_SOURCE_DIR_EIGEN={eigen}",
        "CMAKE_POLICY_VERSION_MINIMUM=3.5", "CMAKE_POLICY_DEFAULT_CMP0169=OLD",
        "onnxruntime_ENABLE_CPU_FP16_OPS=OFF", "onnxruntime_BUILD_UNIT_TESTS=OFF",
    ]
    # Exceptions intentionally remain enabled. No GPU/NNAPI/OpenCV/Paddle Lite.
    run(command)
    vendor = MOBILE_ROOT / "android/app/src/main/cpp/onnxruntime"
    include = vendor / "include"
    library = vendor / "lib/arm64-v8a/libonnxruntime.so"
    include.mkdir(parents=True, exist_ok=True)
    library.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source / "include/onnxruntime/core/session/onnxruntime_c_api.h", include)
    shutil.copy2(source / "LICENSE", vendor / "LICENSE")
    shutil.copy2(source / "ThirdPartyNotices.txt", vendor / "ThirdPartyNotices.txt")
    assets = MOBILE_ROOT / "android/app/src/main/assets/models"
    assets.mkdir(parents=True, exist_ok=True)
    shutil.copy2(vendor / "LICENSE", assets / "LICENSE-ONNXRuntime.txt")
    shutil.copy2(vendor / "ThirdPartyNotices.txt", assets / "NOTICE-ONNXRuntime.txt")
    shutil.copy2(work / "android/Release/libonnxruntime.so", library)
    strip = ndk / "toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-strip"
    run([str(strip), "--strip-unneeded", str(library)])
    details = {
        "version": VERSION, "abi": "arm64-v8a", "api": 28, "format": "ORT",
        "source": SOURCE_URL, "sourceSha256": SOURCE_SHA256, "eigenCommit": EIGEN_COMMIT,
        "precision": "FP32", "minimalBuild": True, "operatorTypeReduction": True,
        "exceptions": True, "executionProviders": ["CPUExecutionProvider"],
        "requiredOperatorsSha256": hashlib.sha256(config.read_bytes()).hexdigest(),
        "libraryBytes": library.stat().st_size,
        "librarySha256": hashlib.sha256(library.read_bytes()).hexdigest(),
    }
    (vendor / "build-manifest.json").write_text(json.dumps(details, indent=2) + "\n")
    print(json.dumps(details, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=Path, required=True)
    parser.add_argument("--sdk", type=Path, default=Path.home() / "Library/Android/sdk")
    parser.add_argument("--ndk", type=Path)
    parser.add_argument("--cmake", type=Path, default=Path(shutil.which("cmake") or "/missing/cmake"))
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    args.work_dir.mkdir(parents=True, exist_ok=True)
    build(args.work_dir.resolve(), args.sdk.resolve(),
          (args.ndk or args.sdk / "ndk/28.2.13676358").resolve(), args.cmake.resolve(), args.jobs)
