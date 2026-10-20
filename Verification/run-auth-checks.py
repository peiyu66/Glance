from pathlib import Path
import subprocess,sys
root=Path(__file__).resolve().parent.parent
out=Path(sys.argv[1]) if len(sys.argv)>1 else root/'Verification/auth-output'
out.mkdir(parents=True,exist_ok=True)
controller=(root/'App/SIWCView.swift').read_text().split('\nstruct SIWCView: View {',1)[0]
(out/'ControllerUnderTest.swift').write_text(controller+(root/'Verification/AuthChecks/FixtureBody.swift').read_text())
files=sorted((root/'Sources/GlanceCore').glob('*.swift'))+[root/'App/SIWCStorageNetwork.swift',root/'App/SIWCLoopback.swift',root/'Verification/AuthChecks/MacShims.swift',out/'ControllerUnderTest.swift']
cmd=['xcrun','swiftc','-swift-version','6','-parse-as-library','-target','arm64-apple-macos15.0','-module-cache-path',str(out/'module-cache')]+[str(p) for p in files]+['-o',str(out/'check')]
subprocess.run(cmd,check=True)
subprocess.run([str(out/'check'),'--siwc-auth-fixture',str(out/'result.json')],check=True,timeout=90)
