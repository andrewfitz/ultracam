import CryptoKit
import Foundation
import Metal
import Synchronization

/// A persistent warm start for an engine's pipelines (Metal 4 archives).
///
/// An engine made with a `cacheDirectory` builds its library and every pipeline
/// with this archive's `compiler`, passing the archive files of earlier launches
/// as lookup archives (`MTL4CompilerTaskOptions.lookupArchives`), so a pipeline
/// built before is loaded instead of compiled. `save()` builds each pipeline of
/// the session again with a second compiler whose `MTL4PipelineDataSetSerializer`
/// records the GPU binaries (each found in an archive or in the system's shader
/// cache, which the first compile filled: about half a millisecond apiece) and
/// writes them to a new file (`serializeAsArchiveAndFlush`).
///
/// Why two compilers: the first is a plain one, so it reads and fills the
/// system's shader cache as a host's compiler does; a compiler with a serializer
/// reads that cache but does not fill it, and compiles about 1.5–3× slower cold.
/// Measured on an M4 Max (shared, loaded): the 30 all-tools picture and focus
/// pipelines of `MonitorEngine.warmUp()` take 7–22 s to compile when neither cache
/// has them, about 5 ms from a warm system cache and 4–20 ms from an archive (the
/// first process to read a new file about 0.9 s). The system cache is
/// content-keyed but may be purged at any time; the archive is the host's.
///
/// Files are named `<name>-<gpu>-<key>-<content>.mtl4archive`:
/// - `key` is a SHA-256 of the exact shader source given to the compiler, the
///   compile options, the GPU (`MTLDevice.name`, `architecture.name`), the OS
///   version and build, and the file format version. Any change gives another
///   key, so an archive from other shaders, another OS build or another GPU is
///   never opened; `save()` removes the stale ones.
/// - `content` is a SHA-256 of the file's bytes. A file is handed to Metal only
///   after its bytes hash to its name, so a truncated, corrupt or foreign file is
///   ignored (and removed) before Metal reads it; Metal can crash on arbitrary bytes.
///
/// Each save writes a new file (a temporary file renamed into place, so a
/// concurrent reader or another engine saving the same key never sees a partial
/// file), holding every pipeline built this session, including those loaded from
/// older files, so the newest file holds everything this launch used. A save
/// happens only when something was compiled. At most `maximumFiles` per key are
/// kept, newest first; a pipeline only in an evicted file compiles once more.
///
/// An archive never changes pixels: Metal returns a pipeline from it only when the
/// whole pipeline descriptor (functions, constants, attachments) matches, and the
/// GPU binary is the one the compiler made for it.
///
/// Thread-safe. Lookups take a short lock; `save()` does file I/O (a few hundred
/// milliseconds) and is never called on a frame: engines save at the end of
/// `warmUp`/`prepare` calls and, for pipelines built later, from a utility-priority
/// task `saveDelay` seconds after the last new pipeline (no thread or queue of the
/// library's own).
public final class MonitorPipelineArchive: @unchecked Sendable {
  /// Counters for logs and tests.
  public struct Statistics: Equatable, Sendable {
    /// Verified archive files loaded at init or written since.
    public var filesLoaded = 0
    /// Files of this key that were truncated, corrupt or unreadable: ignored and removed.
    public var filesRejected = 0
    /// Files of another key (other shaders, OS build or GPU) removed by a save.
    public var staleFilesRemoved = 0
    /// Pipelines found in a loaded archive.
    public var hits = 0
    /// Pipelines compiled because no archive had them (recorded for the next save).
    public var misses = 0
    /// Archive files written.
    public var saves = 0
    /// The last save or load failure, if any.
    public var lastError: String?
  }

  /// The file format version, part of the key.
  static let formatVersion = 1
  static let fileExtension = "mtl4archive"
  /// Seconds after the last newly built pipeline before a scheduled save runs.
  public static let saveDelay: TimeInterval = 2

