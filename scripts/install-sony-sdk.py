#!/usr/bin/env python3
"""Install the user's Sony SDK locally; never fetch or redistribute Sony binaries."""
import io
from pathlib import Path
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def install(archive):
    destination = ROOT / "ThirdParty/SonyCameraRemoteSDK"
    with zipfile.ZipFile(archive) as outer:
        with zipfile.ZipFile(io.BytesIO(outer.read("SimpleCli.zip"))) as sample:
            files = {}
            for entry in sample.infolist():
                path = Path(entry.filename)
                if path.is_absolute() or ".." in path.parts:
                    raise ValueError("Unsafe SDK archive path")
                if entry.is_dir():
                    continue
                if entry.filename.startswith("app/CRSDK/"):
                    files[Path("include") / path.name] = sample.read(entry)
                elif entry.filename.startswith("external/crsdk/"):
                    files[Path("lib") / path.relative_to("external/crsdk")] = sample.read(entry)
            if Path("include/CameraRemote_SDK.h") not in files or Path("lib/libCr_Core.dylib") not in files:
                raise ValueError("The archive does not contain the expected macOS Camera Remote SDK")
            for relative, data in files.items():
                target = destination / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
    print(f"Installed Sony SDK in {destination}. Regenerate the project before building.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: install-sony-sdk.py /path/to/CrSDK_Mac.zip")
    install(sys.argv[1])
