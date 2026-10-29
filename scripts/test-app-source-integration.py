#!/usr/bin/env python3
"""Exercise AppModel's actual audio selector and linked processing methods."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parent.parent
source = (root / 'Sources/App/AppModel.swift').read_text()
def method(name):
    start = source.index(name)
    opening = source.index('{', start)
    end, depth = opening + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
fixture = '''import Foundation
import XCTest
struct FeedDescriptor {
 var id:Int; var enabled=true; var selectedDevice="device"
 var applyLUT=false;var lutBookmark:String?;var downscale=false;var convertTo420=false;var reduceFrameRate=false
 var resizeTarget="source";var colorTarget="source";var frameRateTarget="source";var scalingMode="fit"
 var pipelineEnabled=true;var gamut="source";var previewEnabled=true
 var sourceProfileID="source";var lutInputSpaceID="input";var lutOutputSpaceID="output";var programColorSpaceID="rec709"
 mutating func setSourceProfile(_ id:String) { sourceProfileID=id }
 mutating func setGamut(_ gamut:String) { self.gamut=gamut }
}
struct CaptureUpdate {
 var mediaTime:Int?; var audioPacketTime:Int?;var audioPresent:Bool
 var audioActivityRMS:Float;var audioActivityPeak:Float
 var audioRMSLeft=0.0;var audioRMSRight=0.0;var audioPeakLeft=0.0;var audioPeakRight=0.0
}
enum OutputMode {case program,separate}
final class IntegrationCoordinator {var outputMode=OutputMode.program;func evaluateSwitcher(at:Int)->Bool {true}}
final class DirectorSpy {
 var rms:Float?;var peak:Float?;var audioTime:Int?;var tickTime:Int?
 func ingestAudio(time:Int,rms:Float,peak:Float,present:Bool) { self.rms=rms;self.peak=peak;audioTime=time }
 func tick(time:Int) {tickTime=time}
}
final class TimelineSpy {var tickTime:Int?;func recordTick(time:Int) {tickTime=time}}
final class IntegrationFixture {
 let feedCoordinator=IntegrationCoordinator()
 var autoSwitcherBridge:DirectorSpy?=DirectorSpy();var autoSwitcherTimeline:TimelineSpy?=TimelineSpy()
 var syncCameras=true;var synchronizingCameras=false;var lutLoadingFeeds:Set<Int>=[];var cameraLUTs:[Int:String]=[:]
 var feedDescriptors=[FeedDescriptor(id:1),FeedDescriptor(id:2,selectedDevice:"second-device"),FeedDescriptor(id:3,enabled:false)]
 func cancelLUTLoad(_ id:Int) {}
 func updateCamera(_ id:Int,_ update:(inout FeedDescriptor)->Void) {let index=feedDescriptors.firstIndex {$0.id==id}!;update(&feedDescriptors[index])}
 func descriptor(for id:Int)->FeedDescriptor? {feedDescriptors.first {$0.id==id}}
 func applyPipeline(_ id:Int) {}
 func restoreLUT(_ id:Int) {}
 func feedAudio(_ update:CaptureUpdate) {feedAutoSwitcherAudio(update)}
 func sync(_ source:FeedDescriptor) {synchronizeProcessing(from:source)}
'''
fixture += method('private func feedAutoSwitcherAudio(') + '\n' + method('private func synchronizeProcessing(') + '\n}\n'
fixture += (root / 'Tests/BoundaryContracts/AppSourceIntegrationChecks.swift').read_text()
fixture += '''
let suite=XCTestSuite(forTestCaseClass:AppSourceIntegrationChecks.self)
suite.run()
guard let run=suite.testRun,run.executionCount==3 else {exit(2)}
exit(run.hasSucceeded ? 0:1)
'''
developer = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
frameworks = developer / 'Platforms/MacOSX.platform/Developer/Library/Frameworks'
libraries = developer / 'Platforms/MacOSX.platform/Developer/usr/lib'
with tempfile.TemporaryDirectory(prefix='ultracam-app-source-integration-') as tmp:
    path=Path(tmp)
    (path/'main.swift').write_text(fixture)
    subprocess.run(['xcrun','swiftc','-D','APP_SOURCE_INTEGRATION_CHECKS','-F',str(frameworks),
        '-Xlinker','-rpath','-Xlinker',str(frameworks),'-I',str(libraries),'-L',str(libraries),
        '-lXCTestSwiftSupport','-Xlinker','-rpath','-Xlinker',str(libraries),
        str(path/'main.swift'),'-o',str(path/'checks')],check=True)
    subprocess.run([str(path/'checks')],check=True)
