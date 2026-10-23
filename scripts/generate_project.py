#!/usr/bin/env python3
"""Generate the two-target Xcode project using only the Python standard library."""
import hashlib
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXTERNAL_ROOT = Path("/Volumes/8TB/cinesomatic-director-work").resolve(strict=False)
objects = {}


def ref(key):
    return hashlib.sha256(key.encode()).hexdigest()[:24].upper()


def add(key, isa, **fields):
    objects[ref(key)] = dict(isa=isa, **fields)
    return ref(key)


def file(path, type):
    return add(path, "PBXFileReference", lastKnownFileType=type, path=path, sourceTree="<group>")


shared = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "Sources/Shared").glob("*.swift"))
recording = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "Sources/Recording").glob("*.swift"))
app = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "Sources/App").iterdir() if p.suffix in (".swift", ".metal")) + shared + recording
native = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "Sources/DeckLinkBackend").iterdir() if p.suffix in (".h", ".mm", ".inc"))
app += native
camera = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "Sources/CameraExtension").glob("*.swift")) + [
    "Sources/Shared/VideoContract.swift", "Sources/Shared/VideoBufferLayout.swift",
    "Sources/Shared/VirtualCameraRegistry.swift",
    "Sources/Shared/VirtualCameraRegistryTransport.swift",
]
def source_type(path):
    if path.endswith(".metal"): return "sourcecode.metal"
    if path.endswith(".mm"): return "sourcecode.cpp.objcpp"
    if path.endswith((".h", ".inc")): return "sourcecode.c.h"
    return "sourcecode.swift"
source_refs = {path: file(path, source_type(path)) for path in sorted(set(app + camera))}
icon_catalog = "Config/Assets.xcassets"
icon_catalog_ref = file(icon_catalog, "folder.assetcatalog")


def contained_path(value, root, label):
    candidate = Path(value).expanduser().resolve(strict=False)
    if candidate == root or not candidate.is_relative_to(root):
        raise SystemExit(f"{label} must be inside {root}.")
    return str(candidate)


# The SDK interfaces are in the repo; an override must stay in the repo or the external workspace.
sdk_override = os.environ.get("DECKLINK_SDK_DIR")
sdk_dir = (str((ROOT / "ThirdParty/DeckLinkSDK/include").resolve()) if sdk_override is None
  else contained_path(sdk_override, ROOT if Path(sdk_override).expanduser().resolve(strict=False).is_relative_to(ROOT)
    else EXTERNAL_ROOT, "DECKLINK_SDK_DIR"))
auto_switcher_lib_dir = os.environ.get(
    "AUTO_SWITCHER_LIB_DIR",
    "$(SRCROOT)/Tools/auto-switcher/target/release",
)
if "$(" not in auto_switcher_lib_dir:
    auto_switcher_lib_dir = contained_path(auto_switcher_lib_dir, ROOT, "AUTO_SWITCHER_LIB_DIR")
dispatch_path = str(Path(sdk_dir) / "DeckLinkAPIDispatch.cpp")
source_refs[dispatch_path] = add("sdk-dispatch-reference", "PBXFileReference", lastKnownFileType="sourcecode.cpp.cpp", path=dispatch_path, sourceTree="<absolute>")
app.append(dispatch_path)
config_refs = [file(p.relative_to(ROOT).as_posix(), "text.plist.xml") for p in sorted((ROOT / "Config").glob("*")) if p.is_file() and p.name != "Signing.xcconfig"]
config_refs.append(icon_catalog_ref)
app_product = add("app-product", "PBXFileReference", explicitFileType="wrapper.application", path="Ultracam.app", sourceTree="BUILT_PRODUCTS_DIR")
camera_product = add("camera-product", "PBXFileReference", explicitFileType="wrapper.system-extension", path="org.ultracam.app.camera.systemextension", sourceTree="BUILT_PRODUCTS_DIR")
products = add("products", "PBXGroup", children=[app_product, camera_product], name="Products", sourceTree="<group>")
group = add("root-group", "PBXGroup", children=list(source_refs.values()) + config_refs + [products], sourceTree="<group>")


