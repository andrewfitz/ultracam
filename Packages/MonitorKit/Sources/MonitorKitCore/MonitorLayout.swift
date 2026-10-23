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
    display(rect, toPicture: MonitorRect(x: 0, y: 0, width: w, height: h), flip: flip)
  }

  /// Maps `rect` (display) onto the region `crop` of the picture (picture pixels),
  /// flipped as requested: the display rect's edges land on the crop's edges.
  public static func display(_ rect: MonitorRect, toPicture crop: MonitorRect, flip: FlipMode) -> AxisMap {
    let sx = crop.width / rect.width, sy = crop.height / rect.height
    return AxisMap(
      scaleX: flip.flipsX ? -sx : sx, scaleY: flip.flipsY ? -sy : sy,
      offsetX: flip.flipsX ? crop.maxX + rect.x * sx : crop.x - rect.x * sx,
      offsetY: flip.flipsY ? crop.maxY + rect.y * sy : crop.y - rect.y * sy)
  }
}

/// A frame's geometry without its pixels: what the picture's shape depends on.
/// Cheap to build on any thread (e.g. the main thread sizing a layer before the
/// render thread encodes); `MonitorLayout(frame:geometry:…)` and
/// `displayAspectRatio` read it without allocating.
public struct MonitorFrameGeometry: Equatable, Sendable {
  /// Encoded size in pixels.
  public var width: Int
  public var height: Int
  /// Horizontal over vertical pixel spacing (CoreVideo's pixel aspect ratio).
  public var pixelAspectRatio: Double
  /// The region of the frame that is picture (the clean aperture, SMPTE RP 187 /
  /// ISO/IEC 14496-12 `clap`), in pixels with a top-left origin; nil is the whole frame.
  public var cleanAperture: MonitorRect?

  /// Pixel aspect ratios a picture can be shown with. Outside it (a broken tag)
  /// the picture is shown with square pixels and the status says why
  /// (`MonitorUnavailableReason.unsupportedGeometry`). MonitorTools' bound.
  public static let pixelAspectRatioRange: ClosedRange<Double> = 0.0625...16

  public init(width: Int, height: Int, pixelAspectRatio: Double = 1, cleanAperture: MonitorRect? = nil) {
    self.width = width
    self.height = height
    self.pixelAspectRatio = pixelAspectRatio
    self.cleanAperture = cleanAperture
  }

  /// Whether the pixel aspect ratio is finite and inside `pixelAspectRatioRange`.
  public var hasUsablePixelAspectRatio: Bool {
    pixelAspectRatio.isFinite && Self.pixelAspectRatioRange.contains(pixelAspectRatio)
  }

  /// The pixel aspect ratio the picture is shown with: the frame's, or 1 when unusable.
  public var effectivePixelAspectRatio: Double { hasUsablePixelAspectRatio ? pixelAspectRatio : 1 }

  /// The region shown, in frame pixels: the clean aperture clipped to the frame, or
  /// the whole frame when there is none or it is unusable (not finite, or under a
  /// pixel on either axis once clipped).
  public var shownRect: MonitorRect {
    let w = Double(max(1, width)), h = Double(max(1, height))
    let frame = MonitorRect(x: 0, y: 0, width: w, height: h)
    guard let a = cleanAperture, a.x.isFinite, a.y.isFinite, a.width.isFinite, a.height.isFinite else { return frame }
    let clipped = a.intersection(frame)
    return clipped.width >= 1 && clipped.height >= 1 ? clipped : frame
  }

  /// Width over height of the picture as displayed: the shown region with the pixel
  /// aspect ratio and the anamorphic `desqueeze` (1…4) applied.
  public func displayAspectRatio(desqueeze: Double = 1) -> Double {
    let r = shownRect
    let d = desqueeze.isFinite ? min(4, max(1, desqueeze)) : 1
    return r.width * effectivePixelAspectRatio * d / r.height
  }

  /// `displayAspectRatio(desqueeze:)` with the state's de-squeeze.
  public func displayAspectRatio(for state: MonitorState) -> Double {
    displayAspectRatio(desqueeze: state.geometry.desqueeze)
  }
}

