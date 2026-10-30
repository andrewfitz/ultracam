#!/usr/bin/env python3
"""CPU regression checks executing settings intent and tile decisions extracted from production."""
from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parent.parent
app=(root/'Sources/App/AppModel.swift').read_text()
settings=(root/'Sources/App/AppSettingsStore.swift').read_text()
view=(root/'Sources/App/MonitorWorkspaceView.swift').read_text()
tools=(root/'Sources/App/UIMonitorTools.swift').read_text()
def body(source, marker):
    start=source.index(marker); start=source.index('{',start)+1; end=start; depth=1
    while depth:
        depth+=(source[end]=='{')-(source[end]=='}'); end+=1
    return source[start:end-1]
# The fixture keeps unrelated framework/capture dependencies out of these decisions.
selection=body(app,'if descriptor.selectedDevice != before.selectedDevice')
callback=app[(app.index('      } else if let descriptor = self.feedDescriptors.first') if '      } else if let descriptor = self.feedDescriptors.first' in app else app.index('      } else if var descriptor = self.feedDescriptors.first')):app.index('      self.synchronizeMonitoring(from: target, preferences: configuration, previous: previous)')]
callback=callback.replace('      } else if','      if')
warning=view[view.index('        if isProgram',view.index('if displayed.toolsEnabled && displayed.state.falseColor.mode')):]
warning=warning[:warning.index(' {')]
field='  var inputClearedByChoice = false' if 'var inputClearedByChoice = false' in settings else ''
decode='inputClearedByChoice = try values.decodeIfPresent(Bool.self, forKey: .inputClearedByChoice) ?? false' if 'inputClearedByChoice = try values.decodeIfPresent' in settings else ''
intent_start=app.index('    inputsClearedByChoice = Set(snapshot.feeds.filter')
initialization=app[intent_start:app.index('    }',intent_start)+5]
discovery='    for descriptor in feedDescriptors where descriptor.enabled && descriptor.selectedDevice.isEmpty &&\n      !inputsClearedByChoice.contains(descriptor.id) && !cameraActive(descriptor.id) {\n      guard let free = devices.first(where: { inputHolder($0.id, excluding: descriptor.id) == nil }) else { break }\n      updateCamera(descriptor.id) { $0.selectedDevice = free.id }\n    }\n'
availability=body(tools,'  static func unavailableReason(_ tool:')
tile_tools=body(view,'  private var unavailableTools:')
toolbar_call=view[view.index('      MonitorTileToolbar('):view.index('      ) {',view.index('      MonitorTileToolbar('))]
mode_argument='nil'
if 'falseColorModes:' in toolbar_call:
    mode_argument=toolbar_call.split('falseColorModes:',1)[1].split(', layout:',1)[0].strip()