  public let directory: URL
  /// The file name prefix, e.g. "MonitorKit" or "MonitorKitScopes".
  public let name: String
  /// Hex SHA-256 of the shader source, compile options, GPU and OS (see the type).
  public let key: String
  /// Files kept per key.
  public let maximumFiles: Int
  /// Builds the library and every pipeline (a plain compiler: it uses the system
  /// shader cache), looking each up in the loaded archives first.
  package let compiler: any MTL4Compiler
  /// Records the pipelines for `save()`: builds them again with its serializer.
  private let recorder: any MTL4Compiler
  private let device: MTLDevice
  private let serializer: any MTL4PipelineDataSetSerializer
  /// `<name>-<gpu>-`: every file of this engine kind on this GPU.
  private let gpuPrefix: String
  /// `<gpuPrefix><key prefix>-`: the files of this key.
  private let keyPrefix: String
  private let saveLock = NSLock()

  private struct Loaded {
    var url: URL
    var archive: any MTL4Archive
  }

  /// A pipeline built this session, kept for `save()` to record.
  private enum Recipe: @unchecked Sendable {
    case render(MTL4RenderPipelineDescriptor)
    case compute(MTL4ComputePipelineDescriptor)
  }

  private struct State {
    /// Newest first.
    var loaded: [Loaded] = []
    /// Every pipeline built this session, in order. Each save records them all,
    /// so each new file holds the whole session.
    var built: [Recipe] = []
    var options = MTL4CompilerTaskOptions()
    var statistics = Statistics()
    /// A pipeline was compiled (not found) since the last save.
    var dirty = false
    var saveScheduled = false
    /// When the last pipeline was compiled (`DispatchTime` nanoseconds).
    var lastMiss: UInt64 = 0
  }

  private let state: Mutex<State>

  /// Makes the compiler and loads this key's verified archives from `directory`
  /// (created when missing). `source` is the exact library source the engine
  /// compiles, `options` its compile options. Throws only when Metal cannot make a
  /// compiler; an unusable directory or file just means a cold start.
  package init(
    device: MTLDevice, directory: URL, name: String, source: String, options: MTLCompileOptions,
    maximumFiles: Int = 8
  ) throws {
    self.device = device
    self.directory = directory
    self.name = name
    self.maximumFiles = max(1, maximumFiles)
    let gpu = "\(device.name)\n\(device.architecture.name)"
    let identity = [
      "MonitorKit pipeline archive \(Self.formatVersion)", name, gpu, Self.osIdentity, Self.validationIdentity,
      "language \(options.languageVersion.rawValue) math \(options.mathMode.rawValue)", source,
    ].joined(separator: "\n\u{1}\n")
    key = Self.hex(SHA256.hash(data: Data(identity.utf8)))
    gpuPrefix = "\(name)-\(Self.hex(SHA256.hash(data: Data(gpu.utf8))).prefix(12))-"
    keyPrefix = gpuPrefix + key.prefix(32) + "-"
    let s = MTL4PipelineDataSetSerializerDescriptor()
    s.configuration = [.captureBinaries]
    serializer = device.makePipelineDataSetSerializer(descriptor: s)
    let c = MTL4CompilerDescriptor()
    c.label = "\(name) pipelines"
    let r = MTL4CompilerDescriptor()
    r.label = "\(name) pipeline archive recorder"
    r.pipelineDataSetSerializer = serializer
    do {
      compiler = try device.makeCompiler(descriptor: c)
      recorder = try device.makeCompiler(descriptor: r)
    } catch {
      throw MonitorKitError.gpu("Cannot create the \(name) pipeline compiler: \(error)")
    }
    var initial = State()
    var rejected = 0
    for url in Self.files(in: directory, prefix: keyPrefix).sorted(by: Self.newestFirst) {
      guard initial.loaded.count < self.maximumFiles else { break }
      if let archive = Self.verifiedArchive(url, keyPrefix: keyPrefix, device: device) {
        initial.loaded.append(Loaded(url: url, archive: archive))
      } else {
        rejected += 1
        try? FileManager.default.removeItem(at: url)
      }
    }
    initial.statistics.filesLoaded = initial.loaded.count
    initial.statistics.filesRejected = rejected
    initial.options.lookupArchives = initial.loaded.map(\.archive)
    state = Mutex(initial)
  }

