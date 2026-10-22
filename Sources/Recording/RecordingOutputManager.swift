import Foundation
import Darwin

/// Lifecycle of one atomic recording output file.
public enum RecordingOutputSessionState: String, Equatable, Sendable {
  case idle
  case recording
  case paused
  case finished
  case cancelled
  case failed
}

/// The paths allocated for one feed/session. The temporary path is kept beside
/// the final path so a successful move is an atomic same-volume rename.
public struct RecordingOutputPaths: Equatable, Sendable {
  public let rootDirectory: URL
  public let feedDirectory: URL
  public let temporaryFile: URL
  public let finalFile: URL

  public init(rootDirectory: URL, feedDirectory: URL, temporaryFile: URL, finalFile: URL) {
    self.rootDirectory = rootDirectory
    self.feedDirectory = feedDirectory
    self.temporaryFile = temporaryFile
    self.finalFile = finalFile
  }
}

/// A filesystem boundary used by admission checks. Tests can provide a fixed
/// value without allocating a large file or changing the host volume.
public protocol RecordingOutputDiskSpaceProviding: Sendable {
  func availableBytes(at directory: URL) throws -> UInt64
}

public struct FileManagerRecordingOutputDiskSpaceProvider: RecordingOutputDiskSpaceProviding {
  public init() {}

  public func availableBytes(at directory: URL) throws -> UInt64 {
    let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    guard let value = values.volumeAvailableCapacityForImportantUsage, value >= 0 else {
      throw RecordingOutputError.diskSpaceUnavailable
    }
    return UInt64(value)
  }
}

public enum RecordingOutputError: Error, Equatable, LocalizedError, Sendable {
  case invalidRoot
  case invalidFeedID
  case invalidFileExtension
  case unsafePath
  case diskSpaceUnavailable
  case insufficientDiskSpace(required: UInt64, available: UInt64)
  case invalidState(RecordingOutputSessionState, operation: String)
  case destinationExists
  case ioFailure(String)

  public var errorDescription: String? {
    switch self {
    case .invalidRoot: return "The recording output root must be a writable directory."
    case .invalidFeedID: return "The feed ID must be one safe path component."
    case .invalidFileExtension: return "The recording file extension is invalid."
    case .unsafePath: return "The recording path would leave the configured output root."
    case .diskSpaceUnavailable: return "Free space could not be determined for the recording volume."
    case let .insufficientDiskSpace(required, available):
      return "Recording requires \(required) bytes of free space; only \(available) are available."
    case let .invalidState(state, operation):
      return "Cannot \(operation) while recording session is \(state.rawValue)."
    case .destinationExists: return "The recording destination already exists."
    case let .ioFailure(message): return "Recording output I/O failed: \(message)"
    }
  }
}

/// Configuration for a recording output catalog. Every session reserves its
/// expected bytes before opening a temporary file and preserves a free-space
/// floor throughout its lifetime.
public struct RecordingOutputConfiguration: Equatable, Sendable {
  public let rootDirectory: URL
  public let fileExtension: String
  public let minimumFreeBytes: UInt64

  public init(rootDirectory: URL, fileExtension: String = "mov",
              minimumFreeBytes: UInt64 = 128 * 1024 * 1024) throws {
    guard rootDirectory.isFileURL else { throw RecordingOutputError.invalidRoot }
    let root = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
    guard !root.path.isEmpty else { throw RecordingOutputError.invalidRoot }
    let extensionValue = try Self.validateExtension(fileExtension)
    self.rootDirectory = root
    self.fileExtension = extensionValue
    self.minimumFreeBytes = minimumFreeBytes
  }

  fileprivate static func validateExtension(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let withoutDot = trimmed.hasPrefix(".") ? String(trimmed.dropFirst()) : trimmed
    guard !withoutDot.isEmpty, withoutDot.count <= 16,
      withoutDot.unicodeScalars.allSatisfy({ scalar in
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
          .contains(scalar)
      }) else {
      throw RecordingOutputError.invalidFileExtension
    }
    return withoutDot.lowercased()
  }
}

