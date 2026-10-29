#!/usr/bin/env python3
"""Lint organizational vendor boundaries; this is not compiler isolation.

Scans source text (including comments/strings for brand wording), derives known
symbols from current declarations, and checks the actual generated PBX targets.
This catches known coupling, not every possible dependency of a single module.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
import vendors

SOURCE_SUFFIXES = {'.swift', '.h', '.m', '.mm', '.cpp', '.metal', '.inc'}
BRAND = re.compile(r'blackmagic|ultrastudio|decklink|sony|fx3', re.I)
SDK_SYMBOL = re.compile(r'\b(?:IDeckLink\w*|BMD\w+|bmd[A-Z]\w*|UCDeckLink\w*|Cr(?:Device|Camera|Error|Command|Property)\w*|SCRSDK\w*)\b')
IMPORT = re.compile(r'^\s*(?:@(?:testable|preconcurrency)\s+)?import\s+(\w+)|^\s*#\s*(?:import|include)\s*[<"]([^>"\n]+)', re.M)
DECL = re.compile(r'\b(?:enum\s+class|class|struct|enum|protocol|typealias|actor)\s+(\w+)|@(?:interface|protocol)\s+(\w+)')
FAKE = re.compile(r'\b(?:Fake(?:Capture|Control)\w*|AppHardwareSyntheticFixture)\b')
REGISTRY = 'Sources/DeviceAPI/VendorRegistry.swift'
BRIDGE = 'Sources/DeviceAPI/GeneratedBridgingHeader.h'
# Named colour-science identifiers are not plugin dependencies. Only these
# tokens/literals are removed; adding an SDK call on the same line still fails.
COLOR = re.compile(r'\b(?:SonySLog3FalseColor|SonyARRIStyleFalseColor|sonySLog3)\b|"sony-slog3-sgamut3(?:cine)?"|"Blackmagic Wide Gamut / Film Gen 5"|"FX3_SLog3_to_709\.cube"')
EXACT = {
    'Sources/App/UIContext.swift': ('"UltraStudio Mini Recorder 12G"', '"ultrastudio-4k-mini"', '"UltraStudio 4K Mini"'),
    'Sources/App/VendorSettingsStore.swift': ('"decklink:advertiseHDRToCameras"', '"decklink"'),
    'Sources/App/CameraControlStore.swift': ('"ui.sony.controls.v1"', '"sony"', '"ui.camera.controls.sony-migrated.v1"'),
    'Sources/App/MonitorFeedHost.swift': ("Sony's tables need S-Log3",),
    'Sources/Shared/MonitorWorkspace.swift': ("Sony's Pattern 2 on", "ARRI-style S-Log3 mode into Sony's."),
    'Sources/App/UISupport.swift': ("Sony's Pattern 2 on S-Log3",),
    'Sources/App/UIMonitorToolControls.swift': ('"Sony S-Log3"',),
    'Sources/App/UIMonitorToolFalseColor.swift': ('"Sony S-Gamut3.Cine / S-Log3"', '"Sony S-Gamut3 / S-Log3"',
        '"Sony source IRE thresholds are independent of EI and don\'t guarantee sensor clipping."',
        '"Declare the Sony S-Log3 profile that matches the camera."',
        '"ARRI-style bands need a Sony S-Gamut3 or S-Gamut3.Cine / S-Log3 source."'),
    'Sources/App/UIMonitorToolScreens.swift': ('A camera declared as Sony S-Gamut3.Cine / S-Log3', '"sony"'),
    'Sources/App/UIMonitorToolForms.swift': ("The safe areas offered: FX3's 80 and 90",),
    'Sources/App/UISettings.swift': ('Sony S-Log3 and ARRI LogC modes require the matching source declaration.',),
    'Sources/App/UIMonitorToolVerify.swift': ('"false color: Sony on S-Log3"', '"false color: no Sony table on LogC3"',
        '"declaring LogC switches Sony false color to ARRI\'s"', '"declaring S-Log3 switches ARRI false color to Sony\'s"'),
    'Config/App-Info.plist': ('Capture your UltraStudio feed to apply a LUT and publish a processed camera.',
                              'Discover and control Sony cameras over Wi-Fi while video arrives over HDMI.'),
    'Config/App.entitlements': ('DeckLinkAPI is loaded from the installed, Blackmagic-signed driver.',
                              'com.blackmagic-design.desktopvideo.DeckLinkHardwareXPCService',
                              'com.blackmagic-design.desktopvideo.prefspanel'),
}


def code_only(text):
    """Mask strings/comments without changing positions (for symbol checks)."""
    return re.sub(r'//[^\n]*|/\*[\s\S]*?\*/|"""[\s\S]*?"""|"(?:\\.|[^"\\])*"',
                  lambda m: ''.join('\n' if c == '\n' else ' ' for c in m[0]), text)


def declared_symbols(text, native=False):
    code = code_only(text)
    result = set()
    # Top-level Swift functions and exported C functions, not every generic
    # member named start/stop. Depth is measured on masked code.
    depth = 0
    for line in code.splitlines():
        if depth == 0:
            result.update(a or b for a, b in DECL.findall(line))
            result.update(re.findall(r'\bfunc\s+(\w+)\s*\(', line))
            native_match = re.match(r'^\s*(?:(?:FOUNDATION_EXPORT|extern)\s+)?[A-Za-z_][\w:<>, \t*]*\s+([A-Za-z_]\w*)\s*\([^;{}]*\)\s*(?:;|\{)', line)
            if native_match and native and not re.search(r'\b(?:typedef|func|if|while|switch|return)\b', line):
                result.add(native_match[1])
        depth += line.count('{') - line.count('}')
    return result


def masked_exceptions(path, text):
    result = COLOR.sub(lambda m: ' ' * len(m[0]), text)
    # Camera colour science profiles describe source encoding, not vendor SDK
    # coupling. Restrict identifiers and display names to the four consumers.
    if path in {'Sources/Shared/SourceFormat.swift', 'Sources/Shared/FormatDisplayIdentity.swift',
                'Sources/App/SourceColorSpaceCatalog.swift', 'Sources/App/MonitorFeedHost.swift'}:
        result = re.sub(r'\b(?:blackmagicWideGamutGen5|blackmagicFilmGen5)\b',
                        lambda m: ' ' * len(m[0]), result)
        if path == 'Sources/Shared/FormatDisplayIdentity.swift':
            for name in ('"Blackmagic Wide Gamut Gen 5"', '"Blackmagic Film Gen 5"'):
                result = result.replace(name, ' ' * len(name))
        if path == 'Sources/App/SourceColorSpaceCatalog.swift':
            name = '"blackmagic-film-gen5-widegamut"'
            result = result.replace(name, ' ' * len(name))
    for exact in EXACT.get(path, ()):
        result = result.replace(exact, ' ' * len(exact))
    # Local names in the colour-science evaluation fixtures; exact identifiers,
    # never an entire file or arbitrary string containing a brand.
    local_color_names = {'Sources/App/MonitorFeedHost.swift': r'\bsony\b',
                         'Sources/App/UIMonitorToolVerify.swift': r'\b(?:sony|sonyWide|toSony)\b'}
    if path in local_color_names:
        result = re.sub(local_color_names[path], lambda m: ' ' * len(m[0]), result)
    if path == REGISTRY:
        # Only concrete constructor names in the capture/control registration
        # arrays, not arbitrary use elsewhere in this file.
        pattern = r'(static\s+let\s+(?:capture|control)\s*:\s*\[any\s+(?:CaptureSourcePlugin|CameraControlPlugin)\]\s*=\s*\[)([^\]\n]*)(\])'
        def registration(match):
            body = re.sub(r'\b\w+(?:CapturePlugin|ControlPlugin)\s*\(\s*\)', lambda m: ' ' * len(m[0]), match[2])
            return match[1] + body + match[3]
        result = re.sub(pattern, registration, result)
    return result


def guarded_lines(text):
    """Return lines guaranteed to require TEST_SUPPORT, including nested #ifs."""
    stack = []
    for number, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith('#if '):
            expr = stripped[4:].strip()
            required = expr == 'ULTRACAM_TEST_SUPPORT' or bool(re.fullmatch(r'ULTRACAM_TEST_SUPPORT\s*&&\s*[^|]+', expr))
            stack.append(required)
        elif stripped.startswith(('#else', '#elseif')) and stack:
            stack[-1] = False
        elif stripped == '#endif' and stack:
            stack.pop()
        yield number, any(stack)