  public var statistics: Statistics { state.withLock { $0.statistics } }

  /// The archive files in use for lookups, newest first.
  public var files: [URL] { state.withLock { $0.loaded.map(\.url) } }

  // MARK: Building

  package func makeLibrary(descriptor: MTL4LibraryDescriptor) throws -> MTLLibrary {
    try compiler.makeLibrary(descriptor: descriptor)
  }

  /// The render pipeline for `descriptor`: from an archive when one has it,
  /// otherwise compiled. Either way kept for the next save to record.
  package func makeRenderPipelineState(descriptor: MTL4RenderPipelineDescriptor) throws -> MTLRenderPipelineState {
    let (options, hit) = lookup { try $0.makeRenderPipelineState(descriptor: descriptor) }
    let made = try compiler.makeRenderPipelineState(descriptor: descriptor, compilerTaskOptions: options)
    // A copy: the caller's descriptor is its own to change.
    note(hit: hit, .render(descriptor.copy() as! MTL4RenderPipelineDescriptor))
    return made
  }

  /// The compiler's asynchronous build (Metal's compiler threads). Only the plain
  /// build compiler is used asynchronously: on macOS 27 (SDK 27.0) an asynchronous
  /// build by a compiler with a pipeline data set serializer crashes in Metal's
  /// compiler scheduler, so the recorder builds synchronously, in `save()`.
  package func makeRenderPipelineState(descriptor: MTL4RenderPipelineDescriptor) async throws
    -> MTLRenderPipelineState
  {
    let (options, hit) = lookup { try $0.makeRenderPipelineState(descriptor: descriptor) }
    let made = try await compiler.makeRenderPipelineState(descriptor: descriptor, compilerTaskOptions: options)
    note(hit: hit, .render(descriptor.copy() as! MTL4RenderPipelineDescriptor))
    return made
  }

  package func makeComputePipelineState(descriptor: MTL4ComputePipelineDescriptor) throws -> MTLComputePipelineState {
    let (options, hit) = lookup { try $0.makeComputePipelineState(descriptor: descriptor) }
    let made = try compiler.makeComputePipelineState(descriptor: descriptor, compilerTaskOptions: options)
    note(hit: hit, .compute(descriptor.copy() as! MTL4ComputePipelineDescriptor))
    return made
  }

  /// `makeRenderPipelineState(descriptor:) async` for a compute pipeline.
  package func makeComputePipelineState(descriptor: MTL4ComputePipelineDescriptor) async throws
    -> MTLComputePipelineState
  {
    let (options, hit) = lookup { try $0.makeComputePipelineState(descriptor: descriptor) }
    let made = try await compiler.makeComputePipelineState(descriptor: descriptor, compilerTaskOptions: options)
    note(hit: hit, .compute(descriptor.copy() as! MTL4ComputePipelineDescriptor))
    return made
  }

  /// The lookup options, and whether an archive holds the pipeline (`probe` makes it
  /// from one archive; a miss marks the archive for saving). The compiler then
  /// builds it with the same archives, so a hit is loaded, not compiled.
  private func lookup<T>(_ probe: (any MTL4Archive) throws -> T) -> (MTL4CompilerTaskOptions, Bool) {
    let (options, archives) = state.withLock { ($0.options, $0.loaded.map(\.archive)) }
    var i = 0
    while i < archives.count {
      if (try? probe(archives[i])) != nil { return (options, true) }
      i += 1
    }
    return (options, false)
  }