/// Where the picture lands in a viewport, and how display pixels map back to it.
///
/// Two picture spaces: the maps (`displayToPicture`, `navigatorToPicture`) and
/// `visiblePictureRect` are in frame pixels (the encoded frame, top-left origin),
/// so with a clean aperture the shown picture's left edge maps to `aperture.x`,
/// not 0. `pictureWidth` × `pictureHeight` is the aperture's size, and the
/// magnification centre is a fraction of the aperture: convert a mapped point with
/// `pictureFraction(x:y:)`, not by dividing by `pictureWidth`.
public struct MonitorLayout: Equatable, Sendable {
  public let viewportWidth: Double, viewportHeight: Double
  /// The shown region's size in frame pixels: `aperture.width` × `aperture.height`.
  public let pictureWidth: Double, pictureHeight: Double
  /// The whole picture fitted to the viewport (pixel-aligned).
  public let fitRect: MonitorRect
  /// The picture as shown, zoomed and panned. May extend past the viewport.
  /// Equal to `fitRect` unless magnified or pixel-exact.
  public let imageRect: MonitorRect
  /// Display pixel → frame pixel (inside `aperture`).
  public let displayToPicture: AxisMap
  /// The part of the picture currently on screen, in frame pixels (inside `aperture`).
  public let visiblePictureRect: MonitorRect
  /// Inset showing the whole picture while magnified.
  public let navigatorRect: MonitorRect?
  /// Navigator display pixel → frame pixel (inside `aperture`).
  public let navigatorToPicture: AxisMap
  public let isMagnified: Bool
  /// The region of the frame shown, in frame pixels: the clean aperture, or the
  /// whole frame. `pictureWidth` and `pictureHeight` are its size; every map into
  /// the picture lands inside it.
  public let aperture: MonitorRect

