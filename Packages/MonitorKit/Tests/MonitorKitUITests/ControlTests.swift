import AppKit
import MonitorKit
import MonitorKitCore
import SwiftUI
import XCTest

@testable import MonitorKitUI

/// A value the bindings write into.
@MainActor final class Box<T> {
  var value: T
  init(_ value: T) { self.value = value }
  var binding: Binding<T> { Binding(get: { self.value }, set: { self.value = $0 }) }
}

@MainActor
final class BindingTests: XCTestCase {
  /// Every control writes through `normalizing`, so Core's clamps are the only ones.
  func testNormalizingBindingStoresNormalizedState() {
    let box = Box(MonitorState())
    let state = box.binding.normalizing
    state.zebras[0].level.wrappedValue = 500
    XCTAssertEqual(box.value.zebras[0].level, 120)
    state.display.brightness.wrappedValue = .nan
    XCTAssertEqual(box.value.display.brightness, 0)
    state.geometry.magnification.zoom.wrappedValue = 0.2
    XCTAssertEqual(box.value.geometry.magnification.zoom, 1)
    state.focus.sensitivity.wrappedValue = 0.75
    XCTAssertEqual(box.value.focus.sensitivity, 0.75)
    state.display.temperature.wrappedValue = 100_000
    XCTAssertEqual(box.value.display.temperature, WhitePointTrim.temperatureRange.upperBound)
    XCTAssertEqual(box.value, box.value.normalized())
  }

  /// The temperature slider steps 50 K, which misses D65's 6504 K: within half a
  /// step it stores D65 exactly, so the trim can be dragged off again.
  func testTemperatureSliderSnapsToD65() {
    let box = Box(MonitorState())
    let temperature = DisplayAdjustmentControls.temperatureBinding(
      box.binding.normalizing.display.temperature, step: DisplayAdjustmentControls.temperatureStep)
    temperature.wrappedValue = 6000
    XCTAssertTrue(box.value.display.trimsWhitePoint)
    for grid in [6500.0, 6529, 6479] {
      temperature.wrappedValue = grid
      XCTAssertEqual(box.value.display.temperature, WhitePointTrim.d65Temperature, "\(grid)")
      XCTAssertFalse(box.value.display.trimsWhitePoint, "\(grid)")
      XCTAssertTrue(box.value.display.isIdentity, "\(grid)")
    }
    temperature.wrappedValue = 6550
    XCTAssertEqual(box.value.display.temperature, 6550, "a step away is a trim")
    temperature.wrappedValue = 6450
    XCTAssertEqual(box.value.display.temperature, 6450)
    XCTAssertEqual(WhitePointTrim.snappedToD65(6504 + 25, within: 25), WhitePointTrim.d65Temperature)
    XCTAssertEqual(WhitePointTrim.snappedToD65(6504 + 25.5, within: 25), 6529.5)
    XCTAssertTrue(WhitePointTrim.snappedToD65(.nan, within: 25).isNaN)
  }

  func testFrameGuideAspectBinding() {
    let box = Box(GuideSettings())
    let aspect = GuideControls.aspectBinding(box.binding)
    XCTAssertEqual(aspect.wrappedValue, 0)
    aspect.wrappedValue = 2.39
    XCTAssertEqual(box.value.frameGuides.map(\.aspect), [2.39])
    box.value.frameGuides[0].style = .matte
    aspect.wrappedValue = 1.85
    XCTAssertEqual(box.value.frameGuides.map(\.aspect), [1.85])
    XCTAssertEqual(box.value.frameGuides[0].style, .matte, "changing the ratio keeps the style")
    aspect.wrappedValue = 0
    XCTAssertTrue(box.value.frameGuides.isEmpty)
  }

  func testSafeAreaBinding() {
    let box = Box(GuideSettings())
    GuideControls.safeAreaBinding(box.binding, 93).wrappedValue = true
    GuideControls.safeAreaBinding(box.binding, 80).wrappedValue = true
    GuideControls.safeAreaBinding(box.binding, 93).wrappedValue = true
    XCTAssertEqual(box.value.safeAreas, [80, 93])
    XCTAssertTrue(GuideControls.safeAreaBinding(box.binding, 80).wrappedValue)
    GuideControls.safeAreaBinding(box.binding, 80).wrappedValue = false
    XCTAssertEqual(box.value.safeAreas, [93])
  }

  func testOutputEncodingChoicesRoundTrip() {
    let box = Box(MonitorOutputColor(primaries: .displayP3, encoding: .pq, referenceWhite: 5000))
    let choice = OutputColorControls.encodingBinding(box.binding)
    for c in OutputEncodingChoice.allCases {
      choice.wrappedValue = c
      XCTAssertEqual(box.value.encoding, c.encoding)
      XCTAssertEqual(OutputEncodingChoice(c.encoding), c)
      XCTAssertEqual(choice.wrappedValue, c)
      XCTAssertEqual(box.value.primaries, .displayP3, "the primaries stay")
      XCTAssertEqual(box.value.referenceWhite, 1000, "written normalized")
    }
  }

