#!/usr/bin/env python3
"""Check the built camera package before an OS activation request."""
from pathlib import Path
import plistlib
import subprocess
import sys
import argparse
import hashlib
import json
import ctypes

ROOT = Path(__file__).resolve().parents[1]


def validate(app, *, root=ROOT, inventory_path=None, signed=False, official_release=False,
             architectures=None, release_evidence=None):
    app = Path(app)
    extension = app / "Contents/Library/SystemExtensions/org.ultracam.app.camera.systemextension"
    for bundle, identifier, kind in (
        (app, "org.ultracam.app", "APPL"),
        (extension, "org.ultracam.app.camera", "SYSX"),
    ):
        with (bundle / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        if info.get("CFBundleIdentifier") != identifier or info.get("CFBundlePackageType") != kind:
            raise ValueError(f"Incorrect bundle identity/type: {bundle}")
        usage = info.get("NSSystemExtensionUsageDescription")
        if not isinstance(usage, str) or not usage.strip():
            raise ValueError(f"Missing system-extension usage description: {bundle}")
        executable = info.get("CFBundleExecutable", "")
        if not executable or Path(executable).name != executable or not (bundle / "Contents/MacOS" / executable).is_file():
            raise ValueError(f"Missing bundle executable: {bundle}")
        if bundle == app:
            signature = subprocess.run(
                ["/usr/bin/codesign", "-d", "--entitlements", ":-", str(bundle)], capture_output=True)
            if signature.returncode == 0 and signature.stdout:
                app_entitlements = plistlib.loads(signature.stdout)
            elif signed:
                raise ValueError("Signed host signature has no readable entitlements.")
            else:
                template = Path(root) / "Config/App.entitlements"
                app_entitlements = plistlib.loads(template.read_bytes())
            if app_entitlements.get("com.apple.security.files.user-selected.read-write") is not True:
                raise ValueError("Recording requires read/write access to user-selected folders.")
            if app_entitlements.get("com.apple.security.files.user-selected.read-only"):
                raise ValueError("Read-only selected-file access prevents recording output.")
            if app_entitlements.get("com.apple.security.cs.disable-library-validation") is not True:
                raise ValueError("The host must allow Blackmagic's separately signed DeckLink framework.")
        if bundle == extension:
            service = info.get("CMIOExtension", {}).get("CMIOExtensionMachServiceName", "")
            if not service or "$(" in service:
                raise ValueError("Camera Mach service is missing or has unresolved build variables.")
            signature = subprocess.run(
                ["/usr/bin/codesign", "-d", "--entitlements", ":-", str(bundle)],
                capture_output=True,
            )
            if signature.returncode == 0 and signature.stdout:
                entitlements = plistlib.loads(signature.stdout)
            elif signed:
                raise ValueError("Signed camera extension signature has no readable entitlements.")
            else:
                # Unsigned builds still need to match the configured app group.
                template = Path(root) / "Config/Camera.entitlements"
                entitlements = plistlib.loads(template.read_bytes())
            groups = entitlements.get("com.apple.security.application-groups", [])
            if entitlements.get("com.apple.security.cs.disable-library-validation"):
                raise ValueError("The camera extension must retain library validation; only the host loads DeckLink.")
            if not any(service.startswith(group + ".") for group in groups):
                raise ValueError("Camera Mach service must be prefixed with an entitled app group.")
    # MonitorTools is retired (MonitorKit replaced it): nothing of it may ship, e.g. a
    # resource bundle left behind by an incremental build from before the retirement.
    if any("MonitorTools" in path.name for path in app.rglob("*")):
        raise ValueError("The retired MonitorTools package must not be packaged into the app.")
    # MonitorKit's runtime shaders: SwiftPM `.copy("Shaders")` resources, host only.
    for name, shaders in (
        ("MonitorKit_MonitorKit.bundle", ("MKLUT.msl", "MKDecode.msl", "MKMonitor.msl")),
        ("MonitorKit_MonitorKitScopes.bundle", ("MKScopes.msl",)),
    ):
        bundle = app / "Contents/Resources" / name
        if not bundle.is_dir():
            raise ValueError(f"Host MonitorKit resource bundle {name} is missing.")
        for shader in shaders:
            if not any(path.is_file() and path.parent.name == "Shaders" for path in bundle.rglob(shader)):
                raise ValueError(f"{name} is missing Shaders/{shader}.")
    if any("MonitorKit" in path.name for path in extension.rglob("*")):
        raise ValueError("MonitorKit must not be packaged into the camera extension.")
    # Static linking leaves no file behind, so also check the extension's code for MonitorKit symbols.
    if any(b"MonitorKit" in path.read_bytes() for path in (extension / "Contents/MacOS").iterdir() if path.is_file()):
        raise ValueError("MonitorKit must not be linked into the camera extension.")
    validate_symbols(app)
    validate_vendors(app, root=root, inventory_path=inventory_path, signed=signed,
                     official_release=official_release, architectures=architectures, release_evidence=release_evidence)
    print("Camera metadata and host-only MonitorKit resources validated; no MonitorTools shipped.")


def binary_uuids(path):
    """The (arch, LC_UUID) pairs of a Mach-O file or a dSYM bundle."""
    result = subprocess.run(["/usr/bin/dwarfdump", "--uuid", str(path)], capture_output=True, text=True)
    if result.returncode != 0:
        raise ValueError(f"Cannot read the UUIDs of {path}: {result.stderr.strip()}")
    uuids = set()
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) >= 3 and fields[0] == "UUID:":
            uuids.add((fields[2].strip("()"), fields[1]))
    if not uuids:
        raise ValueError(f"{path} carries no UUID.")
    return uuids


