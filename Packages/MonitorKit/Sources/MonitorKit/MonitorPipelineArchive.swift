import CryptoKit
import Foundation
import Metal
import Synchronization

/// A persistent warm start for an engine's pipelines (Metal 4 archives).
///
/// An engine made with a `cacheDirectory` builds its library and every pipeline
/// through this archive: a pipeline built before is made from the archive file of
/// an earlier launch that holds it (`MTL4Archive.make…PipelineState`, one load, no
/// compile); any other is compiled by `compiler`. `save()` builds each pipeline of
/// the session again with a second compiler whose `MTL4PipelineDataSetSerializer`
/// records the GPU binaries (each found in an archive, passed as
/// `MTL4CompilerTaskOptions.lookupArchives`, or in the system's shader cache,
/// which the first compile filled: about half a millisecond apiece) and writes
/// them to a new file (`serializeAsArchiveAndFlush`).
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
/// Each archive is used once by `compiler` (a trivial kernel, with it as the only
/// lookup archive) as soon as it is opened. Metal reads an `MTL4Archive`'s file
/// again at its first use in a compiler build, and when the file is gone by then
/// raises an uncaught exception (`-[__NSArrayM insertObject:atIndex:]: object
/// cannot be nil` in AGX's `convertBinaryArchives`, macOS 27.0.1), which would end
/// the host. Once used, the archive no longer needs its file, so a host clearing
/// its caches, or another engine of this key evicting a file this one loaded,
/// changes nothing but what the next launch finds.
///
/// Each save writes a new file (a temporary file renamed into place, so a
/// concurrent reader or another engine saving the same key never sees a partial
/// file), holding every pipeline built this session, including those loaded from
/// older files, so the newest file holds everything this launch used. A save
/// happens only when something was compiled. At most `maximumFiles` per key are
/// kept, newest first; a pipeline only in an evicted file compiles once more.
///
/// Only the newest verified file is opened at init: it holds the whole last
/// session, so a launch that uses what the last one did reads, hashes and primes
/// one file (about 3–5 ms for the 4 MB picture archive). The older files are
/// opened at the first pipeline the open ones lack, before it compiles; a launch
/// that finds everything never touches them.
///
/// An archive never changes pixels: Metal returns a pipeline from it only when the
/// whole pipeline descriptor (functions, constants, attachments) matches, and the
/// GPU binary is the one the compiler made for it.
///
/// Thread-safe. Lookups take a short lock; `save()` records every pipeline of the
/// session again and writes a file (tens to a few hundred milliseconds) and is
/// never called on a frame: engines save at the end of `MonitorEngine.warmUp` and
/// the bulk `ScopeEngine.prepare` calls and, for pipelines built later, from a
/// utility-priority task `saveDelay` seconds after the last new pipeline (no
/// thread or queue of the library's own).
public final class MonitorPipelineArchive: @unchecked Sendable {
  /// Counters for logs and tests.
  public struct Statistics: Equatable, Sendable {
    /// Verified archive files opened (the newest at init, the older ones at the
    /// first pipeline the open ones lack) or written since.
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
    /// The last save, recording or load failure, if any.
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
  /// Files kept per key (3 by default: the newest holds the whole last session).
  public let maximumFiles: Int
  /// Builds the library and every pipeline no loaded archive holds (a plain
  /// compiler: it uses and fills the system shader cache).
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
  /// The trivial pipeline each archive is first used with (see the type), made on
  /// the first archive opened.
  private let primer = Mutex<MTL4ComputePipelineDescriptor?>(nil)

  private struct Loaded {
    var url: URL
    var archive: any MTL4Archive
  }

  /// A pipeline built this session, kept for `save()` to record.
  private enum Recipe: @unchecked Sendable {
    case render(MTL4RenderPipelineDescriptor)
    case compute(MTL4ComputePipelineDescriptor)
  }

  /// A recipe's descriptor as a set member (MTL4 pipeline descriptors compare by value).
  private struct Recorded: Hashable, @unchecked Sendable {
    let descriptor: NSObject
  }

