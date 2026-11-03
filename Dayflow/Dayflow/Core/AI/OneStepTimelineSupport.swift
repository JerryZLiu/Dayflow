import AppKit
import Foundation

/// The frames of one batch written out as files a CLI can read.
struct OneStepTimelineFrames {
  struct Frame {
    let capturedAt: Int
    let url: URL
  }

  let directory: URL
  let frames: [Frame]

  /// The new window: the first frame's minute to one minute after the last frame's minute.
  var windowStart: Int { frames[0].capturedAt - frames[0].capturedAt % 60 }
  var windowEnd: Int {
    let last = frames[frames.count - 1].capturedAt
    return last - last % 60 + 60
  }

  /// True when the frames are about a minute apart and no two share a minute label.
  var isOneFramePerMinute: Bool {
    guard frames.count > 1 else { return true }
    let gaps = zip(frames, frames.dropFirst()).map { $1.capturedAt - $0.capturedAt }.sorted()
    let medianGap = gaps[gaps.count / 2]
    let minutes = Set(frames.map { $0.capturedAt / 60 })
    return (45...90).contains(medianGap) && minutes.count == frames.count
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: directory)
  }

  static func write(
    _ screenshots: [Screenshot], maxHeight: Int, directoryPrefix: String
  ) async throws -> OneStepTimelineFrames {
    try await Task.detached(priority: .utility) {
      let sorted = screenshots.sorted { $0.capturedAt < $1.capturedAt }
      let selected = ClaudeTranscriptionInputBuilder.evenlySpacedIndices(itemCount: sorted.count)
        .map { sorted[$0] }
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(directoryPrefix)-\(UUID().uuidString)", isDirectory: true)
        .resolvingSymlinksInPath()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

      var frames: [OneStepTimelineFrames.Frame] = []
      for (index, screenshot) in selected.enumerated() {
        let url = directory.appendingPathComponent(String(format: "frame_%02d.jpg", index + 1))
        do {
          try screenshot.writeJPEG(to: url, maxHeight: maxHeight, quality: 0.85)
          frames.append(.init(capturedAt: screenshot.capturedAt, url: url))
        } catch {
          print(
            "[OneStepTimeline] Skipping unreadable timeline frame: \(error.localizedDescription)")
        }
      }

      guard !frames.isEmpty else {
        try? FileManager.default.removeItem(at: directory)
        throw NSError(
          domain: "OneStepTimeline", code: -94,
          userInfo: [
            NSLocalizedDescriptionKey: "No screenshots could be loaded for timeline generation."
          ])
      }
      return OneStepTimelineFrames(directory: directory, frames: frames)
    }.value
  }
}

/// The condensed accessibility log for a batch's window, for users who have the accessibility
/// recorder on. It rides along with the screenshots so cards can quote exact text.
enum OneStepTimelineAccessibilityLog {
  /// Nil when there is no log for the window (the recorder is off or wasn't running), and the
  /// prompt is then exactly what it was without one. Reading and condensing can't fail the
  /// batch: a log that can't be read is the same as no log.
  static func load(windowStart: Int, windowEnd: Int, batchId: Int64?) async -> String? {
    await Task.detached(priority: .utility) {
      let startedAt = Date()
      let start = Date(timeIntervalSince1970: TimeInterval(windowStart))
      let end = Date(timeIntervalSince1970: TimeInterval(windowEnd))
      guard let log = AccessibilityLogCondenser.condensedLog(from: start, to: end) else {
        return nil
      }
      if let batchId {
        AccessibilityLogStore.shared.saveCondensedLog(log, batchId: batchId, batchStart: start)
      }
      var properties: [String: Any] = [
        "characters": log.count,
        "condense_ms": Int(Date().timeIntervalSince(startedAt) * 1000),
      ]
      if let batchId { properties["batch_id"] = batchId }
      AnalyticsService.shared.capture("accessibility_log_condensed", properties)
      return log
    }.value
  }
}

