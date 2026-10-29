#!/usr/bin/env python3
"""Generate the two-target Xcode project using only the Python standard library."""
import argparse
import shlex
import hashlib
import json
import os
import sys
from pathlib import Path
from work_paths import work_paths
from vendors import read_inventory, build_settings, source_paths, generate_bridge, input_digest, check_capabilities

ROOT = Path(__file__).resolve().parents[1]
# MonitorKit is a git submodule; a clone without it would generate a project
# whose package reference points at an empty directory.
if not (ROOT / "Packages/MonitorKit/Package.swift").is_file():
    sys.exit("generate_project.py: Packages/MonitorKit/Package.swift is missing; "
             "MonitorKit is a git submodule: run git submodule update --init")
objects = {}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--sdk-inventory', type=Path)
parser.add_argument('--output-dir', type=Path)
args = parser.parse_args()
manifests, sdk_inventory = read_inventory(ROOT, args.sdk_inventory)
vendor_settings = build_settings(manifests, sdk_inventory)
vendor_digest = input_digest(manifests, sdk_inventory)
generate_bridge(ROOT, manifests)
check_capabilities(ROOT, manifests, sdk_inventory)


def ref(key):
    return hashlib.sha256(key.encode()).hexdigest()[:24].upper()


def add(key, isa, **fields):
    objects[ref(key)] = dict(isa=isa, **fields)
    return ref(key)


def file(path, type):
    return add(path, "PBXFileReference", lastKnownFileType=type, path=path, sourceTree="<absolute>" if Path(path).is_absolute() else "<group>")


shared = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "Sources/Shared").glob("*.swift"))
program = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "Sources/Program").glob("*.swift"))
recording = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "Sources/Recording").glob("*.swift"))
device_api = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "Sources/DeviceAPI").glob("*.swift") if not p.name.startswith("Fake"))
app = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "Sources/App").iterdir() if p.suffix in (".swift", ".metal")) + program + shared + recording + device_api
app += source_paths(manifests, 'app') + ["Sources/DeviceAPI/DeviceAPI.h", "Sources/DeviceAPI/GeneratedBridgingHeader.h"]
vendor_resources = sorted({entry['path'] for manifest in manifests for entry in manifest['resources'] if 'app' in entry['membership']})
app += vendor_resources
app = sorted(set(app))

camera = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "Sources/CameraExtension").glob("*.swift")) + [
    "Sources/Shared/VideoContract.swift", "Sources/Shared/VideoBufferLayout.swift",
    "Sources/Shared/SourceFormat.swift", "Sources/Shared/ColorimetryContract.swift",
    "Sources/Shared/DerivedOutputAdmission.swift",
    "Sources/Shared/ExtensionFormatCatalog.swift",
    "Sources/Shared/GPUStandbyProducer.swift", "Sources/Shared/GPUStandbyLifecycle.swift",
    "Sources/Shared/VirtualCameraRegistry.swift",
    "Sources/Shared/VirtualCameraRegistryTransport.swift",
]
def source_type(path):
    if path.endswith(".xcassets"): return "folder.assetcatalog"
    if path.endswith(".metal"): return "sourcecode.metal"
    if path.endswith(".mm"): return "sourcecode.cpp.objcpp"
    if path.endswith(".m"): return "sourcecode.c.objc"
    if path.endswith(".cpp"): return "sourcecode.cpp.cpp"
    if path.endswith((".h", ".inc")): return "sourcecode.c.h"
    if path.endswith(".strings"): return "text.plist.strings"
    return "sourcecode.swift"
source_refs = {path: file(path, source_type(path)) for path in sorted(set(app + camera))}
# A localized strings file must be a variant-group child. Copying its file
# reference directly flattens the locale directory and breaks Bundle lookup.
localized = {}
for path in vendor_resources:
    resource = Path(path)
    if resource.parent.suffix == '.lproj':
        key = (resource.parent.parent.as_posix(), resource.name)
        localized.setdefault(key, []).append(path)
for (parent, name), paths in localized.items():
    children = []
    for path in paths:
        child = source_refs[path]
        objects[child]['name'] = Path(path).parent.stem
        children.append(child)
    variant = add('localized-' + parent + '/' + name, 'PBXVariantGroup',
                  children=children, name=name, sourceTree='<group>')
    for path in paths:
        source_refs[path] = variant
icon_catalog = "Config/Assets.xcassets"
icon_catalog_ref = file(icon_catalog, "folder.assetcatalog")


def contained_path(value, root, label):
    candidate = Path(value).expanduser().resolve(strict=False)
    if candidate == root or not candidate.is_relative_to(root):
        raise SystemExit(f"{label} must be inside {root}.")
    return str(candidate)


def project_path(path):
    return path if Path(path).is_absolute() else "$(SRCROOT)/" + path