def validate_symbols(app):
    """A stripped app executable must ship beside a dSYM built from the same link.

    Release strips the executable (STRIP_STYLE=all), which drops every local symbol, so
    crash reports and samples can name a function only by symbolicating against
    Ultracam.app.dSYM by UUID. Debug keeps its symbol table and needs no dSYM, but any
    dSYM beside it must still match.
    """
    with (app / "Contents/Info.plist").open("rb") as stream:
        executable = app / "Contents/MacOS" / plistlib.load(stream)["CFBundleExecutable"]
    dsym = app.parent / (app.name + ".dSYM")
    symbols = subprocess.run(["/usr/bin/nm", str(executable)], capture_output=True, text=True)
    if symbols.returncode != 0:
        raise ValueError(f"Cannot read the symbol table of {executable}: {symbols.stderr.strip()}")
    stripped = " t " not in symbols.stdout
    if not dsym.is_dir():
        if stripped:
            raise ValueError(f"{executable} is stripped but {dsym} is missing; its crash reports could not be symbolicated.")
        return
    if binary_uuids(dsym) != binary_uuids(executable):
        raise ValueError(f"{dsym} does not match {executable} (UUIDs differ); it is from another build.")


def _tool(runner, arguments):
    result = runner(arguments, capture_output=True, text=True)
    if result.returncode:
        raise ValueError(f"Cannot inspect {arguments[-1]}: {result.stderr.strip()}")
    return result.stdout


def _install_names(path, runner, architectures=()):
    names = set()
    for architecture in architectures or (None,):
        arguments = ["/usr/bin/otool"] + (["-arch", architecture] if architecture else []) + ["-D", str(path)]
        output = _tool(runner, arguments)
        names.update(line.strip() for line in output.splitlines()
                     if line.strip() and not line.rstrip().endswith(":"))
    return names


def _macho(path):
    with path.open("rb") as stream:
        return stream.read(4) in {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
                                  b"\xfe\xed\xfa\xce", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
                                  b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}