  private struct State {
    /// Newest first.
    var loaded: [Loaded] = []
    /// Older files of this key not opened yet, newest first: opened at the first
    /// lookup the loaded archives miss (`openOlderFiles`).
    var older: [URL] = []
    /// Every pipeline built this session, in order, each once. Each save records
    /// them all, so each new file holds the whole session.
    var built: [Recipe] = []
    /// The descriptors in `built`.
    var recorded = Set<Recorded>()
    var options = MTL4CompilerTaskOptions()
    var statistics = Statistics()
    /// A pipeline was compiled (not found) since the last save.
    var dirty = false
    var saveScheduled = false
    /// When the last pipeline was compiled (`DispatchTime` nanoseconds).
    var lastMiss: UInt64 = 0
  }

  private let state: Mutex<State>

  /// Makes the compiler and opens this key's newest verified archive in
  /// `directory` (created by the first save when missing); the older ones open at
  /// the first pipeline it lacks. `source` is the exact library source the engine
  /// compiles, `options` its compile options. Throws only when Metal cannot make a
  /// compiler; an unusable directory or file just means a cold start.
  package init(
    device: MTLDevice, directory: URL, name: String, source: String, options: MTLCompileOptions,
    maximumFiles: Int = 3
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
    state = Mutex(State())
    var loaded: [Loaded] = []
    var rejected = 0
    var candidates = Self.files(in: directory, prefix: keyPrefix).sorted(by: Self.newestFirst)
    // The newest file that verifies; the rest wait for a miss.
    while loaded.isEmpty && !candidates.isEmpty {
      let url = candidates.removeFirst()
      switch verifiedArchive(url) {
      case .opened(let archive): loaded.append(Loaded(url: url, archive: archive))
      case .rejected:
        rejected += 1
        try? FileManager.default.removeItem(at: url)
      case .unavailable: break
      }
    }
    let older = Array(candidates.prefix(max(0, self.maximumFiles - loaded.count)))
    state.withLock { s in
      s.loaded = loaded
      s.older = older
      s.statistics.filesLoaded = loaded.count
      s.statistics.filesRejected = rejected
      s.options.lookupArchives = loaded.map(\.archive)
    }
  }

  public var statistics: Statistics { state.withLock { $0.statistics } }

  /// The archive files in use for lookups, newest first (older files of the key
  /// join once a lookup missed in these).
  public var files: [URL] { state.withLock { $0.loaded.map(\.url) } }

  /// The pipelines the next save records (each descriptor once).
  var recipeCount: Int { state.withLock { $0.built.count } }

  // MARK: Building

  package func makeLibrary(descriptor: MTL4LibraryDescriptor) throws -> MTLLibrary {
    try compiler.makeLibrary(descriptor: descriptor)
  }

  /// The render pipeline for `descriptor`: made from the newest loaded archive
  /// that holds it, otherwise compiled. Either way kept for the next save to record.
  package func makeRenderPipelineState(descriptor: MTL4RenderPipelineDescriptor) throws -> MTLRenderPipelineState {
    // A copy: the caller's descriptor is its own to change.
    let recipe = descriptor.copy() as! MTL4RenderPipelineDescriptor
    if let found = lookup({ try $0.makeRenderPipelineState(descriptor: descriptor) }) {
      note(hit: true, recipe, .render(recipe))
      return found
    }
    let made = try compiler.makeRenderPipelineState(descriptor: descriptor)
    note(hit: false, recipe, .render(recipe))
    return made
  }

  /// The compiler's asynchronous build (Metal's compiler threads) on a miss. Only
  /// the plain build compiler is used asynchronously: on macOS 27 (SDK 27.0) an
  /// asynchronous build by a compiler with a pipeline data set serializer crashes
  /// in Metal's compiler scheduler, so the recorder builds synchronously, in `save()`.
  package func makeRenderPipelineState(descriptor: MTL4RenderPipelineDescriptor) async throws
    -> MTLRenderPipelineState
  {
    let recipe = descriptor.copy() as! MTL4RenderPipelineDescriptor
    if let found = lookup({ try $0.makeRenderPipelineState(descriptor: descriptor) }) {
      note(hit: true, recipe, .render(recipe))
      return found
    }
    let made = try await compiler.makeRenderPipelineState(descriptor: descriptor)
    note(hit: false, recipe, .render(recipe))
    return made
  }

  package func makeComputePipelineState(descriptor: MTL4ComputePipelineDescriptor) throws -> MTLComputePipelineState {
    let recipe = descriptor.copy() as! MTL4ComputePipelineDescriptor
    if let found = lookup({ try $0.makeComputePipelineState(descriptor: descriptor) }) {
      note(hit: true, recipe, .compute(recipe))
      return found
    }
    let made = try compiler.makeComputePipelineState(descriptor: descriptor)
    note(hit: false, recipe, .compute(recipe))
    return made
  }

