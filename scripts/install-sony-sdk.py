#!/usr/bin/env python3
"""Compatibility entry point for the manifest-driven local SDK installer."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

def install(archive):
    subprocess.run([sys.executable, str(ROOT / "scripts/vendor-sdk.py"),
                    "install", "sony", str(archive)], check=True)

if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: install-sony-sdk.py /path/to/CrSDK_Mac.zip")
    try:
        install(sys.argv[1])
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.returncode) from error
