#!/usr/bin/env python3
"""Compile exact production ROI/quality code for the existing x86_64 iOS simulator.
Only generated PNGs are read; run the resulting command explicitly via simctl.
"""
from pathlib import Path
import argparse, hashlib, json, subprocess
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('output', type=Path)
p.add_argument('baseline', type=Path)
a=p.parse_args(); root=Path(__file__).resolve().parents[2]; out=a.output.resolve(); out.mkdir(parents=True, exist_ok=True)
def declaration(text, marker):
    begin=text.index(marker); opening=text.index('{',begin); depth=1; end=opening+1
    while depth:
        depth += (text[end]=='{')-(text[end]=='}'); end+=1
    return text[begin:end]
camera=(root/'App/CameraCapture.swift').read_text()
source='import Foundation\nimport CoreGraphics\nimport CoreImage\nimport ImageIO\n'
source+=(root/'Sources/GlanceCore/FrameAnalysisGate.swift').read_text()
source+=(root/'Sources/GlanceCore/FocusCandidateSelection.swift').read_text()
source+='\nenum ProductionCapture {\n'+declaration(camera,'static func visibleImage(')+'\n'+declaration(camera,'static func centralFocusQuality(')+'\n}\n'
source+=(Path(__file__).parent/'Metrics.swift').read_text()
(out/'MetricsMain.swift').write_text(source)
sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
framework=root/'Vendor/OpenCV'
commands=[['xcrun','clang++','-O2','-std=c++17','-fobjc-arc','-target','x86_64-apple-ios17.0-simulator','-isysroot',sdk,'-F',str(framework),'-c',str(root/'App/OpenCV/GLOpenCVBridge.mm'),'-o',str(out/'bridge.o')],
['xcrun','swiftc','-O','-swift-version','6','-target','x86_64-apple-ios17.0-simulator','-sdk',sdk,'-module-cache-path',str(out/'module-cache'),'-import-objc-header',str(root/'App/OpenCV/GLOpenCVBridge.h'),str(out/'MetricsMain.swift'),str(out/'bridge.o'),'-F',str(framework),'-framework','opencv2','-framework','Foundation','-framework','UIKit','-framework','Accelerate','-framework','CoreImage','-framework','CoreGraphics','-framework','ImageIO','-framework','CoreMedia','-framework','CoreVideo','-framework','AVFoundation','-lc++','-lz','-o',str(out/'focus-metrics')]]
manifest={'commands':[],'inputsSHA256':{str(f.relative_to(root)):hashlib.sha256(f.read_bytes()).hexdigest() for f in [root/'App/CameraCapture.swift',root/'App/OpenCV/GLOpenCVBridge.mm',root/'App/OpenCV/GLOpenCVBridge.h',root/'Sources/GlanceCore/FocusCandidateSelection.swift',Path(__file__),Path(__file__).parent/'Metrics.swift']},'baseline':str(a.baseline.resolve()),'realCamera':False,'network':False}
for i,cmd in enumerate(commands):
    result=subprocess.run(cmd,capture_output=True,text=True)
    (out/f'compile-{i}.log').write_text(result.stdout+result.stderr)
    manifest['commands'].append({'args':cmd,'exitCode':result.returncode})
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    if result.returncode: print(result.stdout+result.stderr); raise SystemExit(result.returncode)
print(json.dumps({'executable':str(out/'focus-metrics'),'baseline':str(a.baseline.resolve()),'output':str(out/'metrics.json')}))
