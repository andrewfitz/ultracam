import Foundation

public struct MonitorRect: Equatable, Sendable {
  public var x: Double, y: Double, width: Double, height: Double
  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
  public var maxX: Double { x + width }
  public var maxY: Double { y + height }
  public var midX: Double { x + width / 2 }
  public var midY: Double { y + height / 2 }
  public var isEmpty: Bool { !(width > 0 && height > 0) }
  /// Scaled about the centre.
  public func scaled(_ factor: Double) -> MonitorRect {
    MonitorRect(
      x: midX - width * factor / 2, y: midY - height * factor / 2, width: width * factor,
      height: height * factor)
  }
  /// The largest centred rect of `aspect` (width / height) inside this one.
  public func fitting(aspect: Double) -> MonitorRect {
    guard aspect > 0, !isEmpty else { return self }
    let w = min(width, height * aspect), h = w / aspect
    return MonitorRect(x: midX - w / 2, y: midY - h / 2, width: w, height: h)
  }
  public func intersection(_ o: MonitorRect) -> MonitorRect {
    let x0 = max(x, o.x), y0 = max(y, o.y), x1 = min(maxX, o.maxX), y1 = min(maxY, o.maxY)
    return MonitorRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
  }
}

/// Maps continuous coordinates: `out = in * scale + offset` per axis.
/// Pixel centres sit at `i + 0.5` in both spaces. A negative scale flips.
public struct AxisMap: Equatable, Sendable {
  public var scaleX: Double, scaleY: Double, offsetX: Double, offsetY: Double
  public init(scaleX: Double, scaleY: Double, offsetX: Double, offsetY: Double) {
    self.scaleX = scaleX
    self.scaleY = scaleY
    self.offsetX = offsetX
    self.offsetY = offsetY
  }
  public static let identity = AxisMap(scaleX: 1, scaleY: 1, offsetX: 0, offsetY: 0)
  public func apply(x: Double, y: Double) -> (x: Double, y: Double) {
    (x * scaleX + offsetX, y * scaleY + offsetY)
  }
  /// Maps `rect` (display) onto the picture `[0, width] × [0, height]`, flipped as requested.
  public static func display(_ rect: MonitorRect, toPictureWidth w: Double, height h: Double, flip: FlipMode)
    -> AxisMap
  {
    let sx = w / rect.width, sy = h / rect.height
    return AxisMap(
      scaleX: flip.flipsX ? -sx : sx, scaleY: flip.flipsY ? -sy : sy,
      offsetX: flip.flipsX ? w + rect.x * sx : -rect.x * sx,
      offsetY: flip.flipsY ? h + rect.y * sy : -rect.y * sy)
  }
}

/// Where the picture lands in a viewport, and how display pixels map back to it.
public struct MonitorLayout: Equatable, Sendable {
  public let viewportWidth: Double, viewportHeight: Double
  public let pictureWidth: Double, pictureHeight: Double
  /// The whole picture fitted to the viewport (pixel-aligned).
  public let fitRect: MonitorRect
  /// The picture as shown, zoomed and panned. May extend past the viewport.
  /// Equal to `fitRect` unless magnified or pixel-exact.
  public let imageRect: MonitorRect
  /// Display pixel → picture pixel.
  public let displayToPicture: AxisMap
  /// The part of the picture currently on screen, in picture pixels.
  public let visiblePictureRect: MonitorRect
  /// Inset showing the whole picture while magnified.
  public let navigatorRect: MonitorRect?
  public let navigatorToPicture: AxisMap
  public let isMagnified: Bool

