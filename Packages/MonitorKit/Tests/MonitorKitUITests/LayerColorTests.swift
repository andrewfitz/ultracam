import MonitorKit
import MonitorKitCore
import XCTest

@testable import MonitorKitUI

final class LayerColorTests: XCTestCase {
  /// Every encoding and primaries: the layer gets the format, space, EDR flag and
  /// metadata Core describes, through the real `kCGColorSpace…` constants.
  func testLayerConfigurationPerOutputColor() throws {
    let encodings: [MonitorOutputColor.Encoding] = [
      .sdr(.bt1886), .sdr(.sRGB), .sdr(.gamma22), .extendedLinear, .pq, .hlg,
    ]
    for encoding in encodings {
      for primaries in ColorPrimaries.allCases {
        let color = MonitorOutputColor(primaries: primaries, encoding: encoding).layer()
        let layer = CAMetalLayer()
        color.apply(to: layer)
        let name = "\(encoding) \(primaries)"
        XCTAssertEqual(layer.pixelFormat, encoding.isHDR ? .rgba16Float : .bgr10a2Unorm, name)
        XCTAssertEqual(layer.wantsExtendedDynamicRangeContent, encoding.isHDR, name)
        let space = try XCTUnwrap(layer.colorspace, name)
        if let named = color.namedColorSpace {
          XCTAssertEqual(space.name as String?, named.rawValue, name)
          XCTAssertEqual(named.cgName as String, named.rawValue, name)
        } else {
          XCTAssertNil(space.name, "\(name): a calibrated space")
          XCTAssertEqual(space.model, .rgb)
        }
        switch encoding {
        case .pq, .hlg: XCTAssertNotNil(layer.edrMetadata, name)
        default: XCTAssertNil(layer.edrMetadata, name)
        }
      }
    }
  }

  /// Re-applying the same colour leaves the layer's pixel format untouched (a
  /// change would make Core Animation reallocate its drawables).
  func testApplyIsIdempotent() {
    let layer = CAMetalLayer()
    let color = MonitorOutputColor(primaries: .rec2020, encoding: .pq).layer()
    color.apply(to: layer)
    let space = layer.colorspace
    color.apply(to: layer)
    XCTAssertTrue(layer.colorspace === space, "the same colour space object stays")
  }

  /// The calibrated spaces for the unnamed cases carry the primaries' matrix in
  /// the order Core Graphics reads it: their primaries convert exactly to the
  /// named linear spaces of the same primaries.
  func testCalibratedSpacesMatchNamedPrimaries() throws {
    let pairs: [(ColorPrimaries, CFString)] = [
      (.rec709, CGColorSpace.extendedLinearSRGB), (.displayP3, CGColorSpace.extendedLinearDisplayP3),
      (.rec2020, CGColorSpace.extendedLinearITUR_2020),
    ]
    for (primaries, linearName) in pairs {
      let calibrated = MonitorLayerColor.calibrated(primaries: primaries, gamma: 1)
      let linear = try XCTUnwrap(CGColorSpace(name: linearName))
      for rgb in [[1.0, 0, 0], [0, 1.0, 0], [0, 0, 1.0], [1.0, 1, 1], [0.25, 0.5, 0.75]] {
        let c = try XCTUnwrap(CGColor(colorSpace: calibrated, components: rgb.map { CGFloat($0) } + [1]))
        let out = try XCTUnwrap(c.converted(to: linear, intent: .absoluteColorimetric, options: nil)?.components)
        for k in 0..<3 { XCTAssertEqual(Double(out[k]), rgb[k], accuracy: 2e-3, "\(primaries) \(rgb)[\(k)]") }
      }
    }
    // Gamma: mid-grey of a 2.4 power is 0.5^2.4 in light, of a 2.2 power 0.5^2.2.
    let p3Linear = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    let power24 = MonitorLayerColor.calibrated(primaries: .displayP3, gamma: 2.4)
    let grey = try XCTUnwrap(CGColor(colorSpace: power24, components: [0.5, 0.5, 0.5, 1]))
    let light = try XCTUnwrap(grey.converted(to: p3Linear, intent: .absoluteColorimetric, options: nil)?.components)
    XCTAssertEqual(Double(light[1]), pow(0.5, 2.4), accuracy: 2e-3)
    // Core names no space for gamma 2.2: the calibrated one stands in.
    let g22 = MonitorLayerColor(primaries: .displayP3, kind: .sdr(.gamma22))
    XCTAssertNil(g22.colorSpace)
    XCTAssertFalse(g22.hasNamedColorSpace)
    let grey22 = try XCTUnwrap(CGColor(colorSpace: g22.cgColorSpace, components: [0.5, 0.5, 0.5, 1]))
    let light22 = try XCTUnwrap(grey22.converted(to: p3Linear, intent: .absoluteColorimetric, options: nil)?.components)
    XCTAssertEqual(Double(light22[1]), pow(0.5, 2.2), accuracy: 2e-3)
  }

