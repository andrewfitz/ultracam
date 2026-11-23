#!/usr/bin/env python3
"""Find the complete Auto Switcher package used by Cargo and the C bridge."""
from pathlib import Path
import sys

AUTO_SWITCHER_LOCATIONS = ('../auto-switcher', 'Apps/AutoSwitcher')


def auto_switcher_source(root):
    required = ('Cargo.toml', 'Cargo.lock', 'src/lib.rs', 'include/auto_switcher.h')
    for relative in AUTO_SWITCHER_LOCATIONS:
        candidate = root / relative
        if all((candidate / path).is_file() for path in required):
            return candidate
    raise ValueError('Auto Switcher source is incomplete in ../auto-switcher and Apps/AutoSwitcher.')


if __name__ == '__main__':
    try:
        print(auto_switcher_source(Path(__file__).resolve().parents[1]))
    except ValueError as error:
        sys.exit(str(error))