  func testColorConversionRoundTrips() {
    for c in [ColorRGB(r: 1, g: 0, b: 0), ColorRGB(r: 0.2, g: 0.6, b: 0.9), ColorRGB(r: 1, g: 1, b: 1)] {
      let back = ColorRGB(c.color)
      XCTAssertEqual(back.r, c.r, accuracy: 1e-3)
      XCTAssertEqual(back.g, c.g, accuracy: 1e-3)
      XCTAssertEqual(back.b, c.b, accuracy: 1e-3)
    }
    let box = Box(ColorRGB(r: 0, g: 0, b: 0))
    colorBinding(box.binding).wrappedValue = Color(.sRGB, red: 0.5, green: 0.25, blue: 1)
    XCTAssertEqual(box.value.g, 0.25, accuracy: 1e-3)
  }

  func testLabels() {
    XCTAssertEqual(
      FrameGuide.standardAspects.map(MonitorFormat.aspect),
      [
        "9:16", "4:5", "1:1", "4:3", "13:9", "14:9", "15:9", "16:9", "17:9", "1.66:1", "1.85:1", "1.91:1", "2:1",
        "2.35:1", "2.39:1", "2.40:1",
      ])
    XCTAssertEqual(
      ViewGeometry.standardDesqueezeFactors.map(MonitorFormat.desqueeze),
      ["Off", "1.3×", "1.33×", "1.5×", "1.65×", "1.66×", "1.8×", "2×"])
    XCTAssertEqual(MonitorFormat.number(1.50), "1.5")
    XCTAssertEqual(MonitorFormat.number(2), "2")
    XCTAssertEqual(MonitorFormat.zoom(2.25), "2.2×")
    XCTAssertEqual(MonitorFormat.zoom(16), "16×")
    XCTAssertEqual(PeakingControls.levels.map(\.1), [0.25, 0.5, 0.75], "FocusSettings' Low/Mid/High")
    // Every enum a control lists has a title.
    XCTAssertTrue(FalseColorMode.allCases.allSatisfy { !$0.title.isEmpty })
    XCTAssertTrue(DisplayTransform.allCases.allSatisfy { !$0.title.isEmpty })
    XCTAssertTrue(OutputEncodingChoice.allCases.allSatisfy { !$0.title.isEmpty })
    XCTAssertEqual(FalseColorMode.sonySLog3.title, SonySLog3FalseColor.displayName)
  }
}

/// Every control builds and lays out, with all of its options shown.
@MainActor
final class ControlViewTests: XCTestCase {
  func everythingOn() -> MonitorState {
    var s = MonitorState()
    s.zebras[0] = ZebraSet(mode: .band, level: 70)
    s.zebras[1] = ZebraSet(mode: .lowerLimit, level: 100)
    s.falseColor.mode = .custom
    s.falseColor.customUnit = .stops
    s.falseColor.customBands = [FalseColorBand(lower: -1, upper: 1, color: ColorRGB(r: 0, g: 1, b: 0))]
    s.focus.enabled = true
    s.guides.enabled = true
    s.guides.frameGuides = [FrameGuide(aspect: 2.39, style: .linesAndMatte)]
    s.guides.squareGrid = true
    s.displayTransform.mode = .hdrPassthrough
    s.clipIndicators.enabled = true
    s.clipIndicators.coloring = .uniform
    return s
  }

  func host<V: View>(_ view: V) -> NSSize {
    let hosting = NSHostingView(rootView: view.monitorControlStyle().frame(width: 320))
    hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 2000)
    hosting.layoutSubtreeIfNeeded()
    return hosting.fittingSize
  }

  func testControlsLayOut() {
    let box = Box(everythingOn())
    var status = MonitorStatus()
    status = MonitorStatus()
    let output = Box(MonitorOutputColor(primaries: .rec2020, encoding: .extendedLinear))
    let routing = Box(LUTRouting.monitorOnly), interpolation = Box(LUTInterpolation.tetrahedral)
    let sizes = [
      host(ZebraControls(state: box.binding, status: status)),
      host(FalseColorControls(state: box.binding, status: status)),
      host(PeakingControls(state: box.binding)),
      host(GuideControls(state: box.binding)),
      host(GeometryControls(state: box.binding)),
      host(DisplayAdjustmentControls(state: box.binding)),
      host(LUTRoutingControls(state: box.binding, routing: routing.binding, interpolation: interpolation.binding, lutName: "Look")),
      host(OutputColorControls(state: box.binding, outputColor: output.binding)),
      host(ClipIndicatorControls(state: box.binding)),
      host(CleanSwitch(state: box.binding)),
    ]
    for (i, size) in sizes.enumerated() { XCTAssertGreaterThan(size.height, 10, "control \(i)") }
    // Every false-colour mode's legend lays out.
    for mode in FalseColorMode.allCases {
      box.value.falseColor.mode = mode
      XCTAssertGreaterThan(host(FalseColorControls(state: box.binding, signal: SignalDescription(encoding: .log(.sLog3SGamut3Cine)))).height, 10)
    }
    XCTAssertEqual(box.value, everythingOn().with { $0.falseColor.mode = .custom }, "laying out writes nothing")
  }
}

