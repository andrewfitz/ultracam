#!/usr/bin/env python3
"""Run actual shared standby timing and CameraSink transport code in isolation."""
from pathlib import Path
import re
import subprocess
import tempfile
root = Path(__file__).resolve().parent.parent

def declaration(source, name):
    start = source.index(name)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

shared = (root / 'Sources/Shared/VideoContract.swift').read_text()
sink = (root / 'Sources/App/CameraSink.swift').read_text()
fixture = 'import Foundation\nimport CoreMedia\nimport CoreVideo\nimport XCTest\n'
fixture += declaration(shared, 'enum CameraStandbyTimingPolicy {') + '\n'
key = declaration(shared, 'static var sourcePauseAllowanceAttachmentKey:')
fixture += 'enum VideoContract {' + key + '}\n'
fixture += 'enum VideoError: Error { case message(String) }\n'
fixture += 'enum CameraSink {' + declaration(sink, 'static func transportSample(') + '}\n'
fixture += (root / 'Tests/BoundaryContracts/CameraStandbyTimingChecks.swift').read_text()
fixture += '''
let suite = XCTestSuite(forTestCaseClass: CameraStandbyTimingChecks.self)
suite.run()
guard let run = suite.testRun, run.executionCount == 3 else { exit(2) }
exit(run.hasSucceeded ? 0 : 1)
'''
developer = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
frameworks = developer / 'Platforms/MacOSX.platform/Developer/Library/Frameworks'
libraries = developer / 'Platforms/MacOSX.platform/Developer/usr/lib'
with tempfile.TemporaryDirectory(prefix='ultracam-camera-standby-timing-') as temporary:
    path = Path(temporary)
    (path / 'main.swift').write_text(fixture)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors', '-D', 'CAMERA_STANDBY_TIMING_CHECKS', '-F', str(frameworks),
        '-Xlinker', '-rpath', '-Xlinker', str(frameworks), '-I', str(libraries), '-L', str(libraries),
        '-lXCTestSwiftSupport', '-Xlinker', '-rpath', '-Xlinker', str(libraries),
        str(path / 'main.swift'), '-o', str(path / 'checks')], check=True)
    subprocess.run([str(path / 'checks')], check=True)