  /// End to end for every SDR encoding and primaries: a grey of a BT.709 signal,
  /// encoded by the pass's colour pipeline for the output and decoded by the
  /// layer's colour space, shows the light BT.1886 gives it (V^2.4). Also the
  /// signal-native layer of a signal with those primaries, which writes the
  /// signal untouched. BT.1886 on Display P3 failed this with Core's named space.
  func testLayerSpaceDecodesWhatThePassWrites() throws {
    let linear: [ColorPrimaries: CFString] = [
      .rec709: CGColorSpace.extendedLinearSRGB, .displayP3: CGColorSpace.extendedLinearDisplayP3,
      .rec2020: CGColorSpace.extendedLinearITUR_2020,
    ]
    for primaries in ColorPrimaries.allCases {
      let signal = SignalDescription(range: .full, encoding: .display(.bt709), primaries: primaries)
      let outputs: [MonitorOutputColor] =
        [.signalNative] + [.bt1886, .sRGB, .gamma22].map { MonitorOutputColor(primaries: primaries, encoding: .sdr($0)) }
      for output in outputs {
        let layer = output.layer(for: signal)
        XCTAssertEqual(layer.primaries, primaries)
        let pipeline = MonitorColorPipeline(output: output, signal: signal)
        let target = try XCTUnwrap(CGColorSpace(name: linear[primaries]!))
        for v in [0.02, 0.1, 0.5, 0.9] {
          let written = pipeline.converted(ColorRGB(r: v, g: v, b: v))
          let c = try XCTUnwrap(CGColor(colorSpace: layer.cgColorSpace, components: [written.g, written.g, written.g, 1]))
          let shown = try XCTUnwrap(c.converted(to: target, intent: .absoluteColorimetric, options: nil)?.components)
          let expected = pow(v, 2.4)
          XCTAssertEqual(Double(shown[1]), expected, accuracy: max(2e-6, expected * 2e-3), "\(output.encoding) \(primaries) V \(v)")
        }
      }
    }
    let p3 = MonitorLayerColor(primaries: .displayP3, kind: .sdr(.bt1886))
    XCTAssertFalse(p3.hasNamedColorSpace, "kCGColorSpaceDisplayP3 has the sRGB curve")
    XCTAssertTrue(p3.cgColorSpace === p3.cgColorSpace, "one calibrated space object per case")
    XCTAssertTrue(MonitorLayerColor(primaries: .displayP3, kind: .sdr(.sRGB)).hasNamedColorSpace)
  }

  func testEDRMetadataValues() throws {
    let pq = MonitorLayerColor(primaries: .rec2020, kind: .pq)
    XCTAssertNotNil(pq.caEDRMetadata)
    XCTAssertNotNil(MonitorLayerColor(primaries: .rec2020, kind: .hlg).caEDRMetadata)
    XCTAssertNil(MonitorLayerColor(primaries: .rec709, kind: .extendedLinear).caEDRMetadata)
    XCTAssertNil(MonitorLayerColor(primaries: .rec709, kind: .sdr(.sRGB)).caEDRMetadata)
  }

  /// A second surface on a signal-native layer writes exactly the tag's encoding.
  func testExplicitOutputForLayer() {
    let base = MonitorOutputColor(referenceWhite: 180, hlgNominalPeak: 1500, headroom: 3)
    let cases: [(MonitorLayerColor.Kind, MonitorOutputColor.Encoding)] = [
      (.sdr(.bt1886), .sdr(.bt1886)), (.sdr(.sRGB), .sdr(.sRGB)), (.extendedLinear, .extendedLinear), (.pq, .pq),
      (.hlg, .hlg),
    ]
    for (kind, encoding) in cases {
      let o = base.explicit(for: MonitorLayerColor(primaries: .displayP3, kind: kind))
      XCTAssertEqual(o.encoding, encoding)
      XCTAssertEqual(o.primaries, .displayP3)
      XCTAssertEqual(o.referenceWhite, 180)
      XCTAssertEqual(o.hlgNominalPeak, 1500)
      // And it tags the same layer.
      XCTAssertEqual(o.layer(), MonitorLayerColor(primaries: .displayP3, kind: kind))
    }
  }

  func testHeadroomSanitized() {
    XCTAssertEqual(MonitorDisplayHeadroom.sanitized(.nan), 1)
    XCTAssertEqual(MonitorDisplayHeadroom.sanitized(0.5), 1)
    XCTAssertEqual(MonitorDisplayHeadroom.sanitized(.infinity), 1)
    XCTAssertEqual(MonitorDisplayHeadroom.sanitized(4.5), 4.5)
  }
}

final class RegionTests: XCTestCase {
  /// Regions that tile the view tile the target exactly, at any size.
  func testRegionsTileWithoutGapsOrOverlap() {
    for (w, h) in [(1920, 1080), (1001, 777), (3, 2), (64, 36)] {
      let thirds = (0..<3).map { MonitorRegion(x: Double($0) / 3, y: 0, width: 1.0 / 3, height: 1) }
      let vps = thirds.compactMap { $0.viewport(width: w, height: h) }
      XCTAssertEqual(vps.first?.x, 0)
      XCTAssertEqual(vps.reduce(0) { $0 + $1.width }, w, "\(w)×\(h)")
      for i in 1..<vps.count { XCTAssertEqual(vps[i].x, vps[i - 1].x + vps[i - 1].width) }
      XCTAssertTrue(vps.allSatisfy { $0.height == h && $0.y == 0 })
    }
    XCTAssertNil(MonitorRegion(x: 0, y: 0, width: 0, height: 1).viewport(width: 100, height: 100))
    XCTAssertNil(MonitorRegion(x: .nan, y: 0, width: 1, height: 1).viewport(width: 100, height: 100))
    XCTAssertEqual(MonitorRegion(x: -1, y: -1, width: 3, height: 3).viewport(width: 10, height: 20)?.width, 10)
    XCTAssertEqual(MonitorRegion.full.viewport(width: 8, height: 4, pixelsPerPoint: 2)?.pixelsPerPoint, 2)
    XCTAssertTrue(MonitorRegion(x: 0.5, y: 0, width: 0.5, height: 1).contains(u: 0.75, v: 0.5))
    XCTAssertFalse(MonitorRegion(x: 0.5, y: 0, width: 0.5, height: 1).contains(u: 0.25, v: 0.5))
  }
}