def configs(key, settings):
    ids = []
    for name in ("Debug", "Release"):
        build = dict(settings)
        build.update(SWIFT_OPTIMIZATION_LEVEL="-Onone" if name == "Debug" else "-O", SWIFT_COMPILATION_MODE="singlefile" if name == "Debug" else "wholemodule")
        ids.append(add(f"{key}-{name}", "XCBuildConfiguration", buildSettings=build, name=name))
    return add(f"{key}-configs", "XCConfigurationList", buildConfigurations=ids, defaultConfigurationIsVisible=0, defaultConfigurationName="Debug")


project_configs = configs("project", dict(SDKROOT="macosx", MACOSX_DEPLOYMENT_TARGET="26.0", SWIFT_VERSION="5.0", CLANG_ENABLE_MODULES="YES", CLANG_ENABLE_OBJC_ARC="YES", CLANG_CXX_LANGUAGE_STANDARD="c++17", ENABLE_HARDENED_RUNTIME="YES", CODE_SIGN_STYLE="Automatic", SWIFT_STRICT_CONCURRENCY="complete", SWIFT_TREAT_WARNINGS_AS_ERRORS="YES", ARCHS="arm64"))


# MonitorKit, linked into the app only (never the camera extension). Xcode links package
# products as object files, so all five products and both resource bundles ship in the app.
monitor_kit_package = add("monitor-kit-package", "XCLocalSwiftPackageReference", relativePath="Packages/MonitorKit")
monitor_products = [add(f"monitor-kit-product-{name}", "XCSwiftPackageProductDependency", package=monitor_kit_package, productName=name)
                    for name in ("MonitorKitCore", "MonitorKit", "MonitorKitScopes", "MonitorKitAudio", "MonitorKitUI")]