  /// `makeRenderPipelineState(descriptor:) async` for a compute pipeline.
  package func makeComputePipelineState(descriptor: MTL4ComputePipelineDescriptor) async throws
    -> MTLComputePipelineState
  {
    let recipe = descriptor.copy() as! MTL4ComputePipelineDescriptor
    if let found = lookup({ try $0.makeComputePipelineState(descriptor: descriptor) }) {
      note(hit: true, recipe, .compute(recipe))
      return found
    }
    let made = try await compiler.makeComputePipelineState(descriptor: descriptor)
    note(hit: false, recipe, .compute(recipe))
    return made
  }

  /// The pipeline `make` makes from the newest loaded archive that holds it (Metal
  /// returns one only when the whole descriptor matches), or nil. When none holds
  /// it, the key's older files are opened first (once) and tried too.
  private func lookup<T>(_ make: (any MTL4Archive) throws -> T) -> T? {
    let archives = state.withLock { $0.loaded.map(\.archive) }
    var i = 0
    while i < archives.count {
      if let found = try? make(archives[i]) { return found }
      i += 1
    }
    let older = openOlderFiles()
    i = 0
    while i < older.count {
      if let found = try? make(older[i]) { return found }
      i += 1
    }
    return nil
  }

  /// Opens the key's older files (verified and primed, as at init) the first time
  /// a lookup misses, and adds them after the loaded ones within `maximumFiles`.
  /// Returns those opened by this call (none once done, or while another thread
  /// opens them: that lookup then compiles, which is only slower).
  private func openOlderFiles() -> [any MTL4Archive] {
    let urls = state.withLock { s -> [URL] in
      defer { s.older = [] }
      return s.older
    }
    guard !urls.isEmpty else { return [] }
    var opened: [Loaded] = []
    var rejected = 0
    var i = 0
    while i < urls.count {
      switch verifiedArchive(urls[i]) {
      case .opened(let archive): opened.append(Loaded(url: urls[i], archive: archive))
      case .rejected:
        rejected += 1
        try? FileManager.default.removeItem(at: urls[i])
      case .unavailable: break
      }
      i += 1
    }
    state.withLock { s in
      // Older than every loaded file (a save since put its own first).
      let room = max(0, maximumFiles - s.loaded.count)
      let kept = opened.prefix(room).filter { o in !s.loaded.contains { $0.url == o.url } }
      s.loaded.append(contentsOf: kept)
      s.statistics.filesLoaded += kept.count
      s.statistics.filesRejected += rejected
      let options = MTL4CompilerTaskOptions()
      options.lookupArchives = s.loaded.map(\.archive)
      s.options = options
    }
    return opened.map(\.archive)
  }

