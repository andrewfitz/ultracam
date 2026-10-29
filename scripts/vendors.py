#!/usr/bin/env python3
"""Validated vendor build descriptions; paths are manifest-relative, never shell code.

This reader is deliberately inactive until manifest-driven project activation.
"""
import argparse
import hashlib
import json
import re
from pathlib import Path

SCHEMA_VERSION = 1
API_VERSION = 1
_FIELDS = {'schemaVersion', 'id', 'kinds', 'sources', 'publicHeaders',
           'headerSearchPaths', 'librarySearchPaths', 'frameworks', 'libraries', 'defines',
           'embedLibraries', 'tests', 'capabilities', 'sdk', 'resources', 'testBuild', 'testGroups'}
_NAME = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*$')
_ID = re.compile(r'^[a-z][a-z0-9-]*$')
_DEFINE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*(?:=[A-Za-z0-9_.-]+)?$')

def _check(condition, message):
    if not condition:
        raise ValueError(message)

def _strings(value, field):
    _check(isinstance(value, list) and all(isinstance(v, str) for v in value), f'{field} must be a string list')
    _check(len(value) == len(set(value)), f'{field} has duplicates')
    return value

def _path(value, base, roots, field, exists=True):
    _check(isinstance(value, str) and value and '\x00' not in value, f'{field} must be a path')
    _check(not Path(value).is_absolute(), f'{field} must be manifest-relative')
    path = (base / value).resolve()
    _check(any(path.is_relative_to(root) and path != root for root in roots), f'{field} escapes allowed roots: {value}')
    _check(not exists or path.exists(), f'{field} does not exist: {value}')
    return str(path)

