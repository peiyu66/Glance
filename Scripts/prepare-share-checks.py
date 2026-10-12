#!/usr/bin/env python3
"""Build a simulator-only share harness; no camera, credentials or network."""
from pathlib import Path
import hashlib,json,shutil,sys
root=Path(__file__).resolve().parent.parent
out=Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=True)
source=(root/'App/CameraView.swift').read_text()
checks=(root/'Scripts/ShareFixture/ControllerChecks.swift').read_text()
(out/'CameraView.swift').write_text(source+'\n'+checks)
inputs=sorted((root/'Sources/GlanceCore').glob('*.swift'))+[root/'App/CameraCapture.swift',root/'App/SIWCView.swift',root/'App/SIWCStorageNetwork.swift',root/'App/SIWCLoopback.swift',root/'Scripts/ShareFixture/FixtureApp.swift',root/'Scripts/ShareFixture/ShareUITests.swift']
for p in inputs:shutil.copyfile(p,out/p.name)
# Preserve production authentication files. The dedicated harness replaces only
# Keychain and URLSession construction so it cannot read credentials or contact a server.
p=out/'SIWCStorageNetwork.swift';network=p.read_text()
a=network.index('enum SIWCKeychain {');b=network.index('struct SIWCHTTPError:',a)
network=network[:a]+"enum SIWCKeychain { static func load() throws -> SIWCSaved? { nil }; static func save(_ value:SIWCSaved) throws { throw SIWCError.invalidResponse } }\n\n"+network[b:]
needle='let config = URLSessionConfiguration.ephemeral'
assert network.count(needle)==1
network=network.replace(needle,needle+'\n        config.protocolClasses = [ShareFixtureBlockedNetwork.self]')
network+='''
final class ShareFixtureBlockedNetwork: URLProtocol, @unchecked Sendable {
    private static let lock=NSLock()
    nonisolated(unsafe) private static var attempts=0
    static var attemptedRequests:Int { lock.withLock { attempts } }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.attempts += 1 }
        client?.urlProtocol(self,didFailWithError:URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
'''
p.write_text(network)

(out/'source-hashes.json').write_text(json.dumps({'productionCameraViewSHA256':hashlib.sha256(source.encode()).hexdigest(),'controllerChecksSHA256':hashlib.sha256(checks.encode()).hexdigest(),'inputs':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}},indent=2))
objects=[]
def add(n,body): objects.append(f'{n:024X} = {{ {body} }};');return f'{n:024X}'
def ids(values):return '('+','.join(f'{n:024X}' for n in values)+',)'
appfiles=[p.name for p in inputs if p.name!='ShareUITests.swift']+['CameraView.swift']
appbuild=[];refs=[]
for i,name in enumerate(appfiles+['ShareUITests.swift']):
 ref=100+i*2;build=ref+1;refs.append(ref)
 add(ref,f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{name}"; sourceTree = "<group>";')
 add(build,f'isa = PBXBuildFile; fileRef = {ref:024X};')
 if name!='ShareUITests.swift':appbuild.append(build)
 else:testbuild=build
add(1,'isa = PBXProject; buildConfigurationList = '+f'{20:024X}; compatibilityVersion = "Xcode 14.0"; mainGroup = {2:024X}; productRefGroup = {3:024X}; projectDirPath = ""; targets = '+ids([4,5])+';')
add(2,'isa = PBXGroup; children = '+ids(refs+[3])+'; sourceTree = "<group>";')
add(3,'isa = PBXGroup; children = '+ids([6,7])+'; name = Products; sourceTree = "<group>";')
add(6,'isa = PBXFileReference; explicitFileType = wrapper.application; path = ShareFixture.app; sourceTree = BUILT_PRODUCTS_DIR;')
add(7,'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = ShareUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
for n,name,product,config,phases,kind in [(4,'ShareFixture',6,21,[8,10],'application'),(5,'ShareUITests',7,22,[9,11],'bundle.ui-testing')]:
 add(n,f'isa = PBXNativeTarget; buildConfigurationList = {config:024X}; buildPhases = '+ids(phases)+f'; buildRules = (); dependencies = (); name = {name}; productName = {name}; productReference = {product:024X}; productType = "com.apple.product-type.{kind}";')
for n,builds in [(8,appbuild),(9,[testbuild])]: add(n,'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = '+ids(builds)+'; runOnlyForDeploymentPostprocessing = 0;')
for n in [10,11]:add(n,'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
common='SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SWIFT_VERSION = 6.0; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; CODE_SIGNING_ALLOWED = NO;'
app='PRODUCT_BUNDLE_IDENTIFIER = local.peiyu.Glance.R2PublicShareFixture; PRODUCT_NAME = "$(TARGET_NAME)"; TARGETED_DEVICE_FAMILY = "1,2"; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_UILaunchScreen_Generation = YES; INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";'
test='PRODUCT_BUNDLE_IDENTIFIER = local.peiyu.Glance.ShareUITests; PRODUCT_NAME = "$(TARGET_NAME)"; GENERATE_INFOPLIST_FILE = YES; TEST_TARGET_NAME = ShareFixture; TARGETED_DEVICE_FAMILY = "1,2";'
for n,settings in [(23,common),(24,app),(25,test)]:add(n,f'isa = XCBuildConfiguration; buildSettings = {{ {settings} }}; name = Debug;')
for n,config in [(20,23),(21,24),(22,25)]:add(n,'isa = XCConfigurationList; buildConfigurations = '+ids([config])+'; defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;')
project=out/'ShareFixture.xcodeproj';project.mkdir(exist_ok=True)
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {1:024X};}}')
schemes=project/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True)
def reference(n,name):return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{n:024X}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:ShareFixture.xcodeproj"/>'
(schemes/'ShareFixture.xcscheme').write_text('<?xml version="1.0" encoding="UTF-8"?><Scheme version="1.3"><BuildAction><BuildActionEntries>'+''.join('<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">'+reference(n,name)+'</BuildActionEntry>' for n,name in [(4,'ShareFixture.app'),(5,'ShareUITests.xctest')])+'</BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">'+reference(5,'ShareUITests.xctest')+'</TestableReference></Testables></TestAction></Scheme>')
print(out)