  public init(
    pictureWidth: Int, pictureHeight: Int, pixelAspectRatio: Double = 1,
    viewportWidth: Int, viewportHeight: Int, geometry: ViewGeometry
  ) {
    let g = geometry
    let pw = Double(max(1, pictureWidth)), ph = Double(max(1, pictureHeight))
    let vw = Double(max(1, viewportWidth)), vh = Double(max(1, viewportHeight))
    let par = pixelAspectRatio.isFinite && pixelAspectRatio > 0 ? pixelAspectRatio : 1
    let desqueeze = g.desqueeze.isFinite && g.desqueeze >= 1 ? g.desqueeze : 1
    let aspect = pw * par * desqueeze / ph
    self.viewportWidth = vw
    self.viewportHeight = vh
    self.pictureWidth = pw
    self.pictureHeight = ph

    let raw = MonitorRect(x: 0, y: 0, width: vw, height: vh).fitting(aspect: aspect)
    // Whole-pixel edges keep borders and guides crisp; the aspect error is under a pixel.
    let x0 = raw.x.rounded(), y0 = raw.y.rounded()
    let fit = MonitorRect(
      x: x0, y: y0, width: max(1, raw.maxX.rounded() - x0), height: max(1, raw.maxY.rounded() - y0))
    fitRect = fit

    let m = g.magnification
    let cx = min(1, max(0, m.centerX.isFinite ? m.centerX : 0.5))
    let cy = min(1, max(0, m.centerY.isFinite ? m.centerY : 0.5))
    let u = g.flip.flipsX ? 1 - cx : cx, v = g.flip.flipsY ? 1 - cy : cy
    // Centred when it fits; otherwise the point (u, v) is kept at the view's
    // centre as far as the edges allow, so the view never shows past the picture.
    func place(_ size: Double, _ view: Double, _ t: Double) -> Double {
      size <= view ? (view - size) / 2 : min(0, max(view - size, view / 2 - t * size))
    }
    var image = fit
    if m.pixelExact {
      // One picture row per display row; columns carry the pixel aspect and de-squeeze.
      // Whole-pixel origins keep every picture pixel on exactly one display pixel.
      let w = pw * par * desqueeze, h = ph
      func origin(_ size: Double, _ view: Double, _ t: Double) -> Double {
        let o = place(size, view, t).rounded(.down)
        return size <= view ? o : min(0, max(view - size, o))
      }
      image = MonitorRect(x: origin(w, vw, u), y: origin(h, vh, v), width: w, height: h)
      isMagnified = w > vw + 1e-9 || h > vh + 1e-9
    } else {
      let zoom = max(1, m.zoom.isFinite ? m.zoom : 1)
      isMagnified = zoom > 1
      if isMagnified {
        let w = fit.width * zoom, h = fit.height * zoom
        image = MonitorRect(x: place(w, vw, u), y: place(h, vh, v), width: w, height: h)
      }
    }
    imageRect = image
    displayToPicture = AxisMap.display(image, toPictureWidth: pw, height: ph, flip: g.flip)

    let shown = image.intersection(MonitorRect(x: 0, y: 0, width: vw, height: vh))
    let a = displayToPicture.apply(x: shown.x, y: shown.y)
    let b = displayToPicture.apply(x: shown.maxX, y: shown.maxY)
    visiblePictureRect = MonitorRect(
      x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))

    if isMagnified && m.showsNavigator {
      let margin = (0.02 * min(vw, vh)).rounded()
      var w = (0.22 * vw).rounded(), h = (w / aspect).rounded()
      if h > 0.3 * vh {
        h = (0.3 * vh).rounded()
        w = (h * aspect).rounded()
      }
      let rect = MonitorRect(x: vw - margin - w, y: vh - margin - h, width: w, height: h)
      navigatorRect = rect.isEmpty ? nil : rect
      navigatorToPicture = AxisMap.display(rect, toPictureWidth: pw, height: ph, flip: g.flip)
    } else {
      navigatorRect = nil
      navigatorToPicture = .identity
    }
  }

  /// Picture pixels covered by one display pixel, per axis.
  public var footprintX: Double { abs(displayToPicture.scaleX) }
  public var footprintY: Double { abs(displayToPicture.scaleY) }
}

/// Guide lines in viewport pixels, ready for the GPU rasteriser.
public struct GuideRaster: Equatable, Sendable {
  public struct Segment: Equatable, Sendable {
    public var x0: Double, y0: Double, x1: Double, y1: Double
    /// Half the stroke width, in pixels. A zero-length segment draws a dot.
    public var halfWidth: Double
    public init(x0: Double, y0: Double, x1: Double, y1: Double, halfWidth: Double) {
      self.x0 = x0
      self.y0 = y0
      self.x1 = x1
      self.y1 = y1
      self.halfWidth = halfWidth
    }
  }
  public static let maximumSegments = 128
  public var segments: [Segment] = []
  /// Area inside the shown picture but outside `matteRect` is darkened by `matteOpacity`.
  public var matteRect: MonitorRect?
  public var matteOpacity = 0.0
  /// Stroke width in pixels: the line width in points times pixels per point, whole pixels.
  public var strokeWidth = 1.0

  public init() {}