def validate_manifest(value, manifest_path, checkout_root, sdk_roots=()):
    """Return normalized data or ValueError. Unknown fields and flags fail closed."""
    _check(isinstance(value, dict), 'manifest must be an object')
    _check(not set(value) - _FIELDS, f'unknown manifest fields: {sorted(set(value) - _FIELDS)}')
    _check(type(value.get('schemaVersion')) is int and value['schemaVersion'] == SCHEMA_VERSION, 'unsupported schemaVersion')
    _check(isinstance(value.get('id'), str) and bool(_ID.fullmatch(value['id'])), 'invalid vendor id')
    kinds = _strings(value.get('kinds'), 'kinds')
    _check(bool(kinds) and set(kinds) <= {'capture', 'control'}, 'invalid kinds')
    root = Path(checkout_root).resolve()
    base = Path(manifest_path).resolve().parent
    _check(base.is_relative_to(root), 'manifest escapes checkout')
    roots = (root, *(Path(p).resolve() for p in sdk_roots))
    def normalized(path):
        resolved = Path(path)
        return resolved.relative_to(root).as_posix() if resolved.is_relative_to(root) else str(resolved)
    result = {'schemaVersion': SCHEMA_VERSION, 'id': value['id'], 'kinds': sorted(kinds)}
    sources = value.get('sources')
    _check(isinstance(sources, list), 'sources must be a list')
    result['sources'] = []
    seen = set()
    for source in sources:
        _check(isinstance(source, dict) and set(source) == {'path', 'membership'}, 'invalid source entry')
        members = _strings(source['membership'], 'membership')
        _check(bool(members) and set(members) <= {'app', 'test'}, 'vendor membership must be app/test')
        path = _path(source['path'], base, roots, 'source')
        _check(Path(path).suffix in {'.swift', '.m', '.mm', '.cpp', '.metal', '.h', '.inc'}, 'unsupported source type')
        _check(path not in seen, 'duplicate source path')
        seen.add(path)
        result['sources'].append({'path': normalized(path), 'membership': sorted(members)})
    result['resources'] = []
    resources = value.get('resources', [])
    _check(isinstance(resources, list), 'resources must be a list')
    for entry in resources:
        _check(isinstance(entry, dict) and set(entry) == {'path', 'membership'}, 'invalid resource entry')
        membership = _strings(entry['membership'], 'resource membership')
        _check(bool(membership) and set(membership) <= {'app', 'test'}, 'vendor resource membership must be app/test')
        path = Path(_path(entry['path'], base, (root,), 'resource'))
        _check(path.is_file() or path.suffix == '.xcassets', 'unsupported resource directory')
        result['resources'].append({'path': normalized(path), 'membership': sorted(membership)})
    for field in ('publicHeaders', 'headerSearchPaths', 'librarySearchPaths'):
        paths = _strings(value.get(field, []), field)
        result[field] = [normalized(_path(p, base, roots, field, exists=field == 'publicHeaders')) for p in paths]
    for field in ('frameworks', 'libraries'):
        entries = _strings(value.get(field, []), field)
        _check(all(_NAME.fullmatch(entry) for entry in entries), f'invalid {field}')
        result[field] = sorted(entries)
    defines = _strings(value.get('defines', []), 'defines')
    _check(all(_DEFINE.fullmatch(entry) for entry in defines), 'invalid defines')
    result['defines'] = sorted(defines)
    result['embedLibraries'] = []
    embeds = value.get('embedLibraries', [])
    _check(isinstance(embeds, list), 'embedLibraries must be a list')
    for entry in embeds:
        _check(isinstance(entry, dict) and set(entry) == {'path', 'subfolder'}, 'invalid embed library')
        folder = entry['subfolder']
        _check(isinstance(folder, str) and (not folder or bool(re.fullmatch(r'[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*', folder))), 'invalid embed subfolder')
        path = _path(entry['path'], base, roots, 'embedded library', exists=False)
        _check(Path(path).suffix == '.dylib', 'embedded file must be a dylib')
        result['embedLibraries'].append({'path': normalized(path), 'subfolder': folder})
    tests = _strings(value.get('tests', []), 'tests')
    result['tests'] = [normalized(_path(p, base, (root,), 'test entry point')) for p in tests]
    capabilities = value.get('capabilities', {})
    _check(isinstance(capabilities, dict) and not set(capabilities) - {'entitlements', 'infoPlist'}, 'invalid capabilities')
    result['capabilities'] = {key: sorted(_strings(capabilities.get(key, []), key)) for key in ('entitlements', 'infoPlist')}
    build_fields = {'headerSearchPaths', 'librarySearchPaths', 'frameworks', 'libraries', 'defines', 'embedLibraries'}
    result['testBuild'] = {key: [] for key in sorted(build_fields)}
    if 'testBuild' in value:
        test_build = value['testBuild']
        _check(isinstance(test_build, dict) and not set(test_build) - build_fields, 'invalid testBuild fields')
        checked = validate_manifest(dict(schemaVersion=SCHEMA_VERSION, id=value['id'], kinds=kinds,
            sources=[], **test_build), manifest_path, checkout_root, sdk_roots)
        result['testBuild'] = {key: checked[key] for key in sorted(build_fields)}
    groups = value.get('testGroups', {})
    _check(isinstance(groups, dict), 'testGroups must be an object')
    result['testGroups'] = {}
    for name, group in groups.items():
        _check(isinstance(name, str) and bool(_ID.fullmatch(name)), 'invalid test group id')
        _check(isinstance(group, dict) and not set(group) - {'swiftSources', 'nativeSources', 'sdk', 'python', 'build'}, 'invalid test group fields')
        checked = {}
        for field, suffixes in (('swiftSources', {'.swift'}), ('nativeSources', {'.mm', '.m', '.cpp'})):
            entries = _strings(group.get(field, []), field)
            paths = [_path(path, base, roots, field) for path in entries]
            _check(all(Path(path).suffix in suffixes for path in paths), f'invalid {field} extension')
            checked[field] = [normalized(path) for path in paths]
        use_sdk = group.get('sdk', False)
        _check(type(use_sdk) is bool, 'test group sdk must be a boolean')
        checked['sdk'] = use_sdk
        group_build = group.get('build', {})
        _check(isinstance(group_build, dict) and not set(group_build) - build_fields, 'invalid test group build')
        checked_build = validate_manifest(dict(schemaVersion=SCHEMA_VERSION, id=value['id'], kinds=kinds,
            sources=[], **group_build), manifest_path, checkout_root, sdk_roots)
        checked['build'] = {key: checked_build[key] for key in sorted(build_fields)}
        if 'python' in group:
            path = _path(group['python'], base, (root,), 'python test')
            _check(Path(path).suffix == '.py', 'python test must end in .py')
            checked['python'] = normalized(path)
        _check(checked['swiftSources'] or checked['nativeSources'] or 'python' in checked, 'empty test group')
        result['testGroups'][name] = checked
    sdk = value.get('sdk')
    if sdk is not None:
        _check(isinstance(sdk, dict) and set(sdk) <= {'policy', 'version', 'requiredFiles', 'sha256', 'optional', 'enabledBuild', 'root', 'fileSHA256', 'archiveLayout', 'externalDrivers'} and {'policy', 'version', 'requiredFiles'} <= set(sdk), 'invalid sdk')
        _check(sdk['policy'] in {'vendored', 'download', 'local'}, 'invalid SDK policy')
        _check(isinstance(sdk['version'], str) and bool(sdk['version']), 'invalid SDK version')
        required = _strings(sdk['requiredFiles'], 'SDK requiredFiles')
        _check(bool(required), 'SDK predicate needs requiredFiles')
        required_paths = [normalized(_path(p, base, roots, 'SDK required file', exists=False)) for p in required]
        archive_checksum = sdk.get('sha256')
        _check(archive_checksum is None or isinstance(archive_checksum, str) and bool(re.fullmatch(r'[0-9a-f]{64}', archive_checksum)), 'invalid SDK sha256')
        optional = sdk.get('optional', True)
        _check(type(optional) is bool, 'sdk.optional must be a boolean')
        enabled_build = sdk.get('enabledBuild', {})
        build_fields = {'headerSearchPaths', 'librarySearchPaths', 'frameworks', 'libraries', 'defines', 'embedLibraries'}
        _check(isinstance(enabled_build, dict) and not set(enabled_build) - build_fields, 'invalid SDK enabledBuild fields')
        conditional = validate_manifest(dict(schemaVersion=SCHEMA_VERSION, id=value['id'], kinds=kinds,
            sources=[], **enabled_build), manifest_path, checkout_root, sdk_roots)
        sdk_root = normalized(_path(sdk.get('root', 'SDK'), base, roots, 'SDK root', exists=False))
        pins = sdk.get('fileSHA256', {})
        _check(isinstance(pins, dict), 'SDK fileSHA256 must be an object')
        checked_pins = {}
        for path, file_checksum in pins.items():
            _check(isinstance(file_checksum, str) and bool(re.fullmatch(r'[0-9a-f]{64}', file_checksum)), 'invalid SDK file checksum')
            checked_path = normalized(_path(path, base, roots, 'SDK pin', exists=False))
            _check(Path(root / checked_path).is_relative_to(root / sdk_root), 'SDK pin escapes SDK root')
            checked_pins[checked_path] = file_checksum
        drivers = _strings(sdk.get('externalDrivers', []), 'SDK externalDrivers')
        for driver in drivers:
            candidate = Path(driver)
            _check(candidate.is_absolute() and str(candidate).startswith('/Library/') and len(candidate.parts) >= 4
                and candidate.suffix in {'.framework', '.bundle', '.dylib'} and '..' not in candidate.parts
                and not any(character in driver for character in ('*', '?', '\n', '\r', '\0')), 'invalid external driver root')
        layout = sdk.get('archiveLayout')
        if layout is not None:
            _check(isinstance(layout, dict) and not set(layout) - {'nestedArchive', 'mappings'}, 'invalid archiveLayout fields')
            nested = layout.get('nestedArchive')
            if nested is not None:
                _check(isinstance(nested, str) and nested and not Path(nested).is_absolute() and '..' not in Path(nested).parts
                    and nested.endswith('.zip') and not any(c in nested for c in ('\0', '\n', '\r')), 'invalid nested archive path')
            mappings = layout.get('mappings')
            _check(isinstance(mappings, list) and bool(mappings) and len(mappings) <= 16, 'archiveLayout mappings must be a bounded nonempty list')
            for mapping in mappings:
                _check(isinstance(mapping, dict) and set(mapping) == {'prefix', 'destination', 'flatten'}, 'invalid archive mapping')
                for field in ('prefix', 'destination'):
                    path = mapping[field]
                    _check(isinstance(path, str) and path and not Path(path).is_absolute() and '..' not in Path(path).parts
                        and not any(c in path for c in ('\0', '\n', '\r')), 'unsafe archive mapping path')
                _check(type(mapping['flatten']) is bool and mapping['prefix'].endswith('/'), 'invalid archive mapping format')
        result['sdk'] = dict(archiveLayout=layout, externalDrivers=drivers, fileSHA256=checked_pins, root=sdk_root, policy=sdk['policy'], version=sdk['version'], requiredFiles=required_paths,
                             sha256=archive_checksum, optional=optional,
                             enabledBuild={key: conditional[key] for key in sorted(build_fields)})
    return result