  /// Counts the build and keeps `recipe` for the next save (once per descriptor:
  /// two threads may build the same pipeline); a miss schedules a save.
  private func note(hit: Bool, _ descriptor: NSObject, _ recipe: Recipe) {
    let key = Recorded(descriptor: descriptor)
    let schedule = state.withLock { s -> Bool in
      if s.recorded.insert(key).inserted { s.built.append(recipe) }
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
  /// utility-priority task (the library makes no thread or queue of its own, so
  /// the save's file I/O blocks one cooperative-pool thread for its tens to a few
  /// hundred milliseconds). Holds the archive until then.
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
  /// is in `statistics.lastError`, and the session's pipelines stay to be saved by
  /// the next call.
  @discardableResult
  public func save() -> Bool {
    saveLock.lock()
    defer { saveLock.unlock() }
    let (dirty, built, options) = state.withLock { s -> (Bool, [Recipe], MTL4CompilerTaskOptions) in
      defer { s.dirty = false }
      return (s.dirty, s.built, s.options)
    }
    guard dirty else { return false }
    /// Leaves the session to the next save (misses since stay counted).
    func failed(_ message: String) -> Bool {
      state.withLock { s in
        s.dirty = true
        s.statistics.lastError = message
      }
      return false
    }
    // Into the serializer: archive or system-cache hits, as the build compiler
    // just compiled any that were missing. One that fails is left out (reported).
    var failures = 0
    var firstFailure: (any Error)?
    var i = 0
    while i < built.count {
      do {
        switch built[i] {
        case .render(let d): _ = try recorder.makeRenderPipelineState(descriptor: d, compilerTaskOptions: options)
        case .compute(let d): _ = try recorder.makeComputePipelineState(descriptor: d, compilerTaskOptions: options)
        }
      } catch {
        failures += 1
        firstFailure = firstFailure ?? error
      }
      i += 1
    }
    let recorderError = firstFailure.map { "recorder: \(failures) of \(built.count) pipelines failed: \($0)" }
    let fm = FileManager.default
    let temporary = directory.appendingPathComponent(".\(name)-\(UUID().uuidString).tmp")
    defer { try? fm.removeItem(at: temporary) }
    let url: URL
    let archive: any MTL4Archive
    do {
      try fm.createDirectory(at: directory, withIntermediateDirectories: true)
      do {
        try serializer.serializeAsArchiveAndFlush(url: temporary)
      } catch let error as NSError where error.domain == MTLBinaryArchiveDomain && error.code == 3 {
        // "Nothing to serialize": `built` is not empty, so every recording failed.
        return failed(recorderError ?? "recorder: nothing recorded of \(built.count) pipelines")
      }
      // Hashed once: the archive is opened (and used once) from this file, which
      // only this save knows, before it is renamed into place.
      let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
      url = directory.appendingPathComponent(
        keyPrefix + Self.hex(SHA256.hash(data: data)).prefix(32) + "." + Self.fileExtension)
      guard let opened = try? device.makeArchive(url: temporary), prime(opened) else {
        return failed("save: Metal cannot open the archive it wrote")
      }
      archive = opened
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
      return failed("save: \(error)")
    }
    state.withLock { s in
      s.statistics.saves += 1
      if let recorderError { s.statistics.lastError = recorderError }
      s.loaded.removeAll { $0.url == url }
      s.loaded.insert(Loaded(url: url, archive: archive), at: 0)
      s.statistics.filesLoaded += 1
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

  private enum Opened {
    case opened(any MTL4Archive)
    /// Damaged: the bytes do not hash to the name, or Metal cannot open them.
    case rejected
    /// Gone (removed by another engine or the host) or not usable now.
    case unavailable
  }

  /// The archive at `url` if its bytes hash to the content hash in its name (so
  /// Metal never reads a truncated or corrupt file) and Metal opens it, used once
  /// (`prime`), so it no longer needs the file.
  private func verifiedArchive(_ url: URL) -> Opened {
    let file = url.deletingPathExtension().lastPathComponent
    guard file.hasPrefix(keyPrefix) else { return .rejected }
    let expected = file.dropFirst(keyPrefix.count)
    guard expected.count == 32 else { return .rejected }
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return .unavailable }
    guard !data.isEmpty, Self.hex(SHA256.hash(data: data)).prefix(32) == expected,
      let archive = try? device.makeArchive(url: url)
    else { return .rejected }
    return prime(archive) ? .opened(archive) : .unavailable
  }

  /// Uses `archive` once in a compiler build (a trivial kernel, `archive` its only
  /// lookup archive): Metal reads the archive's file again at its first compiler
  /// use and raises an uncaught exception there when the file is gone, so this runs
  /// while the file is known to be present. Measured: about 0.2 ms (a few ms for
  /// the first in a process). False when the build fails: the archive is not used.
  private func prime(_ archive: any MTL4Archive) -> Bool {
    let descriptor = primer.withLock { made -> MTL4ComputePipelineDescriptor? in
      if let made { return made }
      let l = MTL4LibraryDescriptor()
      l.name = "\(name) archive primer"
      l.source = "kernel void mk_archive_prime() {}"
      guard let library = try? compiler.makeLibrary(descriptor: l) else { return nil }
      let f = MTL4LibraryFunctionDescriptor()
      f.name = "mk_archive_prime"
      f.library = library
      let d = MTL4ComputePipelineDescriptor()
      d.computeFunctionDescriptor = f
      made = d
      return d
    }
    guard let descriptor else { return false }
    let options = MTL4CompilerTaskOptions()
    options.lookupArchives = [archive]
    return (try? compiler.makeComputePipelineState(descriptor: descriptor, compilerTaskOptions: options)) != nil
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
