#!/usr/bin/env python3
"""Verify registration and runtime discovery for every compiled app XCTest suite."""
import argparse
import os
import subprocess
import sys
import re
from pathlib import Path

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

def verify_coverage(log, expected):
    failures = []
    for name, count in expected.items():
        pattern = r"Test Suite '" + re.escape(name) + r"' passed[^\n]*\n\s*Executed (\d+) tests?\b"
        found = re.findall(pattern, log)
        if len(found) != 1:
            failures.append(f'{name}: expected one completed runtime suite, found {len(found)}')
        elif int(found[0]) != count:
            failures.append(f'{name}: executed {found[0]} tests, expected {count}')
    if failures:
        raise ValueError('; '.join(failures))

def expected_counts(root):
    root = Path(root)
    registered = re.findall(r"forTestCaseClass: (\w+)\.self", (root / "Tests/main.swift").read_text())
    if len(registered) != len(set(registered)):
        raise ValueError("Duplicate XCTest suite registration")
    sources = list((root / "Tests").glob("*.swift"))
    sources += list((root / "Tests/Recording").glob("*.swift"))
    sources += list((root / "Tests/CameraProvider").glob("*.swift"))
    sources += [root / "Tests/MonitorKitHost/MonitorFeedHostChecks.swift"]
    vendor_sources = subprocess.check_output(
        [sys.executable, str(root / "scripts/vendors.py"), "query", "--root", str(root),
         "--membership", "test", "--kind", "swift-sources"], text=True)
    sources += [Path(path) for path in vendor_sources.splitlines() if path]
    sources = list(dict.fromkeys(sources))
    expected = {}
    for path in sources:
        source = path.read_text()
        for name in re.findall(r"\bclass\s+(\w+)\s*:\s*XCTestCase\b", source):
            if name not in registered:
                raise ValueError(f"{path}: unregistered XCTest suite {name}")
            if name in expected:
                raise ValueError(f"Duplicate XCTest suite declaration: {name}")
            expected[name] = len(class_test_methods(source, name))
    missing = set(registered) - expected.keys()
    if missing:
        raise ValueError("Registered XCTest suite missing from compiled sources: " + ", ".join(sorted(missing)))
    # Count extensions separately, including several in the same file.
    for path in sources:
        source = path.read_text()
        literals = r'"""[\s\S]*?"""|"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/'
        source = re.sub(literals, lambda match: "\n" * match.group().count("\n"), source)
        for declaration in re.finditer(r"\bextension\s+(\w+)\s*\{", source):
            name = declaration.group(1)
            if name not in expected:
                continue
            depth, index = 1, declaration.end()
            while depth and index < len(source):
                depth += (source[index] == "{") - (source[index] == "}")
                index += 1
            body = source[declaration.end():index-1]
            expected[name] += len(re.findall(r"^\s*(?:@\w+(?:\([^\n]*\))?\s+)*func\s+(test\w+)\s*\(", body, re.MULTILINE))
    return expected


def verify_skips(log, required=False):
    skipped = re.findall(r"Test Case '([^']+)' skipped[^\n]*", log)
    if skipped:
        print(f"App runtime: {len(skipped)} skipped; coverage is incomplete:")
        for identity in skipped:
            print("  " + identity)
        if required:
            raise ValueError("Required GPU proof lane refuses skipped app tests")
    else:
        print("App runtime: no skipped tests")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        expected = expected_counts(args.root)
        log = args.log.read_text()
        verify_coverage(log, expected)
        print("All app suite discovery: " + ", ".join(f"{name}={count}" for name, count in expected.items()))
        verify_skips(log, required=os.environ.get("ULTRACAM_REQUIRE_GPU_PROOFS") == "1")
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'App suite coverage FAILED: {error}\n')


if __name__ == '__main__':
    main()
