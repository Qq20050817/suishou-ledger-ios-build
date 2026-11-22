#!/usr/bin/env python3
"""Generate the small Xcode project with no package-manager dependency."""
import hashlib
import json
from pathlib import Path
import plistlib
import runpy

root = Path(__file__).resolve().parents[1]
runpy.run_path(str(root / "scripts/generate_sounds.py"), run_name="__main__")
repo = root.parent
project = root / "SuishouLedger.xcodeproj"
project.mkdir(exist_ok=True)
objects = []

def uid(label):
    return hashlib.sha256(label.encode()).hexdigest()[:24].upper()

def q(value):
    return json.dumps(value, ensure_ascii=False)

def add(label, body):
    objects.append(f"{uid(label)} = {{ {body} }};")
    return uid(label)

sources = ["../main.m"] + [str(p.relative_to(root)) for p in sorted((root / "App").glob("*.swift"))]
icons = ["../icons/" + p.name for p in sorted((repo / "icons").glob("*.png")) if p.name != "original.png"]
sounds = [str(p.relative_to(root)) for p in sorted((root / "Resources").glob("*.wav"))]
refs, source_build, resource_build = [], [], []
for path in sources + icons + sounds:
    kind = "sourcecode.c.objc" if path.endswith(".m") else "sourcecode.swift" if path.endswith(".swift") else "audio.wav" if path.endswith(".wav") else "image.png"
    ref = add("file:" + path, f'isa = PBXFileReference; lastKnownFileType = {kind}; path = {q(path)}; sourceTree = "<group>";')
    refs.append(ref)
    build = add("build:" + path, f"isa = PBXBuildFile; fileRef = {ref};")
    (source_build if path in sources else resource_build).append(build)