def load_manifests(checkout_root, sdk_roots=()):
    root = Path(checkout_root).resolve()
    manifests, ids = [], set()
    for path in sorted((root / 'Vendors').glob('*/vendor.json')):
        value = validate_manifest(json.loads(path.read_text()), path, root, sdk_roots)
        _check(value['id'] not in ids, f'duplicate vendor id: {value["id"]}')
        ids.add(value['id'])
        manifests.append(value)
    return manifests

def resolve_sdk_inventory(manifests, requested, checkout_root):
    """Only explicitly enabled SDKs are available, even when installed locally.

    Empty inventory is the committed canonical optional-SDK-absent state.
    An enabled SDK with missing predicate files fails instead of silently changing
    the generated project on a developer's machine.
    """
    _check(isinstance(requested, dict), 'SDK inventory must be an object')
    ids = {manifest['id'] for manifest in manifests}
    _check(not set(requested) - ids, 'SDK inventory names an unknown vendor')
    _check(all(type(value) is bool for value in requested.values()), 'SDK inventory values must be booleans')
    root = Path(checkout_root).resolve()
    result = {}
    for manifest in manifests:
        identity = manifest['id']
        sdk = manifest.get('sdk')
        optional = sdk is None or sdk['optional']
        enabled = requested.get(identity, not optional)
        _check(optional or enabled, f'{identity} SDK is required and cannot be disabled')
        _check(not enabled or sdk is not None, f'{identity} has no optional SDK')
        if enabled:
            for path in sdk['requiredFiles']:
                _check((root / path).is_file(), f'{identity} SDK requested but missing: {path}')
            for path, expected in sdk['fileSHA256'].items():
                actual = hashlib.sha256((root / path).read_bytes()).hexdigest()
                _check(actual == expected, f'{identity} SDK checksum mismatch: {path}; verify/install declared SDK {sdk["version"]}')
        result[identity] = dict(available=enabled, version=sdk['version'] if enabled else None,
                                reason=None if enabled else 'disabled by explicit SDK inventory')
    return result

