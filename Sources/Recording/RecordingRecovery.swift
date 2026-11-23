import AVFoundation
import CryptoKit
import Darwin
import Foundation

/// Holds a sandbox grant for the entire asynchronous operation.
final class RecordingDirectoryAccess: @unchecked Sendable {
  let url: URL
  private let accessed: Bool
  init(_ url: URL) {
    self.url = url
    accessed = url.startAccessingSecurityScopedResource()
  }
  deinit { if accessed { url.stopAccessingSecurityScopedResource() } }
}

/// One small, fsynced journal owns an interrupted movie. A process lock keeps
/// discovery/recovery from opening a take that another writer still owns.
final class RecordingRecoveryJournal: @unchecked Sendable {
  struct MovieIdentity: Codable, Equatable {
    let bytes: UInt64
    let fingerprint: Data

    init(reading url: URL) throws {
      let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
      guard fd >= 0 else { throw RecordingOutputError.unsafePath }
      let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      defer { try? handle.close() }
      var info = stat()
      guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0 else {
        throw RecordingOutputError.unsafePath
      }
      bytes = UInt64(info.st_size)
      // The identity must survive both a rename and a removable volume remount.
      let sampleBytes = 4096
      let headBytes = Int(min(UInt64(sampleBytes), bytes))
      guard let head = try handle.read(upToCount: headBytes), head.count == headBytes else {
        throw RecordingOutputError.unsafePath
      }
      var hash = SHA256()
      hash.update(data: head)
      if bytes > UInt64(headBytes) {
        let tailBytes = Int(min(UInt64(sampleBytes), bytes - UInt64(headBytes)))
        try handle.seek(toOffset: bytes - UInt64(tailBytes))
        guard let tail = try handle.read(upToCount: tailBytes), tail.count == tailBytes else {
          throw RecordingOutputError.unsafePath
        }
        hash.update(data: tail)
      }
      fingerprint = Data(hash.finalize())
    }
  }

  struct Entry: Codable {
    var version = 1
    let temporaryName: String
    let finalName: String
    var recoveredName: String?
    var recoveredIdentity: MovieIdentity? = nil
    var sidecarOwned: Bool? = nil
  }
  private struct Update: Codable {
    let revision: UInt64
    let entry: Entry
  }
  private struct StoredUpdate: Codable {
    let payload: Data
    let checksum: Data
  }
  let url: URL
  private let descriptor: Int32
  private var revision: UInt64 = 0
  private(set) var entry: Entry
  // Keep the original JSON intact. The two slots above it alternate on
  // update, so a torn write preserves the latest committed record.
  private static let slotBytes = 16 * 1024
  private static let maximumJournalBytes = 3 * slotBytes

  static func url(for temporary: URL) -> URL {
    temporary.appendingPathExtension("ultracam-recovery")
  }