/// Owns feed directories and admission reservations. Sessions created by one
/// manager do not share lifecycle state: pausing or failing one feed never
/// changes another feed's state.
public final class RecordingOutputManager: @unchecked Sendable {
  private let configuration: RecordingOutputConfiguration
  private let diskSpace: any RecordingOutputDiskSpaceProviding
  private let fileManager: FileManager
  private let lock = NSLock()
  private var reservedBytes: UInt64 = 0
  private var pathNonce: UInt64 = 0

  public init(configuration: RecordingOutputConfiguration,
              diskSpace: any RecordingOutputDiskSpaceProviding = FileManagerRecordingOutputDiskSpaceProvider(),
              fileManager: FileManager = .default) throws {
    self.configuration = configuration
    self.diskSpace = diskSpace
    self.fileManager = fileManager
    try Self.prepareRoot(configuration.rootDirectory, fileManager: fileManager)
  }

  public convenience init(rootDirectory: URL, fileExtension: String = "mov",
                          minimumFreeBytes: UInt64 = 128 * 1024 * 1024,
                          diskSpace: any RecordingOutputDiskSpaceProviding = FileManagerRecordingOutputDiskSpaceProvider(),
                          fileManager: FileManager = .default) throws {
    try self.init(configuration: RecordingOutputConfiguration(rootDirectory: rootDirectory,
      fileExtension: fileExtension, minimumFreeBytes: minimumFreeBytes),
      diskSpace: diskSpace, fileManager: fileManager)
  }

  /// Creates an idle session after performing disk-space admission. Call
  /// `start()` (or use `beginSession`) before appending bytes.
  public func makeSession(feedID: String, sessionID: UUID = UUID(),
                          expectedBytes: UInt64 = 0) throws -> RecordingOutputSession {
    let safeFeedID = try Self.validateFeedID(feedID)
    let paths = try makePaths(feedID: safeFeedID, sessionID: sessionID)
    try reserve(expectedBytes: expectedBytes)
    return RecordingOutputSession(manager: self, paths: paths, expectedBytes: expectedBytes)
  }

  /// Creates and starts a session in one operation.
  public func beginSession(feedID: String, sessionID: UUID = UUID(),
                           expectedBytes: UInt64 = 0) throws -> RecordingOutputSession {
    let session = try makeSession(feedID: feedID, sessionID: sessionID, expectedBytes: expectedBytes)
    do {
      try session.start()
      return session
    } catch {
      session.cancelWithoutThrowing()
      throw error
    }
  }

  /// Creates a session whose temporary path is owned by an external media
  /// writer such as AVAssetWriter. The writer creates the movie at the
  /// temporary URL, while this boundary retains disk admission and performs
  /// the final same-volume rename after the writer closes it.
  public func beginExternalWriterSession(feedID: String, sessionID: UUID = UUID(),
                                         expectedBytes: UInt64 = 0) throws -> RecordingOutputSession {
    let session = try makeSession(feedID: feedID, sessionID: sessionID,
      expectedBytes: expectedBytes)
    do {
      try session.startExternalWriter()
      return session
    } catch {
      try? session.cancel()
      throw error
    }
  }

  public var outputRoot: URL { configuration.rootDirectory }

  fileprivate var minimumFreeBytes: UInt64 { configuration.minimumFreeBytes }
  fileprivate var fileExtension: String { configuration.fileExtension }
  fileprivate var fileManagerRef: FileManager { fileManager }

  fileprivate func release(reserved: UInt64) {
    lock.lock()
    reservedBytes = reservedBytes >= reserved ? reservedBytes - reserved : 0
    lock.unlock()
  }