extension MonitorState {
  func with(_ body: (inout MonitorState) -> Void) -> MonitorState {
    var v = self
    body(&v)
    return v
  }
}

extension BindingTests {
  /// A frame guide's style binding outlives its guide without trapping.
  func testFirstGuideBindingIsSafeWhenEmpty() {
    let box = Box(GuideSettings())
    let style = GuideControls.firstGuide(box.binding, \.style, .lines)
    XCTAssertEqual(style.wrappedValue, .lines)
    style.wrappedValue = .matte
    XCTAssertTrue(box.value.frameGuides.isEmpty, "no guide, nothing written")
    box.value.frameGuides = [FrameGuide(aspect: 2.39)]
    style.wrappedValue = .linesAndMatte
    XCTAssertEqual(box.value.frameGuides[0].style, .linesAndMatte)
    GuideControls.aspectBinding(box.binding).wrappedValue = 0
    XCTAssertEqual(style.wrappedValue, .lines)
  }
}

extension BindingTests {
  /// A state with fewer zebra sets (a host's own or an older model) neither traps
  /// the zebra controls nor loses an edit.
  func testZebraBindingIsSafeOnShortStates() {
    var short = MonitorState()
    short.zebras = [ZebraSet(mode: .band, level: 60)]
    let box = Box(short)
    let second = ZebraControls.zebra(box.binding.normalizing, 1)
    XCTAssertEqual(second.wrappedValue, ZebraSet())
    second.enabled.wrappedValue = true
    XCTAssertEqual(box.value.zebras.count, MonitorState.maximumZebraSets)
    XCTAssertTrue(box.value.zebras[1].enabled)
    XCTAssertEqual(box.value.zebras[0].level, 60)
    box.value.zebras = []
    XCTAssertFalse(ZebraControls.zebra(box.binding, 0).wrappedValue.enabled)
    let size = NSHostingView(rootView: ZebraControls(state: Box(short).binding).frame(width: 320)).fittingSize
    XCTAssertGreaterThan(size.height, 10, "lays out without trapping")
  }

  /// A custom ratio, de-squeeze or safe area shows in its picker and can be typed;
  /// values Core would drop are ignored.
  func testCustomGuideAndDesqueezeValues() {
    XCTAssertEqual(GuideControls.aspectChoices(current: 2.39), [0] + FrameGuide.standardAspects)
    XCTAssertEqual(GuideControls.aspectChoices(current: 1.78).last, 1.78)
    let guides = Box(GuideSettings())
    let custom = GuideControls.customAspectBinding(guides.binding)
    custom.wrappedValue = 2.2
    XCTAssertEqual(guides.value.frameGuides.map(\.aspect), [2.2])
    custom.wrappedValue = 50
    XCTAssertEqual(guides.value.frameGuides.map(\.aspect), [2.2], "outside 0.1…10: ignored")
    GuideControls.addSafeArea(85, to: guides.binding)
    GuideControls.addSafeArea(5, to: guides.binding)
    XCTAssertEqual(guides.value.safeAreas, [85])
    XCTAssertEqual(GuideControls.safeAreaChoices(guides.value), [80, 85, 90, 93, 95])
    for p in [90.0, 93, 95, 97] { GuideControls.addSafeArea(p, to: guides.binding) }
    XCTAssertEqual(guides.value.safeAreas.count, 4, "at most four, as Core keeps")

    XCTAssertEqual(GeometryControls.desqueezeChoices(current: 1.25).last, 1.25)
    XCTAssertEqual(GeometryControls.desqueezeChoices(current: 2), ViewGeometry.standardDesqueezeFactors)
    let geometry = Box(ViewGeometry())
    let factor = GeometryControls.customDesqueezeBinding(geometry.binding)
    factor.wrappedValue = 1.25
    XCTAssertEqual(geometry.value.desqueeze, 1.25)
    factor.wrappedValue = 6
    XCTAssertEqual(geometry.value.desqueeze, 1.25)

    var state = MonitorState()
    state.guides.enabled = true
    state.guides.frameGuides = [FrameGuide(aspect: 1.78)]
    state.guides.safeAreas = [85]
    state.geometry.desqueeze = 1.25
    let box = Box(state)
    XCTAssertGreaterThan(NSHostingView(rootView: GuideControls(state: box.binding).frame(width: 320)).fittingSize.height, 10)
    XCTAssertGreaterThan(NSHostingView(rootView: GeometryControls(state: box.binding).frame(width: 320)).fittingSize.height, 10)
    XCTAssertEqual(box.value, state, "laying out writes nothing")
  }
}