  init(temporary: URL, final: URL) throws {
    url = Self.url(for: temporary)
    entry = Entry(temporaryName: temporary.lastPathComponent, finalName: final.lastPathComponent)
    let opened = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard opened >= 0 else { throw RecordingOutputError.ioFailure("Cannot create recovery journal.") }
    guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
      close(opened)
      throw RecordingOutputError.ioFailure("Cannot lock recovery journal.")
    }
    descriptor = opened
    do {
      guard Self.isValid(entry, at: url) else { throw RecordingOutputError.unsafePath }
      let baseline = try JSONEncoder().encode(entry)
      guard baseline.count < Self.slotBytes else { throw RecordingOutputError.unsafePath }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
      try handle.write(contentsOf: baseline)
      try handle.synchronize()
    }
    catch { remove(); throw error }
  }

  init(opening url: URL) throws {
    self.url = url
    let opened = open(url.path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard opened >= 0 else { throw RecordingOutputError.unsafePath }
    do {
      var info = stat()
      // A creator acquires the lock before its first write. Leave a newly
      // created empty file alone so discovery cannot take its lock first.
      guard fstat(opened, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
        info.st_size > 0 else { throw RecordingOutputError.unsafePath }
      guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
        throw RecordingOutputError.ioFailure("This recording is still in use.")
      }
      guard fstat(opened, &info) == 0, info.st_size > 0,
        info.st_size <= Self.maximumJournalBytes else { throw RecordingOutputError.unsafePath }
      let handle = FileHandle(fileDescriptor: opened, closeOnDealloc: false)
      guard let data = try handle.read(upToCount: Int(info.st_size)),
        data.count == info.st_size else { throw RecordingOutputError.unsafePath }
      let decoder = JSONDecoder()
      // The sparse gap before the update slots reads as NUL, which cannot
      // occur literally in JSON. A legacy file contains only the baseline.
      let baselineBytes = data.prefix(Self.slotBytes).prefix { $0 != 0 }
      let baseline = try decoder.decode(Entry.self, from: baselineBytes)
      guard Self.isValid(baseline, at: url) else { throw RecordingOutputError.unsafePath }
      var latest = Update(revision: 0, entry: baseline)
      for offset in stride(from: Self.slotBytes, to: data.count, by: Self.slotBytes) {
        let slot = data[offset..<min(offset + Self.slotBytes, data.count)]
        guard let end = slot.firstIndex(of: 0x0a),
          let stored = try? decoder.decode(StoredUpdate.self, from: slot[..<end]),
          stored.checksum == Data(SHA256.hash(data: stored.payload)),
          let update = try? decoder.decode(Update.self, from: stored.payload),
          update.revision > latest.revision, Self.slotOffset(for: update.revision) == offset,
          update.entry.finalName == baseline.finalName, Self.isValid(update.entry, at: url) else { continue }
        latest = update
      }
      descriptor = opened
      entry = latest.entry
      revision = latest.revision
    } catch { close(opened); throw error }
  }

  private static func isValid(_ entry: Entry, at url: URL) -> Bool {
    let finalExtension = URL(fileURLWithPath: entry.finalName).pathExtension
    return entry.version == 1 &&
      safeName(entry.temporaryName) && safeName(entry.finalName) &&
      (try? RecordingOutputConfiguration.validateExtension(finalExtension)) == finalExtension.lowercased() &&
      url.lastPathComponent == entry.temporaryName + ".ultracam-recovery" &&
      entry.temporaryName == "." + String(entry.finalName.dropLast(finalExtension.count + 1)) + ".partial" &&
      (entry.recoveredName.map(safeName) ?? true)
  }

  private static func safeName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
      && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
  }

  private static func slotOffset(for revision: UInt64) -> Int {
    slotBytes * (revision.isMultiple(of: 2) ? 2 : 1)
  }

  private func save(_ candidate: Entry) throws {
    guard Self.isValid(candidate, at: url) else { throw RecordingOutputError.unsafePath }
    guard revision < UInt64.max else { throw RecordingOutputError.unsafePath }
    let nextRevision = revision + 1
    let offset = UInt64(Self.slotOffset(for: nextRevision))
    let encoder = JSONEncoder()
    let payload = try encoder.encode(Update(revision: nextRevision, entry: candidate))
    var data = try encoder.encode(StoredUpdate(payload: payload, checksum: Data(SHA256.hash(data: payload))))
    data.append(0x0a)
    guard data.count <= Self.slotBytes else { throw RecordingOutputError.unsafePath }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    do {
      try handle.seek(toOffset: offset)
      try handle.write(contentsOf: data)
      try handle.synchronize()
      revision = nextRevision
      entry = candidate
    } catch {
      // Invalidate an update the caller couldn't commit. The other slot
      // (or the initial record) remains authoritative.
      if (try? handle.seek(toOffset: offset)) != nil {
        try? handle.write(contentsOf: Data([0]))
        try? handle.synchronize()
      }
      throw error
    }
  }

  func claimSidecar() throws {
    guard entry.sidecarOwned != true else { return }
    var candidate = entry
    candidate.sidecarOwned = true
    try save(candidate)
  }
  func preparePublication(of staging: URL, to destination: URL) throws {
    let identity = try MovieIdentity(reading: staging)
    guard entry.recoveredName != destination.lastPathComponent || entry.recoveredIdentity != identity else { return }
    var candidate = entry
    candidate.recoveredName = destination.lastPathComponent
    candidate.recoveredIdentity = identity
    try save(candidate)
  }

  func publishedMovie(in folder: URL) -> URL? {
    guard let name = entry.recoveredName else { return nil }
    let url = folder.appendingPathComponent(name)
    guard let identity = try? MovieIdentity(reading: url),
      entry.recoveredIdentity.map({ $0 == identity }) ?? true else { return nil }
    return url
  }
  func remove() {
    var opened = stat()
    var current = stat()
    guard fstat(descriptor, &opened) == 0, lstat(url.path, &current) == 0,
      opened.st_dev == current.st_dev, opened.st_ino == current.st_ino else { return }
    _ = unlink(url.path)
  }
  deinit { close(descriptor) }
}