  fileprivate func reserve(expectedBytes: UInt64) throws {
    lock.lock()
    defer { lock.unlock() }
    try checkAndReserveLocked(additional: expectedBytes)
  }

  fileprivate func reserveAdditional(_ additional: UInt64) throws {
    lock.lock()
    defer { lock.unlock() }
    try checkAndReserveLocked(additional: additional)
  }

  private func checkAndReserveLocked(additional: UInt64) throws {
    let available: UInt64
    do {
      available = try diskSpace.availableBytes(at: configuration.rootDirectory)
    } catch let error as RecordingOutputError {
      throw error
    } catch {
      throw RecordingOutputError.diskSpaceUnavailable
    }
    let required = Self.saturatingAdd(configuration.minimumFreeBytes,
      Self.saturatingAdd(reservedBytes, additional))
    guard available >= required else {
      throw RecordingOutputError.insufficientDiskSpace(required: required, available: available)
    }
    reservedBytes = Self.saturatingAdd(reservedBytes, additional)
  }

  private func makePaths(feedID: String, sessionID: UUID) throws -> RecordingOutputPaths {
    // Path allocation is performed under the same lock as reservations. This
    // manager is used by multiple feed starts, and an external AVAssetWriter
    // does not create its temporary file until after this method returns.
    lock.lock()
    defer { lock.unlock() }
    let feedDirectory = configuration.rootDirectory.appendingPathComponent(feedID, isDirectory: true)
      .standardizedFileURL
    guard Self.isDescendant(feedDirectory, of: configuration.rootDirectory) else {
      throw RecordingOutputError.unsafePath
    }
    if fileManager.fileExists(atPath: feedDirectory.path) {
      let resolved = feedDirectory.resolvingSymlinksInPath()
      guard Self.isDescendant(resolved, of: configuration.rootDirectory) else {
        throw RecordingOutputError.unsafePath
      }
    }
    let nonce = pathNonce
    pathNonce &+= 1
    let take = String(format: "%03llu", nonce + 1)
    let stemBase = "\(feedID)_\(Self.fileTimestamp())_\(take)_\(sessionID.uuidString)"
    var stem = stemBase
    var suffix = 2
    while fileManager.fileExists(atPath: feedDirectory.appendingPathComponent(".\(stem).partial").path)
      || fileManager.fileExists(atPath: feedDirectory.appendingPathComponent("\(stem).\(configuration.fileExtension)").path)
      || fileManager.fileExists(atPath: feedDirectory.appendingPathComponent(".\(stem).partial.ultracam-recovery").path) {
      stem = "\(stemBase)-\(suffix)"
      suffix += 1
    }
    let temporary = feedDirectory.appendingPathComponent(".\(stem).partial", isDirectory: false)
    let final = feedDirectory.appendingPathComponent("\(stem).\(configuration.fileExtension)", isDirectory: false)
    guard Self.isDescendant(temporary, of: configuration.rootDirectory),
      Self.isDescendant(final, of: configuration.rootDirectory) else {
      throw RecordingOutputError.unsafePath
    }
    guard !fileManager.fileExists(atPath: temporary.path), !fileManager.fileExists(atPath: final.path) else {
      throw RecordingOutputError.destinationExists
    }
    return RecordingOutputPaths(rootDirectory: configuration.rootDirectory,
      feedDirectory: feedDirectory, temporaryFile: temporary, finalFile: final)
  }

