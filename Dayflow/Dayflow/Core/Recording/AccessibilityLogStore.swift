//
//  AccessibilityLogStore.swift
//  Dayflow
//
//  Writes accessibility events (clicks, typing, screen-text snapshots) to
//  plain JSONL files next to the recordings:
//
//    Application Support/Dayflow/accessibility/2026-10-28/1430.jsonl
//
//  One folder per local day, one file per 10-minute window, one event per
//  line. Files are only ever appended to, so a crash loses at most the line
//  being written. They live outside chunks.sqlite so the frequent writes
//  never compete with screenshot and card writes.
//

import Foundation

/// One line in an accessibility log file. Nil fields are left out of the JSON.
struct AccessibilityLogEvent: Codable {
  let time: Date
  /// What happened: session_start, session_stop, window, click, drag,
  /// context_menu, text, submit, shortcut, escape, snapshot, diff.
  let kind: String
  var app: String?
  var bundleId: String?
  var window: String?
  /// True when the frontmost app is on the user's blocked-apps list; nothing
  /// else about that app is recorded.
  var blocked: Bool?
  /// The element that was clicked, e.g. `button "Send"`.
  var target: String?
  /// The label of the text field that was typed into or submitted.
  var field: String?
  /// What the text field contained.
  var text: String?
  /// The key combination for shortcuts, e.g. `⌘C`.
  var keys: String?
  /// What caused a snapshot or diff, e.g. `click +250ms` or `window`.
  var trigger: String?
  /// A full screen-text snapshot of the focused window.
  var tree: String?
  /// What changed since the last snapshot of the same app.
  var diff: String?
  var snapshotMs: Int?

  /// Reads the lines `AccessibilityLogStore` writes.
  static func decoder() -> JSONDecoder {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let withoutFraction = ISO8601DateFormatter()

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let text = try container.decode(String.self)
      guard let date = withFraction.date(from: text) ?? withoutFraction.date(from: text) else {
        throw DecodingError.dataCorruptedError(
          in: container, debugDescription: "Unreadable time: \(text)")
      }
      return date
    }
    return decoder
  }
}

final class AccessibilityLogStore: @unchecked Sendable {
  static let shared = AccessibilityLogStore()

  let rootURL: URL

  private static let windowSeconds = 10 * 60

  /// Everything below is only touched on `queue`.
  private let queue = DispatchQueue(label: "com.dayflow.accessibility.store", qos: .utility)
  private let encoder: JSONEncoder
  private var handle: FileHandle?
  private var handlePath: String?

  private init() {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
    rootURL = appSupport.appendingPathComponent("Dayflow/accessibility", isDirectory: true)

    let timeFormatter = ISO8601DateFormatter()
    timeFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(timeFormatter.string(from: date))
    }
  }

  func append(_ event: AccessibilityLogEvent) {
    queue.async { [weak self] in
      self?.write(event)
    }
  }

  /// Closes the open file. Called on quit; the next event reopens it.
  func close() {
    queue.sync {
      closeHandle()
    }
  }

  /// Deletes every file whose 10-minute window ended before `cutoff`, then
  /// any day folders left empty.
  func prune(before cutoff: Date) {
    queue.sync {
      let fileManager = FileManager.default
      guard
        let dayFolders = try? fileManager.contentsOfDirectory(
          at: rootURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
      else { return }

      for dayFolder in dayFolders {
        let files =
          (try? fileManager.contentsOfDirectory(
            at: dayFolder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []

        for file in files where file.pathExtension == "jsonl" {
          if file.path == handlePath { continue }
          guard let windowStart = Self.windowStart(dayFolder: dayFolder, file: file) else {
            continue
          }
          let windowEnd = windowStart.addingTimeInterval(TimeInterval(Self.windowSeconds))
          if windowEnd < cutoff {
            try? fileManager.removeItem(at: file)
          }
        }

        let remaining =
          (try? fileManager.contentsOfDirectory(
            at: dayFolder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        if remaining.isEmpty {
          try? fileManager.removeItem(at: dayFolder)
        }
      }
    }
  }

  /// The log files that may hold events from `[start, end)`. File names use
  /// the local time when they were written, which is off after a time zone or
  /// daylight saving change, so files are matched by when they were created
  /// and last written instead. Folders a day either side are checked for the
  /// same reason.
  func logFiles(from start: Date, to end: Date) -> [URL] {
    let fileManager = FileManager.default
    let calendar = Calendar.current
    let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey]
    var urls: [URL] = []
    guard
      var day = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: start)),
      let lastDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))
    else { return [] }
    while day <= lastDay {
      let folder = fileURL(for: day).deletingLastPathComponent()
      let files =
        (try? fileManager.contentsOfDirectory(
          at: folder, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
      for file in files where file.pathExtension == "jsonl" {
        let values = try? file.resourceValues(forKeys: Set(keys))
        let created = values?.creationDate ?? .distantPast
        let written = values?.contentModificationDate ?? .distantFuture
        if created < end && written >= start {
          urls.append(file)
        }
      }
      guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
      day = nextDay
    }
    return urls.sorted { $0.path < $1.path }
  }

  // MARK: - Writing

  private func write(_ event: AccessibilityLogEvent) {
    guard var line = try? encoder.encode(event) else { return }
    line.append(0x0A)  // newline

    let url = fileURL(for: event.time)
    if url.path != handlePath {
      closeHandle()
      openHandle(at: url)
    }

    do {
      try handle?.write(contentsOf: line)
    } catch {
      print("⚠️ [AccessibilityLogStore] Write failed: \(error)")
      closeHandle()
    }
  }

  private func openHandle(at url: URL) {
    let fileManager = FileManager.default
    do {
      try fileManager.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      if !fileManager.fileExists(atPath: url.path) {
        fileManager.createFile(atPath: url.path, contents: nil)
      }
      let newHandle = try FileHandle(forWritingTo: url)
      try newHandle.seekToEnd()
      handle = newHandle
      handlePath = url.path
    } catch {
      print("⚠️ [AccessibilityLogStore] Could not open \(url.path): \(error)")
    }
  }

  private func closeHandle() {
    try? handle?.close()
    handle = nil
    handlePath = nil
  }

  // MARK: - Paths

  /// `accessibility/yyyy-MM-dd/HHmm.jsonl`, with the minutes rounded down to
  /// the 10-minute window, in local time.
  func fileURL(for date: Date) -> URL {
    let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    let windowMinute = (parts.minute ?? 0) / 10 * 10
    let file = String(format: "%02d%02d.jsonl", parts.hour ?? 0, windowMinute)
    return rootURL.appendingPathComponent(day, isDirectory: true).appendingPathComponent(file)
  }

  /// Reads the window's start time back out of its folder and file name.
  private static func windowStart(dayFolder: URL, file: URL) -> Date? {
    let dayParts = dayFolder.lastPathComponent.split(separator: "-").compactMap { Int($0) }
    let time = file.deletingPathExtension().lastPathComponent
    guard dayParts.count == 3, time.count == 4,
      let hour = Int(time.prefix(2)), let minute = Int(time.suffix(2))
    else { return nil }

    var components = DateComponents()
    components.year = dayParts[0]
    components.month = dayParts[1]
    components.day = dayParts[2]
    components.hour = hour
    components.minute = minute
    return Calendar.current.date(from: components)
  }
}
