import AppKit
import Foundation

/// Performs the side effects of a `dayflow://export-timeline` deep link: builds the Markdown
/// for the requested range, resolves the destination path, writes the file, emits analytics,
/// and optionally reveals the result in Finder.
///
/// The path/name resolution is factored into pure static helpers so it can be unit tested
/// without touching the real filesystem.
enum TimelineExportService {
  /// Runs the export described by `request`. Intended to be called off the main actor
  /// (the deep-link router dispatches it on a detached task). Fails soft: errors are logged
  /// and reported to analytics, never thrown.
  static func run(_ request: TimelineExportRequest, now: Date = Date()) {
    let output = TimelineRangeExport.build(
      startDay: request.startDay,
      endDay: request.endDay,
      now: now
    )

    let destination = resolveDestination(
      rawPath: request.destinationPath,
      startDay: request.startDay,
      endDay: request.endDay
    )

    do {
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try output.markdown.write(to: destination, atomically: true, encoding: .utf8)
    } catch {
      print("[DeepLink] export-timeline: write failed: \(error.localizedDescription)")
      AnalyticsService.shared.capture(
        "timeline_export_failed",
        ["source": "deeplink", "error": error.localizedDescription])
      return
    }

    print(
      "[DeepLink] export-timeline: wrote \(output.activityCount) "
        + "activit\(output.activityCount == 1 ? "y" : "ies") across "
        + "\(output.dayCount) day\(output.dayCount == 1 ? "" : "s") to \(destination.path)")

    AnalyticsService.shared.capture(
      "timeline_exported",
      [
        "start_day": dayString(request.startDay),
        "end_day": dayString(request.endDay),
        "day_count": output.dayCount,
        "activity_count": output.activityCount,
        "format": "markdown",
        "file_extension": destination.pathExtension.lowercased(),
        "source": "deeplink",
      ])

    if request.reveal {
      let revealURL = destination
      Task { @MainActor in
        NSWorkspace.shared.activateFileViewerSelecting([revealURL])
      }
    }
  }

  // MARK: - Pure helpers (unit tested)

  /// Resolves the final file URL for the export.
  ///
  /// - `rawPath == nil`/empty → `<downloads>/<derived name>`.
  /// - `rawPath` is an existing directory (or ends with a path separator) → `<dir>/<derived name>`.
  /// - otherwise `rawPath` is the target file; a missing extension gets `.md` appended.
  ///
  /// A leading `~` is expanded. `fileManager` is injectable so tests can stub the home/Downloads
  /// directory and the directory-existence check.
  static func resolveDestination(
    rawPath: String?,
    startDay: Date,
    endDay: Date,
    fileManager: FileManager = .default
  ) -> URL {
    let fileName = defaultFileName(startDay: startDay, endDay: endDay)

    guard let rawPath, !rawPath.isEmpty else {
      return downloadsDirectory(fileManager: fileManager).appendingPathComponent(fileName)
    }

    let expanded = (rawPath as NSString).expandingTildeInPath
    let looksLikeDirectory =
      rawPath.hasSuffix("/") || isExistingDirectory(expanded, fileManager: fileManager)

    if looksLikeDirectory {
      return URL(fileURLWithPath: expanded, isDirectory: true).appendingPathComponent(fileName)
    }

    var fileURL = URL(fileURLWithPath: expanded)
    if fileURL.pathExtension.isEmpty {
      fileURL.appendPathExtension("md")
    }
    return fileURL
  }

  /// The default file name, mirroring the Settings UI export naming.
  static func defaultFileName(startDay: Date, endDay: Date) -> String {
    let start = dayString(startDay)
    let end = dayString(endDay)
    if start == end {
      return "Dayflow timeline \(start).md"
    }
    return "Dayflow timeline \(start) to \(end).md"
  }

  // MARK: - Private

  private static func dayString(_ date: Date) -> String {
    DateFormatter.yyyyMMdd.string(from: date)
  }

  private static func downloadsDirectory(fileManager: FileManager) -> URL {
    if let url = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first {
      return url
    }
    return fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
  }

  private static func isExistingDirectory(_ path: String, fileManager: FileManager) -> Bool {
    var isDirectory: ObjCBool = false
    let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
    return exists && isDirectory.boolValue
  }
}