def audit(root, manifests, targets):
    """Return diagnostics; manifests are normalized vendors.load_manifests data.

    targets maps app/camera to actual PBX source/resource/framework paths.
    Empty targets is useful for isolated lexical fixtures only.
    """
    root = Path(root)
    errors = []
    def issue(path, line, rule, detail):
        errors.append(f'{path}:{line}: {rule}: {detail}')
    vendor_paths = {entry['path'] for manifest in manifests for entry in manifest['sources']}
    # Inventory every vendor source, not only manifest members, so newly added
    # unclassified declarations cannot evade the known-symbol check.
    vendor_files = sorted(p for p in (root / 'Vendors').glob('*/Sources/**/*') if p.is_file() and p.suffix in SOURCE_SUFFIXES)
    vendor_headers = {Path(path).name for manifest in manifests for path in manifest['publicHeaders']}
    vendor_modules = {Path(name).stem for name in vendor_headers}
    plugin_symbols = set()
    for path in vendor_files:
        plugin_symbols.update(declared_symbols(path.read_text(), native=path.suffix == '.h'))
    core_symbols = set()
    for directory in ('Sources/App', 'Sources/Recording'):
        for path in (root / directory).rglob('*.swift'):
            core_symbols.update(declared_symbols(path.read_text()))
    shared_symbols = set()
    for directory in ('Sources/Shared', 'Sources/DeviceAPI'):
        for path in (root / directory).rglob('*.swift'):
            shared_symbols.update(declared_symbols(path.read_text(), native=path.suffix == '.h'))
    core_symbols -= shared_symbols
    scanned = sorted(p for p in (root / 'Sources').rglob('*') if p.is_file() and p.suffix in SOURCE_SUFFIXES)
    scanned += sorted(p for p in (root / 'Config').rglob('*') if p.is_file() and p.suffix in {'.plist', '.entitlements', '.json', '.svg'})
    for path in scanned:
        relative = path.relative_to(root).as_posix()
        text = path.read_text()
        if relative == BRIDGE:
            if text != vendors.render_bridge(manifests):
                issue(relative, 1, 'generated-bridge', 'must exactly match vendors.render_bridge(validated manifests)')
            continue
        allowed = masked_exceptions(relative, text)
        code = code_only(allowed) if path.suffix in SOURCE_SUFFIXES else ''
        for number, line in enumerate(allowed.splitlines(), 1):
            for match in BRAND.finditer(line):
                issue(relative, number, 'vendor-name', match[0])
        for match in IMPORT.finditer(text):
            module = match[1] or match[2]
            if (BRAND.search(module) or Path(module).name in vendor_headers or module in vendor_modules
                    or any(part in module for part in ('CrSDK', 'CameraRemote', '/Vendors/'))):
                issue(relative, text.count('\n', 0, match.start()) + 1, 'vendor-import', module)
        for number, line in enumerate(code.splitlines(), 1):
            tokens = set(re.findall(r'\b\w+\b', line))
            for symbol in sorted(tokens & plugin_symbols):
                issue(relative, number, 'plugin-symbol', symbol)
            for match in SDK_SYMBOL.finditer(line):
                issue(relative, number, 'sdk-symbol', match[0])
        guard = dict(guarded_lines(text))
        for number, line in enumerate(code_only(text).splitlines(), 1):
            if FAKE.search(line) and not guard[number]:
                issue(relative, number, 'test-guard', 'fake definition/reference requires ULTRACAM_TEST_SUPPORT')
    for path in vendor_files:
        relative = path.relative_to(root).as_posix()
        text = path.read_text()
        for match in IMPORT.finditer(text):
            module = match[1] or match[2]
            if re.search(r'(?:^|[/\.])(?:App|Ultracam|Recording|MonitorKit\w*)(?:$|[/\.])', module):
                issue(relative, text.count('\n', 0, match.start()) + 1, 'core-import', module)
        locally_declared = {a or b for a, b in DECL.findall(code_only(text))}
        for number, line in enumerate(code_only(text).splitlines(), 1):
            for symbol in sorted(set(re.findall(r'\b\w+\b', line)) & (core_symbols - locally_declared)):
                issue(relative, number, 'core-symbol', symbol)
        if relative not in vendor_paths:
            issue(relative, 1, 'unclassified-vendor-source', 'missing validated manifest source membership')
    for path in targets.get('camera', []):
        if not (path.startswith('Sources/CameraExtension/') or path.startswith('Sources/Shared/')):
            issue(path, 1, 'extension-isolation', 'vendor, app, SDK or package dependency in extension target')
    for path in targets.get('app', []):
        if Path(path).name.startswith('Fake'):
            issue(path, 1, 'shipping-fake', 'fake source must not be in app target')
    return sorted(set(errors))