  private static func fileTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    return formatter.string(from: Date())
  }

  fileprivate static func prepareRoot(_ root: URL, fileManager: FileManager) throws {
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else { throw RecordingOutputError.invalidRoot }
    } else {
      do { try fileManager.createDirectory(at: root, withIntermediateDirectories: true) }
      catch { throw RecordingOutputError.ioFailure(error.localizedDescription) }
    }
  }

  fileprivate static func validateFeedID(_ value: String) throws -> String {
    guard !value.isEmpty, value != ".", value != "..", value.count <= 128,
      !value.unicodeScalars.contains(where: { scalar in
        // Keep feed IDs a single, printable path component. `isWhitespace`
        // does not cover every C0 control (for example U+0001), and those
        // bytes can still produce ambiguous or unrenderable file paths.
        scalar == "/" || scalar == "\\" || scalar.value < 0x20 || scalar.value == 0x7F
      }) else {
      throw RecordingOutputError.invalidFeedID
    }
    return value
  }

  fileprivate static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
    let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
    let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
    guard candidatePath != rootPath else { return false }
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    return candidatePath.hasPrefix(prefix)
  }

  fileprivate static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? UInt64.max : result
  }
}

/// A byte-oriented session file. The temporary file remains in place while a
/// session is paused and is renamed only after `finish()` flushes and closes it.
public final class RecordingOutputSession: @unchecked Sendable {
  private let manager: RecordingOutputManager
  public let paths: RecordingOutputPaths
  public let expectedBytes: UInt64
  private let lock = NSLock()
  private var stateValue: RecordingOutputSessionState = .idle
  private var handle: FileHandle?
  private var reservedBytes: UInt64
  private var bytesWrittenValue: UInt64 = 0
  private var releasedReservation = false
  private var ownsTemporaryFile = false
  private var externalWriterOwnsFile = false
  private var recoveryJournal: RecordingRecoveryJournal?

  fileprivate init(manager: RecordingOutputManager, paths: RecordingOutputPaths, expectedBytes: UInt64) {
    self.manager = manager
    self.paths = paths
    self.expectedBytes = expectedBytes
    self.reservedBytes = expectedBytes
  }

  public var state: RecordingOutputSessionState {
    lock.lock(); defer { lock.unlock() }
    return stateValue
  }

  public var bytesWritten: UInt64 {
    lock.lock(); defer { lock.unlock() }
    return bytesWrittenValue
  }

  public var temporaryURL: URL { paths.temporaryFile }
  public var finalURL: URL { paths.finalFile }

