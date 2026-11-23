#!/usr/bin/env python3
"""Verify registration and runtime discovery for every compiled app XCTest suite."""
import argparse
import os
import subprocess
import sys
import re
from pathlib import Path

# A triple quote opens a multiline literal only before the line break. For
# example, #"""# is a single-line raw literal containing a double quote.
SWIFT_LITERAL = r'//|/\*|(?P<hashes>#*)(?P<quotes>"""(?=[ \t]*\r?\n)|")'
SWIFT_LITERAL_START = re.compile(SWIFT_LITERAL)
SWIFT_INTERPOLATION_TOKEN = re.compile(SWIFT_LITERAL + r'|[()]')
SWIFT_COMMENT_DELIMITER = re.compile(r'/\*|\*/')
SWIFT_TEST_MEMBER = re.compile(r'\bfunc\s+(test\w+)\s*\(\s*\)|[{}]')
SWIFT_SUITE = re.compile(r'\bclass\s+(\w+)\s*:\s*XCTestCase\s*\{')


def literal_end(source, start):
    if start[0] == '//':
        end = source.find('\n', start.end())
        return len(source) if end == -1 else end
    if start[0] == '/*':
        depth = 1
        for delimiter in SWIFT_COMMENT_DELIMITER.finditer(source, start.end()):
            depth += 1 if delimiter[0] == '/*' else -1
            if depth == 0:
                return delimiter.end()
        return len(source)

    closing = start['quotes'] + start['hashes']
    escape = '\\' + start['hashes']
    index = start.end()
    while index < len(source):
        if source.startswith(closing, index):
            return index + len(closing)
        if source.startswith(escape, index):
            index += len(escape)
            if source.startswith('(', index):
                index = interpolation_end(source, index + 1)
                continue
        index += 1
    return len(source)


def interpolation_end(source, index):
    depth = 1
    while token := SWIFT_INTERPOLATION_TOKEN.search(source, index):
        index = token.end()
        if token[0] == '(':
            depth += 1
        elif token[0] == ')':
            depth -= 1
            if depth == 0:
                return index
        else:
            index = literal_end(source, token)
    return len(source)


def swift_code(source):
    pieces, index = [], 0
    while start := SWIFT_LITERAL_START.search(source, index):
        pieces.append(source[index:start.start()])
        index = literal_end(source, start)
        pieces.append(' ' + '\n' * source.count('\n', start.start(), index))
    pieces.append(source[index:])
    return ''.join(pieces)


def test_members(code, start, name):
    depth, methods = 1, []
    for token in SWIFT_TEST_MEMBER.finditer(code, start):
        if token[0] == '{':
            depth += 1
        elif token[0] == '}':
            depth -= 1
            if depth == 0:
                return methods
        elif depth == 1:
            methods.append(token[1])
    raise ValueError(f'{name}: unterminated XCTestCase declaration or extension')


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
    registered = re.findall(r"forTestCaseClass:\s*(\w+)\.self", swift_code((root / "Tests/main.swift").read_text()))
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
    sources = {path: swift_code(path.read_text()) for path in dict.fromkeys(sources)}
    expected = {}
    for path, code in sources.items():
        for declaration in SWIFT_SUITE.finditer(code):
            name = declaration[1]
            if name not in registered:
                raise ValueError(f"{path}: unregistered XCTest suite {name}")
            if name in expected:
                raise ValueError(f"Duplicate XCTest suite declaration: {name}")
            expected[name] = test_members(code, declaration.end(), name)
    missing = set(registered) - expected.keys()
    if missing:
        raise ValueError("Registered XCTest suite missing from compiled sources: " + ", ".join(sorted(missing)))
    # Count extensions separately, including several in the same file.
    for code in sources.values():
        for declaration in re.finditer(r"\bextension\s+(\w+)\s*\{", code):
            name = declaration.group(1)
            if name in expected:
                expected[name].extend(test_members(code, declaration.end(), name))
    for name, methods in expected.items():
        if not methods or len(methods) != len(set(methods)):
            raise ValueError(f'{name}: no methods or duplicate method names')
    return {name: len(methods) for name, methods in expected.items()}


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
