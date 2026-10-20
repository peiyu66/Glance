#!/usr/bin/env python3
"""Export exact production grayscale ROI on macOS; measure with official cv2 5.
This validates numerical policy and generated crop, not the iOS bridge binary.
Dependencies must already be hash-verified and locally extracted; no installs.
"""
from pathlib import Path
import argparse,json,subprocess,hashlib,sys,time
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('output',type=Path);p.add_argument('baseline',type=Path);p.add_argument('dependencies',type=Path)
a=p.parse_args();root=Path(__file__).resolve().parents[2];out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
sys.path.insert(0,str(a.dependencies.resolve()/'site-packages'))
import cv2
import numpy as np
cv2.setNumThreads(1);cv2.ocl.setUseOpenCL(False)
def declaration(text,marker):
    begin=text.index(marker);opening=text.index('{',begin);depth=1;end=opening+1
    while depth:
        depth+=(text[end]=='{')-(text[end]=='}');end+=1
    return text[begin:end]
camera=(root/'App/CameraCapture.swift').read_text();metrics=(Path(__file__).parent/'Metrics.swift').read_text()
metrics=metrics.replace('let start = ProcessInfo.processInfo.systemUptime','ROIExport.name = name\n    let start = ProcessInfo.processInfo.systemUptime').replace('0..<5','0..<1')
source='import Foundation\nimport CoreGraphics\nimport CoreImage\nimport ImageIO\n'
source+=(root/'Sources/GlanceCore/FrameAnalysisGate.swift').read_text()+(root/'Sources/GlanceCore/FocusCandidateSelection.swift').read_text()
source+='''
@MainActor enum ROIExport { static var name = "" }
@MainActor enum GLOpenCVBridge {
 static func focusMetrics(gray: Data, width: Int, height: Int) throws -> [String: Any] {
  try gray.write(to: URL(fileURLWithPath: CommandLine.arguments[3]).appendingPathComponent(ROIExport.name + ".gray"))
  return ["mean": 0.5, "variance": 0.0, "tenengrad": 0.0, "laplacianVariance": 0.0]
 }
}
@MainActor enum ProductionCapture {
'''+declaration(camera,'static func visibleImage(')+'\n'+declaration(camera,'static func centralFocusQuality(')+'\n}\n'+metrics
(out/'Export.swift').write_text(source)
commands=[['xcrun','swiftc','-O','-swift-version','6','-module-cache-path',str(out/'module-cache'),str(out/'Export.swift'),'-o',str(out/'export-roi')],[str(out/'export-roi'),str(a.baseline.resolve()),str(out/'export.json'),str(out)]]
manifest={'cv2Version':cv2.__version__,'numpyVersion':np.__version__,'method':'Exact production Swift full-visible crop and central grayscale ROI; official macOS OpenCV same Gaussian/Sobel/Laplacian equations as production Objective-C++ bridge. Different platform/binary.','commands':[],'inputSHA256':{str(f.relative_to(root)):hashlib.sha256(f.read_bytes()).hexdigest() for f in [root/'App/CameraCapture.swift',root/'App/OpenCV/GLOpenCVBridge.mm',root/'Sources/GlanceCore/FocusCandidateSelection.swift',Path(__file__),Path(__file__).parent/'Metrics.swift']},'realCamera':False,'network':False}
for i,cmd in enumerate(commands):
 result=subprocess.run(cmd,capture_output=True,text=True);(out/f'command-{i}.log').write_text(result.stdout+result.stderr);manifest['commands'].append({'args':cmd,'exitCode':result.returncode});(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
 if result.returncode:print(result.stdout+result.stderr);raise SystemExit(result.returncode)
rows=json.loads((out/'export.json').read_text())
for row in rows:
 raw=np.frombuffer((out/(row['name']+'.gray')).read_bytes(),dtype=np.uint8).reshape(256,256)
 start=time.perf_counter()
 for _ in range(5):
  gray=raw.astype(np.float64)/255.0
  smooth=cv2.GaussianBlur(gray,(3,3),0.8,sigmaY=0.8,borderType=cv2.BORDER_REFLECT_101)
  gx=cv2.Sobel(smooth,cv2.CV_64F,1,0,ksize=3,borderType=cv2.BORDER_REFLECT_101)
  gy=cv2.Sobel(smooth,cv2.CV_64F,0,1,ksize=3,borderType=cv2.BORDER_REFLECT_101)
  lap=cv2.Laplacian(smooth,cv2.CV_64F,ksize=1,borderType=cv2.BORDER_REFLECT_101)
  mean,std=cv2.meanStdDev(smooth);_,lapdev=cv2.meanStdDev(lap)
  mean=float(mean[0,0]);variance=float(std[0,0]**2);ten=float(cv2.mean(gx*gx+gy*gy)[0]);lapvar=float(lapdev[0,0]**2)
 elapsed=(time.perf_counter()-start)*1000/5
 row.update(mean=mean,variance=variance,tenengrad=ten,laplacianVariance=lapvar,score=lapvar/max(variance,.000001),edgeRatio=lapvar/max(ten,.000001),cv2Milliseconds=elapsed)
 row.pop('state');row.pop('reason');row.pop('milliseconds')
(out/'numerical-metrics.json').write_text(json.dumps(rows,indent=2)+'\n')
# Feed real measured numbers through the exact production Swift policy.
policy='import Foundation\n'+(root/'Sources/GlanceCore/FocusCandidateSelection.swift').read_text()+'''
let url=URL(fileURLWithPath:CommandLine.arguments[1])
var rows = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
for index in rows.indices {
 let row=rows[index]
 let quality=CentralFocusQuality(mean:row["mean"] as! Double,variance:row["variance"] as! Double,tenengrad:row["tenengrad"] as! Double,laplacianVariance:row["laplacianVariance"] as! Double)
 rows[index]["state"]=quality.state.rawValue;rows[index]["reason"]=quality.reason.rawValue
}
try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
'''
(out/'Policy.swift').write_text(policy)
cmd=['xcrun','swiftc','-O','-module-cache-path',str(out/'module-cache'),str(out/'Policy.swift'),'-o',str(out/'policy')]
subprocess.run(cmd,check=True,capture_output=True)
subprocess.run([str(out/'policy'),str(out/'numerical-metrics.json'),str(out/'metrics.json')],check=True)
print(json.dumps({'samples':len(rows),'cv2':cv2.__version__,'output':str(out/'metrics.json')}))
