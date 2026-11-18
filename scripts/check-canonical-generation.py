#!/usr/bin/env python3
"""Regenerate canonical files without inheriting a developer's SDK/cache profile."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
GENERATED = ('Ultracam.xcodeproj/project.pbxproj', 'Sources/DeviceAPI/GeneratedBridgingHeader.h',
             'Ultracam.xcodeproj/xcshareddata/xcschemes/Ultracam.xcscheme')


def verify_canonical(root=ROOT, *, runner=subprocess.run, environ=None):
    root = Path(root)
    environment = dict(os.environ if environ is None else environ)
    for name in ('ULTRACAM_SDK_INVENTORY', 'ULTRACAM_WORK_ROOT', 'ULTRACAM_SDK_CACHE',
                 'AUTO_SWITCHER_LIB_DIR', 'CARGO_TARGET_DIR', 'ULTRACAM_DERIVED_DATA_PATH'):
        environment.pop(name, None)
    with tempfile.TemporaryDirectory() as work:
        output = Path(work)
        runner([sys.executable, str(root / 'scripts/generate_project.py'),
                '--output-dir', str(output / 'Ultracam.xcodeproj'),
                '--bridge-output', str(output / 'Sources/DeviceAPI/GeneratedBridgingHeader.h')],
               cwd=root, env=environment, check=True)
        changed = [name for name in GENERATED if not (root / name).is_file()
                   or (root / name).read_bytes() != (output / name).read_bytes()]
    if changed:
        raise ValueError('Canonical generation differs: ' + ', '.join(changed)
                         + '; run python3 scripts/generate_project.py without a local SDK/cache profile')


if __name__ == '__main__':
    try:
        verify_canonical()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from error
    print('Canonical project and bridge match generation.')
