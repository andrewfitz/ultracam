#!/usr/bin/env python3
"""Check the built camera package before an OS activation request."""
from pathlib import Path
import plistlib
import subprocess
import sys


def validate(app):
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
            else:
                template = Path(__file__).resolve().parents[1] / "Config/App.entitlements"
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
            else:
                # Unsigned builds still need to match the configured app group.
                template = Path(__file__).resolve().parents[1] / "Config/Camera.entitlements"
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


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: validate_bundle.py APP.app")
    try:
        validate(sys.argv[1])
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise SystemExit(str(error)) from error