def input_digest(manifests, sdk_inventory):
    payload = dict(schemaVersion=SCHEMA_VERSION, apiVersion=API_VERSION,
                   manifests=sorted(manifests, key=lambda value: value['id']), sdkInventory=sdk_inventory)
    return hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()).hexdigest()

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = Path('Sources/DeviceAPI/GeneratedBridgingHeader.h')
BUILD_FIELDS = ('headerSearchPaths', 'librarySearchPaths', 'frameworks', 'libraries', 'defines', 'embedLibraries')

def absolute(root, path):
    return str(Path(root) / path)

def read_inventory(root=ROOT, inventory_path=None, sdk_present=None, sdk_disabled=None):
    import os
    selected = inventory_path or os.environ.get('ULTRACAM_SDK_INVENTORY')
    requested = json.loads(Path(absolute(root, selected)).read_text()) if selected else {}
    _check(isinstance(requested, dict), 'SDK inventory must be an object')
    if sdk_present:
        requested[sdk_present] = True
    if sdk_disabled:
        requested[sdk_disabled] = False
    cache = os.environ.get('ULTRACAM_SDK_CACHE')
    roots = (Path(cache).resolve(),) if cache else ()
    manifests = load_manifests(root, roots)
    inventory = resolve_sdk_inventory(manifests, requested, root)
    # Pin enabled input files in the generated digest. Optional absent SDKs do
    # not inspect local files, so canonical generation is machine independent.
    for manifest in manifests:
        status = inventory[manifest['id']]
        if status['available']:
            status['files'] = {path: hashlib.sha256(Path(absolute(root, path)).read_bytes()).hexdigest()
                               for path in sorted(set(manifest['sdk']['requiredFiles']) | set(manifest['sdk']['fileSHA256']))}
    return manifests, inventory