def project_targets(project):
    """Read sources plus framework/resource/copy dependencies from PBX objects."""
    objects = project['objects']
    targets = {}
    def resolve(identifier, ancestors=()):
        if identifier in ancestors:
            raise ValueError('cycle in PBX resource group')
        item = objects.get(identifier, {})
        if item.get('isa') in {'PBXVariantGroup', 'PBXGroup'}:
            children = item.get('children', [])
            if not children:
                raise ValueError('empty PBX resource group')
            return [path for child in children for path in resolve(child, (*ancestors, identifier))]
        return [item.get('path') or item.get('productName') or '<unresolved PBX dependency>']
    for target in objects.values():
        if target.get('isa') != 'PBXNativeTarget':
            continue
        key = 'camera' if target.get('name') == 'UltracamCamera' else 'app' if target.get('name') == 'Ultracam' else None
        if key is None:
            continue
        paths = []
        for phase_id in target.get('buildPhases', []):
            for build_id in objects[phase_id].get('files', []):
                build = objects[build_id]
                paths.extend(resolve(build.get('fileRef') or build.get('productRef')))
        targets[key] = paths
    if set(targets) != {'app', 'camera'}:
        raise ValueError('expected Ultracam and UltracamCamera PBXNativeTargets')
    return targets


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        manifests = vendors.load_manifests(root)
        parsed = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(root / 'Ultracam.xcodeproj/project.pbxproj')],
                                check=True, capture_output=True, text=True)
        errors = audit(root, manifests, project_targets(json.loads(parsed.stdout)))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f'vendor-boundaries: invalid inputs: {error}', file=sys.stderr)
        return 2
    if errors:
        print('\n'.join(errors))
        print(f'vendor-boundaries: {len(errors)} violation(s)', file=sys.stderr)
        return 1
    print('vendor-boundaries: passed (text and target-membership lint; not compiler isolation)')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
