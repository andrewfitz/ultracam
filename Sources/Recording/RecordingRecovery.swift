import AVFoundation
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
  struct Entry: Codable {
    var version = 1
    let temporaryName: String
    let finalName: String
    var recoveredName: String?
    var sidecarOwned: Bool? = nil
  }
  let url: URL
  private let descriptor: Int32
  private(set) var entry: Entry

  static func url(for temporary: URL) -> URL {
    temporary.appendingPathExtension("ultracam-recovery")
  }

  init(temporary: URL, final: URL) throws {
    url = Self.url(for: temporary)
    entry = Entry(temporaryName: temporary.lastPathComponent, finalName: final.lastPathComponent)
    descriptor = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw RecordingOutputError.ioFailure("Cannot create recovery journal.") }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      close(descriptor)
      throw RecordingOutputError.ioFailure("Cannot lock recovery journal.")
    }
    do { try save() }
    catch { close(descriptor); try? FileManager.default.removeItem(at: url); throw error }
  }

  init(opening url: URL) throws {
    self.url = url
    descriptor = open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw RecordingOutputError.unsafePath }
    do {
      guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        throw RecordingOutputError.ioFailure("This recording is still in use.")
      }
      var info = stat()
      guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
        info.st_size > 0, info.st_size < 16_384 else { throw RecordingOutputError.unsafePath }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
      entry = try JSONDecoder().decode(Entry.self, from: handle.readToEnd() ?? Data())
      let finalExtension = URL(fileURLWithPath: entry.finalName).pathExtension
      let validFinalExtension = (try? RecordingOutputConfiguration.validateExtension(finalExtension))
      guard entry.version == 1,
        Self.safeName(entry.temporaryName), Self.safeName(entry.finalName),
        entry.temporaryName.hasPrefix("."), entry.temporaryName.hasSuffix(".partial"),
        validFinalExtension == finalExtension.lowercased(),
        url.lastPathComponent == entry.temporaryName + ".ultracam-recovery",
        entry.temporaryName == "." + String(entry.finalName.dropLast(finalExtension.count + 1)) + ".partial",
        entry.recoveredName.map(Self.safeName) ?? true else { throw RecordingOutputError.unsafePath }
    } catch { close(descriptor); throw error }
  }

  private static func safeName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
      && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
  }

  private func save() throws {
    let data = try JSONEncoder().encode(entry)
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    try handle.seek(toOffset: 0)
    try handle.write(contentsOf: data)
    try handle.truncate(atOffset: UInt64(data.count))
    try handle.synchronize()
  }

  func claimSidecar() throws {
    entry.sidecarOwned = true
    try save()
  }
  func markRecovered(_ url: URL) throws {
    entry.recoveredName = url.lastPathComponent
    try save()
  }
  func remove() { try? FileManager.default.removeItem(at: url) }
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
  /// Only our journals directly inside feed folders are inspected. Foreign
  /// partial files and symlinks are never treated as recoverable recordings.
  static func scan(root: URL) throws -> [InterruptedRecording] {
    scanLock.lock()
    defer { scanLock.unlock() }
    let access = RecordingDirectoryAccess(root)
    defer { withExtendedLifetime(access) {} }
    let fm = FileManager.default
    let folders = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    var result: [InterruptedRecording] = []
    for folder in folders {
      let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
      let files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [])
      for url in files where url.pathExtension == "ultracam-recovery" {
        guard let journal = try? RecordingRecoveryJournal(opening: url) else { continue }
        let source = folder.appendingPathComponent(journal.entry.temporaryName)
        // The journal lock also covers export. Only reclaim its staging file
        // after a crashed exporter has released that lock.
        let staging = source.appendingPathExtension("export.ultracam-recovery")
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
        let final = folder.appendingPathComponent(journal.entry.finalName)
        if let recovered = journal.entry.recoveredName,
          fm.fileExists(atPath: folder.appendingPathComponent(recovered).path) { continue }
        guard !fm.fileExists(atPath: final.path), regularNonempty(source) else { continue }
        result.append(InterruptedRecording(journalURL: url, temporaryURL: source, finalURL: final))
      }
    }
    return result.sorted { $0.title < $1.title }
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
    guard folder.standardizedFileURL.deletingLastPathComponent().path == canonicalRoot.path,
      folder.resolvingSymlinksInPath().path == folder.standardizedFileURL.path else { throw RecordingOutputError.unsafePath }
    let journal = try RecordingRecoveryJournal(opening: take.journalURL)
    guard folder.appendingPathComponent(journal.entry.temporaryName) == take.temporaryURL,
      folder.appendingPathComponent(journal.entry.finalName) == take.finalURL,
      regularNonempty(take.temporaryURL) else { throw RecordingOutputError.unsafePath }
    if let name = journal.entry.recoveredName {
      let recovered = folder.appendingPathComponent(name)
      if regularNonempty(recovered) { return recovered }
    }
    let asset = AVURLAsset(url: take.temporaryURL, options: [AVURLAssetOverrideMIMETypeKey: "video/quicktime"])
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
    defer { try? fm.removeItem(at: staging) }
    try await exporter.export(to: staging, as: .mov)
    // The staging name has no movie extension, so state the container type,
    // as for the source; otherwise AVFoundation cannot open the export.
    let recoveredAsset = AVURLAsset(url: staging, options: [AVURLAssetOverrideMIMETypeKey: "video/quicktime"])
    let recoveredTracks = try await recoveredAsset.loadTracks(withMediaType: .video)
    let recoveredDuration = try await recoveredAsset.load(.duration)
    guard !recoveredTracks.isEmpty, recoveredDuration.isNumeric, recoveredDuration.seconds > 0 else {
      throw RecordingOutputError.ioFailure("Recovery produced no playable video. The original has been kept.")
    }
    let handle = try FileHandle(forWritingTo: staging)
    try handle.synchronize()
    try handle.close()
    let stem = take.finalURL.deletingPathExtension().lastPathComponent + "_Recovered"
    var destination = folder.appendingPathComponent(stem + ".mov")
    var counter = 2
    while fm.fileExists(atPath: destination.path) || fm.fileExists(atPath: RecordingTakeSidecar.url(for: destination).path)
      || fm.fileExists(atPath: RecordingTakeSidecar.url(for: destination).appendingPathExtension("journal").path) {
      destination = folder.appendingPathComponent(stem + "_\(counter).mov")
      counter += 1
    }
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
    try journal.markRecovered(destination)
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
    var seen = Set<String>()
    for url in urls {
      let path = url.standardizedFileURL.path
      guard seen.insert(path).inserted else { continue }
      let access = RecordingDirectoryAccess(url)
      defer { withExtendedLifetime(access) {} }
      bookmarks[path] = try url.bookmarkData(options: .withSecurityScope,
        includingResourceValuesForKeys: nil, relativeTo: nil)
      unresolvedRecoveryBookmarks.removeValue(forKey: path)
    }
    defaults.set(bookmarks, forKey: "recordingRecoveryRootBookmarks")
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
