#!/usr/bin/env python3
"""Check runtime discovery for the explicitly registered new contract suites."""
import argparse
import re
from pathlib import Path

# These classes are explicitly registered under ULTRACAM_TEST_SUPPORT in main.
NEW_SUITES = (
    'SourceFormatContractChecks', 'SourceAdmissionChecks', 'DerivedOutputAdmissionChecks', 'RecordingTimebaseChecks', 'DeviceAPIConformance',
    'CameraControlContractChecks', 'CameraControlStoreChecks',
    'DeckLinkAdapterContractChecks', 'VendorRegistryChecks',
    'CapturePluginBridgeChecks', 'GPUStandbyChecks', 'GPUStandbyLifecycleChecks', 'CameraGPUStandbyChecks', 'RecordingPolicyChecks', 'RecordingSourceAdmissionChecks',
    'ExtensionFormatCatalogChecks', 'CameraControlUIStateChecks', 'VendorHardwareChecks',
    'VendorSettingsStoreChecks', 'VendorSettingsBootstrapChecks',
    'CaptureAdmissionChecks', 'CaptureTypedAdmissionChecks', 'CaptureSourceAdmissionChecks', 'CaptureTakeContextChecks',
    'LUTPassthroughOwnershipChecks', 'LUTSourceAdmissionChecks', 'SyntheticCaptureFixtureChecks', 'VendorSettingsHardwareChecks',
    'CPUCompatibilitySettingsChecks', 'CPUCompatibilityActivityChecks',
    'RecordingCPUAdmissionChecks', 'RecordingTakeLifecycleChecks',
)

def class_test_methods(source, name):
    # Strip comments and Swift string literals before balancing class braces.
    literals = r'"""[\s\S]*?"""|"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/'
    source = re.sub(literals, lambda match: '\n' * match.group().count('\n'), source)
    declaration = re.search(r'\bclass\s+' + re.escape(name) + r'\s*:\s*XCTestCase\s*\{', source)
    if declaration is None:
        raise ValueError(f'{name}: XCTestCase declaration missing')
    depth, index, start = 1, declaration.end(), declaration.end()
    while depth and index < len(source):
        depth += (source[index] == '{') - (source[index] == '}')
        index += 1
    if depth:
        raise ValueError(f'{name}: unterminated XCTestCase declaration')
    methods = re.findall(r'^\s*(?:@\w+(?:\([^\n]*\))?\s+)*func\s+(test\w+)\s*\(', source[start:index-1], re.MULTILINE)
    if not methods or len(methods) != len(set(methods)):
        raise ValueError(f'{name}: no methods or duplicate method names')
    return methods

def expected_counts(root):
    result = {}
    for name in NEW_SUITES:
        relative = ('Vendors/Blackmagic/Tests/' if name == 'DeckLinkAdapterContractChecks' else 'Tests/') + name + '.swift'
        source = (Path(root) / relative).read_text()
        result[name] = len(class_test_methods(source, name))
    return result

def verify_coverage(log, expected):
    failures = []
    for name, count in expected.items():
        pattern = r"Test Suite '" + re.escape(name) + r"' (?:passed|failed)[^\n]*\n\s*Executed (\d+) tests?\b"
        found = re.findall(pattern, log)
        if len(found) != 1:
            failures.append(f'{name}: expected one completed runtime suite, found {len(found)}')
        elif int(found[0]) != count:
            failures.append(f'{name}: executed {found[0]} tests, expected {count}')
    if failures:
        raise ValueError('; '.join(failures))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        expected = expected_counts(args.root)
        verify_coverage(args.log.read_text(), expected)
    except (OSError, ValueError) as error:
        parser.exit(1, f'Contract suite coverage FAILED: {error}\n')
    print('Contract suite coverage: ' + ', '.join(f'{name}={count}' for name, count in expected.items()))

if __name__ == '__main__':
    main()
