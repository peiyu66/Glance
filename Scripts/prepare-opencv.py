#!/usr/bin/env python3
"""Obtain the pinned official framework. Never invoked implicitly by an app build."""
import argparse, hashlib, json, subprocess, tempfile, urllib.request
from pathlib import Path
VERSION = '5.0.0'
SHA256 = 'c844d3466f7999b6e920d4ee53c71310c4cdd34b13f1547f373723834e308b0e'
URL = f'https://github.com/opencv/opencv/releases/download/{VERSION}/opencv-{VERSION}-ios-framework.zip'
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--archive', type=Path, help='Use an already downloaded official ZIP; still verify its hash.')
p.add_argument('--destination', type=Path, default=Path(__file__).resolve().parent.parent / 'Vendor/OpenCV')
a = p.parse_args()
if a.destination.exists(): p.error('Destination already exists; choose a new destination to preserve existing files.')
with tempfile.TemporaryDirectory(prefix='glance-opencv-') as temp:
    archive = a.archive or Path(temp) / 'opencv.zip'
    if not a.archive: urllib.request.urlretrieve(URL, archive)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != SHA256: raise SystemExit('OpenCV ZIP hash mismatch; nothing extracted.')
    subprocess.run(['/usr/bin/ditto', '-x', '-k', str(archive.resolve()), str(a.destination)], check=True)
    framework = a.destination / 'opencv2.framework'
    if not (framework / 'opencv2').is_file(): raise SystemExit('Verified archive did not produce the expected framework.')
    (a.destination / 'source.json').write_text(json.dumps({'version': VERSION, 'url': URL, 'archiveSHA256': digest}, indent=2) + '\n')
print(f'Prepared official OpenCV {VERSION}: {a.destination}')
