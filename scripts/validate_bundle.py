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
    # Runtime shader source is a SwiftPM Bundle.module resource in the host only.
    monitor_bundles = list((app / "Contents/Resources").glob("*MonitorToolsMetal.bundle"))
    if not monitor_bundles or not any(list(bundle.rglob("MonitorTools.metal.txt")) for bundle in monitor_bundles):
        raise ValueError("Host MonitorToolsMetal shader resource bundle is missing.")
    if any("MonitorTools" in path.name for path in extension.rglob("*")):
        raise ValueError("Monitor Tools must not be packaged into the camera extension.")
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
    print("Camera metadata and host-only Monitor Tools and MonitorKit resources validated.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: validate_bundle.py APP.app")
    try:
        validate(sys.argv[1])
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise SystemExit(str(error)) from error
