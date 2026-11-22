import AppKit
import CoreGraphics
import Foundation

/// Preferences belong to the triggering application, even when several apps share a camera.
struct AppRecordingProfile: Codable, Equatable, Sendable {
  static let defaultPattern = "{date} {time} {session} - Ultracam ({camera})"
  static let defaultVideoMbps = 10
  var videoMbps = Self.defaultVideoMbps
  var pattern = defaultPattern
  var folderBookmark: Data?
  var folderPath: String?

  var bitrate: Int { min(50, max(1, videoMbps)) * 1_000_000 }

  mutating func chooseFolder(_ url: URL?) throws {
    let access = url.map(RecordingDirectoryAccess.init)
    defer { withExtendedLifetime(access) {} }
    folderBookmark = try url?.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    folderPath = url?.path
  }

  func folder() throws -> URL? {
    guard let folderBookmark else { return nil }
    var stale = false
    return try URL(resolvingBookmarkData: folderBookmark, options: [.withSecurityScope, .withoutUI],
      relativeTo: nil, bookmarkDataIsStale: &stale)
  }
}

struct AppRecordingTake: Equatable, Sendable {
  let appID: String
  let appName: String
  let profile: AppRecordingProfile
  var started = Date()

  /// Redact before chopping long names or replacing punctuation, including email in templates
  /// and camera labels. Limit UTF-8 bytes to leave room for recovery and metadata suffixes.
  static func clean(_ value: String, bytes: Int = 100) -> String {
    let stripped = value.replacingOccurrences(of: #"(?i)(?:mailto:)?[^\s<>()\[\],;]*[@＠][^\s<>()\[\],;]*"#,
      with: "", options: .regularExpression)
      .replacingOccurrences(of: #"[<(\[]\s*[>)\]]"#, with: "", options: .regularExpression)
    let safe = stripped.components(separatedBy: CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:")))
      .joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    var result = ""
    var length = 0
    for c in safe {
      length += String(c).utf8.count
      if length > bytes { break }
      result.append(c)
    }
    return result.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".-–— ")))
  }

  func filename(camera: String, session: String?, timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    let day = formatter.string(from: started)
    formatter.dateFormat = "HH.mm.ss"
    let time = formatter.string(from: started)
    let app = Self.clean(appName)
    let title = Self.clean(session ?? "")
    let cameraLabel = Self.clean(camera, bytes: 48)
    let parts = ["{date}": day, "{time}": time, "{camera}": cameraLabel.isEmpty ? "Camera" : cameraLabel,
      "{app}": app, "{session}": title.isEmpty ? (appID == "us.zoom.xos" ? "Zoom Meeting" : app) : title]
    let template = profile.pattern.isEmpty ? AppRecordingProfile.defaultPattern : profile.pattern
    // Replace tokens in the template only. Text supplied by Zoom is never parsed as a token.
    var stem = ""
    var rest = template.prefix(512)
    while !rest.isEmpty {
      if let key = parts.keys.first(where: { rest.hasPrefix($0) }) {
        stem += parts[key]!
        rest = rest.dropFirst(key.count)
      } else { stem.append(rest.removeFirst()) }
    }
    let name = Self.clean(stem, bytes: 195)
    return name.isEmpty ? "\(day) \(time) Ultracam" : name
  }
}

/// Window metadata is available to sandboxed apps with Screen Recording permission.
/// The recording worker reads titles only; it never captures the screen or opens Zoom.
enum ZoomSessionTitle {
  static func current() -> String? {
    guard CGPreflightScreenCaptureAccess() else { return nil }
    let meetings = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "us.zoom.ZoomMeeting").map(\.processIdentifier))
    let zoom = meetings.union(NSRunningApplication.runningApplications(withBundleIdentifier: "us.zoom.xos").map(\.processIdentifier))
    guard !zoom.isEmpty, let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] else { return nil }
    var candidates: [(title: String, meetingProcess: Bool)] = []
    for w in windows {
      guard let pid = w[kCGWindowOwnerPID as String] as? Int32, zoom.contains(pid),
        (w[kCGWindowLayer as String] as? Int) == 0, let title = w[kCGWindowName as String] as? String else { continue }
      candidates.append((title, meetings.contains(pid)))
    }
    return topic(in: candidates)
  }

  static func topic(in windows: [(title: String, meetingProcess: Bool)]) -> String? {
    var topics = Set<String>()
    var bareTitles = Set<String>()
    let generic = ["zoom", "zoom meeting", "zoom workplace", "settings", "video preview",
      "participants", "chat", "meeting", "meeting controls", "zoom webinar", "waiting room",
      "share screen", "screen sharing", "audio settings", "video settings", "zoom chat", "closed caption",
      "breakout rooms", "meeting chat", "reactions", "whiteboard", "more", "interpretation"]
    for window in windows {
      var title = window.title
      var labelled = false
      for separator in [" - ", " – ", " — ", " | ", ": "] {
        for marker in ["Zoom Meeting", "Zoom Webinar"] {
          if title.hasPrefix(marker + separator) { title.removeFirst(marker.count + separator.count); labelled = true }
          if title.hasSuffix(separator + marker) { title.removeLast(marker.count + separator.count); labelled = true }
        }
      }
      let cleaned = AppRecordingTake.clean(title)
      guard !cleaned.isEmpty, !generic.contains(cleaned.lowercased()) else { continue }
      if labelled { topics.insert(cleaned) }
      else if window.meetingProcess { bareTitles.insert(cleaned) }
    }
    if topics.count == 1 { return topics.first }
    return topics.isEmpty && bareTitles.count == 1 ? bareTitles.first : nil
  }
}