auto_switcher_lib_dir = os.environ.get(
    "AUTO_SWITCHER_LIB_DIR",
    str(work_paths(ROOT)["build_root"] / "auto-switcher-target/release"),
)
if "$(" not in auto_switcher_lib_dir:
    library_path = Path(auto_switcher_lib_dir).expanduser().resolve(strict=False)
    permitted_root = ROOT if library_path.is_relative_to(ROOT) else work_paths(ROOT)["work_root"]
    auto_switcher_lib_dir = contained_path(auto_switcher_lib_dir, permitted_root, "AUTO_SWITCHER_LIB_DIR")
    # Relative to the checkout like DECKLINK_SDK_DIR, so build.sh (which exports an
    # absolute path) regenerates the committed, relocatable project.
    if Path(auto_switcher_lib_dir).is_relative_to(ROOT):
        auto_switcher_lib_dir = "$(SRCROOT)/" + Path(auto_switcher_lib_dir).relative_to(ROOT).as_posix()
config_refs = [file(p.relative_to(ROOT).as_posix(), "text.plist.xml") for p in sorted((ROOT / "Config").glob("*")) if p.is_file() and p.name != "Signing.xcconfig"]
config_refs.append(icon_catalog_ref)
app_product = add("app-product", "PBXFileReference", explicitFileType="wrapper.application", path="Ultracam.app", sourceTree="BUILT_PRODUCTS_DIR")
camera_product = add("camera-product", "PBXFileReference", explicitFileType="wrapper.system-extension", path="org.ultracam.app.camera.systemextension", sourceTree="BUILT_PRODUCTS_DIR")
products = add("products", "PBXGroup", children=[app_product, camera_product], name="Products", sourceTree="<group>")
group = add("root-group", "PBXGroup", children=list(dict.fromkeys(source_refs.values())) + config_refs + [products], sourceTree="<group>")


def configs(key, settings, release=None):
    ids = []
    for name in ("Debug", "Release"):
        build = dict(settings)
        build.update(SWIFT_OPTIMIZATION_LEVEL="-Onone" if name == "Debug" else "-O", SWIFT_COMPILATION_MODE="singlefile" if name == "Debug" else "wholemodule")
        if name == "Release":
            build.update(release or {})
        ids.append(add(f"{key}-{name}", "XCBuildConfiguration", buildSettings=build, name=name))
    return add(f"{key}-configs", "XCConfigurationList", buildConfigurations=ids, defaultConfigurationIsVisible=0, defaultConfigurationName="Debug")


project_configs = configs("project", dict(SDKROOT="macosx", MACOSX_DEPLOYMENT_TARGET="26.0", SWIFT_VERSION="5.0", CLANG_ENABLE_MODULES="YES", CLANG_ENABLE_OBJC_ARC="YES", CLANG_CXX_LANGUAGE_STANDARD="c++17", ENABLE_HARDENED_RUNTIME="YES", CODE_SIGN_STYLE="Automatic", SWIFT_STRICT_CONCURRENCY="complete", SWIFT_TREAT_WARNINGS_AS_ERRORS="YES", ARCHS="arm64"))


# MonitorKit, linked into the app only (never the camera extension). Xcode links package
# products as object files, so all five products and both resource bundles ship in the app.
monitor_kit_package = add("monitor-kit-package", "XCLocalSwiftPackageReference", relativePath="Packages/MonitorKit")
monitor_products = [add(f"monitor-kit-product-{name}", "XCSwiftPackageProductDependency", package=monitor_kit_package, productName=name)
                    for name in ("MonitorKitCore", "MonitorKit", "MonitorKitScopes", "MonitorKitAudio", "MonitorKitUI")]


