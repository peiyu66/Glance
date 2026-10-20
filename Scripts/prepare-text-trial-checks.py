#!/usr/bin/env python3
"""Compile the real bounded text controller/transport with synthetic credentials and blocked network."""
from pathlib import Path
import hashlib,json,shutil,sys
root=Path(__file__).resolve().parent.parent
out=Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=True)
readiness_only='--readiness-only' in sys.argv[2:]
inputs=sorted((root/'Sources/GlanceCore').glob('*.swift'))+[root/'App/SIWCStorageNetwork.swift',root/'App/BoundedTextTrialView.swift',root/'App/FixedTextTrialCatalog.swift',root/'Scripts/TextTrialFixture/FixtureApp.swift',root/'Scripts/TextTrialFixture/CaptureUITests.swift']
for p in inputs:shutil.copyfile(p,out/p.name)
p=out/'SIWCStorageNetwork.swift';s=p.read_text();a=s.index('enum SIWCKeychain {');b=s.index('/// Fixed reason plus OSStatus',a)
s=s[:a]+"enum SIWCKeychain { static func load() throws -> SIWCSaved? { preconditionFailure(\"fixture must inject synthetic account\") }; static func loadForTextTrial() throws -> SIWCSaved? { preconditionFailure(\"fixture must inject synthetic account\") }; static func saveForTextTrial(_ value:SIWCSaved) throws { preconditionFailure(\"inject synthetic save\") }; static func save(_ value:SIWCSaved) throws { preconditionFailure(\"no credential writes\") } }\n\n"+s[b:]
needle='let config = configurationOverride ?? URLSessionConfiguration.ephemeral';assert s.count(needle)==1
s=s.replace(needle,needle+'\n        config.protocolClasses = [TextTrialProtocol.self]')
p.write_text(s)
(out/'source-hashes.json').write_text(json.dumps({'inputs':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},'keychainStubbed':True,'networkAlwaysIntercepted':True,'readinessOnly':readiness_only},indent=2))
objects=[]
def add(n,body): objects.append(f'{n:024X} = {{ {body} }};');return f'{n:024X}'
def ids(values):return '('+','.join(f'{n:024X}' for n in values)+',)'
appfiles=[p.name for p in inputs if p.name != 'CaptureUITests.swift']
appbuild=[];refs=[]
for i,name in enumerate(appfiles+['CaptureUITests.swift']):
 ref=100+i*2;build=ref+1;refs.append(ref)
 add(ref,f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{name}"; sourceTree = "<group>";')
 add(build,f'isa = PBXBuildFile; fileRef = {ref:024X};')
 if name!='CaptureUITests.swift':appbuild.append(build)
 else:testbuild=build
add(1,'isa = PBXProject; buildConfigurationList = '+f'{20:024X}; compatibilityVersion = "Xcode 14.0"; mainGroup = {2:024X}; productRefGroup = {3:024X}; projectDirPath = ""; targets = '+ids([4,5])+';')
add(2,'isa = PBXGroup; children = '+ids(refs+[3])+'; sourceTree = "<group>";')
add(3,'isa = PBXGroup; children = '+ids([6,7])+'; name = Products; sourceTree = "<group>";')
add(6,'isa = PBXFileReference; explicitFileType = wrapper.application; path = CaptureFixture.app; sourceTree = BUILT_PRODUCTS_DIR;')
add(7,'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = CaptureUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
for n,name,product,config,phases,kind in [(4,'CaptureFixture',6,21,[8,10],'application'),(5,'CaptureUITests',7,22,[9,11],'bundle.ui-testing')]:
 add(n,f'isa = PBXNativeTarget; buildConfigurationList = {config:024X}; buildPhases = '+ids(phases)+f'; buildRules = (); dependencies = (); name = {name}; productName = {name}; productReference = {product:024X}; productType = "com.apple.product-type.{kind}";')
for n,builds in [(8,appbuild),(9,[testbuild])]: add(n,'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = '+ids(builds)+'; runOnlyForDeploymentPostprocessing = 0;')
for n in [10,11]:add(n,'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
common='SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SWIFT_VERSION = 6.0; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; CODE_SIGNING_ALLOWED = NO;'
if readiness_only: common += ' SWIFT_ACTIVE_COMPILATION_CONDITIONS = GLANCE_READINESS_DIAGNOSTIC;'
app='PRODUCT_BUNDLE_IDENTIFIER = local.peiyu.Glance.TextTrialFixture; PRODUCT_NAME = "$(TARGET_NAME)"; MARKETING_VERSION = 7.8.9; CURRENT_PROJECT_VERSION = 48; TARGETED_DEVICE_FAMILY = "1,2"; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_UILaunchScreen_Generation = YES; INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription = "Save the selected synthetic recognition image."; INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";'
if readiness_only: app=app.replace('CURRENT_PROJECT_VERSION = 48', 'CURRENT_PROJECT_VERSION = 47')
test='PRODUCT_BUNDLE_IDENTIFIER = local.peiyu.Glance.TextTrialUITests; PRODUCT_NAME = "$(TARGET_NAME)"; GENERATE_INFOPLIST_FILE = YES; TEST_TARGET_NAME = CaptureFixture; TARGETED_DEVICE_FAMILY = "1,2";'
for n,settings in [(23,common),(24,app),(25,test)]:add(n,f'isa = XCBuildConfiguration; buildSettings = {{ {settings} }}; name = Debug;')
for n,config in [(20,23),(21,24),(22,25)]:add(n,'isa = XCConfigurationList; buildConfigurations = '+ids([config])+'; defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;')
project=out/'CaptureFixture.xcodeproj';project.mkdir(exist_ok=True)
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {1:024X};}}')
schemes=project/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True)
def reference(n,name):return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{n:024X}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:CaptureFixture.xcodeproj"/>'
(schemes/'CaptureFixture.xcscheme').write_text('<?xml version="1.0" encoding="UTF-8"?><Scheme version="1.3"><BuildAction><BuildActionEntries>'+''.join('<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">'+reference(n,name)+'</BuildActionEntry>' for n,name in [(4,'CaptureFixture.app'),(5,'CaptureUITests.xctest')])+'</BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">'+reference(5,'CaptureUITests.xctest')+'</TestableReference></Testables></TestAction></Scheme>')
print(out)
