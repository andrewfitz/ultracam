// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import AppKit
import MonitorKitAudio
import Observation
import SwiftUI
import XCTest

@testable import MonitorKitUI

/// The meters' layer drawing: a frame sets only the layer properties that
/// moved, lands where the view's own coordinates say, runs no display link
/// without a window, and its readouts change only when a printed value does.
@MainActor
final class MeterLayerTests: XCTestCase {
  let colors = MeterLayerColors(.standard, in: EnvironmentValues())
  let scale = MeterScale.expandedPeak()

  /// A layer view `size` big drawing two channels at `levels` (dBTP) as vertical bars.
  func bars(_ levels: [Double], size: CGSize = CGSize(width: 20, height: 100)) -> MeterLayerView {
    let view = MeterLayerView(frame: CGRect(origin: .zero, size: size))
    let layouts = levels.map { scale.layout(level: $0) }
    let spans = scale.zoneSpans
    view.colors = colors
    view.draw = { frame, layers, colors in
      LevelMeterView.layout(layouts, spans: spans, reference: nil, axis: .vertical, size: frame.size) {
        layers.fill($0, colors($1))
      }
    }
    return view
  }

  func testAFrameSetsOnlyWhatMoved() {
    let layers = MeterLayers()
    let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    let green = CGColor(red: 0, green: 1, blue: 0, alpha: 1)
    func frame(_ rects: [(CGRect, CGColor)]) {
      layers.begin(size: CGSize(width: 100, height: 10), scale: 2)
      for (r, c) in rects { layers.fill(r, c) }
      layers.finish()
    }
    frame([(CGRect(x: 0, y: 0, width: 50, height: 10), green), (CGRect(x: 50, y: 0, width: 10, height: 10), red)])
    XCTAssertTrue(layers.changed)
    XCTAssertEqual(layers.layerCount, 2)
    frame([(CGRect(x: 0, y: 0, width: 50, height: 10), green), (CGRect(x: 50, y: 0, width: 10, height: 10), red)])
    XCTAssertFalse(layers.changed, "the same frame again sets nothing")
    // Under half a pixel of movement rounds to the same pixel: still nothing.
    frame([(CGRect(x: 0, y: 0, width: 50.2, height: 10), green), (CGRect(x: 50.2, y: 0, width: 10, height: 10), red)])
    XCTAssertFalse(layers.changed)
    // One rectangle fewer: the spare layer is hidden, not removed.
    frame([(CGRect(x: 0, y: 0, width: 30, height: 10), green)])
    XCTAssertTrue(layers.changed)
    XCTAssertEqual(layers.layerCount, 2)
    XCTAssertEqual(layers.frames, [CGRect(x: 0, y: 0, width: 30, height: 10)])
  }

  func testEdgesLandOnWholePixels() {
    let layers = MeterLayers()
    layers.begin(size: CGSize(width: 100, height: 10), scale: 2)
    layers.fill(CGRect(x: 10.3, y: 0, width: 20.4, height: 10), colors.well)
    // A line thinner than a pixel still shows as one pixel.
    layers.fill(CGRect(x: 40.1, y: 0, width: 0.1, height: 10), colors.reference)
    layers.finish()
    XCTAssertEqual(layers.frames[0], CGRect(x: 10.5, y: 0, width: 20, height: 10))
    XCTAssertEqual(layers.frames[1].width, 0.5)
  }

