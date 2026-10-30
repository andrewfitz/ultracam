#!/usr/bin/env python3
"""Verify pinned vendor SDKs or install a developer-provided ZIP. Never downloads.

Paths and SHA256 pins come from validated vendor manifests. Installation refuses
existing SDK payloads, stages and verifies first, then publishes without replacing
files. A tracked README-only SDK directory is preserved.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import sys
import tempfile
import zipfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
STAMP = '.ultracam-sdk.json'
MAX_BYTES = 2 * 1024**3


def _hash(data):
    return hashlib.sha256(data).hexdigest()


def _safe_name(name):
    path = PurePosixPath(name)
    if not name or '\\' in name or '\0' in name or path.is_absolute() or '..' in path.parts or ':' in name:
        raise ValueError(f'Unsafe SDK archive/path: {name!r}')
    return path


def _config(manifest, checkout, sdk_roots=()):
    checkout = Path(checkout).resolve()
    if not manifest.get('sdk'):
        raise ValueError('This vendor has no SDK to install')
    sdk = manifest['sdk']
    requested = Path(sdk['root'])
    if not requested.is_absolute():
        _safe_name(sdk['root'])
        requested = checkout / requested
    # SDK destinations are dedicated vendor SDK trees, never Sources or checkout.
    relative = requested.relative_to(checkout) if requested.is_relative_to(checkout) else None
    allowed = relative is not None and len(relative.parts) == 3 and relative.parts[0] == 'Vendors' and relative.parts[2] == 'SDK'
    allowed = allowed or any(requested.is_relative_to(Path(p).resolve()) and requested != Path(p).resolve() for p in sdk_roots)
    if not allowed or requested.is_symlink():
        raise ValueError('SDK root is outside allowed dedicated SDK roots or is a symlink')
    root = requested.resolve()
    if root != requested or any(parent.exists() and not parent.is_dir() for parent in (root, *root.parents)):
        raise ValueError('SDK root contains a symlink or non-directory ancestor')
    pins = {}
    for key, checksum in sdk.get('fileSHA256', {}).items():
        path = Path(key)
        if not path.is_absolute():
            _safe_name(key)
            path = checkout / path
        if not path.is_relative_to(root) or path == root or not re.fullmatch('[0-9a-f]{64}', checksum):
            raise ValueError('Invalid SDK file pin or path outside SDK root')
        pins[path.relative_to(root).as_posix()] = checksum
    required = []
    for key in sdk['requiredFiles']:
        path = Path(key)
        if not path.is_absolute():
            _safe_name(key)
            path = checkout / path
        if not path.is_relative_to(root) or path == root:
            raise ValueError('Required SDK file escapes SDK root')
        required.append(path.relative_to(root).as_posix())
    if not pins or not set(required) <= pins.keys():
        raise ValueError('Every required SDK file needs a pinned SHA256')
    if not isinstance(sdk['version'], str) or not sdk['version']:
        raise ValueError('SDK version is required')
    return sdk, root, pins, required


def _verify_tree(root, sdk, pins):
    for name, checksum in pins.items():
        path = root / name
        if path.is_symlink() or path.resolve() != path or not path.is_file():
            raise ValueError(f'Missing or unsafe SDK file: {name}')
        if _hash(path.read_bytes()) != checksum:
            raise ValueError(f'SDK checksum mismatch: {name}')
    stamp = root / STAMP
    if stamp.exists():
        if stamp.is_symlink():
            raise ValueError('Unsafe SDK version stamp')
        if json.loads(stamp.read_text()).get('version') != sdk['version']:
            raise ValueError('Installed SDK version does not match manifest')


def verify(manifest, checkout=ROOT, sdk_roots=()):
    if not manifest.get('sdk'):
        return {'id': manifest['id'], 'available': True, 'version': None, 'reason': 'System frameworks; no SDK required'}
    sdk, root, pins, _ = _config(manifest, checkout, sdk_roots)
    _verify_tree(root, sdk, pins)
    return {'id': manifest['id'], 'available': True, 'version': sdk['version'], 'root': str(root), 'reason': 'Pinned SDK verified'}


def status(manifest, checkout=ROOT, sdk_roots=()):
    try:
        return verify(manifest, checkout, sdk_roots)
    except (ValueError, OSError, zipfile.BadZipFile) as error:
        sdk = manifest.get('sdk', {})
        reason = str(error)
        if sdk.get('optional', True):
            reason += '; optional SDK unavailable: source build remains supported with this plugin unavailable'
        return {'id': manifest['id'], 'available': False, 'version': sdk.get('version'), 'reason': reason}


def _zip_files(archive):
    files, names, total = {}, set(), 0
    with zipfile.ZipFile(archive) as source:
        if len(source.infolist()) > 20000:
            raise ValueError('SDK archive has too many entries')
        for entry in source.infolist():
            path = _safe_name(entry.filename)
            name = path.as_posix()
            key = name.casefold()
            if key in names:
                raise ValueError(f'Duplicate SDK archive path: {name}')
            names.add(key)
            mode = entry.external_attr >> 16
            if stat.S_ISLNK(mode) or (stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR)):
                raise ValueError('SDK archive links and special files are forbidden')
            if entry.is_dir():
                continue
            total += entry.file_size
            if total > MAX_BYTES:
                raise ValueError('SDK archive exceeds size limit')
            files[name] = source.read(entry)
    return files


def _archive_files(archive, layout=None):
    files = _zip_files(archive)
    if layout is None:
        return files
    nested_name = str(_safe_name(layout['nestedArchive']))
    if nested_name not in files:
        raise ValueError(f'Missing nested SDK archive: {nested_name}')
    nested = _zip_files(io.BytesIO(files[nested_name]))
    mapped, names = {}, set()
    for name, data in nested.items():
        for mapping in layout['mappings']:
            prefix = mapping['prefix']
            _safe_name(prefix)
            destination = _safe_name(mapping['destination'])
            if not prefix.endswith('/') or not isinstance(mapping['flatten'], bool):
                raise ValueError('Invalid SDK archive mapping')
            if not name.startswith(prefix):
                continue
            suffix = PurePosixPath(name).name if mapping['flatten'] else name[len(prefix):]
            target = str(destination / _safe_name(suffix))
            if target.casefold() in names:
                raise ValueError('Duplicate mapped SDK archive path')
            mapped[target] = data
            names.add(target.casefold())
    return mapped


def install(manifest, checkout, archive, sdk_roots=()):
    sdk, destination, pins, _ = _config(manifest, checkout, sdk_roots)
    if sdk['policy'] != 'local':
        raise ValueError('Only locally installed SDK policy accepts install; vendored SDKs are verified in place')
    if destination.exists():
        entries = list(destination.iterdir())
        if any(p.name != 'README.md' or p.is_symlink() or not p.is_file() for p in entries):
            raise ValueError('SDK destination contains existing payload; refusing to replace installed files')
    archive = Path(archive)
    checksum = _hash(archive.read_bytes())
    if sdk.get('sha256') and checksum != sdk['sha256']:
        raise ValueError('SDK archive checksum mismatch')
    files = _archive_files(archive, sdk.get('archiveLayout'))
    if STAMP in files and json.loads(files[STAMP]).get('version') != sdk['version']:
        raise ValueError('SDK archive version does not match manifest')
    # Check all pins before writing even a staging tree. Only pinned files ship.
    for name, expected in pins.items():
        if name not in files or _hash(files[name]) != expected:
            raise ValueError(f'Missing SDK file or checksum mismatch: {name}')
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='.sdk-stage-', dir=destination.parent))
    try:
        for name in pins:
            target = stage / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(files[name])
        (stage / STAMP).write_text(json.dumps({'vendor': manifest['id'], 'version': sdk['version'], 'archiveSHA256': checksum}, sort_keys=True) + '\n')
        _verify_tree(stage, sdk, pins)
        if destination.is_symlink():
            raise ValueError('SDK destination became a symlink while staging')
        if destination.exists():
            # A fresh checkout carries only the tracked README. Publish each
            # verified file exclusively; never replace that file or any payload.
            entries = list(destination.iterdir())
            if any(p.name != 'README.md' or p.is_symlink() or not p.is_file() for p in entries):
                raise ValueError('SDK destination contains existing payload; refusing replacement')
            created = []
            created_directories = []
            try:
                for source in sorted(stage.rglob('*')):
                    if source.is_file():
                        target = destination / source.relative_to(stage)
                        missing = []
                        parent = target.parent
                        while not parent.exists():
                            missing.append(parent)
                            parent = parent.parent
                        for parent in reversed(missing):
                            parent.mkdir()
                            created_directories.append(parent)
                        os.link(source, target)
                        created.append(target)
            except BaseException:
                for target in reversed(created):
                    target.unlink()
                for directory in reversed(created_directories):
                    try:
                        directory.rmdir()
                    except OSError:
                        # Never remove contents introduced by another owner.
                        # Keep the original publication failure as the error.
                        pass
                raise
        else:
            stage.rename(destination)
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    return verify(manifest, checkout, sdk_roots)


def main():
    from vendors import load_manifests
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkout-root', type=Path, default=ROOT)
    parser.add_argument('--sdk-root', type=Path, action='append', default=[])
    parser.add_argument('--json', action='store_true')
    parser.add_argument('command', choices=['status', 'verify', 'install'])
    parser.add_argument('vendor', nargs='?')
    parser.add_argument('archive', nargs='?', type=Path)
    args = parser.parse_args()
    try:
        manifests = load_manifests(args.checkout_root, args.sdk_root)
        selected = [m for m in manifests if args.vendor is None or m['id'] == args.vendor]
        if not selected or (args.command != 'status' and not args.vendor):
            raise ValueError('Select a known vendor id')
        if args.command == 'install' and args.archive is None:
            raise ValueError('install requires a developer-provided ZIP archive')
        if args.command != 'install' and args.archive is not None:
            raise ValueError('Archive argument is only valid for install')
        results = []
        for manifest in selected:
            if args.command == 'install':
                results.append(install(manifest, args.checkout_root, args.archive, args.sdk_root))
            else:
                results.append(globals()[args.command](manifest, args.checkout_root, args.sdk_root))
        if args.json:
            print(json.dumps(results, sort_keys=True))
        else:
            for result in results:
                print(f"{result['id']}: {result.get('version') or 'system'}: {result['reason']}")
    except (ValueError, OSError, zipfile.BadZipFile, RuntimeError) as error:
        parser.exit(2, f'vendor-sdk: {error}\n')


if __name__ == '__main__':
    main()