  private func note(hit: Bool, _ recipe: Recipe) {
    let schedule = state.withLock { s -> Bool in
      s.built.append(recipe)
      if hit {
        s.statistics.hits += 1
        return false
      }
      s.statistics.misses += 1
      s.dirty = true
      s.lastMiss = DispatchTime.now().uptimeNanoseconds
      if s.saveScheduled { return false }
      s.saveScheduled = true
      return true
    }
    if schedule { scheduleSave(after: Self.saveDelay) }
  }

  /// One save `saveDelay` seconds after the last new pipeline of a burst, from a
  /// utility-priority task (no thread or queue of the library's own). Holds the
  /// archive until then.
  private func scheduleSave(after delay: TimeInterval) {
    Task.detached(priority: .utility) { [self] in
      var wait = delay
      while wait > 0 {
        try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
        wait = state.withLock { s -> TimeInterval in
          let since = Double(DispatchTime.now().uptimeNanoseconds &- s.lastMiss) / 1e9
          if since < Self.saveDelay { return Self.saveDelay - since }
          s.saveScheduled = false
          return 0
        }
      }
      save()
    }
  }

  // MARK: Saving

  /// When a pipeline was compiled since the last save: records every pipeline
  /// built this session (each about half a millisecond: an archive or system
  /// shader cache hit) into a new archive file and uses it for lookups. Removes this
  /// GPU's files of other keys, files past `maximumFiles` and stale temporary
  /// files. Blocks for the file I/O; call it off the frame path (engines call it
  /// after warm-up). Returns whether a file was written. Never throws: a failure
  /// is in `statistics.lastError` and the next launch starts cold.
  @discardableResult
  public func save() -> Bool {
    saveLock.lock()
    defer { saveLock.unlock() }
    let (dirty, built, options) = state.withLock { s -> (Bool, [Recipe], MTL4CompilerTaskOptions) in
      defer { s.dirty = false }
      return (s.dirty, s.built, s.options)
    }
    guard dirty else { return false }
    // Into the serializer: archive or system-cache hits, as the build compiler
    // just compiled any that were missing. One that fails is left out.
    var i = 0
    while i < built.count {
      switch built[i] {
      case .render(let d): _ = try? recorder.makeRenderPipelineState(descriptor: d, compilerTaskOptions: options)
      case .compute(let d): _ = try? recorder.makeComputePipelineState(descriptor: d, compilerTaskOptions: options)
      }
      i += 1
    }
    let fm = FileManager.default
    let temporary = directory.appendingPathComponent(".\(name)-\(UUID().uuidString).tmp")
    defer { try? fm.removeItem(at: temporary) }
    let url: URL
    do {
      try fm.createDirectory(at: directory, withIntermediateDirectories: true)
      do {
        try serializer.serializeAsArchiveAndFlush(url: temporary)
      } catch let error as NSError where error.domain == MTLBinaryArchiveDomain && error.code == 3 {
        return false  // Nothing to serialize: everything was already written.
      }
      let data = try Data(contentsOf: temporary, options: .uncached)
      url = directory.appendingPathComponent(
        keyPrefix + Self.hex(SHA256.hash(data: data)).prefix(32) + "." + Self.fileExtension)
      if fm.fileExists(atPath: url.path) {
        // The same bytes, written by another engine of this key.
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
      } else {
        do {
          try fm.moveItem(at: temporary, to: url)
        } catch where fm.fileExists(atPath: url.path) {
          // Another engine renamed the same bytes into place first.
        }
      }
    } catch {
      state.withLock { $0.statistics.lastError = "save: \(error)" }
      return false
    }
    let archive = Self.verifiedArchive(url, keyPrefix: keyPrefix, device: device)
    state.withLock { s in
      s.statistics.saves += 1
      if let archive {
        s.loaded.removeAll { $0.url == url }
        s.loaded.insert(Loaded(url: url, archive: archive), at: 0)
        s.statistics.filesLoaded += 1
      }
      if s.loaded.count > maximumFiles { s.loaded.removeLast(s.loaded.count - maximumFiles) }
      s.options = MTL4CompilerTaskOptions()
      s.options.lookupArchives = s.loaded.map(\.archive)
    }
    removeOldFiles(keeping: url)
    return true
  }

