import MonitorKitCore

/// Gestures as edits of `MonitorState.geometry.magnification`, in the viewport
/// pixels of the surface's last `MonitorLayout` (origin top left). Pure: the
/// view calls these and stores the result; nothing here knows about events.
///
/// The layout keeps the image inside the view, so where an edge stops a zoom or
/// a pan the stored centre is the one the layout actually shows: a gesture
/// reversing direction moves the picture at once, with no dead travel.
public enum MonitorMagnifier {
  /// The zoom range `MonitorState.normalized()` keeps.
  public static let zoomRange = 1.0...64.0

  /// Zooms by `factor` about `point`, keeping the picture point under it in
  /// place as far as the edges allow. Pixel-exact turns into the equivalent zoom.
  public static func zoom(
    _ m: Magnification, by factor: Double, about point: (x: Double, y: Double), layout: MonitorLayout
  ) -> Magnification {
    guard factor.isFinite, factor > 0 else { return m }
    var v = m
    let current = effectiveZoom(layout)
    let zoom = min(zoomRange.upperBound, max(zoomRange.lowerBound, current * factor))
    v.pixelExact = false
    v.zoom = zoom
    let image = layout.imageRect, fit = layout.fitRect
    let flips = flips(layout)
    func axis(_ p: Double, _ origin: Double, _ size: Double, _ fitSize: Double, _ view: Double, _ flip: Bool) -> Double {
      let u = min(1, max(0, (p - origin) / size))
      let w = fitSize * zoom
      // MonitorLayout places origin = view/2 - t·w (clamped); solve for t with origin = p - u·w.
      let t = clampCenter((view / 2 - p) / w + u, size: w, view: view)
      return flip ? 1 - t : t
    }
    v.centerX = axis(point.x, image.x, image.width, fit.width, layout.viewportWidth, flips.x)
    v.centerY = axis(point.y, image.y, image.height, fit.height, layout.viewportHeight, flips.y)
    return v
  }

  /// Moves the picture with a drag of (`dx`, `dy`) viewport pixels.
  public static func pan(_ m: Magnification, by delta: (dx: Double, dy: Double), layout: MonitorLayout) -> Magnification {
    guard delta.dx.isFinite, delta.dy.isFinite, layout.isMagnified else { return m }
    var v = m
    let image = layout.imageRect
    let flips = flips(layout)
    func axis(_ d: Double, _ origin: Double, _ size: Double, _ view: Double, _ flip: Bool) -> Double {
      let shown = (view / 2 - origin) / size
      let t = clampCenter(shown - d / size, size: size, view: view)
      return flip ? 1 - t : t
    }
    v.centerX = axis(delta.dx, image.x, image.width, layout.viewportWidth, flips.x)
    v.centerY = axis(delta.dy, image.y, image.height, layout.viewportHeight, flips.y)
    return v
  }

  /// Double click or tap: into pixel-exact centred on the picture point under
  /// `point`, or back out of it (the zoom and centre stay).
  public static func togglePixelExact(
    _ m: Magnification, at point: (x: Double, y: Double), layout: MonitorLayout
  ) -> Magnification {
    var v = m
    if m.pixelExact {
      v.pixelExact = false
      return v
    }
    v.pixelExact = true
    let c = pictureFraction(at: point, layout: layout)
    v.centerX = c.x
    v.centerY = c.y
    return v
  }

  /// A click in the navigator inset recentres the magnified view there. Nil
  /// when `point` is outside the navigator.
  public static func recenter(
    _ m: Magnification, navigatorPoint point: (x: Double, y: Double), layout: MonitorLayout
  ) -> Magnification? {
    guard let nav = layout.navigatorRect, point.x >= nav.x, point.x < nav.maxX, point.y >= nav.y, point.y < nav.maxY
    else { return nil }
    var v = m
    let p = layout.navigatorToPicture.apply(x: point.x, y: point.y)
    v.centerX = min(1, max(0, p.x / layout.pictureWidth))
    v.centerY = min(1, max(0, p.y / layout.pictureHeight))
    return v
  }

  /// Fit: zoom 1, centred, pixel-exact off.
  public static func reset(_ m: Magnification) -> Magnification {
    var v = Magnification()
    v.showsNavigator = m.showsNavigator
    return v
  }

  /// The picture point under `point` as fractions of the picture (the centre's
  /// coordinates, so flipped pictures map back to their own pixels).
  public static func pictureFraction(at point: (x: Double, y: Double), layout: MonitorLayout) -> (x: Double, y: Double) {
    let p = layout.displayToPicture.apply(x: point.x, y: point.y)
    return (min(1, max(0, p.x / layout.pictureWidth)), min(1, max(0, p.y / layout.pictureHeight)))
  }

  /// Displayed size over fitted size: the zoom pixel-exact amounts to.
  public static func effectiveZoom(_ layout: MonitorLayout) -> Double {
    guard layout.fitRect.width > 0 else { return 1 }
    return layout.imageRect.width / layout.fitRect.width
  }

  private static func flips(_ layout: MonitorLayout) -> (x: Bool, y: Bool) {
    (layout.displayToPicture.scaleX < 0, layout.displayToPicture.scaleY < 0)
  }

  /// The centres the layout can show for an image of `size` in `view`.
  private static func clampCenter(_ t: Double, size: Double, view: Double) -> Double {
    guard size > view else { return 0.5 }
    let half = view / (2 * size)
    return min(1 - half, max(half, t))
  }
}