def target(key, name, sources, product, product_type, bundle_id, plist, entitlements):
    builds = [add(f"{key}-{path}", "PBXBuildFile", fileRef=source_refs[path]) for path in sources if path.endswith((".swift", ".mm", ".cpp"))]
    phase = add(f"{key}-sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=builds, runOnlyForDeploymentPostprocessing=0)
    package_builds = [add(f"{key}-package-{product}", "PBXBuildFile", productRef=product) for product in monitor_products] if key == "app" else []
    frameworks = add(f"{key}-frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=package_builds, runOnlyForDeploymentPostprocessing=0)
    settings = dict(PRODUCT_NAME=name, PRODUCT_BUNDLE_IDENTIFIER=bundle_id, INFOPLIST_FILE=plist, CODE_SIGN_ENTITLEMENTS=entitlements, GENERATE_INFOPLIST_FILE="NO", LD_RUNPATH_SEARCH_PATHS="$(inherited) @executable_path/../Frameworks", COMBINE_HIDPI_IMAGES="YES")
    if key == "camera":
        settings.update(PRODUCT_NAME=bundle_id, SKIP_INSTALL="YES")
    else:
        settings.update(ASSETCATALOG_COMPILER_APPICON_NAME="AppIcon",
                        SWIFT_OBJC_BRIDGING_HEADER="Sources/DeckLinkBackend/BridgingHeader.h", DECKLINK_SDK_DIR=sdk_dir,
                        HEADER_SEARCH_PATHS=["$(inherited)", "$(DECKLINK_SDK_DIR)"],
                        LIBRARY_SEARCH_PATHS=["$(inherited)", auto_switcher_lib_dir],
                        OTHER_LDFLAGS=["$(inherited)", "-lauto_switcher", "-lc++", "-lz", "-liconv",
                                       "-framework", "Security", "-framework", "CoreFoundation",
                                       "-framework", "SystemConfiguration"])
    resources = [add(f"{key}-resource-{path}", "PBXBuildFile", fileRef=source_refs[path]) for path in sources if path.endswith(".metal")]
    resource_phase = add(f"{key}-resources", "PBXCopyFilesBuildPhase", buildActionMask=2147483647, files=resources, dstPath="", dstSubfolderSpec=7, name="Copy GPU Shader Source", runOnlyForDeploymentPostprocessing=0)
    phases = [phase, frameworks, resource_phase]
    if key == "app":
        icon_build = add("app-icon-build", "PBXBuildFile", fileRef=icon_catalog_ref)
        phases.append(add("app-icon-resources", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=[icon_build], runOnlyForDeploymentPostprocessing=0))
    return add(f"{key}-target", "PBXNativeTarget", buildConfigurationList=configs(key, settings), buildPhases=phases, buildRules=[], dependencies=[], packageProductDependencies=monitor_products if key == "app" else [], name=name, productName=name, productReference=product, productType=product_type)


camera_id = target("camera", "UltracamCamera", camera, camera_product, "com.apple.product-type.system-extension", "org.ultracam.app.camera", "Config/Camera-Info.plist", "Config/Camera.entitlements")
app_id = target("app", "Ultracam", app, app_product, "com.apple.product-type.application", "org.ultracam.app", "Config/App-Info.plist", "Config/App.entitlements")
proxy = add("camera-proxy", "PBXContainerItemProxy", containerPortal=ref("project"), proxyType=1, remoteGlobalIDString=camera_id, remoteInfo="UltracamCamera")
dependency = add("camera-dependency", "PBXTargetDependency", target=camera_id, targetProxy=proxy)
embed_file = add("embed-camera-file", "PBXBuildFile", fileRef=camera_product, settings=dict(ATTRIBUTES=["CodeSignOnCopy", "RemoveHeadersOnCopy"]))
embed = add("embed-camera", "PBXCopyFilesBuildPhase", buildActionMask=2147483647, dstPath="$(CONTENTS_FOLDER_PATH)/Library/SystemExtensions", dstSubfolderSpec=16, files=[embed_file], name="Embed Camera Extension", runOnlyForDeploymentPostprocessing=0)
objects[app_id]["dependencies"] = [dependency]
objects[app_id]["buildPhases"].append(embed)
project = add("project", "PBXProject", attributes=dict(BuildIndependentTargetsInParallel=1, LastUpgradeCheck="2700"), buildConfigurationList=project_configs, compatibilityVersion="Xcode 14.0", developmentRegion="en", hasScannedForEncodings=0, knownRegions=["en", "Base"], mainGroup=group, productRefGroup=products, projectDirPath="", projectRoot="", targets=[app_id, camera_id], packageReferences=[monitor_kit_package])


def encode(value, level=0):
    if isinstance(value, dict):
        return "{\n" + "\n".join("\t" * (level + 1) + json.dumps(str(k)) + " = " + encode(v, level + 1) + ";" for k, v in value.items()) + "\n" + "\t" * level + "}"
    if isinstance(value, list):
        return "(" + ", ".join(encode(v, level) for v in value) + ")"
    return str(value) if isinstance(value, int) else json.dumps(value)


directory = ROOT / "Ultracam.xcodeproj"
directory.mkdir(exist_ok=True)
(directory / "project.pbxproj").write_text("// !$*UTF8*$!\n" + encode(dict(archiveVersion=1, classes={}, objectVersion=56, objects=objects, rootObject=project)) + "\n")
schemes = directory / "xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
(schemes / "Ultracam.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_id}" BuildableName="Ultracam.app" BlueprintName="Ultracam" ReferencedContainer="container:Ultracam.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="NO"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_id}" BuildableName="Ultracam.app" BlueprintName="Ultracam" ReferencedContainer="container:Ultracam.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print("Generated Ultracam.xcodeproj")
