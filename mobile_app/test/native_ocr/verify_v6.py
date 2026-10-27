#!/usr/bin/env python3
"""Compile the production C++ OCR core and run real v6 assets on fixed fixtures.

Host-only correctness verification. Timings here are not Android benchmarks.
Dependencies: Pillow, onnxruntime==1.21.1; C++17 compiler and runtime headers.
"""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
CPP = ROOT / 'android/app/src/main/cpp'
FIXTURES = ROOT / 'test/fixtures/ocr_v6'


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--det', required=True, type=Path)
    parser.add_argument('--rec', required=True, type=Path)
    parser.add_argument('--keys', required=True, type=Path)
    parser.add_argument('--runtime-lib', type=Path)
    parser.add_argument('--compiler', default='clang++')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    if args.runtime_lib is None:
        import onnxruntime
        capi = Path(onnxruntime.__file__).parent / 'capi'
        candidates = sorted(capi.glob('libonnxruntime*.dylib')) + sorted(capi.glob('libonnxruntime.so*'))
        if not candidates:
            parser.error('Host ONNX Runtime shared library not found; pass --runtime-lib')
        args.runtime_lib = candidates[0]
    runtime = args.runtime_lib.resolve()
    specs = json.loads((FIXTURES / 'expected.json').read_text())['cases']
    reports = []
    with tempfile.TemporaryDirectory(prefix='ocr-v6-native-test-') as tmp:
        temp = Path(tmp)
        binary = temp / 'ocr_v6_host'
        command = [args.compiler, '-std=c++17', '-O2', '-I', str(CPP),
                   '-I', str(CPP / 'onnxruntime/include'),
                   str(Path(__file__).with_name('ocr_v6_host.cpp')),
                   str(CPP / 'ocr_v6_engine.cpp'), str(runtime),
                   '-Wl,-rpath,' + str(runtime.parent), '-o', str(binary)]
        subprocess.run(command, check=True)
        environment = os.environ.copy()
        for key in ('LD_LIBRARY_PATH', 'DYLD_LIBRARY_PATH'):
            environment[key] = str(runtime.parent) + os.pathsep + environment.get(key, '')
        for spec in specs:
            image = Image.open(FIXTURES / spec['image']).convert('RGBA')
            raw = temp / (spec['image'] + '.rgba')
            raw.write_bytes(image.tobytes())
            command = [str(binary), str(args.det.resolve()), str(args.rec.resolve()),
                       str(args.keys.resolve()), str(image.width), str(image.height), str(raw)]
            begin = time.monotonic()
            process = subprocess.run(command, check=True, text=True, capture_output=True,
                                     env=environment, timeout=120)
            output = json.loads(process.stdout)
            metrics = next((json.loads(line.removeprefix('HOST_METRICS '))
                            for line in process.stderr.splitlines() if line.startswith('HOST_METRICS ')), {})
            text = ''.join(row['text'] for row in output)
            normalized = ''.join(text.split())
            missing = [s for s in spec['required'] if ''.join(s.split()) not in normalized]
            cells = {''.join(row['text'].split()) for row in output}
            missing_cells = [s for s in spec.get('exact_cells', []) if ''.join(s.split()) not in cells]
            passed = not missing and not missing_cells and (not spec.get('empty') or not output)
            result = {'fixture': spec['image'], 'passed': passed, 'missing': missing,
                      'missing_cells': missing_cells, 'text': text, 'detections': output,
                      'host_wall_seconds': round(time.monotonic() - begin, 4), 'host_metrics': metrics}
            reports.append(result)
            print(json.dumps(result, ensure_ascii=False))
            if spec['image'] == 'clear_list.png':
                cancelled = subprocess.run(command + ['timeouts'], check=True, text=True,
                                           capture_output=True, env=environment, timeout=120)
                recovered = json.loads(cancelled.stdout)
                recovered_text = ''.join(''.join(row['text'].split()) for row in recovered)
                if any(''.join(s.split()) not in recovered_text for s in spec['required']):
                    raise AssertionError('Same-engine request failed after deadline cancellation')
                print('Deadline 0/1/20ms cancellation and same-engine recovery passed.')
    report = {'scope': 'Host production-core correctness; not Android performance',
              'model_files': {'det': args.det.name, 'rec': args.rec.name, 'keys': args.keys.name},
              'results': reports, 'passed': all(x['passed'] for x in reports)}
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