def target(key, name, sources, product, product_type, bundle_id, plist, entitlements):
    builds = [add(f"{key}-{path}", "PBXBuildFile", fileRef=source_refs[path]) for path in sources if path.endswith((".swift", ".m", ".mm", ".cpp"))]
    phase = add(f"{key}-sources", "PBXSourcesBuildPhase", buildActionMask=2147483647, files=builds, runOnlyForDeploymentPostprocessing=0)
    package_builds = [add(f"{key}-package-{product}", "PBXBuildFile", productRef=product) for product in monitor_products] if key == "app" else []
    frameworks = add(f"{key}-frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=package_builds, runOnlyForDeploymentPostprocessing=0)
    settings = dict(PRODUCT_NAME=name, PRODUCT_BUNDLE_IDENTIFIER=bundle_id, INFOPLIST_FILE=plist, CODE_SIGN_ENTITLEMENTS=entitlements, GENERATE_INFOPLIST_FILE="NO", LD_RUNPATH_SEARCH_PATHS="$(inherited) @executable_path/../Frameworks", COMBINE_HIDPI_IMAGES="YES")
    release = None
    if key == "camera":
        settings.update(PRODUCT_NAME=bundle_id, SKIP_INSTALL="YES",
                        OTHER_LDFLAGS=["$(inherited)", "-framework", "Metal"])
    else:
        # Release app only: the linker drops code nothing reaches (-dead_strip; MonitorKit,
        # the Rust switcher and the app keep every live symbol, ObjC classes and Swift
        # conformance/metadata sections), and the built product is stripped
        # (STRIP_INSTALLED_PRODUCT/STRIP_STYLE take effect only with DEPLOYMENT_POSTPROCESSING).
        # The symbols move to Ultracam.app.dSYM beside the product: the shipped binary keeps
        # no function names (STRIP_STYLE=debugging would keep them at about twice the size),
        # so crash reports and samples symbolicate only against that dSYM, matched by UUID.
        # validate_bundle.py refuses a stripped app without it. Debug keeps everything; the
        # camera extension's settings are unchanged.
        release = dict(DEAD_CODE_STRIPPING="YES", DEPLOYMENT_POSTPROCESSING="YES",
                       STRIP_INSTALLED_PRODUCT="YES", STRIP_STYLE="all",
                       DEBUG_INFORMATION_FORMAT="dwarf-with-dsym")
        settings.update(ASSETCATALOG_COMPILER_APPICON_NAME="AppIcon",
                        SWIFT_OBJC_BRIDGING_HEADER="Sources/DeviceAPI/GeneratedBridgingHeader.h",
                        HEADER_SEARCH_PATHS=["$(inherited)"] + [project_path(path) for path in vendor_settings['headerSearchPaths']],
                        LIBRARY_SEARCH_PATHS=["$(inherited)", auto_switcher_lib_dir] + [project_path(path) for path in vendor_settings['librarySearchPaths']],
                        OTHER_LDFLAGS=["$(inherited)", "-lauto_switcher", "-lc++", "-lz", "-liconv",
                                       "-framework", "Security", "-framework", "CoreFoundation",
                                       "-framework", "SystemConfiguration"])
        if vendor_settings['defines']:
            settings['GCC_PREPROCESSOR_DEFINITIONS'] = ['$(inherited)'] + vendor_settings['defines']
        for framework in vendor_settings['frameworks']:
            settings['OTHER_LDFLAGS'] += ['-framework', framework]
        for library in vendor_settings['libraries']:
            flag = '-l' + library
            if flag not in settings['OTHER_LDFLAGS']: settings['OTHER_LDFLAGS'].append(flag)
    resources = [add(f"{key}-resource-{path}", "PBXBuildFile", fileRef=source_refs[path]) for path in sources if path.endswith(".metal")]
    resource_phase = add(f"{key}-resources", "PBXCopyFilesBuildPhase", buildActionMask=2147483647, files=resources, dstPath="", dstSubfolderSpec=7, name="Copy GPU Shader Source", runOnlyForDeploymentPostprocessing=0)
    phases = [phase, frameworks, resource_phase]
    if key == "app":
        icon_build = add("app-icon-build", "PBXBuildFile", fileRef=icon_catalog_ref)
        vendor_resource_builds = [add('vendor-resource-' + identity, 'PBXBuildFile', fileRef=identity) for identity in dict.fromkeys(source_refs[path] for path in vendor_resources)]
        phases.append(add("app-icon-resources", "PBXResourcesBuildPhase", buildActionMask=2147483647, files=[icon_build] + vendor_resource_builds, runOnlyForDeploymentPostprocessing=0))
        embeds = {}
        for entry in vendor_settings['embedLibraries']:
            path = entry['path']
            library_ref = file(path, 'compiled.mach-o.dylib')
            objects[group]['children'].append(library_ref)
            library_build = add(path + '-embed', 'PBXBuildFile', fileRef=library_ref, settings=dict(ATTRIBUTES=['CodeSignOnCopy']))
            embeds.setdefault(entry['subfolder'], []).append(library_build)
        for folder, library_builds in sorted(embeds.items()):
            phases.append(add('vendor-embed-' + folder, 'PBXCopyFilesBuildPhase', buildActionMask=2147483647,
                files=library_builds, dstPath=folder, dstSubfolderSpec=10, name='Embed Vendor Runtime ' + folder, runOnlyForDeploymentPostprocessing=0))
        guard_script = 'exec /usr/bin/python3 "$SRCROOT/scripts/vendors.py" check-generated --root "$SRCROOT" --expected-digest ' + vendor_digest
        if args.sdk_inventory:
            guard_script += ' --sdk-inventory ' + shlex.quote(str(args.sdk_inventory.resolve()))
        guard = add('vendor-input-guard', 'PBXShellScriptBuildPhase', buildActionMask=2147483647, files=[],
            inputPaths=[], outputPaths=[], runOnlyForDeploymentPostprocessing=0, alwaysOutOfDate=1,
            name='Check Vendor Inputs', shellPath='/bin/sh', shellScript=guard_script, showEnvVarsInLog=0)
        phases.insert(0, guard)
    return add(f"{key}-target", "PBXNativeTarget", buildConfigurationList=configs(key, settings, release), buildPhases=phases, buildRules=[], dependencies=[], packageProductDependencies=monitor_products if key == "app" else [], name=name, productName=name, productReference=product, productType=product_type)


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


directory = args.output_dir or ROOT / "Ultracam.xcodeproj"
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
