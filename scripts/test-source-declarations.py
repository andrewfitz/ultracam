#!/usr/bin/env python3
"""Compile UISupport's actual pure declaration without the application's UI dependencies."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
source = (root / 'Sources/App/UISupport.swift').read_text()
start = source.index('  static func sourceProfile(forGamut')
opening = source.index('{', start)
depth, end = 1, opening + 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
with tempfile.TemporaryDirectory(prefix='ultracam-source-declarations-') as temporary:
    main = Path(temporary) / 'main.swift'
    main.write_text('enum UIMonitorBridge {\n' + source[start:end] + '\n}\n' +
        (root / 'Tests/SourceDeclarationChecks.swift').read_text() + '''
let suite = XCTestSuite(forTestCaseClass: SourceDeclarationChecks.self)
suite.run()
guard let run = suite.testRun, run.executionCount == 2 else { exit(2) }
exit(run.hasSucceeded ? 0 : 1)
''')
    developer = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
    frameworks = developer / 'Platforms/MacOSX.platform/Developer/Library/Frameworks'
    libraries = developer / 'Platforms/MacOSX.platform/Developer/usr/lib'
    binary = Path(temporary) / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-D', 'SOURCE_DECLARATION_CHECKS',
        '-F', str(frameworks), '-Xlinker', '-rpath', '-Xlinker', str(frameworks),
        '-I', str(libraries), '-L', str(libraries), '-lXCTestSwiftSupport',
        '-Xlinker', '-rpath', '-Xlinker', str(libraries), str(main), '-o', str(binary)], check=True)
    sys.exit(subprocess.run([str(binary)]).returncode)