  /// Guides follow the shown picture (`imageRect`) and are hidden while magnified.
  public init(layout: MonitorLayout, guides: GuideSettings, pixelsPerPoint: Double = 1) {
    guard guides.enabled, !layout.isMagnified else { return }
    let fit = layout.imageRect
    let stroke = max(1, (guides.lineWidth * max(0.5, pixelsPerPoint)).rounded())
    strokeWidth = stroke
    let half = stroke / 2
    // Odd strokes centre on a pixel centre, even strokes on a pixel edge; ends
    // land on pixel edges, so every stroke covers whole pixels.
    let odd = Int(stroke) % 2 == 1
    func snap(_ v: Double) -> Double { odd ? v.rounded(.down) + 0.5 : v.rounded() }
    func across(_ v: Double, _ low: Double, _ high: Double) -> Double {
      min(max(snap(v), low + half), high - half)
    }
    func vertical(_ x: Double, _ r: MonitorRect) {
      let s = across(x, r.x, r.maxX)
      segments.append(Segment(x0: s, y0: r.y.rounded(), x1: s, y1: r.maxY.rounded(), halfWidth: half))
    }
    func horizontal(_ y: Double, _ r: MonitorRect) {
      let s = across(y, r.y, r.maxY)
      segments.append(Segment(x0: r.x.rounded(), y0: s, x1: r.maxX.rounded(), y1: s, halfWidth: half))
    }
    func outline(_ r: MonitorRect) {
      let x0 = across(r.x, r.x, r.maxX), x1 = across(r.maxX, r.x, r.maxX)
      let y0 = across(r.y, r.y, r.maxY), y1 = across(r.maxY, r.y, r.maxY)
      // Verticals run the full outer height, so the corners close.
      segments.append(Segment(x0: x0, y0: y0 - half, x1: x0, y1: y1 + half, halfWidth: half))
      segments.append(Segment(x0: x1, y0: y0 - half, x1: x1, y1: y1 + half, halfWidth: half))
      segments.append(Segment(x0: x0, y0: y0, x1: x1, y1: y0, halfWidth: half))
      segments.append(Segment(x0: x0, y0: y1, x1: x1, y1: y1, halfWidth: half))
    }

    var basis = fit
    for (index, guide) in guides.frameGuides.enumerated() {
      let rect = fit.fitting(aspect: guide.aspect)
      if index == 0 && guides.followsFrameGuide { basis = rect }
      if guide.style != .matte { outline(rect) }
      if guide.style != .lines && matteRect == nil {
        matteRect = rect
        matteOpacity = guide.matteOpacity
      }
    }
    for percent in guides.safeAreas { outline(basis.scaled(percent / 100)) }
    if guides.thirds {
      for i in 1...2 {
        vertical(basis.x + basis.width * Double(i) / 3, basis)
        horizontal(basis.y + basis.height * Double(i) / 3, basis)
      }
    }
    if guides.squareGrid {
      let rows = max(2, guides.squareGridRows), cell = basis.height / Double(rows)
      for i in 1..<rows { horizontal(basis.y + cell * Double(i), basis) }
      var k = 0.0
      while basis.midX + k * cell < basis.maxX - half {
        vertical(basis.midX + k * cell, basis)
        if k > 0 { vertical(basis.midX - k * cell, basis) }
        k += 1
      }
    }
    if guides.diagonals {
      segments.append(Segment(x0: basis.x, y0: basis.y, x1: basis.maxX, y1: basis.maxY, halfWidth: half))
      segments.append(Segment(x0: basis.maxX, y0: basis.y, x1: basis.x, y1: basis.maxY, halfWidth: half))
    }
    let cx = snap(basis.midX), cy = snap(basis.midY)
    if guides.centerCross {
      let arm = (0.04 * basis.height).rounded() + (odd ? 0.5 : 0)
      segments.append(Segment(x0: cx - arm, y0: cy, x1: cx + arm, y1: cy, halfWidth: half))
      segments.append(Segment(x0: cx, y0: cy - arm, x1: cx, y1: cy + arm, halfWidth: half))
    }
    if guides.centerDot {
      segments.append(Segment(x0: cx, y0: cy, x1: cx, y1: cy, halfWidth: max(2, stroke * 1.5)))
    }
    if segments.count > Self.maximumSegments { segments.removeLast(segments.count - Self.maximumSegments) }
  }
}
