#!/usr/bin/env python3
"""Stage an ad-hoc signed local camera build. Never install or change macOS policy."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time

# Keep imports from creating cache files beside the project scripts.
sys.dont_write_bytecode = True
from validate_bundle import validate

ROOT = Path(__file__).resolve().parents[1]
LOCAL_GROUP = "group.org.ultracam.local"
LOCAL_MARKER = "UltracamLocalDevelopmentBuild"
APP_ID = "org.ultracam.app"
EXTENSION_ID = APP_ID + ".camera"


def read_plist(path):
    with path.open("rb") as stream:
        return plistlib.load(stream)


def write_plist(path, value):
    with path.open("wb") as stream:
        plistlib.dump(value, stream)


def sign_staged_libraries(app):
    """Sign nested code in the copied bundle before sealing its parents.

    Sony ships a mixture of signed and unsigned libraries. App signing does not
    recursively sign them, and Debug also embeds separate code/preview dylibs.
    Never alter the downloaded SDK or the original build's library signatures.
    """
    libraries = sorted(app.rglob("*.dylib"), key=lambda path: (-len(path.parts), str(path)))
    for library in libraries:
        if library.is_symlink() or not library.is_file():
            continue
        subprocess.run([
            "/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none",
            "--options", "runtime", str(library),
        ], check=True)


def main():
    if len(sys.argv) != 3:
        raise SystemExit("Usage: prepare_local_build.py INPUT.app STAGED.app")
    source = Path(sys.argv[1]).resolve(strict=True)
    requested_destination = Path(sys.argv[2]).absolute()
    if requested_destination.is_symlink():
        raise SystemExit("Refusing a symlink staging destination.")
    # Resolve parent aliases and '..' before checking overlap or replacing any
    # previous stage. Lexically different paths can name the same source app.
    destination = requested_destination.parent.resolve() / requested_destination.name
    validate(source)
    if source == destination or destination.is_relative_to(source) or source.is_relative_to(destination):
        raise SystemExit("Source and staging destination must be separate bundles.")
    if read_plist(source / "Contents/Info.plist").get("CFBundleIdentifier") != APP_ID:
        raise SystemExit("Input is not an Ultracam build.")
    if destination.exists():
        previous = read_plist(destination / "Contents/Info.plist")
        if previous.get("CFBundleIdentifier") != APP_ID or previous.get(LOCAL_MARKER) is not True:
            raise SystemExit("Refusing to replace a bundle not marked as our local build.")
        executable = destination / "Contents/MacOS" / previous["CFBundleExecutable"]
        opened = subprocess.run(["/usr/sbin/lsof", "-t", str(executable)], capture_output=True)
        if opened.returncode != 1 or opened.stdout:
            raise SystemExit("Quit the staged local app before rebuilding it.")
        shutil.rmtree(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, destination, symlinks=True)
    # A stripped Release executable symbolicates only against the dSYM of its link
    # (validate_bundle.validate_symbols); keep a copy beside the staged app. Signing
    # does not change the executable's LC_UUID, so the copy still matches.
    source_symbols = source.parent / (source.name + ".dSYM")
    destination_symbols = destination.parent / (destination.name + ".dSYM")
    if destination_symbols.is_symlink() or destination_symbols.is_file():
        destination_symbols.unlink()
    elif destination_symbols.exists():
        shutil.rmtree(destination_symbols)
    if source_symbols.is_dir():
        shutil.copytree(source_symbols, destination_symbols, symlinks=True)
    extension = destination / "Contents/Library/SystemExtensions" / (EXTENSION_ID + ".systemextension")
    version = str(int(time.time()))
    for bundle in (destination, extension):
        info_path = bundle / "Contents/Info.plist"
        info = read_plist(info_path)
        info[LOCAL_MARKER] = True
        info["CFBundleVersion"] = version
        if bundle == extension:
            info["CMIOExtension"]["CMIOExtensionMachServiceName"] = LOCAL_GROUP + ".camera"
        write_plist(info_path, info)
    sign_staged_libraries(destination)
    # Generate outside the repo; both signatures must contain the exact same
    # app group, and the extension's Mach service must start with that group.
    with tempfile.TemporaryDirectory(prefix="ultracam-sign-", dir=os.environ.get("TMPDIR")) as work:
        for bundle, template, name in (
            (extension, "Camera.entitlements", "camera"),
            (destination, "App.entitlements", "app"),
        ):
            entitlements = read_plist(ROOT / "Config" / template)
            # Ad-hoc builds have no authorized app-identifier prefix/profile.
            # Keychain persistence is available in provisioned signed builds.
            entitlements.pop("keychain-access-groups", None)
            entitlements["com.apple.security.application-groups"] = [LOCAL_GROUP]
            entitlements_path = Path(work) / (name + ".entitlements")
            write_plist(entitlements_path, entitlements)
            subprocess.run([
                "/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none",
                "--options", "runtime", "--entitlements", str(entitlements_path), str(bundle),
            ], check=True)
    for bundle in (extension, destination):
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--verbose=2", str(bundle)], check=True)
    validate(destination)
    print(f"Local development build: {destination}")
    print("Ad-hoc signed with embedded entitlements; not notarized. macOS must permit local system extensions.")


if __name__ == "__main__":
    main()