  public func start() throws {
    lock.lock(); defer { lock.unlock() }
    guard stateValue == .idle else {
      throw RecordingOutputError.invalidState(stateValue, operation: "start")
    }
    do {
      try prepareFilesystemLocked()
      let descriptor = open(paths.temporaryFile.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
      guard descriptor >= 0 else {
        if errno == EEXIST { throw RecordingOutputError.destinationExists }
        throw RecordingOutputError.ioFailure(String(cString: strerror(errno)))
      }
      let next = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      handle = next
      ownsTemporaryFile = true
      stateValue = .recording
    } catch let error as RecordingOutputError {
      stateValue = .failed
      releaseReservationLocked()
      throw error
    } catch {
      stateValue = .failed
      releaseReservationLocked()
      throw RecordingOutputError.ioFailure(error.localizedDescription)
    }
  }

  /// Starts a session without creating the temporary file. This is used by a
  /// media writer that must create its own container at the URL. It retains
  /// the same path and disk safety checks as `start()`.
  fileprivate func startExternalWriter() throws {
    lock.lock(); defer { lock.unlock() }
    guard stateValue == .idle else {
      throw RecordingOutputError.invalidState(stateValue, operation: "start external writer")
    }
    do {
      try prepareFilesystemLocked()
      recoveryJournal = try RecordingRecoveryJournal(temporary: paths.temporaryFile, final: paths.finalFile)
      ownsTemporaryFile = true
      externalWriterOwnsFile = true
      stateValue = .recording
    } catch let error as RecordingOutputError {
      stateValue = .failed
      releaseReservationLocked()
      throw error
    } catch {
      stateValue = .failed
      releaseReservationLocked()
      throw RecordingOutputError.ioFailure(error.localizedDescription)
    }
  }

  public func pause() throws {
    lock.lock(); defer { lock.unlock() }
    guard stateValue == .recording else {
      throw RecordingOutputError.invalidState(stateValue, operation: "pause")
    }
    do { handle?.synchronizeFile() }
    stateValue = .paused
  }

  public func resume() throws {
    lock.lock(); defer { lock.unlock() }
    guard stateValue == .paused else {
      throw RecordingOutputError.invalidState(stateValue, operation: "resume")
    }
    // External media writers own the file descriptor, so their session never
    // has a local FileHandle. Their writer lifecycle is paused/resumed by the
    // caller (for example SourceRecorderCore); the output boundary only needs
    // to preserve its admission reservation and state.
    guard handle != nil || externalWriterOwnsFile else {
      stateValue = .failed
      releaseReservationLocked()
      throw RecordingOutputError.ioFailure("Temporary output file is closed.")
    }
    stateValue = .recording
  }

  /// Appends bytes to the current temporary output. Pausing preserves the file
  /// and rejects new bytes until `resume()` is called.
  public func append(_ data: Data) throws {
    lock.lock(); defer { lock.unlock() }
    guard stateValue == .recording else {
      throw RecordingOutputError.invalidState(stateValue, operation: "append data")
    }
    guard let handle else {
      if externalWriterOwnsFile {
        throw RecordingOutputError.ioFailure("Cannot append data while the external writer owns the output file.")
      }
      stateValue = .failed
      releaseReservationLocked()
      throw RecordingOutputError.ioFailure("Temporary output file is unavailable.")
    }
    let size = UInt64(data.count)
    let target = RecordingOutputManager.saturatingAdd(bytesWrittenValue, size)
    if target > reservedBytes {
      let extra = target - reservedBytes
      do {
        try manager.reserveAdditional(extra)
        reservedBytes = target
      } catch {
        throw error
      }
    } else {
      do { try manager.reserveAdditional(0) } catch { throw error }
    }
    do {
      try handle.write(contentsOf: data)
      bytesWrittenValue = target
    } catch {
      stateValue = .failed
      releaseReservationLocked()
      throw RecordingOutputError.ioFailure(error.localizedDescription)
    }
  }

  /// Called on the recorder queue before more media reaches the external
  /// writer. Written bytes consume the initial reservation; counting them
  /// again as reserved space would reject a take that still has room.
  public func checkExternalWriterCapacity() throws {
    lock.lock(); defer { lock.unlock() }
    // Samples admitted just before a pause still reach the writer after the
    // session is paused. Space is rechecked once recording resumes.
    if externalWriterOwnsFile, stateValue == .paused { return }
    guard externalWriterOwnsFile, stateValue == .recording else {
      throw RecordingOutputError.invalidState(stateValue, operation: "check external writer space")
    }
    if manager.fileManagerRef.fileExists(atPath: paths.temporaryFile.path) {
      let attributes = try manager.fileManagerRef.attributesOfItem(atPath: paths.temporaryFile.path)
      let written = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
      let consumed = min(reservedBytes, written > bytesWrittenValue ? written - bytesWrittenValue : 0)
      manager.release(reserved: consumed)
      reservedBytes -= consumed
      bytesWrittenValue = written
    }
    try manager.reserveAdditional(0)
  }

  public func finish() throws -> URL {
    lock.lock(); defer { lock.unlock() }
    guard stateValue == .recording || stateValue == .paused else {
      throw RecordingOutputError.invalidState(stateValue, operation: "finish")
    }
    do {
      if let handle {
        handle.synchronizeFile()
        handle.closeFile()
        self.handle = nil
      }
      // The external writer creates the temporary path after admission. Check
      // the resolved path again before reading or moving it so a replaced
      // path cannot make the atomic rename escape the configured root.
      guard RecordingOutputManager.isDescendant(paths.temporaryFile,
        of: paths.rootDirectory),
        RecordingOutputManager.isDescendant(paths.finalFile,
          of: paths.rootDirectory) else {
        throw RecordingOutputError.unsafePath
      }
      guard manager.fileManagerRef.fileExists(atPath: paths.temporaryFile.path) else {
        throw RecordingOutputError.ioFailure("The media writer did not produce a temporary output file.")
      }
      let temporaryAttributes = try manager.fileManagerRef.attributesOfItem(
        atPath: paths.temporaryFile.path)
      guard (temporaryAttributes[.type] as? FileAttributeType) != .typeSymbolicLink else {
        throw RecordingOutputError.unsafePath
      }
      if externalWriterOwnsFile {
        let byteCount = (temporaryAttributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard byteCount > 0 else {
          throw RecordingOutputError.ioFailure("The media writer produced an empty output file.")
        }
      }
      guard !manager.fileManagerRef.fileExists(atPath: paths.finalFile.path) else {
        throw RecordingOutputError.destinationExists
      }
      try manager.fileManagerRef.moveItem(at: paths.temporaryFile, to: paths.finalFile)
      recoveryJournal?.remove()
      recoveryJournal = nil
      stateValue = .finished
      releaseReservationLocked()
      return paths.finalFile
    } catch let error as RecordingOutputError {
      stateValue = .failed
      releaseReservationLocked()
      throw error
    } catch {
      stateValue = .failed
      releaseReservationLocked()
      throw RecordingOutputError.ioFailure(error.localizedDescription)
    }
  }

  /// Stop owning a failed take without deleting its media or recovery journal.
  public func preserveForRecovery() {
    lock.lock(); defer { lock.unlock() }
    handle?.synchronizeFile()
    handle?.closeFile()
    handle = nil
    recoveryJournal = nil
    stateValue = .failed
    releaseReservationLocked()
  }

  public func cancel() throws {
    lock.lock(); defer { lock.unlock() }
    guard stateValue != .finished && stateValue != .cancelled else {
      throw RecordingOutputError.invalidState(stateValue, operation: "cancel")
    }
    handle?.synchronizeFile()
    handle?.closeFile()
    handle = nil
    if ownsTemporaryFile && manager.fileManagerRef.fileExists(atPath: paths.temporaryFile.path) {
      do { try manager.fileManagerRef.removeItem(at: paths.temporaryFile) }
      catch {
        stateValue = .failed
        releaseReservationLocked()
        throw RecordingOutputError.ioFailure(error.localizedDescription)
      }
    }
    recoveryJournal?.remove()
    recoveryJournal = nil
    stateValue = .cancelled
    releaseReservationLocked()
  }

  fileprivate func cancelWithoutThrowing() {
    lock.lock(); defer { lock.unlock() }
    guard stateValue != .finished && stateValue != .cancelled else { return }
    handle?.closeFile()
    handle = nil
    if ownsTemporaryFile { try? manager.fileManagerRef.removeItem(at: paths.temporaryFile) }
    recoveryJournal?.remove()
    recoveryJournal = nil
    stateValue = .cancelled
    releaseReservationLocked()
  }

  deinit {
    lock.lock()
    handle?.closeFile()
    handle = nil
    releaseReservationLocked()
    lock.unlock()
  }

  private func releaseReservationLocked() {
    guard !releasedReservation else { return }
    releasedReservation = true
    manager.release(reserved: reservedBytes)
  }

  private func prepareFilesystemLocked() throws {
    try manager.fileManagerRef.createDirectory(at: paths.feedDirectory,
      withIntermediateDirectories: true)
    let resolved = paths.feedDirectory.resolvingSymlinksInPath()
    guard RecordingOutputManager.isDescendant(resolved, of: paths.rootDirectory) else {
      throw RecordingOutputError.unsafePath
    }
    guard !manager.fileManagerRef.fileExists(atPath: paths.temporaryFile.path),
      !manager.fileManagerRef.fileExists(atPath: paths.finalFile.path) else {
      throw RecordingOutputError.destinationExists
    }
  }
}
