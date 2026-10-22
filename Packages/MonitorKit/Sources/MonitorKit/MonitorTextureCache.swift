import CoreVideo
import Darwin
import IOSurface
import Metal
import MonitorKitCore
import Foundation

/// IOSurface-backed frames as Metal textures made once per surface and kept: a
/// Metal 4 host's replacement for wrapping every frame through a
/// `CVMetalTextureCache` (whose per-frame textures would each need a residency
/// change). Capture and processing pools recycle a small set of IOSurfaces, so in
/// steady state `frame(_:)` makes no texture, changes no residency and allocates
/// nothing: it finds the plane textures by IOSurface ID, plane, format and size.
///
/// Every texture is added to `residency` once, when it is made, and leaves it
/// (`MonitorResidency.retire`) once the submissions that may read it complete:
/// after it has gone unused for `idleLifetime` seconds (swept at most every
/// `sweepInterval`), when its owner is flushed (`flush(owner:)`, e.g. a camera
/// stopping) or on `removeAll()`. Pass `MonitorEngine.residency`, whose
/// submissions every MonitorKit Metal 4 encode observes, so a retired texture
/// stays resident until the work that last read it is done.
///
/// A frame from `frame(_:)` stays drawable after its textures leave the cache:
/// the cache marks the frame's entries released, and MonitorKit's Metal 4 encodes
/// make a held frame's planes resident again for the submission that reads them
/// (`MonitorFrame.keepResidentIfReleased(in:)`), e.g. a stalled camera's last frame
/// redrawn after its textures were swept. A texture is resident before any thread
/// can find it. Frames a host builds from `makeTexture(…)` textures get no such
/// tracking: keep their textures from being swept (or flushed) while drawing them.
///
/// A cached texture retains its IOSurface, not the pixel buffer, so pools still
/// recycle buffers; the `MonitorFrame` returned retains the pixel buffer, so keep
/// the frame until the GPU work that reads it completes (as with any frame).
/// Textures are `.shaderRead`, shared storage, in `MonitorFrame`'s formats.
/// Thread-safe (one short lock per lookup); the sweep runs inside a lookup.
public final class MonitorTextureCache: @unchecked Sendable {
  public let device: MTLDevice
  public let residency: MonitorResidency
  /// Seconds a texture may go unused before the sweep releases it.
  public let idleLifetime: Double
  /// Seconds between sweeps: half the idle lifetime, at most one.
  public let sweepInterval: Double

  struct Key: Equatable {
    var surface: IOSurfaceID
    var plane: Int
    var format: UInt
    var width: Int
    var height: Int
  }

  struct Entry {
    var key: Key
    var texture: MTLTexture
    /// Retained: its identity tells a reused IOSurface ID from the surface the texture wraps.
    var surface: IOSurfaceRef
    var lastUse: Double
    var owner: UInt64
    /// Marked released when the entry leaves the cache, for the frames made over it.
    var token: FrozenPlanes
  }

  struct State {
    var entries: [Entry] = []
    var lastSweep = 0.0
    var made = 0
  }

  private let lock = NSLock()
  private var storage = State()

  /// `body` under the lock. Non-escaping, so it allocates nothing.
  private func locked<R>(_ body: (inout State) -> R) -> R {
    lock.lock()
    defer { lock.unlock() }
    return body(&storage)
  }

  /// `capacity` entries are reserved up front (a plane each), so the cache grows
  /// only past it. `idleLifetime` is clamped to 0.1…3600 s.
  public init(device: MTLDevice, residency: MonitorResidency, idleLifetime: Double = 2, capacity: Int = 64) {
    self.device = device
    self.residency = residency
    let life = idleLifetime.isFinite ? min(3600, max(0.1, idleLifetime)) : 2
    self.idleLifetime = life
    sweepInterval = min(1, life / 2)
    storage.entries.reserveCapacity(max(1, capacity))
  }

  deinit {
    let entries = locked { s -> [Entry] in
      let e = s.entries
      s.entries = []
      return e
    }
    var i = 0
    while i < entries.count {
      entries[i].token.markReleased()
      residency.retire(entries[i].texture, resident: entries[i].texture)
      i += 1
    }
  }

