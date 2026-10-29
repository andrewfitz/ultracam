#!/usr/bin/env python3
"""Compile AppModel's actual source ownership methods without launching capture."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = (root / 'Sources/App/AppModel.swift').read_text()

def method(name):
    start = source.index(name)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

fixture = '''import Foundation
import XCTest
struct FeedID: Hashable { let rawValue: String; static let a = Self(rawValue:"a"); static let b = Self(rawValue:"b") }
struct FeedDescriptor { let id: FeedID; let selectedDevice: String }
struct InputDevice { let id: String; let shareable: Bool }
final class OwnershipCoordinator {
  func isFeedRunning(_ id: FeedID) -> Bool { id == .a }
}
final class OwnershipFixture {
  var devices: [InputDevice] = []
  var feedDescriptors: [FeedDescriptor] = [.init(id:.a,selectedDevice:"input"), .init(id:.b,selectedDevice:"input")]
  let feedCoordinator = OwnershipCoordinator()
  func descriptor(for id: FeedID) -> FeedDescriptor? { feedDescriptors.first { $0.id == id } }
  func busy(_ id: FeedID) -> Bool { inputInUse(by:id) != nil }
'''
fixture += '\n'.join(method(name) for name in ['func inputShareable(', 'func inputHolder(', 'private func inputInUse(']) + '\n}\n'
fixture += (root / 'Tests/BoundaryContracts/SourceOwnershipChecks.swift').read_text()
fixture += '''
let suite = XCTestSuite(forTestCaseClass: SourceOwnershipChecks.self)
suite.run()
guard let run = suite.testRun, run.executionCount == 3 else { exit(2) }
exit(run.hasSucceeded ? 0 : 1)
'''
developer = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
frameworks = developer / 'Platforms/MacOSX.platform/Developer/Library/Frameworks'
libraries = developer / 'Platforms/MacOSX.platform/Developer/usr/lib'
with tempfile.TemporaryDirectory(prefix='ultracam-source-ownership-') as temporary:
    path = Path(temporary)
    (path / 'main.swift').write_text(fixture)
    subprocess.run(['xcrun', 'swiftc', '-D', 'SOURCE_OWNERSHIP_CHECKS', '-F', str(frameworks),
        '-Xlinker', '-rpath', '-Xlinker', str(frameworks), '-I', str(libraries), '-L', str(libraries),
        '-lXCTestSwiftSupport', '-Xlinker', '-rpath', '-Xlinker', str(libraries),
        str(path / 'main.swift'), '-o', str(path / 'checks')], check=True)
    subprocess.run([str(path / 'checks')], check=True)