struct InterruptedRecording: Identifiable, Equatable, Sendable {
  let journalURL: URL
  let temporaryURL: URL
  let finalURL: URL
  var id: URL { journalURL }
  var title: String { finalURL.lastPathComponent }
}

enum RecordingRecovery {
  // Scan requests can overlap during model restoration and view creation.
  // Serialize them so their brief journal locks never hide a take from a
  // newer scan whose result replaces the earlier one.
  private static let scanLock = NSLock()
  /// Only our journals directly inside the root or its feed folders are inspected. Foreign
  /// partial files and symlinks are never treated as recoverable recordings.
  struct ScanReport {
    let takes: [InterruptedRecording]
    /// Busy or unreadable journals still own access to their original root.
    let mayPruneRoot: Bool
  }
  static func scan(root: URL) throws -> [InterruptedRecording] { try scanReport(root: root).takes }
  static func scanReport(root: URL) throws -> ScanReport {
    scanLock.lock()
    defer { scanLock.unlock() }
    let access = RecordingDirectoryAccess(root)
    defer { withExtendedLifetime(access) {} }
    let fm = FileManager.default
    let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
    let folders = try fm.contentsOfDirectory(at: canonicalRoot, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    var result: [InterruptedRecording] = []
    var hasJournal = false
    var unreadable = false
    // Feed folders are never hidden. A volume's root also holds system folders
    // (.Spotlight-V100, .DocumentRevisions-V100) this app may not open. Takes
    // recorded without camera subfolders sit in the root itself.
    for folder in [canonicalRoot] + folders where folder == canonicalRoot || !folder.lastPathComponent.hasPrefix(".") {
      if folder != canonicalRoot {
        guard let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
          unreadable = true
          continue
        }
        guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
      }
      // One folder it can't read must not hide the takes in the others.
      guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: []) else {
        unreadable = true
        continue
      }
      for url in files where url.lastPathComponent.hasSuffix(".partial.ultracam-recovery") {
        hasJournal = true
        guard let journal = try? RecordingRecoveryJournal(opening: url) else { continue }
        // Named from the journal's own folder, as `recover` does. The root's
        // spelling can differ from its listing's (/var against /private/var).
        let folder = url.deletingLastPathComponent()
        let source = folder.appendingPathComponent(journal.entry.temporaryName)
        // The journal lock also covers export. Only reclaim its staging file
        // after a crashed exporter has released that lock.
        let staging = source.appendingPathExtension("export.ultracam-recovery")
        var stagingInfo = stat()
        if lstat(staging.path, &stagingInfo) == 0 {
          guard (stagingInfo.st_mode & S_IFMT) == S_IFREG, unlink(staging.path) == 0 else { continue }
        } else if errno != ENOENT {
          // A read-only or unavailable take must not hide recordings in
          // other folders. Its journal still retains the original root.
          continue
        }
        let final = folder.appendingPathComponent(journal.entry.finalName)
        if journal.publishedMovie(in: folder) != nil { continue }
        // If publication succeeded the partial was moved away. A partial
        // beside an occupied final name still needs recovery to a new name.
        guard regularNonempty(source) else { continue }
        result.append(InterruptedRecording(journalURL: url, temporaryURL: source, finalURL: final))
      }
    }
    return ScanReport(takes: result.sorted { $0.title < $1.title }, mayPruneRoot: !hasJournal && !unreadable)
  }

  private static func regularNonempty(_ url: URL) -> Bool {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
    return attrs[.type] as? FileAttributeType == .typeRegular && (attrs[.size] as? NSNumber)?.int64Value ?? 0 > 0
  }

  /// Re-mux complete fragments into a new MOV. The interrupted original stays
  /// untouched even when export fails, is cancelled, or the app quits again.
  static func recover(_ take: InterruptedRecording, root: URL) async throws -> URL {
    let access = RecordingDirectoryAccess(root)
    defer { withExtendedLifetime(access) {} }
    let folder = take.journalURL.deletingLastPathComponent()
    let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
    // As in the scan: a take sits in a feed folder or, without camera
    // subfolders, in the root itself.
    let standardized = folder.standardizedFileURL
    guard standardized.path == canonicalRoot.path || standardized.deletingLastPathComponent().path == canonicalRoot.path,
      folder.resolvingSymlinksInPath().path == standardized.path else { throw RecordingOutputError.unsafePath }
    let journal = try RecordingRecoveryJournal(opening: take.journalURL)
    guard folder.appendingPathComponent(journal.entry.temporaryName) == take.temporaryURL,
      folder.appendingPathComponent(journal.entry.finalName) == take.finalURL,
      regularNonempty(take.temporaryURL) else { throw RecordingOutputError.unsafePath }
    if let recovered = journal.publishedMovie(in: folder) { return recovered }
    let mp4 = take.finalURL.pathExtension.lowercased() == "mp4"
    let mime = mp4 ? "video/mp4" : "video/quicktime"
    let ext = mp4 ? "mp4" : "mov"
    let asset = AVURLAsset(url: take.temporaryURL, options: [AVURLAssetOverrideMIMETypeKey: mime])
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let duration = try await asset.load(.duration)
    guard !tracks.isEmpty, duration.isNumeric, duration.seconds > 0 else {
      throw RecordingOutputError.ioFailure("No complete video fragment was saved. The interrupted file has been kept.")
    }
    guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
      throw RecordingOutputError.ioFailure("This interrupted movie cannot be recovered. The original has been kept.")
    }
    let fm = FileManager.default
    let staging = take.temporaryURL.appendingPathExtension("export.ultracam-recovery")
    guard !RecordingOutputManager.pathExists(at: staging) else { throw RecordingOutputError.destinationExists }
    defer { _ = unlink(staging.path) }
    try await exporter.export(to: staging, as: mp4 ? .mp4 : .mov)
    // The staging name has no movie extension, so state the container type,
    // as for the source; otherwise AVFoundation cannot open the export.
    let recoveredAsset = AVURLAsset(url: staging, options: [AVURLAssetOverrideMIMETypeKey: mime])
    let recoveredTracks = try await recoveredAsset.loadTracks(withMediaType: .video)
    let recoveredDuration = try await recoveredAsset.load(.duration)
    guard !recoveredTracks.isEmpty, recoveredDuration.isNumeric, recoveredDuration.seconds > 0 else {
      throw RecordingOutputError.ioFailure("Recovery produced no playable video. The original has been kept.")
    }
    let handle = try FileHandle(forWritingTo: staging)
    try handle.synchronize()
    try handle.close()
    let stem = take.finalURL.deletingPathExtension().lastPathComponent + "_Recovered"
    var destination = folder.appendingPathComponent(stem + "." + ext)
    var counter = 2
    func occupied(_ movie: URL) -> Bool {
      let metadata = RecordingTakeSidecar.url(for: movie)
      return [movie, metadata, metadata.appendingPathExtension("journal")].contains {
        RecordingOutputManager.pathExists(at: $0)
      }
    }
    while occupied(destination) {
      destination = folder.appendingPathComponent(stem + "_\(counter).\(ext)")
      counter += 1
    }
    // Persist the intended movie before publishing it. After an interruption,
    // the same marker detects a completed rename or lets an unpublished take retry.
    try journal.preparePublication(of: staging, to: destination)
    if journal.entry.sidecarOwned == true {
      try RecordingTakeSidecar.copyPairedMetadata(from: RecordingTakeSidecar.url(for: take.finalURL), toMovie: destination)
    }
    do { try fm.moveItem(at: staging, to: destination) }
    catch {
      if journal.entry.sidecarOwned == true {
        try? RecordingTakeSidecar.removePairedMetadata(for: destination)
      }
      throw error
    }
    return destination
  }
}