toolbar=(root/'Packages/MonitorKit/Sources/MonitorKitUI/SwiftUI/TileToolbar.swift').read_text()
mode_allowed=body(toolbar,'  func isFalseColorModeAllowed(').strip()
set_source=body(settings,'  mutating func setSourceProfile(')
log_source=body(settings,'  private static func logProfileID(')
source='''import Foundation
enum SourceColorSpaceCatalog {static func title(_ id:String)->String {id}}
enum UIMonitorTool {case falseColor,focus,guides}
enum MonitorTileTool:Hashable {case falseColor,focusPeaking}
enum UIMonitorToolSettingsView {static func unavailableReason(_ tool:UIMonitorTool,isProgram:Bool)->String? {AVAILABILITY}}
func offeredModes(isProgram:Bool)->[Mode]? {MODE_ARGUMENT}
func modeAllowed(_ mode:Mode,isProgram:Bool)->Bool {let falseColorModes=offeredModes(isProgram:isProgram);return MODE_ALLOWED}
func tileTools(isProgram:Bool)->[MonitorTileTool:String] {TILE_TOOLS}
struct Signal: Codable, Equatable {var logProfileID:String?;var sourceProfileID:String?}
struct Preferences: Codable, Equatable {var signal=Signal(); var state=State(); mutating func forgetCameraCalibration() {}}
struct State: Codable, Equatable {var falseColor=FC()}
struct FC: Codable, Equatable {var mode=Mode.sixBand}
enum Mode:String,Codable {case off,sixBand,custom,sony; var needsLogSource:Bool {self == .sony}}
struct FeedDescriptor: Codable, Equatable {var enabled=true;var id=1;var gamut="";var selectedDevice="";var sourceProfileID="unspecified";var monitor=Preferences()
FIELD
init() {}
enum CodingKeys:String,CodingKey {case id,selectedDevice,sourceProfileID,monitor,inputClearedByChoice}
init(from decoder:Decoder) throws {let values=try decoder.container(keyedBy:CodingKeys.self)
id=try values.decodeIfPresent(Int.self,forKey:.id) ?? 1
selectedDevice=try values.decodeIfPresent(String.self,forKey:.selectedDevice) ?? ""
sourceProfileID=try values.decodeIfPresent(String.self,forKey:.sourceProfileID) ?? "unspecified"
monitor=try values.decodeIfPresent(Preferences.self,forKey:.monitor) ?? Preferences()
DECODE
}
private static func logProfileID(_ id:String)->String? {LOG_SOURCE}
mutating func setSourceProfile(_ id:String) {SET_SOURCE}
}
final class Coordinator {var saved=FeedDescriptor();func update(_ d:FeedDescriptor){saved=d}}
final class Fixture {
var peerSource="unspecified";var feedCoordinator=Coordinator();var feedDescriptors:[FeedDescriptor] {[feedCoordinator.saved]};var inputsClearedByChoice:Set<Int>=[]
func discover() {let devices=[(id:"available",unused:0)]
DISCOVERY
}
func reconstruct(_ feeds:[FeedDescriptor]) {let snapshot=(feeds:feeds,unused:0)
INITIALIZATION
}
func cameraActive(_ id:Int)->Bool {false};func inputHolder(_ device:String,excluding:Int)->Int? {nil}
func updateCamera(_ id:Int,shareProcessing:Bool = true,_ mutate:(inout FeedDescriptor)->Void) {var descriptor=feedCoordinator.saved;let before=descriptor;mutate(&descriptor); SELECTION;feedCoordinator.update(descriptor);if shareProcessing && before.sourceProfileID != descriptor.sourceProfileID {peerSource=descriptor.sourceProfileID}}
func edit(_ configuration:Preferences) {let target=(rawValue: "1", unused:0)
CALLBACK
}
}
var failures=0
func check(_ value:Bool,_ label:String) {if !value {print("FAIL: " + label);failures+=1}}
check(UIMonitorToolSettingsView.unavailableReason(.falseColor,isProgram:true) == nil,"Program false color settings and toggle enabled")
check(UIMonitorToolSettingsView.unavailableReason(.focus,isProgram:true) != nil,"Program focus remains unavailable")
check(UIMonitorToolSettingsView.unavailableReason(.falseColor,isProgram:false) == nil,"camera false color enabled")
check(tileTools(isProgram:true)[.falseColor] == nil,"Program tile false color toggle enabled")
check(tileTools(isProgram:true)[.focusPeaking] != nil,"Program tile focus unavailable")
check(modeAllowed(.sixBand,isProgram:true),"detached Program offers six band")
check(modeAllowed(.custom,isProgram:true),"detached Program offers custom")
check(modeAllowed(.off,isProgram:true),"detached Program offers off")
check(!modeAllowed(.sony,isProgram:true),"detached Program excludes log mode")
check(modeAllowed(.sony,isProgram:false),"camera retains log modes")
let model=Fixture();model.feedCoordinator.saved.selectedDevice="camera"
model.updateCamera(1) {$0.selectedDevice=""}
let encoded=try JSONEncoder().encode(model.feedCoordinator.saved)
let json=try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
check(json["inputClearedByChoice"] as? Bool == true,"explicit None persisted")
let restoredNone=try JSONDecoder().decode(FeedDescriptor.self,from:encoded)
model.reconstruct([restoredNone]);check(model.inputsClearedByChoice.contains(1),"single None reconstructed")
model.feedCoordinator.saved=restoredNone;model.discover();check(model.feedCoordinator.saved.selectedDevice.isEmpty,"None remains empty through discovery")
var second=restoredNone;second.id=2
model.reconstruct([restoredNone,second]);check(model.inputsClearedByChoice == [1,2],"all None reconstructed")
let legacy=try JSONDecoder().decode(FeedDescriptor.self,from:Data("{}".utf8))
model.reconstruct([legacy]);check(model.inputsClearedByChoice.isEmpty,"legacy all-empty autoassignment preserved")
var assigned=legacy;assigned.id=2;assigned.selectedDevice="camera"
model.reconstruct([legacy,assigned]);check(model.inputsClearedByChoice == [1],"legacy mixed snapshot preserved")
model.reconstruct([FeedDescriptor()]);check(model.inputsClearedByChoice.isEmpty,"fresh install autoassignment")
model.feedCoordinator.saved=FeedDescriptor();model.discover();check(model.feedCoordinator.saved.selectedDevice == "available","fresh install discovers input")
for prior in ["unspecified","sony-slog3"] {
 model.feedCoordinator.saved.setSourceProfile(prior)
 for picked:String? in ["panasonic-vlog","arri-logc3-ei800",nil] {
  var next=model.feedCoordinator.saved.monitor;next.signal.logProfileID=picked
  model.peerSource="unspecified"
  model.edit(next)
  check(model.peerSource == "unspecified","picker keeps peer declaration isolated")
  let restored=try JSONDecoder().decode(FeedDescriptor.self,from:JSONEncoder().encode(model.feedCoordinator.saved))
  check(restored.sourceProfileID == (picked ?? "unspecified"),"picker authoritative " + (picked ?? "None"))
 }
}
for mode in [Mode.sixBand,.custom,.sony] {let isProgram=true;var displayed=Preferences();displayed.state.falseColor.mode=mode
 var warned=false
 WARNING {warned=true}
 check(warned == mode.needsLogSource,"Program warning " + mode.rawValue)
}
exit(failures == 0 ? 0:1)
'''.replace('MODE_ARGUMENT',mode_argument).replace('MODE_ALLOWED',mode_allowed).replace('AVAILABILITY',availability).replace('TILE_TOOLS',tile_tools).replace('DISCOVERY',discovery).replace('SET_SOURCE',set_source).replace('LOG_SOURCE',log_source).replace('FIELD',field).replace('DECODE',decode).replace('INITIALIZATION',initialization).replace('SELECTION',selection).replace('CALLBACK',callback).replace('WARNING',warning)
# Feed IDs in production are strings, so compare their textual identities in the fixture.
source=source.replace('$0.id.rawValue == target.rawValue','String($0.id) == target.rawValue')
with tempfile.TemporaryDirectory(prefix='ultracam-settings-intent-') as tmp:
    path=Path(tmp)/'main.swift';path.write_text(source)
    subprocess.run(['xcrun','swift',str(path)],check=True)