  func testTheViewDrawsTheLayoutsRectangles() {
    let view = bars([-6, -30])
    view.redraw()
    var expected: [CGRect] = []
    LevelMeterView.layout(
      [-6, -30].map { scale.layout(level: $0) }, spans: scale.zoneSpans, reference: nil, axis: .vertical,
      size: view.bounds.size
    ) { r, _ in expected.append(r) }
    XCTAssertEqual(view.layers.frames.count, expected.count)
    for (drawn, wanted) in zip(view.layers.frames, expected) {
      XCTAssertEqual(drawn.minX, wanted.minX, accuracy: 0.5)
      XCTAssertEqual(drawn.minY, wanted.minY, accuracy: 0.5)
      XCTAssertEqual(drawn.maxX, wanted.maxX, accuracy: 0.5)
      XCTAssertEqual(drawn.maxY, wanted.maxY, accuracy: 0.5)
    }
    view.step(at: 1)
    XCTAssertFalse(view.layers.changed, "a tick with nothing new commits nothing")
    XCTAssertEqual(view.tickCount, 1)
  }

  /// `cacheDisplay` sees no sublayers: the view paints the same bars itself.
  func testASnapshotShowsTheBars() throws {
    let view = bars([-6, -6])
    view.redraw()
    let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    func color(atTop y: CGFloat) -> NSColor? {
      rep.colorAt(x: Int(5 * CGFloat(rep.pixelsWide) / view.bounds.width), y: Int(y * CGFloat(rep.pixelsHigh) / view.bounds.height))
    }
    // −6 dBTP is amber (caution); the bottom of the bar is green, the top an empty well.
    let bottom = try XCTUnwrap(color(atTop: 98)?.usingColorSpace(.sRGB))
    XCTAssertGreaterThan(bottom.greenComponent, 0.6)
    XCTAssertLessThan(bottom.redComponent, 0.4)
    let top = try XCTUnwrap(color(atTop: 1)?.usingColorSpace(.sRGB))
    XCTAssertLessThan(top.greenComponent, 0.4, "above the bar: unlit")
  }

  func testNoLinkWithoutAWindow() throws {
    let meter = try AudioMeter(sampleRate: 48000, channelCount: 2)
    let hosting = NSHostingView(rootView: LevelMeterView(meter: meter, style: .strip).frame(width: 260, height: 60))
    hosting.frame = NSRect(x: 0, y: 0, width: 260, height: 60)
    hosting.layoutSubtreeIfNeeded()
    let views = layerViews(in: hosting)
    XCTAssertEqual(views.count, 1)
    XCTAssertTrue(views[0].isLive)
    XCTAssertFalse(views[0].isLinkRunning, "nothing on screen: no display link")
    XCTAssertGreaterThan(views[0].layers.frames.count, 0, "the update drew the empty wells")
  }

  func testReadoutsChangeOnlyWhenADigitMoves() {
    let readouts = LevelMeterReadouts()
    var s = AudioMeterSnapshot()
    s.channelCount = 2
    s.channels[0] = AudioChannelLevels(truePeak: -6, truePeakHold: -6, truePeakMax: -6.04)
    readouts.update(s, channels: 2, at: 0)
    XCTAssertEqual(readouts.maxima[0], MeterText.level(-6.04))
    final class Flag: @unchecked Sendable { var fired = false }
    func notifies(_ change: () -> Void) -> Bool {
      let flag = Flag()
      withObservationTracking {
        _ = readouts.maxima
        _ = readouts.hot
        _ = readouts.isOver
      } onChange: {
        flag.fired = true
      }
      change()
      return flag.fired
    }
    s.channels[0].truePeakMax = -6.01
    XCTAssertFalse(notifies { readouts.update(s, channels: 2, at: 0.2) }, "−6.0 both times")
    s.channels[0].truePeakMax = -5.5
    XCTAssertFalse(notifies { readouts.update(s, channels: 2, at: 0.25) }, "checked at most 10 times a second")
    XCTAssertTrue(notifies { readouts.update(s, channels: 2, at: 0.4) })
    XCTAssertEqual(readouts.maxima[0], MeterText.level(-5.5))
  }

  func testSummaryChangesAtMostOnceASecond() {
    let store = MeterSummaryStore()
    store.update(at: 0) { "a" }
    store.update(at: 0.5) { "b" }
    XCTAssertEqual(store.text, "a")
    store.update(at: 1) { "b" }
    XCTAssertEqual(store.text, "b")
  }

