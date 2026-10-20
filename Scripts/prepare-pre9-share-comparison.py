#!/usr/bin/env python3
"""Isolate the pre-Build9 share transport and text format in the existing safe fixture.
Keeps current synthetic input/resolver to compare the same document and URL.
Never builds or installs a production app, starts a camera, or uses real accounts.
"""
from pathlib import Path
import subprocess, sys, json, hashlib
root = Path(__file__).resolve().parent.parent
out = Path(sys.argv[1]).resolve()
subprocess.run([sys.executable, str(root/'Scripts/prepare-single-capture-checks.py'), str(out)], check=True)
revision = subprocess.check_output(['git', 'rev-parse', '7930be1^'], cwd=root, text=True).strip()
old = subprocess.check_output(['git', 'show', revision+':App/CameraView.swift'], cwd=root, text=True)
start = 'struct RecognitionShareButton: UIViewRepresentable {'
end = '/// A selected immutable entry keeps its reading position while new answers arrive.'
old_button = old[old.index(start):old.index(end, old.index(start))]
p = out/'CameraView.swift'; current = p.read_text()
a = current.index(start); b = current.index(end, a)
p.write_text(current[:a] + old_button + current[b:])
old_archive = subprocess.check_output(['git', 'show', revision+':Sources/GlanceCore/RecognitionArchive.swift'], cwd=root, text=True)
start = '    public func shareText(at date: Date = Date()) -> String {'
a = old_archive.index(start); b = old_archive.index('    public func captureTimestamp', a)
old_text = old_archive[a:b]
p = out/'RecognitionArchive.swift'; current = p.read_text()
needle = '    public func shareText(at date: Date = Date()) -> String { shareDocument(at: date).plainText }\n'
assert current.count(needle) == 1
p.write_text(current.replace(needle, old_text))
p = out/'SingleCaptureView.swift'; current = p.read_text()
needle = 'return .init(text: document.plainText, jpeg: jpeg, document: document)'
assert current.count(needle) == 1
# The contemporary view creates a rich document; route the snapshot's text back
# through the verbatim pre9 shareText so the old text format actually reaches UIKit.
p.write_text(current.replace(needle, 'return .init(text: current.shareText(), jpeg: jpeg, document: document)'))
p = out/'FixtureApp.swift'; current = p.read_text()
needle = 'prepared = true; status = "ready-\\(model.records.count)"'
assert current.count(needle) == 1
p.write_text(current.replace(needle, 'prepared = true; status = "ready-pre9-\\(model.records.count)"'))
report = {'sourceCommit': revision, 'sourceRelationship': '7930be1^',
          'oldShareButtonSHA256': hashlib.sha256(old_button.encode()).hexdigest(),
          'oldShareTextSHA256': hashlib.sha256(old_text.encode()).hexdigest(),
          'verbatimLegacySections': True, 'commonCurrentResolverAndSyntheticInputs': True,
          'fullHistoricalAppRebuild': False, 'noKeychain': True, 'networkBlocked': True,
          'generatedHashes': {name: hashlib.sha256((out/name).read_bytes()).hexdigest() for name in ['CameraView.swift', 'RecognitionArchive.swift', 'SingleCaptureView.swift']}}
(out/'pre9-comparison-manifest.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report))
