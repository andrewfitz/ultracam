#!/usr/bin/env python3
"""Stage an ad-hoc signed local camera build. Never install or change macOS policy."""
import fcntl
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
from validate_bundle import RELOAD_HELPER, binary_uuids, validate

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
    if read_plist(source / "Contents/Info.plist").get("CFBundleIdentifier") != APP_ID:
        raise SystemExit("Input is not an Ultracam build.")
    source_symbols = source.with_name(source.name + ".dSYM")
    destination_symbols = destination.with_name(destination.name + ".dSYM")
    for original in (source, source_symbols.resolve()):
        for target in (destination, destination_symbols):
            if overlap(original, target):
                raise SystemExit("Source and staging destination must be separate bundles.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    directory = os.open(destination.parent, os.O_RDONLY)
    try:
        fcntl.flock(directory, fcntl.LOCK_EX)
        publish_stage(source, source_symbols, destination, destination_symbols)
    finally:
        os.close(directory)
    print(f"Local development build: {destination}")
    print("Ad-hoc signed with embedded entitlements; not notarized. macOS must permit local system extensions.")


def overlap(first, second):
    # samefile also catches alternate casing on case-insensitive volumes.
    for child, parent in ((first, second), (second, first)):
        if child.is_relative_to(parent):
            return True
        if parent.exists() and any(path.exists() and path.samefile(parent)
                                   for path in (child, *child.parents)):
            return True
    return False


def publish_stage(source, source_symbols, destination, destination_symbols):
    if destination.is_symlink() or destination_symbols.is_symlink():
        raise SystemExit("Refusing to replace a symlink staging destination.")
    executable = None
    if destination.exists():
        previous = read_plist(destination / "Contents/Info.plist")
        if previous.get("CFBundleIdentifier") != APP_ID or previous.get(LOCAL_MARKER) is not True:
            raise SystemExit("Refusing to replace a bundle not marked as our local build.")
        executable = destination / "Contents/MacOS" / previous["CFBundleExecutable"]
        opened = subprocess.run(["/usr/sbin/lsof", "-t", str(executable)], capture_output=True)
        if opened.returncode != 1 or opened.stdout:
            raise SystemExit("Quit the staged local app before rebuilding it.")
    if destination_symbols.exists():
        if executable is None or not destination_symbols.is_dir():
            raise SystemExit("Refusing to replace symbols without their staged local app.")
        if binary_uuids(destination_symbols) != binary_uuids(executable):
            raise SystemExit("Refusing to replace symbols from another build.")
    with tempfile.TemporaryDirectory(prefix=".ultracam-stage-", dir=destination.parent) as work:
        staged = Path(work) / "new" / destination.name
        staged_symbols = staged.with_name(staged.name + ".dSYM")
        shutil.copytree(source, staged, symlinks=True)
        if source_symbols.is_dir():
            shutil.copytree(source_symbols, staged_symbols, symlinks=True)
        sign_and_validate(staged)
        backup_dir = Path(work) / "previous"
        backup_dir.mkdir()
        backups = []
        installed = []
        try:
            for target in (destination, destination_symbols):
                if target.exists():
                    backup = backup_dir / target.name
                    target.rename(backup)
                    backups.append((backup, target))
            for item, target in ((staged_symbols, destination_symbols), (staged, destination)):
                if item.exists():
                    item.rename(target)
                    installed.append((target, item))
        except OSError:
            for target, item in reversed(installed):
                target.rename(item)
            for backup, target in reversed(backups):
                backup.rename(target)
            raise


def sign_and_validate(destination):
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
    reload_helper = destination / RELOAD_HELPER
    subprocess.run([
        "/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none",
        "--options", "runtime", str(reload_helper),
    ], check=True)
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
    for bundle in (reload_helper, extension, destination):
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--verbose=2", str(bundle)], check=True)
    validate(destination)


if __name__ == "__main__":
    main()