  /// Deletes this GPU's files of other keys, this key's files past
  /// `maximumFiles` (oldest first) and temporary files over an hour old. Only files
  /// with this engine's prefix are touched: the directory is the host's.
  private func removeOldFiles(keeping newest: URL) {
    let fm = FileManager.default
    var stale = 0
    var current: [URL] = []
    for url in Self.files(in: directory, prefix: gpuPrefix) {
      if url.lastPathComponent.hasPrefix(keyPrefix) {
        current.append(url)
      } else if (try? fm.removeItem(at: url)) != nil {
        stale += 1
      }
    }
    current.sort(by: Self.newestFirst)
    current.removeAll { $0 == newest }
    if current.count > maximumFiles - 1 {
      for url in current[(maximumFiles - 1)...] { try? fm.removeItem(at: url) }
    }
    let hourAgo = Date(timeIntervalSinceNow: -3600)
    if let names = try? fm.contentsOfDirectory(atPath: directory.path) {
      for n in names where n.hasPrefix(".\(name)-") && n.hasSuffix(".tmp") {
        let url = directory.appendingPathComponent(n)
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let date, date < hourAgo { try? fm.removeItem(at: url) }
      }
    }
    if stale > 0 { state.withLock { $0.statistics.staleFilesRemoved += stale } }
  }

  // MARK: Files

  /// Archive files in `directory` whose names start with `prefix`.
  private static func files(in directory: URL, prefix: String) -> [URL] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
    return names.filter { $0.hasPrefix(prefix) && $0.hasSuffix("." + fileExtension) }
      .map { directory.appendingPathComponent($0) }
  }

  /// The archive at `url` if its bytes hash to the content hash in its name (so
  /// Metal never reads a truncated or corrupt file) and Metal opens it.
  private static func verifiedArchive(_ url: URL, keyPrefix: String, device: MTLDevice) -> (any MTL4Archive)? {
    let file = url.deletingPathExtension().lastPathComponent
    guard file.hasPrefix(keyPrefix) else { return nil }
    let expected = file.dropFirst(keyPrefix.count)
    guard expected.count == 32, let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty,
      hex(SHA256.hash(data: data)).prefix(32) == expected
    else { return nil }
    return try? device.makeArchive(url: url)
  }

  private static func newestFirst(_ a: URL, _ b: URL) -> Bool {
    let key: Set<URLResourceKey> = [.contentModificationDateKey]
    let da = (try? a.resourceValues(forKeys: key))?.contentModificationDate ?? .distantPast
    let db = (try? b.resourceValues(forKeys: key))?.contentModificationDate ?? .distantPast
    return da != db ? da > db : a.lastPathComponent > b.lastPathComponent
  }

  /// The OS version and build (`kern.osversion`, e.g. "25A354"): the Metal compiler
  /// and GPU driver ship with the OS, so a new build may compile differently.
  static let osIdentity: String = {
    var size = 0
    var build = "unknown"
    if sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 {
      var bytes = [CChar](repeating: 0, count: size)
      if sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 {
        build = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      }
    }
    return "\(ProcessInfo.processInfo.operatingSystemVersionString) build \(build)"
  }()

  /// Metal's API and shader validation settings (`MTL_DEBUG_LAYER*`,
  /// `MTL_SHADER_VALIDATION*`): validated pipelines are instrumented binaries, so
  /// they never share an archive with plain ones.
  static var validationIdentity: String {
    ProcessInfo.processInfo.environment
      .filter { $0.key.hasPrefix("MTL_DEBUG_LAYER") || $0.key.hasPrefix("MTL_SHADER_VALIDATION") }
      .map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
  }

  static func hex<D: Digest>(_ digest: D) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
  }
}