def bundle_digest(app):
    """Artifact binding for evidence: sorted relative paths and file SHA-256s."""
    app = Path(app)
    digest = hashlib.sha256()
    for path in sorted(app.rglob("*")):
        if path.is_file():
            digest.update(str(path.relative_to(app)).encode() + b"\0")
            digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def _release_evidence(app, manifests, inventory, path):
    if not inventory.get("sony", {}).get("available"):
        raise ValueError("Official releases require the Sony SDK.")
    if path is None:
        raise ValueError("Official release requires recorded Sony redistribution evidence; docs/SDK_RELEASE_EVIDENCE.md records the outstanding requirements.")
    evidence = json.loads(Path(path).read_text())
    sony = next((m for m in manifests if m["id"] == "sony"), None)
    required = ("reviewedBy", "reviewedAt", "termsReference", "redistributionClauses", "archiveName", "archiveSHA256", "provenance")
    if not isinstance(evidence, dict) or evidence.get("schemaVersion") != 1 or evidence.get("vendorID") != "sony" or any(
            not isinstance(evidence.get(key), str) or not evidence[key].strip() for key in required):
        raise ValueError("Incomplete Sony redistribution evidence.")
    if not sony or evidence.get("sdkVersion") != sony["sdk"]["version"]:
        raise ValueError("Sony redistribution evidence SDK version mismatch.")
    if len(evidence["archiveSHA256"]) != 64 or any(c not in "0123456789abcdef" for c in evidence["archiveSHA256"]):
        raise ValueError("Sony redistribution evidence archive hash is invalid.")
    try:
        from datetime import date
        date.fromisoformat(evidence["reviewedAt"])
    except ValueError as error:
        raise ValueError("Sony redistribution evidence review date must be ISO YYYY-MM-DD.") from error
    if evidence.get("artifactSHA256") != bundle_digest(app):
        raise ValueError("Sony redistribution evidence does not identify this release artifact.")
    from vendors import build_settings
    expected = {str(Path(item["subfolder"]) / Path(item["path"]).name)
                for item in build_settings(manifests, inventory, vendor="sony")["embedLibraries"]}
    runtime_inventory = evidence.get("runtimeInventory", [])
    if not isinstance(runtime_inventory, list) or not all(isinstance(value, str) for value in runtime_inventory) or set(runtime_inventory) != expected:
        raise ValueError("Sony redistribution evidence runtime inventory mismatch.")
    notices = evidence.get("packagedNotices", [])
    if not isinstance(notices, list) or not notices or not all(isinstance(value, str) and value for value in notices):
        raise ValueError("Sony redistribution evidence must identify packaged license and notice files.")
    for relative in notices:
        candidate = app / relative
        if not candidate.resolve().is_relative_to(app.resolve()) or not candidate.is_file() or candidate.stat().st_size == 0:
            raise ValueError("Sony redistribution evidence notice is missing from the artifact.")
    for name in ("LICENSE", "NOTICE", "THIRD_PARTY_LICENSES.md"):
        if not any(p.is_file() and p.stat().st_size > 0 for p in app.rglob(name)):
            raise ValueError(f"Official release artifact is missing {name}.")


def system_library_available(path):
    """Require the precise system path on disk or in dyld's shared cache.

    A system search directory alone says nothing about the requested library.
    Querying cache membership does not load the dependency or execute its code.
    """
    path = Path(path).resolve()
    if not str(path).startswith(("/System/Library/", "/usr/lib/")):
        return False
    if path.is_file():
        return True
    try:
        contains = ctypes.CDLL(None)._dyld_shared_cache_contains_path
        contains.argtypes = [ctypes.c_char_p]
        contains.restype = ctypes.c_bool
        return bool(contains(str(path).encode()))
    except (AttributeError, OSError):
        return False


