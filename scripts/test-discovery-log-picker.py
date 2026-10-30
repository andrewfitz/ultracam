#!/usr/bin/env python3
"""Run AppModel discovery and monitor log-picker declarations without UI/capture."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parent.parent

def declaration(source, name):
    start=source.index(name);opening=source.index('{',start);end=opening+1;depth=1
    while depth:
        depth+=(source[end]=='{')-(source[end]=='}');end+=1
    return source[start:end]

app=(root/'Sources/App/AppModel.swift').read_text()
hardware=(root/'Sources/App/AppHardware.swift').read_text()
ui=(root/'Sources/App/UIMonitorToolFalseColor.swift').read_text()
shared=(root/'Sources/Shared/SourceFormat.swift').read_text()
fixture='import Foundation\nimport XCTest\n'
fixture+=declaration(shared,'struct Colorimetry:')+'\n'
fixture+='enum PluginError: Error { case unsupported(String) }\n'
fixture+=(root/'Sources/App/SourceColorSpaceCatalog.swift').read_text()+'\n'
fixture+='''struct CaptureDeviceInfo {
 let id:String;let name:String;let shareable:Bool;let mayPause:Duration?
 func localizedSupportedModes()->String { "" }
}
'''+declaration(hardware,'struct InputDevice:')+'\n'
fixture+='''enum ARRIFalseColorProfile: String {
 case logC3EI800="arri-logc3-ei800",alexa35LogC4EI800="arri-alexa35-logc4-ei800"
 var displayName:String {rawValue}
}
enum UIFalseColorChoices {
'''
fixture+=ui[ui.index('  static let profiles:'):ui.index('  /// The modes, in menu order.')]+ '}\n'
bridge_line=next(line for line in (root/'Sources/App/UILiveRoot.swift').read_text().splitlines() if 'inputs: model.devices.map' in line)
bridge_expression=bridge_line[bridge_line.index('model.devices.map'):].rstrip().removesuffix(',')
fixture+='''struct UIInput {let id:String;let name:String;let vendor:String?;let shareable:Bool;let supportedModes:String}
struct FeedDescriptor { var id:Int;var enabled=false;var selectedDevice="";var automaticFeed=false }
enum VendorRegistry {static func pluginID(for id:String) throws ->String {"fixture"}}
@MainActor final class VendorSettingsFixture {func restore(deviceID:String,pluginID:String) async {}}
final class DemandFixture {func refresh() {}}
@MainActor final class DiscoveryFixture {
 var devices:[InputDevice]=[];var lastInputNames:[String:String]=[:]
 var feedDescriptors:[FeedDescriptor]=[];var inputsClearedByChoice:Set<Int>=[]
 let vendorSettings=VendorSettingsFixture();let demandMonitor=DemandFixture()
 var bridgeInputs:[UIInput] {let model=self;return BRIDGE_EXPRESSION}
 func captureVendor(for id:String)->String? {nil}
 func inputShareable(_ id:String)->Bool {devices.first {$0.id==id}?.shareable == true}
 func observeDevices(_ snapshot:[InputDevice]) {applyDevices(snapshot,fromDiscovery:true)}
 func cameraActive(_ id:Int)->Bool {false}
 func inputHolder(_ id:String,excluding:Int)->FeedDescriptor? {nil}
 func updateCamera(_ id:Int,_ edit:(inout FeedDescriptor)->Void) {}
 func reconcileAutomaticFeed() {}
'''+declaration(app,'private func applyDevices(')+'\n}\n'
fixture=fixture.replace('BRIDGE_EXPRESSION',bridge_expression)
fixture+=(root/'Tests/BoundaryContracts/DiscoveryAndLogPickerChecks.swift').read_text()
fixture+='''
let suite=XCTestSuite(forTestCaseClass:DiscoveryAndLogPickerChecks.self)
suite.run()
guard let run=suite.testRun,run.executionCount==2 else {exit(2)}
exit(run.hasSucceeded ? 0:1)
'''
developer=Path(subprocess.check_output(['xcode-select','-p'],text=True).strip())
frameworks=developer/'Platforms/MacOSX.platform/Developer/Library/Frameworks'
libraries=developer/'Platforms/MacOSX.platform/Developer/usr/lib'
with tempfile.TemporaryDirectory(prefix='ultracam-discovery-log-picker-') as temp:
    path=Path(temp);(path/'main.swift').write_text(fixture)
    subprocess.run(['xcrun','swiftc','-D','DISCOVERY_AND_LOG_PICKER_CHECKS','-F',str(frameworks),
      '-Xlinker','-rpath','-Xlinker',str(frameworks),'-I',str(libraries),'-L',str(libraries),
      '-lXCTestSwiftSupport','-Xlinker','-rpath','-Xlinker',str(libraries),str(path/'main.swift'),'-o',str(path/'checks')],check=True)
    subprocess.run([str(path/'checks')],check=True)