enum OneStepTimelineObservations {
  /// Rebuilds per-batch observations from the detail lines the cards carry for the new window,
  /// falling back to one observation per card when no line can be read.
  static func make(
    from cards: [ActivityCardData],
    windowStart: Int,
    windowEnd: Int,
    batchId: Int64?,
    model: String
  ) -> [Observation] {
    func clipped(start: Int, end: Int, text: String) -> Observation? {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      let resolvedEnd = end <= start ? start + 60 : end
      guard !trimmed.isEmpty, start < windowEnd, resolvedEnd > windowStart else { return nil }
      let clippedStart = max(start, windowStart)
      return Observation(
        id: nil,
        batchId: batchId ?? -1,
        startTs: clippedStart,
        endTs: max(min(resolvedEnd, windowEnd), clippedStart + 1),
        observation: trimmed,
        metadata: nil,
        llmModel: model,
        createdAt: Date()
      )
    }

    var observations: [Observation] = []
    for card in cards {
      for line in card.detailedSummary.components(separatedBy: .newlines) {
        guard let detail = parseTimelineDetailLine(line),
          let start = timelineEpoch(forClock: detail.start, nearest: windowStart),
          let end = timelineEpoch(forClock: detail.end, nearest: windowStart),
          let observation = clipped(start: start, end: end, text: detail.text)
        else { continue }
        observations.append(observation)
      }
    }

    if observations.isEmpty {
      for card in cards {
        guard let start = timelineEpoch(forClock: card.startTime, nearest: windowStart),
          let end = timelineEpoch(forClock: card.endTime, nearest: windowStart),
          let observation = clipped(start: start, end: end, text: card.title + ": " + card.summary)
        else { continue }
        observations.append(observation)
      }
    }

    return observations.sorted { ($0.startTs, $0.endTs) < ($1.startTs, $1.endTs) }
  }

  private static let timelineDetailLineRegex = try? NSRegularExpression(
    pattern:
      #"^\s*[-•*]?\s*(\d{1,2}:\d{2}\s*[APap][Mm])\s*[-–—]\s*(\d{1,2}:\d{2}\s*[APap][Mm])\s*:?\s*(.+)$"#
  )

  static func parseTimelineDetailLine(_ line: String) -> (start: String, end: String, text: String)?
  {
    guard let regex = timelineDetailLineRegex,
      let match = regex.firstMatch(
        in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
      let start = Range(match.range(at: 1), in: line),
      let end = Range(match.range(at: 2), in: line),
      let text = Range(match.range(at: 3), in: line)
    else { return nil }
    return (String(line[start]), String(line[end]), String(line[text]))
  }

  /// Resolves an "h:mm AM" label to the epoch second nearest the batch, across midnight if needed.
  static func timelineEpoch(
    forClock clock: String, nearest anchor: Int, calendar: Calendar = .current
  ) -> Int? {
    let compact = clock.uppercased().filter { !$0.isWhitespace }
    guard compact.count >= 5 else { return nil }
    let meridiem = compact.suffix(2)
    let parts = compact.dropLast(2).split(separator: ":")
    guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
      (1...12).contains(hour), (0...59).contains(minute), meridiem == "AM" || meridiem == "PM"
    else { return nil }
    let minutesOfDay = (hour % 12 + (meridiem == "PM" ? 12 : 0)) * 60 + minute

    let anchorDate = Date(timeIntervalSince1970: TimeInterval(anchor))
    let midnight = calendar.startOfDay(for: anchorDate)
    let candidates = [-1, 0, 1].compactMap { dayOffset -> Int? in
      guard let day = calendar.date(byAdding: .day, value: dayOffset, to: midnight),
        let date = calendar.date(byAdding: .minute, value: minutesOfDay, to: day)
      else { return nil }
      return Int(date.timeIntervalSince1970)
    }
    return candidates.min { abs($0 - anchor) < abs($1 - anchor) }
  }
}