def build_settings(manifests, inventory, membership='app', vendor=None):
    result = {field: [] for field in BUILD_FIELDS}
    for manifest in manifests:
        if vendor and manifest['id'] != vendor:
            continue
        layers = [manifest]
        if inventory[manifest['id']]['available']:
            layers.append(manifest['sdk']['enabledBuild'])
        if membership == 'test':
            layers.append(manifest['testBuild'])
        for layer in layers:
            for field in BUILD_FIELDS:
                for entry in layer.get(field, []):
                    if entry not in result[field]:
                        result[field].append(entry)
    return result

def source_paths(manifests, membership='app', suffixes=None, vendor=None):
    return sorted({entry['path'] for manifest in manifests if not vendor or manifest['id'] == vendor
                   for entry in manifest['sources'] if membership in entry['membership']
                   and (suffixes is None or Path(entry['path']).suffix in suffixes)})

def render_bridge(manifests):
    import os
    lines = ['// Generated by scripts/vendors.py; do not edit.',
             '#ifndef ULTRACAM_GENERATED_VENDOR_BRIDGE_H', '#define ULTRACAM_GENERATED_VENDOR_BRIDGE_H',
             '#import "DeviceAPI.h"']
    for manifest in manifests:
        for path in manifest['publicHeaders']:
            relative = os.path.relpath(path, str(BRIDGE.parent))
            lines.append(f'#import "{relative}"')
    lines += ['#include "../../Tools/auto-switcher/include/auto_switcher.h"', '#endif', '']
    return '\n'.join(lines)

def generate_bridge(root=ROOT, manifests=None):
    if manifests is None:
        manifests, _ = read_inventory(root)
    destination = Path(root) / BRIDGE
    destination.parent.mkdir(parents=True, exist_ok=True)
    text = render_bridge(manifests)
    if not destination.exists() or destination.read_text() != text:
        destination.write_text(text)