app = add("app", 'isa = PBXFileReference; explicitFileType = wrapper.application; path = SuishouLedger.app; sourceTree = BUILT_PRODUCTS_DIR;')
product = add("product", f"isa = XCSwiftPackageProductDependency; productName = ReceiptCore;")
package = add("package", 'isa = XCLocalSwiftPackageReference; relativePath = ".";')
framework = add("core-link", f"isa = PBXBuildFile; productRef = {product};")
src = add("sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({','.join(source_build)},); runOnlyForDeploymentPostprocessing = 0;")
res = add("resources", f"isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({','.join(resource_build)},); runOnlyForDeploymentPostprocessing = 0;")
fw = add("frameworks", f"isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({framework},); runOnlyForDeploymentPostprocessing = 0;")
test_file = add("test-file", 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RenderTests/ReceiptRenderTests.swift; sourceTree = "<group>";')
refs.append(test_file)
test_build = add("test-build", f"isa = PBXBuildFile; fileRef = {test_file};")
test_core = add("test-core", f"isa = PBXBuildFile; productRef = {product};")
test_sources = add("test-sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({test_build},); runOnlyForDeploymentPostprocessing = 0;")
test_frameworks = add("test-frameworks", f"isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({test_core},); runOnlyForDeploymentPostprocessing = 0;")
test_app = add("test-app", 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = ReceiptRenderTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
dependency = add("test-dependency", f"isa = PBXTargetDependency; target = {uid('target')};")
products = add("products", f'isa = PBXGroup; children = ({app},{test_app},); name = Products; sourceTree = "<group>";')
group = add("group", f'isa = PBXGroup; children = ({",".join(refs)},{products},); sourceTree = "<group>";')

for config in ["Debug", "Release"]:
    settings = {
        "PRODUCT_BUNDLE_IDENTIFIER": "com.qq2301796536.suishouledger",
        "PRODUCT_NAME": "SuishouLedger", "INFOPLIST_FILE": "Info.plist",
        "IPHONEOS_DEPLOYMENT_TARGET": "26.0", "SDKROOT": "iphoneos",
        "SWIFT_VERSION": "6.0", "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
        "TARGETED_DEVICE_FAMILY": "1,2", "CODE_SIGN_STYLE": "Automatic",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if config == "Debug" else "-O",
        "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
        "SWIFT_EMIT_LOC_STRINGS": "YES", "ENABLE_APP_INTENTS_METADATA_GENERATION": "YES",
        "ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES": "YES",
        "ENABLE_TESTABILITY": "YES" if config == "Debug" else "NO",
        "GCC_PREPROCESSOR_DEFINITIONS": "$(inherited) DEBUG=1" if config == "Debug" else "$(inherited)",
    }
    body = " ".join(f"{k} = {q(v)};" for k,v in settings.items())
    add("target-"+config, f"isa = XCBuildConfiguration; name = {config}; buildSettings = {{ {body} }};")
    add("project-"+config, f"isa = XCBuildConfiguration; name = {config}; buildSettings = {{}};")
    test_settings = dict(settings)
    test_settings.pop("INFOPLIST_FILE")
    test_settings.update(PRODUCT_NAME="ReceiptRenderTests", PRODUCT_BUNDLE_IDENTIFIER="com.qq2301796536.suishouledger.render-tests", GENERATE_INFOPLIST_FILE="YES", TEST_HOST="$(BUILT_PRODUCTS_DIR)/SuishouLedger.app/SuishouLedger", BUNDLE_LOADER="$(TEST_HOST)")
    test_body = " ".join(f"{k} = {q(v)};" for k,v in test_settings.items())
    add("tests-"+config, f"isa = XCBuildConfiguration; name = {config}; buildSettings = {{ {test_body} }};")
for scope in ["target", "project", "tests"]:
    add(scope+"-configs", f"isa = XCConfigurationList; buildConfigurations = ({uid(scope+'-Debug')},{uid(scope+'-Release')},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")

add("target", f"isa = PBXNativeTarget; buildConfigurationList = {uid('target-configs')}; buildPhases = ({src},{fw},{res},); buildRules = (); dependencies = (); name = SuishouLedger; packageProductDependencies = ({product},); productName = SuishouLedger; productReference = {app}; productType = \"com.apple.product-type.application\";")
add("tests-target", f"isa = PBXNativeTarget; buildConfigurationList = {uid('tests-configs')}; buildPhases = ({test_sources},{test_frameworks},); buildRules = (); dependencies = ({dependency},); name = ReceiptRenderTests; packageProductDependencies = ({product},); productName = ReceiptRenderTests; productReference = {test_app}; productType = \"com.apple.product-type.bundle.unit-test\";")
add("project", f"isa = PBXProject; attributes = {{ LastUpgradeCheck = 2600; }}; buildConfigurationList = {uid('project-configs')}; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = zh-Hans; hasScannedForEncodings = 0; knownRegions = (en,zh-Hans,Base,); mainGroup = {group}; productRefGroup = {products}; packageReferences = ({package},); projectDirPath = \"\"; projectRoot = \"\"; targets = ({uid('target')},{uid('tests-target')},);")
(project / "project.pbxproj").write_text("// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n"+"\n".join(objects)+f"\n}}; rootObject = {uid('project')}; }}\n")
scheme = project / "xcshareddata/xcschemes/SuishouLedger.xcscheme"
scheme.parent.mkdir(parents=True, exist_ok=True)
scheme.write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('target')}" BuildableName="SuishouLedger.app" BlueprintName="SuishouLedger" ReferencedContainer="container:SuishouLedger.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="NO"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('tests-target')}" BuildableName="ReceiptRenderTests.xctest" BlueprintName="ReceiptRenderTests" ReferencedContainer="container:SuishouLedger.xcodeproj"/></TestableReference></Testables><EnvironmentVariables><EnvironmentVariable key="RECEIPT_RENDER_TESTS" value="1" isEnabled="YES"/></EnvironmentVariables></TestAction><LaunchAction buildConfiguration="Debug"/><ProfileAction buildConfiguration="Release"/><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
info = plistlib.loads((repo / "Info.plist").read_bytes())
info.update(CFBundleIdentifier="$(PRODUCT_BUNDLE_IDENTIFIER)", CFBundleExecutable="$(EXECUTABLE_NAME)", CFBundleShortVersionString="3.0.8", CFBundleVersion="20", MinimumOSVersion="$(IPHONEOS_DEPLOYMENT_TARGET)")
info.pop("UIDeviceFamily", None)
(root / "Info.plist").write_bytes(plistlib.dumps(info, sort_keys=False))
print("Generated Xcode project for native receipt cards; legacy build script and Info.plist preserved.")
