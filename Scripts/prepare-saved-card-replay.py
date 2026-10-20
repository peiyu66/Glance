#!/usr/bin/env python3
"""Prepare local-only UI replay using four explicitly supplied saved trials."""
from pathlib import Path
import base64, hashlib, json, subprocess, sys

repo = Path(__file__).resolve().parent.parent
out, inputs, responses = map(Path, sys.argv[1:4])
assert not out.exists(), 'Use a fresh output folder to preserve prior evidence'
subprocess.run([sys.executable, str(repo/'Scripts/prepare-single-capture-checks.py'), str(out)], check=True)
def digest(data): return hashlib.sha256(data).hexdigest()
values=[]; evidence=[]
for n in [152,153,149,147]:
    request=(inputs/f'{n}.json').read_bytes()
    payload=json.loads(request)['input'][1]['content'][0]['text'].encode()
    response=(responses/f'response-{n}.json').read_bytes()
    p=json.loads(payload); a=json.loads(response)
    assert a['decision']=='selected'
    assert json.loads(p['raw_stage_one_json'])['schema_version']==16
    values.append(f'{n}: ["{base64.b64encode(payload).decode()}", "{base64.b64encode(response).decode()}"]')
    evidence.append({'sequence':n,'requestSHA256':digest(request),'payloadSHA256':digest(payload),'responseSHA256':digest(response),'originalFirstRawSHA256':digest(p['raw_stage_one_json'].encode())})
data='\nenum ReplaySamples { static let values: [Int:[String]] = [\n'+',\n'.join(values)+'\n] }\n'
support=repo/'Scripts/SavedTextCardReplay'
with (out/'Semantic45Checks.swift').open('a') as f: f.write('\n'+(support/'Fixture.swift').read_text()+data)
with (out/'CaptureUITests.swift').open('a') as f: f.write('\n'+(support/'UITests.swift').read_text()+data)
with (out/'SingleCaptureController.swift').open('a') as f: f.write('\n'+(support/'ControllerHook.swift').read_text())
entry=out/'FixtureApp.swift'; text=entry.read_text()
needle='if ProcessInfo.processInfo.arguments.contains("--semantic45-checks")'
assert text.count(needle)==1
text=text.replace(needle,'if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--saved-card=") }) { SavedCardReplayView() }\n            else '+needle)
entry.write_text(text)
paths=['App/SingleCaptureController.swift','App/SingleCaptureView.swift','App/CameraView.swift','Sources/GlanceCore/RecognitionArchive.swift','Sources/GlanceCore/WikipediaSemanticReview.swift','Sources/GlanceCore/CameraPipeline.swift','Sources/GlanceCore/SearchIdentity.swift']
comparison={}
for path in paths:
    current=(repo/path).read_bytes()
    old=subprocess.check_output(['git','show',f'4c5b05d8de0b51d8f645b13650928b984cad530a:{path}'],cwd=repo)
    comparison[path]={'matchesBuild45':current==old,'SHA256':digest(current)}
assert all(v['matchesBuild45'] for v in comparison.values())
manifest={'samples':evidence,'productionMatchesBuild45':comparison,'allNetworkBlocked':True,'realKeychainDisabled':True,'image':'generated placeholder','fixtureHook':'first-stage persistence boundary; original controller body unchanged', 'firstStageAdapter':'P18 fields to schema17; raw v16 unchanged','fixtureSources':{p.name:digest(p.read_bytes()) for p in support.glob('*.swift')}}
(out/'saved-replay-input-evidence.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'samples':len(evidence),'productionFilesMatchBuild45':len(comparison),'output':str(out)}))