def check_capabilities(root, manifests, inventory):
    import plistlib
    root = Path(root)
    with (root / 'Config/App.entitlements').open('rb') as stream:
        entitlements = plistlib.load(stream)
    with (root / 'Config/App-Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    for manifest in manifests:
        if not inventory[manifest['id']]['available']:
            continue
        for field, actual in (('entitlements', entitlements), ('infoPlist', info)):
            for key in manifest['capabilities'][field]:
                _check(key in actual, f'{manifest["id"]} requires {field} key {key}')

def query_values(args, manifests, inventory):
    selected = [m for m in manifests if not args.vendor or m['id'] == args.vendor]
    _check(bool(selected), f'unknown vendor: {args.vendor}')
    group = None
    if args.group:
        _check(len(selected) == 1, 'test group requires one vendor')
        group = selected[0]['testGroups'].get(args.group)
        _check(group is not None, f'unknown test group: {args.group}')
    settings = build_settings(selected, inventory, args.membership)
    if group:
        for field in BUILD_FIELDS:
            for item in group['build'][field]:
                if item not in settings[field]: settings[field].append(item)
    root = args.root
    kind = args.kind
    if kind == 'group-sdk':
        return ['1' if group and group['sdk'] else '0']
    if kind in ('swift-sources', 'native-sources'):
        field = 'swiftSources' if kind == 'swift-sources' else 'nativeSources'
        suffixes = {'.swift'} if kind == 'swift-sources' else {'.mm', '.m', '.cpp'}
        paths = group.get(field, []) if group else source_paths(selected, args.membership, suffixes)
        return [absolute(root, path) for path in paths]
    if kind in ('header-dirs', 'library-dirs'):
        field = 'headerSearchPaths' if kind == 'header-dirs' else 'librarySearchPaths'
        return [absolute(root, path) for path in settings[field]]
    if kind == 'defines':
        return settings['defines']
    if kind == 'link-flags':
        return [value for framework in settings['frameworks'] for value in ('-framework', framework)] + ['-l' + value for value in settings['libraries']]
    if kind == 'bridge-header':
        _check(len(selected) == 1, 'bridge-header requires one vendor')
        return [absolute(root, path) for path in selected[0]['publicHeaders']]
    if kind == 'sdk-root':
        _check(len(selected) == 1 and 'sdk' in selected[0], 'SDK root requires one SDK vendor')
        return [absolute(root, selected[0]['sdk']['root'])]
    if kind == 'python-test':
        _check(group is not None and 'python' in group, 'group is not a Python test')
        return [absolute(root, group['python'])]
    if kind == 'embed-json':
        return [json.dumps([dict(path=absolute(root, value['path']), subfolder=value['subfolder']) for value in settings['embedLibraries']])]
    raise ValueError(f'unknown query: {kind}')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('validate', 'status', 'digest', 'generate', 'check-generated', 'query', 'check-capabilities', 'run-tests'))
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--sdk-inventory', type=Path)
    parser.add_argument('--sdk-present')
    parser.add_argument('--vendor')
    parser.add_argument('--group')
    parser.add_argument('--membership', choices=('app', 'test'), default='app')
    parser.add_argument('--kind')
    parser.add_argument('--null', action='store_true')
    parser.add_argument('--expected-digest')
    args = parser.parse_args()
    try:
        forced_sdk, disabled_sdk = args.sdk_present, None
        if args.vendor and args.group:
            import os
            cache = os.environ.get('ULTRACAM_SDK_CACHE')
            preliminary = load_manifests(args.root, (Path(cache).resolve(),) if cache else ())
            record = next((m for m in preliminary if m['id'] == args.vendor), None)
            _check(record is not None and args.group in record['testGroups'], 'unknown vendor test group')
            if record['testGroups'][args.group]['sdk']: forced_sdk = args.vendor
            else: disabled_sdk = args.vendor
        manifests, inventory = read_inventory(args.root, args.sdk_inventory, forced_sdk, disabled_sdk)
        digest = input_digest(manifests, inventory)
        if args.command == 'query':
            import sys
            values = query_values(args, manifests, inventory)
            separator = '\0' if args.null else '\n'
            sys.stdout.write(separator.join(values) + (separator if values else ''))
        elif args.command == 'digest':
            print(digest)
        elif args.command == 'generate':
            generate_bridge(args.root, manifests)
            check_capabilities(args.root, manifests, inventory)
            print(digest)
        elif args.command == 'check-generated':
            _check(args.expected_digest == digest, 'generated Xcode inputs are stale; run python3 scripts/generate_project.py with your explicit SDK inventory')
            _check((args.root / BRIDGE).is_file() and (args.root / BRIDGE).read_text() == render_bridge(manifests), 'generated bridge is stale; run python3 scripts/generate_project.py')
            check_capabilities(args.root, manifests, inventory)
        elif args.command == 'run-tests':
            import subprocess, sys
            for manifest in manifests:
                for entry in manifest['tests']:
                    path = absolute(args.root, entry)
                    _check(Path(path).suffix in {'.sh', '.py'}, 'test entry point must be a shell or Python file')
                    command = [sys.executable, path] if Path(path).suffix == '.py' else ['/bin/bash', path]
                    completed = subprocess.run(command, cwd=args.root)
                    _check(completed.returncode == 0, f'{manifest["id"]} test entry point failed: {entry}')
        elif args.command == 'check-capabilities':
            check_capabilities(args.root, manifests, inventory)
        elif args.command == 'status':
            print(json.dumps(inventory, sort_keys=True, indent=2))
        else:
            print(f'Validated {len(manifests)} vendor manifests')
    except (ValueError, OSError) as error:
        parser.exit(1, f'vendors.py: {error}\n')

if __name__ == '__main__':
    main()
