import AppKit
import Foundation

/// Performs the side effects of a `dayflow://export-timeline` deep link: builds the Markdown
/// for the requested range, resolves the destination path, writes the file, emits analytics,
/// and optionally reveals the result in Finder.
///
/// The path resolution is factored into pure static helpers so it can be unit tested without
/// touching the real filesystem.
///
/// Because the `dayflow://` URL scheme is invokable by any local process or by a webpage (and
/// the app is not sandboxed), the caller-supplied destination is treated as untrusted: writes
/// are constrained to the user's standard export folders (Downloads, Documents, Desktop) and
/// `..` traversal is collapsed before that check. See `resolveDestination`.
enum TimelineExportService {
  /// Runs the export described by `request`. Intended to be called off the main actor.
  /// Fails soft: errors are logged and reported to analytics, never thrown.
  static func run(_ request: TimelineExportRequest, now: Date = Date()) {
    let output = TimelineRangeExport.build(
      startDay: request.startDay,
      endDay: request.endDay,
      now: now
    )

    guard
      let destination = resolveDestination(
        rawPath: request.destinationPath,
        startDay: request.startDay,
        endDay: request.endDay
      )
    else {
      print(
        "[DeepLink] export-timeline: refused destination "
          + "\(request.destinationPath ?? "<default>") — outside the allowed export folders "
          + "(Downloads, Documents, Desktop)")
      AnalyticsService.shared.capture(
        "timeline_export_failed", ["source": "deeplink", "error": "destination_not_allowed"])
      return
    }

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
        "start_day": DateFormatter.yyyyMMdd.string(from: request.startDay),
        "end_day": DateFormatter.yyyyMMdd.string(from: request.endDay),
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

  /// The standard, safe export roots: the user's Downloads, Documents, and Desktop folders.
  /// Deep-link exports are constrained to these (and their subfolders) so a hostile
  /// `dayflow://export-timeline?path=...` cannot overwrite sensitive files (dotfiles,
  /// `~/Library`, LaunchAgents) on this non-sandboxed app.
  static func allowedExportRoots(fileManager: FileManager = .default) -> [URL] {
    let searchPaths: [FileManager.SearchPathDirectory] = [
      .downloadsDirectory, .documentDirectory, .desktopDirectory,
    ]
    return searchPaths.compactMap {
      fileManager.urls(for: $0, in: .userDomainMask).first?.standardizedFileURL
    }
  }

  /// Resolves the final file URL for the export, or `nil` when the request targets a location
  /// outside `allowedExportRoots`.
  ///
  /// - `rawPath == nil`/empty → `<downloads>/<derived name>`.
  /// - `rawPath` is an existing directory (or ends with a path separator) → `<dir>/<derived name>`.
  /// - otherwise `rawPath` is the target file; a missing extension gets `.md` appended.
  ///
  /// A leading `~` is expanded and `..` is collapsed (the URL is standardized) before the
  /// containment check, so traversal cannot escape the allowed roots. `fileManager` is
  /// injectable so tests can stub the export folders and the directory-existence check.
  static func resolveDestination(
    rawPath: String?,
    startDay: Date,
    endDay: Date,
    fileManager: FileManager = .default
  ) -> URL? {
    let fileName = TimelineRangeExport.defaultFileName(startDay: startDay, endDay: endDay)

    let candidate: URL
    if let rawPath, !rawPath.isEmpty {
      let expanded = (rawPath as NSString).expandingTildeInPath
      let looksLikeDirectory =
        rawPath.hasSuffix("/") || isExistingDirectory(expanded, fileManager: fileManager)
      if looksLikeDirectory {
        candidate = URL(fileURLWithPath: expanded, isDirectory: true)
          .appendingPathComponent(fileName)
      } else {
        var fileURL = URL(fileURLWithPath: expanded)
        if fileURL.pathExtension.isEmpty {
          fileURL.appendPathExtension("md")
        }
        candidate = fileURL
      }
    } else {
      candidate = downloadsDirectory(fileManager: fileManager).appendingPathComponent(fileName)
    }

    let standardized = candidate.standardizedFileURL
    guard isWithinAllowedRoots(standardized, fileManager: fileManager) else { return nil }
    return standardized
  }

  // MARK: - Private

  private static func isWithinAllowedRoots(_ url: URL, fileManager: FileManager) -> Bool {
    let directoryPath = url.deletingLastPathComponent().standardizedFileURL.path
    return allowedExportRoots(fileManager: fileManager).contains { root in
      directoryPath == root.path || directoryPath.hasPrefix(root.path + "/")
    }
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