  /// In a real window the sublayers sit exactly where an AppKit view with the
  /// same frame does, in a plain view and in SwiftUI. Opt-in: the window is
  /// never shown, but it is a window: MONITORKITUI_WINDOW_TESTS=1.
  func testLayersLandWhereTheViewSays() throws {
    guard ProcessInfo.processInfo.environment["MONITORKITUI_WINDOW_TESTS"] == "1" else {
      throw XCTSkip("opt-in: MONITORKITUI_WINDOW_TESTS=1 makes a window")
    }
    let meter = try AudioMeter(sampleRate: 48000, channelCount: 2)
    let swiftUI = NSHostingView(rootView: LevelMeterView(meter: meter, style: .full).frame(width: 120, height: 200))
    let plain = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 200))
    plain.addSubview(bars([-6, -30], size: CGSize(width: 20, height: 100)))
    plain.subviews[0].frame.origin = CGPoint(x: 30, y: 40)
    for content in [plain, swiftUI as NSView] {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 120, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.alphaValue = 0
      window.ignoresMouseEvents = true
      window.contentView = content
      content.wantsLayer = true
      content.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      let view = try XCTUnwrap(layerViews(in: content).first)
      view.redraw()
      let drawn = try XCTUnwrap(view.layers.frames.first)
      // An AppKit view at the same frame, which AppKit places by definition.
      let marker = NSView(frame: drawn)
      marker.wantsLayer = true
      view.addSubview(marker)
      content.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      var root = try XCTUnwrap(view.layer)
      while let up = root.superlayer { root = up }
      let markerLayer = try XCTUnwrap(marker.layer)
      let wanted = markerLayer.convert(markerLayer.bounds, to: root)
      let got = view.layers.host.convert(try XCTUnwrap(view.layers.layerFrames.first), to: root)
      XCTAssertEqual(got.minX, wanted.minX, accuracy: 0.01, "\(type(of: content))")
      XCTAssertEqual(got.minY, wanted.minY, accuracy: 0.01, "\(type(of: content)): flipped \(view.layers.isFlipped)")
      XCTAssertEqual(got.size, wanted.size)
      window.close()
    }
  }

  /// A live meter in a window on screen ticks at the display rate, and stops
  /// when the window leaves the screen. Opt-in: MONITORKITUI_WINDOW_TESTS=1
  /// (the window is transparent and ignores the mouse).
  func testALiveMeterTicksOnlyOnScreen() throws {
    guard ProcessInfo.processInfo.environment["MONITORKITUI_WINDOW_TESTS"] == "1" else {
      throw XCTSkip("opt-in: MONITORKITUI_WINDOW_TESTS=1 puts a transparent window on screen")
    }
    let meter = try AudioMeter(sampleRate: 48000, channelCount: 2)
    let hosting = NSHostingView(rootView: LevelMeterView(meter: meter, style: .strip).frame(width: 260, height: 60))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 260, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.contentView = hosting
    window.orderFrontRegardless()
    defer { window.close() }
    func spin(_ seconds: Double) {
      let end = Date().addingTimeInterval(seconds)
      while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
    spin(0.5)
    let view = try XCTUnwrap(layerViews(in: hosting).first)
    XCTAssertTrue(view.isLinkRunning)
    XCTAssertGreaterThan(view.tickCount, 10, "about 30 frames in half a second at 60 Hz")
    window.orderOut(nil)
    spin(0.5)
    let ticks = view.tickCount
    spin(0.3)
    XCTAssertEqual(view.tickCount, ticks, "off screen: no ticks")
  }

  private func layerViews(in view: NSView) -> [MeterLayerView] {
    var out: [MeterLayerView] = []
    if let v = view as? MeterLayerView { out.append(v) }
    for s in view.subviews { out += layerViews(in: s) }
    return out
  }
}

