#!/usr/bin/env python3
"""Save generated focus samples and measure the unchanged production crop/quality.
No camera, network, account, app build or installation. Requires macOS Swift SDK.
"""
from pathlib import Path
import argparse, datetime, hashlib, json, subprocess, os

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('output', type=Path)
a = p.parse_args()
root = Path(__file__).resolve().parents[2]
out = a.output.resolve()
if out.exists():
    p.error('Choose a new output directory; preserve previous baseline evidence.')
out.mkdir(parents=True)

def declaration(text, marker):
    begin = text.index(marker)
    opening = text.index('{', begin)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[begin:end]

camera = (root / 'App/CameraCapture.swift').read_text()
pipeline = (root / 'Sources/GlanceCore/CameraPipeline.swift').read_text()
parts = [
    'import Foundation\nimport CoreGraphics\nimport CoreImage\nimport ImageIO\nimport UniformTypeIdentifiers\n',
    declaration(pipeline, 'public struct SceneFingerprint:'),
    declaration(pipeline, 'public struct SceneQuality:'),
    'enum ProductionCapture {',
    declaration(camera, 'static func centralImage('),
    declaration(camera, 'static func fingerprint('),
    '}',
    (Path(__file__).parent / 'Samples.swift').read_text(),
]
(out / 'Baseline.swift').write_text('\n'.join(parts))
inputs = ['App/CameraCapture.swift', 'Sources/GlanceCore/CameraPipeline.swift',
          'Sources/GlanceCore/CameraFocusGate.swift', 'App/SingleCaptureController.swift',
          'App/SingleCaptureView.swift', 'Verification/FocusBaseline/Samples.swift',
          'Verification/FocusBaseline/run-baseline.py']
metadata = {
    'createdAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'baseCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
    'sourceHashes': {f: hashlib.sha256((root / f).read_bytes()).hexdigest() for f in inputs},
    'sampleOrigin': 'Deterministic generated grayscale targets; no personal images',
    'method': 'Exact declarations extracted from production centralImage, fingerprint, SceneFingerprint and SceneQuality',
    'limitations': ['macOS Core Image rendering with production options, not iOS optical evidence',
                   'Gaussian blur is a controlled perturbation, not a calibrated defocus model',
                   'No new sharpness threshold or production policy adopted',
                   'Saved PNGs precede production JPEG encoding; color/codec effects not measured'],
    'realCamera': False, 'network': False, 'deviceOperations': False,
}
env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(out / 'module-cache'))
commands = [
    ['xcrun', 'swiftc', '-O', '-module-cache-path', str(out / 'module-cache'), str(out / 'Baseline.swift'), '-o', str(out / 'baseline')],
    [str(out / 'baseline'), str(out)],
]
for i, command in enumerate(commands):
    start = datetime.datetime.now(datetime.timezone.utc)
    result = subprocess.run(command, env=env, capture_output=True, text=True)
    (out / f'command-{i}.log').write_text(result.stdout + result.stderr)
    metadata.setdefault('commands', []).append({'args': command, 'exitCode': result.returncode,
        'startedAt': start.isoformat(), 'endedAt': datetime.datetime.now(datetime.timezone.utc).isoformat()})
    if result.returncode:
        (out / 'manifest.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n')
        print(result.stdout + result.stderr)
        raise SystemExit(result.returncode)
metadata['artifactsSHA256'] = {str(f.relative_to(out)): hashlib.sha256(f.read_bytes()).hexdigest()
    for f in out.rglob('*') if f.is_file() and (f.suffix == '.png' or f.name in ['metrics.json', 'Baseline.swift'])}
(out / 'manifest.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n')
rows = json.loads((out / 'metrics.json').read_text())
print(json.dumps({'samples': len(rows), 'currentQualityPassed': sum(row['usable'] for row in rows),
                  'output': str(out)}, ensure_ascii=False))
