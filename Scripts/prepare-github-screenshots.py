#!/usr/bin/env python3
"""Prepare a simulator-only screenshot host. Never edits production files."""
from pathlib import Path
import hashlib,json,subprocess,sys
root=Path(__file__).resolve().parent.parent
out=Path(sys.argv[1]);assert not out.exists(), 'Keep prior evidence; choose a fresh output directory'
subprocess.run([sys.executable,'-B',str(root/'Scripts/prepare-single-capture-checks.py'),str(out)],check=True)
app=out/'FixtureApp.swift';s=app.read_text();needle='if ProcessInfo.processInfo.arguments.contains("--background62-checks")'
assert s.count(needle)==1;s=s.replace(needle,'if ProcessInfo.processInfo.arguments.contains("--readme-screenshots") { ReadmeScreenshotView() }\n            else '+needle)
app.write_text(s+'\n'+(root/'Scripts/GitHubScreenshots/Fixture.swift').read_text())
view=out/'SingleCaptureView.swift';s=view.read_text();needle='Text("合成預覽").font(.caption).foregroundStyle(.white)'
assert s.count(needle)==1
replacement='VStack(spacing: 12) { Image(systemName: "camera").font(.system(size: 30)); Text("鏡頭預覽區").font(.title3.weight(.semibold)); Text("模擬器示意 · 未啟用相機").font(.caption) }.foregroundStyle(.white)'
view.write_text(s.replace(needle,replacement))
test=out/'CaptureUITests.swift';test.write_text(test.read_text()+'\n'+(root/'Scripts/GitHubScreenshots/Tests.swift').read_text())
project=out/'CaptureFixture.xcodeproj/project.pbxproj';s=project.read_text().replace('MARKETING_VERSION = 7.8.9; CURRENT_PROJECT_VERSION = 321;','MARKETING_VERSION = 0.1.0; CURRENT_PROJECT_VERSION = 70;');project.write_text(s)
manifest={'fixtureOnlyChanges':['synthetic preview label','deterministic invented archive/JSON/source','screenshot XCTest','fixture bundle version70'],'productionFilesModified':False,'realCamera':False,'realOAuth':False,'realAI':False,'inputSHA256':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [root/'Scripts/GitHubScreenshots/Fixture.swift',root/'Scripts/GitHubScreenshots/Tests.swift',Path(__file__).resolve()]}}
(out/'screenshot-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