  /// `pictureWidth` × `pictureHeight` is the frame; `cleanAperture` (frame pixels,
  /// top-left origin) the part of it shown, clipped to the frame (nil, or one
  /// that is not finite or under a pixel once clipped, shows the whole frame). The
  /// aspect, the fit, magnification (its centre is normalized in the aperture),
  /// pixel-exact sizing, guides and the navigator all follow the aperture.
  public init(
    pictureWidth: Int, pictureHeight: Int, pixelAspectRatio: Double = 1,
    viewportWidth: Int, viewportHeight: Int, geometry: ViewGeometry, cleanAperture: MonitorRect? = nil
  ) {
    let g = geometry
    let crop = MonitorFrameGeometry(width: pictureWidth, height: pictureHeight, cleanAperture: cleanAperture).shownRect
    let pw = crop.width, ph = crop.height
    let vw = Double(max(1, viewportWidth)), vh = Double(max(1, viewportHeight))
    let par = pixelAspectRatio.isFinite && pixelAspectRatio > 0 ? pixelAspectRatio : 1
    let desqueeze = g.desqueeze.isFinite && g.desqueeze >= 1 ? g.desqueeze : 1
    let aspect = pw * par * desqueeze / ph
    self.viewportWidth = vw
    self.viewportHeight = vh
    self.pictureWidth = pw
    self.pictureHeight = ph
    aperture = crop

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
    displayToPicture = AxisMap.display(image, toPicture: crop, flip: g.flip)

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
      navigatorToPicture = AxisMap.display(rect, toPicture: crop, flip: g.flip)
    } else {
      navigatorRect = nil
      navigatorToPicture = .identity
    }
  }

  /// The layout of a frame with `geometry` in a viewport, as a `MonitorPass` lays it
  /// out for `state` (its geometry normalized as the pass does; an unusable pixel
  /// aspect ratio shows square pixels). Allocation-free, so a host can size or
  /// hit-test a layer on the main thread before the frame is encoded.
  public init(frame geometry: MonitorFrameGeometry, state: MonitorState, viewportWidth: Int, viewportHeight: Int) {
    self.init(
      pictureWidth: geometry.width, pictureHeight: geometry.height,
      pixelAspectRatio: geometry.effectivePixelAspectRatio, viewportWidth: viewportWidth,
      viewportHeight: viewportHeight, geometry: state.geometry.normalized(), cleanAperture: geometry.cleanAperture)
  }

  /// Picture pixels covered by one display pixel, per axis.
  public var footprintX: Double { abs(displayToPicture.scaleX) }
  public var footprintY: Double { abs(displayToPicture.scaleY) }

  /// A frame-pixel point (what `displayToPicture` and `navigatorToPicture` return)
  /// as fractions of the aperture: 0 at its top-left edge, 1 at its bottom-right,
  /// not clamped. In the coordinates of `Magnification.centerX`/`centerY`, so a
  /// flipped picture maps back to its own pixels.
  public func pictureFraction(x: Double, y: Double) -> (x: Double, y: Double) {
    ((x - aperture.x) / aperture.width, (y - aperture.y) / aperture.height)
  }

  /// The frame-pixel point at fractions of the aperture: `pictureFraction`'s inverse.
  public func picturePoint(fractionX: Double, fractionY: Double) -> (x: Double, y: Double) {
    (aperture.x + fractionX * aperture.width, aperture.y + fractionY * aperture.height)
  }

  /// The aperture fraction under display point `(x, y)`: `pictureFraction` of
  /// `displayToPicture`. E.g. a double-click's new magnification centre.
  public func pictureFraction(displayX x: Double, displayY y: Double) -> (x: Double, y: Double) {
    let p = displayToPicture.apply(x: x, y: y)
    return pictureFraction(x: p.x, y: p.y)
  }
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

  /// Guides follow the shown picture (`imageRect`). While it is magnified they lie
  /// on the magnified picture and are clipped to the viewport (`GuideSettings.isShown(on:)`
  /// decides whether they show then).
  public init(layout: MonitorLayout, guides: GuideSettings, pixelsPerPoint: Double = 1) {
    rebuild(layout: layout, guides: guides, pixelsPerPoint: pixelsPerPoint)
  }

  /// Lays the guides out again into this raster's storage, as `init` would: with
  /// enough capacity reserved in `segments` (e.g. `reserveCapacity(4 * maximumSegments)`),
  /// it allocates nothing, so a pinch or live resize that moves the guides every
  /// frame stays allocation-free.
  public mutating func rebuild(layout: MonitorLayout, guides: GuideSettings, pixelsPerPoint: Double = 1) {
    segments.removeAll(keepingCapacity: true)
    matteRect = nil
    matteOpacity = 0
    strokeWidth = 1
    guard guides.isShown(on: layout) else { return }
    let fit = layout.imageRect
    let stroke = max(1, (guides.lineWidth * max(0.5, pixelsPerPoint)).rounded())
    strokeWidth = stroke
    let b = Builder(half: stroke / 2, odd: Int(stroke) % 2 == 1)

    var basis = fit
    var index = 0
    while index < guides.frameGuides.count {
      let guide = guides.frameGuides[index]
      let rect = fit.fitting(aspect: guide.aspect)
      if index == 0 && guides.followsFrameGuide { basis = rect }
      if guide.style != .matte { b.outline(rect, &segments) }
      if guide.style != .lines && matteRect == nil {
        matteRect = rect
        matteOpacity = guide.matteOpacity
      }
      index += 1
    }
    index = 0
    while index < guides.safeAreas.count {
      b.outline(basis.scaled(guides.safeAreas[index] / 100), &segments)
      index += 1
    }
    if guides.thirds {
      var i = 1
      while i <= 2 {
        b.vertical(basis.x + basis.width * Double(i) / 3, basis, &segments)
        b.horizontal(basis.y + basis.height * Double(i) / 3, basis, &segments)
        i += 1
      }
    }
    if guides.squareGrid {
      let rows = max(2, guides.squareGridRows), cell = basis.height / Double(rows)
      var i = 1
      while i < rows {
        b.horizontal(basis.y + cell * Double(i), basis, &segments)
        i += 1
      }
      var k = 0.0
      while basis.midX + k * cell < basis.maxX - b.half {
        b.vertical(basis.midX + k * cell, basis, &segments)
        if k > 0 { b.vertical(basis.midX - k * cell, basis, &segments) }
        k += 1
      }
    }
    let half = b.half
    if guides.diagonals {
      segments.append(Segment(x0: basis.x, y0: basis.y, x1: basis.maxX, y1: basis.maxY, halfWidth: half))
      segments.append(Segment(x0: basis.maxX, y0: basis.y, x1: basis.x, y1: basis.maxY, halfWidth: half))
    }
    let cx = b.snap(basis.midX), cy = b.snap(basis.midY)
    if guides.centerCross {
      let arm = (0.04 * basis.height).rounded() + (b.odd ? 0.5 : 0)
      segments.append(Segment(x0: cx - arm, y0: cy, x1: cx + arm, y1: cy, halfWidth: half))
      segments.append(Segment(x0: cx, y0: cy - arm, x1: cx, y1: cy + arm, halfWidth: half))
    }
    if guides.centerDot {
      segments.append(Segment(x0: cx, y0: cy, x1: cx, y1: cy, halfWidth: max(2, stroke * 1.5)))
    }
    // A magnified picture extends past the view: keep the part of each stroke on
    // screen, in place (a fitted picture is inside it already, so its strokes stay
    // as laid out).
    if layout.isMagnified {
      let view = MonitorRect(x: 0, y: 0, width: layout.viewportWidth, height: layout.viewportHeight)
      var kept = 0, i = 0
      while i < segments.count {
        if let c = Self.clipped(segments[i], to: view) {
          segments[kept] = c
          kept += 1
        }
        i += 1
      }
      segments.removeLast(segments.count - kept)
    }
    if segments.count > Self.maximumSegments { segments.removeLast(segments.count - Self.maximumSegments) }
  }

  /// Stroke placement for one stroke width. Odd strokes centre on a pixel centre,
  /// even strokes on a pixel edge; ends land on pixel edges, so every stroke covers
  /// whole pixels.
  private struct Builder {
    let half: Double
    let odd: Bool

    func snap(_ v: Double) -> Double { odd ? v.rounded(.down) + 0.5 : v.rounded() }
    func across(_ v: Double, _ low: Double, _ high: Double) -> Double {
      min(max(snap(v), low + half), high - half)
    }
    func vertical(_ x: Double, _ r: MonitorRect, _ out: inout [Segment]) {
      let s = across(x, r.x, r.maxX)
      out.append(Segment(x0: s, y0: r.y.rounded(), x1: s, y1: r.maxY.rounded(), halfWidth: half))
    }
    func horizontal(_ y: Double, _ r: MonitorRect, _ out: inout [Segment]) {
      let s = across(y, r.y, r.maxY)
      out.append(Segment(x0: r.x.rounded(), y0: s, x1: r.maxX.rounded(), y1: s, halfWidth: half))
    }
    func outline(_ r: MonitorRect, _ out: inout [Segment]) {
      let x0 = across(r.x, r.x, r.maxX), x1 = across(r.maxX, r.x, r.maxX)
      let y0 = across(r.y, r.y, r.maxY), y1 = across(r.maxY, r.y, r.maxY)
      // Verticals run the full outer height, so the corners close.
      out.append(Segment(x0: x0, y0: y0 - half, x1: x0, y1: y1 + half, halfWidth: half))
      out.append(Segment(x0: x1, y0: y0 - half, x1: x1, y1: y1 + half, halfWidth: half))
      out.append(Segment(x0: x0, y0: y0, x1: x1, y1: y0, halfWidth: half))
      out.append(Segment(x0: x0, y0: y1, x1: x1, y1: y1, halfWidth: half))
    }
  }

  /// The part of `s` whose stroke can cover a pixel of `view` (the view grown by the
  /// half width, so caps and strokes at the edges stay whole), or nil. Axis-aligned
  /// strokes keep their position and are cut along their length; diagonals are
  /// clipped with Liang and Barsky's parametric test ("A New Concept and Method for
  /// Line Clipping", ACM TOG 3(1), 1984).
  static func clipped(_ s: Segment, to view: MonitorRect) -> Segment? {
    let h = s.halfWidth
    let x0 = view.x - h, x1 = view.maxX + h, y0 = view.y - h, y1 = view.maxY + h
    if s.x0 == s.x1 {
      guard s.x0 >= x0, s.x0 <= x1 else { return nil }
      let low = max(min(s.y0, s.y1), y0), high = min(max(s.y0, s.y1), y1)
      guard low <= high else { return nil }
      return s.y0 <= s.y1
        ? Segment(x0: s.x0, y0: low, x1: s.x1, y1: high, halfWidth: h)
        : Segment(x0: s.x0, y0: high, x1: s.x1, y1: low, halfWidth: h)
    }
    if s.y0 == s.y1 {
      guard s.y0 >= y0, s.y0 <= y1 else { return nil }
      let low = max(min(s.x0, s.x1), x0), high = min(max(s.x0, s.x1), x1)
      guard low <= high else { return nil }
      return s.x0 <= s.x1
        ? Segment(x0: low, y0: s.y0, x1: high, y1: s.y1, halfWidth: h)
        : Segment(x0: high, y0: s.y0, x1: low, y1: s.y1, halfWidth: h)
    }
    let dx = s.x1 - s.x0, dy = s.y1 - s.y0
    var t0 = 0.0, t1 = 1.0
    // p · t ≤ q for each edge (left, right, top, bottom).
    func edge(_ p: Double, _ q: Double) -> Bool {
      if p == 0 { return q >= 0 }
      let t = q / p
      if p < 0 { t0 = max(t0, t) } else { t1 = min(t1, t) }
      return t0 <= t1
    }
    guard edge(-dx, s.x0 - x0), edge(dx, x1 - s.x0), edge(-dy, s.y0 - y0), edge(dy, y1 - s.y0) else { return nil }
    return Segment(x0: s.x0 + t0 * dx, y0: s.y0 + t0 * dy, x1: s.x0 + t1 * dx, y1: s.y0 + t1 * dy, halfWidth: h)
  }
}