  /// Seconds on the uptime clock, the cache's default `now`.
  public static func uptime() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9 }

  /// Textures held now.
  public var count: Int { locked { $0.entries.count } }
  /// Textures made since init: constant while the producers recycle their surfaces.
  public var texturesMade: Int { locked { $0.made } }
  /// Textures held for `owner`.
  public func count(owner: UInt64) -> Int {
    locked { s in
      var n = 0, i = 0
      while i < s.entries.count {
        if s.entries[i].owner == owner { n += 1 }
        i += 1
      }
      return n
    }
  }

  /// The texture over `plane` of `iosurface` as `format` (`width` × `height` texels),
  /// made and made resident on first use. `owner` tags it for `flush(owner:)` (the
  /// last user's tag wins); `now` is seconds on one monotonic clock (default
  /// `uptime()`). Throws if Metal cannot make the texture (e.g. a row pitch the
  /// format cannot use).
  public func makeTexture(
    iosurface: IOSurfaceRef, plane: Int, format: MTLPixelFormat, width: Int, height: Int, owner: UInt64 = 0,
    now: Double? = nil
  ) throws -> MTLTexture {
    try entry(iosurface: iosurface, plane: plane, format: format, width: width, height: height, owner: owner, now: now)
      .texture
  }

  /// `makeTexture`'s texture and its entry's release token.
  private func entry(
    iosurface: IOSurfaceRef, plane: Int, format: MTLPixelFormat, width: Int, height: Int, owner: UInt64,
    now: Double?
  ) throws -> (texture: MTLTexture, token: FrozenPlanes) {
    let t = now ?? Self.uptime()
    let key = Key(
      surface: IOSurfaceGetID(iosurface), plane: plane, format: format.rawValue, width: width, height: height)
    if let hit = lookup(key, iosurface, owner: owner, now: t) { return hit }
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
    d.usage = .shaderRead
    d.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: d, iosurface: iosurface, plane: plane) else {
      throw MonitorKitError.gpu(
        "Cannot make a \(width)×\(height) texture (format \(format.rawValue)) over plane \(plane) of IOSurface \(key.surface).")
    }
    texture.label = "MonitorKit IOSurface \(key.surface) plane \(plane)"
    let token = FrozenPlanes()
    // Another thread may have made the same texture meanwhile: keep the first. A
    // new texture joins the residency set before it is published, so no thread
    // can find it and encode it while it is not yet resident (`add` takes only
    // the residency's own lock and never calls back here).
    let (kept, replaced) = locked { s -> ((MTLTexture, FrozenPlanes), MTLTexture?) in
      if let i = Self.index(of: key, in: s.entries) {
        if s.entries[i].surface === iosurface {
          s.entries[i].lastUse = t
          s.entries[i].owner = owner
          return ((s.entries[i].texture, s.entries[i].token), nil)
        }
        // A reused IOSurface ID: the old texture wraps a surface that is gone.
        let old = s.entries[i]
        old.token.markReleased()
        residency.add(texture)
        s.entries[i] = Entry(key: key, texture: texture, surface: iosurface, lastUse: t, owner: owner, token: token)
        s.made += 1
        return ((texture, token), old.texture)
      }
      residency.add(texture)
      s.entries.append(Entry(key: key, texture: texture, surface: iosurface, lastUse: t, owner: owner, token: token))
      s.made += 1
      return ((texture, token), nil)
    }
    if let replaced { residency.retire(replaced, resident: replaced) }
    return kept
  }

  /// `pixelBuffer` as a `MonitorFrame` over cached plane textures, laid out and
  /// formatted as `MonitorFrame.wrap` does. `signal` overrides what the
  /// attachments say; the pixel aspect ratio and clean aperture come from them.
  /// The frame retains `pixelBuffer`. Throws for a format MonitorKit does not read
  /// or a buffer without an IOSurface.
  public func frame(
    _ pixelBuffer: CVPixelBuffer, signal: SignalDescription? = nil, owner: UInt64 = 0, now: Double? = nil
  ) throws -> MonitorFrame {
    let type = CVPixelBufferGetPixelFormatType(pixelBuffer)
    guard let (layout, range) = MonitorFrame.layout(for: type) else {
      throw MonitorKitError.unsupportedPixelFormat(type)
    }
    guard let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
      throw MonitorKitError.invalidFrame("the pixel buffer is not IOSurface-backed")
    }
    let t = now ?? Self.uptime()
    let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
    var packed: MTLTexture?, luma: MTLTexture?, chroma: MTLTexture?
    // Each plane's entry token: a sweep or flush between the two lookups (or any
    // time later) marks it, and the frame's encodes then make its planes resident again.
    var first: FrozenPlanes?, second: FrozenPlanes?
    switch layout {
    case .v210:
      (packed, first) = try entry(
        iosurface: surface, plane: 0, format: .rgba32Uint, width: (width + 5) / 6, height: height, owner: owner, now: t)
    case .uyvy8, .yuyv8:
      (packed, first) = try entry(
        iosurface: surface, plane: 0, format: .rgba8Uint, width: (width + 1) / 2, height: height, owner: owner, now: t)
    case .biplanar(_, let depth):
      (luma, first) = try entry(
        iosurface: surface, plane: 0, format: depth == 8 ? .r8Unorm : .r16Unorm,
        width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0), height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
        owner: owner, now: t)
      (chroma, second) = try entry(
        iosurface: surface, plane: 1, format: depth == 8 ? .rg8Unorm : .rg16Unorm,
        width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 1), height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 1),
        owner: owner, now: t)
    case .rgb(let depth, let float):
      let format: MTLPixelFormat =
        float
        ? (depth == 16 ? .rgba16Float : .rgba32Float)
        : depth == 8
          ? (type == kCVPixelFormatType_32RGBA ? .rgba8Unorm : .bgra8Unorm)
          : depth == 10 ? .bgr10a2Unorm : .rgba16Unorm
      (luma, first) = try entry(
        iosurface: surface, plane: 0, format: format, width: width, height: height, owner: owner, now: t)
    }
    var frame = try MonitorFrame(
      layout: layout, width: width, height: height, packed: packed, luma: luma, chroma: chroma,
      signal: signal ?? MonitorFrame.signal(of: pixelBuffer, range: range),
      pixelAspectRatio: MonitorFrame.pixelAspectRatio(of: pixelBuffer), retained: (pixelBuffer, nil),
      cleanAperture: MonitorFrame.cleanAperture(of: pixelBuffer))
    frame.frozenPlanes = first
    frame.secondPlanes = second
    return frame
  }

  /// Releases textures unused for `idleLifetime` seconds at `now`. Lookups call it
  /// every `sweepInterval`; call it yourself while no frames arrive. A frame made
  /// over a released texture can still be drawn (see the type's notes).
  public func sweep(now: Double? = nil) {
    let t = now ?? Self.uptime()
    let life = idleLifetime
    let removed = locked { s in
      s.lastSweep = max(s.lastSweep, t)
      return Self.remove(from: &s) { t - $0.lastUse > life }
    }
    retire(removed)
  }

  /// Releases every texture tagged `owner` now (e.g. its camera stopped); their
  /// residency ends once the submissions that may read them complete.
  public func flush(owner: UInt64) {
    let removed = locked { s in Self.remove(from: &s) { $0.owner == owner } }
    retire(removed)
  }

  /// Releases every texture.
  public func removeAll() {
    let removed = locked { s -> [MTLTexture] in
      var out: [MTLTexture] = []
      out.reserveCapacity(s.entries.count)
      var i = 0
      while i < s.entries.count {
        s.entries[i].token.markReleased()
        out.append(s.entries[i].texture)
        i += 1
      }
      s.entries.removeAll(keepingCapacity: true)
      return out
    }
    retire(removed)
  }

  // MARK: - Internals

  /// The cached texture for `key` over `surface`, touched; sweeps when due. The
  /// steady-state path: one lock, a scan of a few entries, no allocation.
  private func lookup(_ key: Key, _ surface: IOSurfaceRef, owner: UInt64, now: Double)
    -> (texture: MTLTexture, token: FrozenPlanes)?
  {
    let interval = sweepInterval, life = idleLifetime
    var due = false
    let hit = locked { s -> (texture: MTLTexture, token: FrozenPlanes)? in
      due = now - s.lastSweep >= interval && Self.hasIdle(s, now: now, life: life)
      if !due && now - s.lastSweep >= interval { s.lastSweep = now }
      guard let i = Self.index(of: key, in: s.entries), s.entries[i].surface === surface else { return nil }
      s.entries[i].lastUse = now
      if s.entries[i].owner != owner { s.entries[i].owner = owner }
      return (s.entries[i].texture, s.entries[i].token)
    }
    if due { sweep(now: now) }
    return hit
  }

  private static func index(of key: Key, in entries: [Entry]) -> Int? {
    var i = 0
    while i < entries.count {
      if entries[i].key == key { return i }
      i += 1
    }
    return nil
  }

  private static func hasIdle(_ s: State, now: Double, life: Double) -> Bool {
    var i = 0
    while i < s.entries.count {
      if now - s.entries[i].lastUse > life { return true }
      i += 1
    }
    return false
  }

  /// Removes the entries `matching` selects (swap-remove), marks them released for
  /// the frames still holding them, and returns their textures.
  private static func remove(from s: inout State, matching: (Entry) -> Bool) -> [MTLTexture] {
    var removed: [MTLTexture] = []
    var i = 0
    while i < s.entries.count {
      if matching(s.entries[i]) {
        s.entries[i].token.markReleased()
        removed.append(s.entries[i].texture)
        s.entries.swapAt(i, s.entries.count - 1)
        s.entries.removeLast()
      } else {
        i += 1
      }
    }
    return removed
  }

  private func retire(_ textures: [MTLTexture]) {
    var i = 0
    while i < textures.count {
      residency.retire(textures[i], resident: textures[i])
      i += 1
    }
  }
}