def validate_vendors(app, *, root=ROOT, inventory_path=None, signed=False, official_release=False,
                     architectures=None, release_evidence=None, manifests=None, inventory=None, runner=subprocess.run):
    """Inspect shipped code even for unsigned builds. Runner injection models
    tool output in tests; production always uses the platform Mach-O tools.
    """
    from vendors import read_inventory, build_settings
    root = Path(root)
    app = Path(app).resolve()
    if manifests is None or inventory is None:
        manifests, inventory = read_inventory(root, inventory_path)
    if official_release:
        if not signed:
            raise ValueError("Official release validation requires signed mode.")
        _release_evidence(app, manifests, inventory, release_evidence)
    extension = app / "Contents/Library/SystemExtensions/org.ultracam.app.camera.systemextension"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    host = app / "Contents/MacOS" / info["CFBundleExecutable"]
    required_architectures = set(architectures or _tool(runner, ["/usr/bin/lipo", "-archs", str(host)]).split())
    if not required_architectures:
        raise ValueError("Host executable has no supported architecture.")
    signature = runner(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(app)], capture_output=True, text=True)
    if signature.returncode == 0 and signature.stdout.strip():
        entitlements = plistlib.loads(signature.stdout.encode())
    elif signed:
        raise ValueError("Signed host signature has no readable entitlements.")
    else:
        entitlements = plistlib.loads((root / "Config/App.entitlements").read_bytes())
    expected_embeds = {}
    all_vendor_names = set()
    external_drivers = []
    for manifest in manifests:
        enabled = inventory[manifest["id"]]["available"] or not manifest.get("sdk")
        selected_embeds = build_settings([manifest], inventory)["embedLibraries"]
        declared = list(manifest.get("embedLibraries", [])) + list((manifest.get("sdk") or {}).get("enabledBuild", {}).get("embedLibraries", []))
        for item in declared:
            all_vendor_names.add(Path(item["path"]).name)
            destination = app / "Contents/Frameworks" / item["subfolder"] / Path(item["path"]).name
            if item not in selected_embeds and destination.exists():
                raise ValueError(f"Runtime for disabled vendor {manifest['id']} is embedded: {destination}")
        for key in manifest.get("capabilities", {}).get("entitlements", []) if enabled else []:
            if not entitlements.get(key):
                raise ValueError(f"Missing vendor entitlement {key} ({manifest['id']}).")
        for key in manifest.get("capabilities", {}).get("infoPlist", []) if enabled else []:
            if not info.get(key):
                raise ValueError(f"Missing vendor Info.plist capability {key} ({manifest['id']}).")
        if enabled:
            external_drivers.extend((manifest.get("sdk") or {}).get("externalDrivers", []))
        for item in selected_embeds:
            destination = app / "Contents/Frameworks" / item["subfolder"] / Path(item["path"]).name
            if not destination.is_file():
                raise ValueError(f"Missing enabled vendor runtime: {destination}")
            if not destination.resolve().is_relative_to(app):
                raise ValueError(f"Vendor runtime escapes app: {destination}")
            for architecture in required_architectures:
                expected = _install_names(root / item["path"], runner, [architecture])
                actual = _install_names(destination, runner, [architecture])
                if not expected or expected != actual:
                    raise ValueError(f"Unexpected vendor install name ({architecture}): {destination}")
            expected_embeds[destination] = _install_names(destination, runner, required_architectures)
    binaries = [p for p in app.rglob("*") if p.is_file() and _macho(p)]
    metadata = {}
    for binary in binaries:
        if not binary.resolve().is_relative_to(app):
            raise ValueError(f"Code escapes app: {binary}")
        if binary.is_relative_to(extension) and (binary.name in all_vendor_names or (binary.suffix == ".dylib" and not binary.name.startswith("libswift"))):
            raise ValueError(f"Vendor runtime must not ship in camera extension: {binary}")
        arches = set(_tool(runner, ["/usr/bin/lipo", "-archs", str(binary)]).split())
        if not required_architectures.issubset(arches):
            raise ValueError(f"Missing architecture {sorted(required_architectures - arches)} in {binary}")
        load = "\n".join(_tool(runner, ["/usr/bin/otool", "-arch", arch, "-L", str(binary)]) for arch in required_architectures)
        dependencies = {line.strip().split(" (compatibility version", 1)[0] for line in load.splitlines()
                        if line[:1].isspace() and " (compatibility version" in line}
        dependencies -= expected_embeds.get(binary, set())
        # Other app/debug dylibs also list their own LC_ID_DYLIB in otool -L.
        if binary.suffix == ".dylib":
            dependencies -= _install_names(binary, runner, required_architectures)
        commands = "\n".join(_tool(runner, ["/usr/bin/otool", "-arch", arch, "-l", str(binary)]) for arch in required_architectures).splitlines()
        rpaths = []
        for index, line in enumerate(commands):
            if line.strip() == "cmd LC_RPATH":
                for following in commands[index + 1:index + 4]:
                    if following.strip().startswith("path "):
                        rpaths.append(following.strip()[5:].rsplit(" (offset", 1)[0])
        metadata[binary] = (dependencies, rpaths)
    resolved_binaries = {p.resolve(): p for p in metadata}
    visited = set()
    reached = set()
    def inspect_dependencies(binary, inherited, executable):
        reached.add(binary)
        dependencies, rpaths = metadata[binary]
        def expand(value):
            return value.replace("@loader_path", str(binary.parent)).replace("@executable_path", str(executable.parent))
        search_paths = list(dict.fromkeys([expand(value) for value in rpaths] + inherited))
        key = (binary, tuple(search_paths), executable)
        if key in visited:
            return
        visited.add(key)
        for dependency in dependencies:
            if Path(dependency).is_absolute() and system_library_available(dependency):
                continue
            if binary.is_relative_to(extension) and Path(dependency).name in all_vendor_names:
                raise ValueError(f"Camera extension links vendor dependency: {dependency}")
            if Path(dependency).is_absolute() and any(Path(dependency).resolve().is_relative_to(Path(driver).resolve()) for driver in external_drivers):
                if binary.is_relative_to(extension):
                    raise ValueError(f"Camera extension links external vendor dependency: {dependency}")
                continue
            candidates = [Path(folder) / dependency[len("@rpath/"): ] for folder in search_paths] if dependency.startswith("@rpath/") else [Path(expand(dependency))]
            # Shared-cache-only libraries still need precise path membership.
            if any(system_library_available(candidate) for candidate in candidates):
                continue
            target = next((resolved_binaries[candidate.resolve()] for candidate in candidates
                           if candidate.resolve().is_relative_to(app) and candidate.resolve() in resolved_binaries), None)
            if target is None:
                raise ValueError(f"Unresolved non-system dependency {dependency} in {binary}")
            if binary.is_relative_to(extension) and not target.is_relative_to(extension):
                raise ValueError(f"Camera extension dependency escapes its bundle: {dependency}")
            inspect_dependencies(target, search_paths, executable)
    roots = [host] + [p for p in extension.glob("Contents/MacOS/*") if p in metadata] + list(expected_embeds) + list(metadata)
    for binary in roots:
        if binary in reached:
            continue
        executable = next((p for p in extension.glob("Contents/MacOS/*") if p in metadata), host) if binary.is_relative_to(extension) else host
        inherited = [value.replace("@loader_path", str(executable.parent)).replace("@executable_path", str(executable.parent))
                     for value in metadata.get(executable, ([], []))[1]]
        inspect_dependencies(binary, inherited, executable)
    if signed:
        for code in list(metadata) + [extension, app]:
            result = runner(["/usr/bin/codesign", "--verify", "--strict", "--verbose=2", str(code)], capture_output=True, text=True)
            if result.returncode:
                raise ValueError(f"Invalid code signature: {code}: {result.stderr.strip()}")
            if official_release:
                # codesign emits display details on stderr.
                result = runner(["/usr/bin/codesign", "--display", "--verbose=4", str(code)], capture_output=True, text=True)
                details = result.stdout + result.stderr
                if "Signature=adhoc" in details or "Authority=" not in details or "TeamIdentifier=not set" in details:
                    raise ValueError(f"Official release requires an identity signature: {code}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app")
    parser.add_argument("--inventory", type=Path)
    parser.add_argument("--signed", action="store_true")
    parser.add_argument("--official-release", action="store_true")
    parser.add_argument("--arch", action="append")
    parser.add_argument("--release-evidence", type=Path)
    args = parser.parse_args()
    try:
        validate(args.app, inventory_path=args.inventory, signed=args.signed, official_release=args.official_release,
                 architectures=args.arch, release_evidence=args.release_evidence)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise SystemExit(str(error)) from error