/// Persist a read/write sandbox bookmark, rather than a path that loses access
/// after restarting the app. Tests opt in with an isolated defaults suite.
final class RecordingFolderStore {
  private let defaults: UserDefaults
  private var unresolvedRecoveryBookmarks: [String: Any] = [:]
  private(set) var recoveryRootWarnings: [String] = []
  init(defaults: UserDefaults = .standard) { self.defaults = defaults }
  private func key(for feedID: String?) -> String {
    feedID.map { "recordingFolderBookmark.feed.\($0)" } ?? "recordingFolderBookmark"
  }
  func saveRecoveryRoots(_ urls: [URL]) throws {
    var bookmarks = unresolvedRecoveryBookmarks
    // A retained root that is offline now keeps the bookmark it was saved with,
    // so one unplugged drive never stops newer take folders from being saved.
    let stored = defaults.dictionary(forKey: "recordingRecoveryRootBookmarks") ?? [:]
    var firstError: Error?
    var seen = Set<String>()
    for url in urls {
      let path = url.standardizedFileURL.path
      guard seen.insert(path).inserted else { continue }
      let access = RecordingDirectoryAccess(url)
      defer { withExtendedLifetime(access) {} }
      do {
        bookmarks[path] = try url.bookmarkData(options: .withSecurityScope,
          includingResourceValuesForKeys: nil, relativeTo: nil)
      } catch {
        if let previous = stored[path] { bookmarks[path] = previous } else if firstError == nil { firstError = error }
      }
      unresolvedRecoveryBookmarks.removeValue(forKey: path)
    }
    defaults.set(bookmarks, forKey: "recordingRecoveryRootBookmarks")
    if let firstError { throw firstError }
  }
  func loadRecoveryRoots() throws -> [URL] {
    let bookmarks = defaults.dictionary(forKey: "recordingRecoveryRootBookmarks") ?? [:]
    unresolvedRecoveryBookmarks = [:]
    recoveryRootWarnings = []
    var roots: [URL] = []
    for path in bookmarks.keys.sorted() {
      do {
        guard let data = bookmarks[path] as? Data else { throw CocoaError(.fileReadCorruptFile) }
        var stale = false
        let root = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
          relativeTo: nil, bookmarkDataIsStale: &stale)
        roots.append(root)
      } catch {
        unresolvedRecoveryBookmarks[path] = bookmarks[path]
        recoveryRootWarnings.append(path)
      }
    }
    return roots
  }
  func save(_ url: URL?, feedID: String? = nil) throws {
    let key = key(for: feedID)
    guard let url else { defaults.removeObject(forKey: key); return }
    let access = RecordingDirectoryAccess(url)
    defer { withExtendedLifetime(access) {} }
    let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    defaults.set(data, forKey: key)
  }
  func load(feedID: String? = nil) throws -> URL? {
    guard let data = defaults.data(forKey: key(for: feedID)) else { return nil }
    var stale = false
    let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
      relativeTo: nil, bookmarkDataIsStale: &stale)
    if stale { try save(url, feedID: feedID) }
    return url
  }
}
