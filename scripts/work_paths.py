#!/usr/bin/env python3
"""Resolve build locations without creating, deleting, or changing any files.

ULTRACAM_WORK_ROOT accepts an absolute path or a path relative to the checkout.
The default is the checkout's .build directory. Shell callers should quote
command substitution: root="$(python3 scripts/work_paths.py --path work_root)".
Never eval this program's output. No shell code is emitted.
"""
import argparse
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
LAYOUT = {
    'tmp_root': 'tmp',
    'artifact_root': 'agent-work/ultracam',
    'logs_root': 'agent-work/ultracam/logs',
    'build_root': 'agent-work/build/ultracam',
    'package_cache_root': 'agent-work/build/ultracam/monitor-kit-package-cache',
}


def _directory_path(path):
    """Check existing ancestors, including aliases, without writing probe files."""
    if any(c in str(path) for c in ('\0', '\n', '\r')):
        raise ValueError('Work paths must be single-line paths')
    resolved = path.resolve()
    if any(c in str(resolved) for c in ('\0', '\n', '\r')):
        raise ValueError('Work paths must resolve to single-line paths')
    for ancestor in (path, *path.parents, resolved, *resolved.parents):
        if ancestor.exists() and not ancestor.is_dir():
            raise ValueError(f'Work path has a non-directory ancestor: {ancestor}')
    return resolved


def _within(path, directory):
    if path.is_relative_to(directory):
        return True
    # resolve() preserves alternate casing on case-insensitive macOS volumes.
    return directory.exists() and any(
        ancestor.exists() and ancestor.samefile(directory) for ancestor in (path, *path.parents)
    )


def _strictly_within(path, directory):
    return _within(path, directory) and not _within(directory, path)


def work_paths(checkout=ROOT, *, environ=None):
    """Return validated absolute Paths; relative overrides are checkout-relative.

    Only the designated .build subtree may overlap the source checkout. Derived directory symlinks
    cannot escape the work root. Callers create only the directories they need;
    filesystem permission errors belong to those actual write operations.
    """
    environ = os.environ if environ is None else environ
    checkout = Path(checkout).resolve()
    if 'ULTRACAM_WORK_ROOT' in environ:
        value = environ['ULTRACAM_WORK_ROOT']
        if not value or not value.strip() or any(c in value for c in ('\0', '\n', '\r')):
            raise ValueError('ULTRACAM_WORK_ROOT must be a nonempty single-line path')
        requested = Path(value).expanduser()
        if not requested.is_absolute():
            requested = checkout / requested
    else:
        requested = checkout / '.build'
    root = _directory_path(requested)
    checkout_build = checkout / '.build'
    if _within(checkout, root) or (_within(root, checkout) and
                                   (checkout_build.is_symlink() or not _within(root, checkout_build))):
        raise ValueError('Work root must be outside the source checkout or in its .build subtree')
    paths = {'work_root': root}
    for name, relative in LAYOUT.items():
        path = _directory_path(root / relative)
        if not _strictly_within(path, root):
            raise ValueError(f'Derived work path escapes work root: {name}')
        paths[name] = path
    for child, parent in (('logs_root', 'artifact_root'), ('package_cache_root', 'build_root')):
        if not _strictly_within(paths[child], paths[parent]):
            raise ValueError(f'{child} must stay inside {parent}')
    separate_roots = ('tmp_root', 'artifact_root', 'build_root')
    for index, name in enumerate(separate_roots):
        for other in separate_roots[index + 1:]:
            if _within(paths[name], paths[other]) or _within(paths[other], paths[name]):
                raise ValueError(f'Work paths must be separate: {name}, {other}')
    return paths


def work_root(checkout=ROOT, *, environ=None):
    return work_paths(checkout, environ=environ)['work_root']


def derived_data_path(value, checkout=ROOT, *, environ=None):
    """Permit reuse only in the build subtree, never source/artifact locations."""
    if not str(value).strip():
        raise ValueError('DerivedData must be a nonempty path')
    paths = work_paths(checkout, environ=environ)
    requested = Path(value).expanduser()
    if not requested.is_absolute():
        requested = paths['build_root'] / requested
    candidate = _directory_path(requested)
    if not _strictly_within(candidate, paths['build_root']):
        raise ValueError('DerivedData must stay inside the configured build root')
    return candidate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    query = parser.add_mutually_exclusive_group()
    query.add_argument('--path', choices=['work_root', *LAYOUT])
    query.add_argument('--derived-data')
    args = parser.parse_args()
    try:
        paths = work_paths()
        derived = derived_data_path(args.derived_data) if args.derived_data is not None else None
    except (ValueError, OSError, RuntimeError) as error:
        parser.exit(2, f'work_paths: {error}\n')
    if derived is not None:
        print(derived)
    elif args.path:
        print(paths[args.path])
    else:
        print(json.dumps({name: str(path) for name, path in paths.items()}, sort_keys=True))


if __name__ == '__main__':
    main()
