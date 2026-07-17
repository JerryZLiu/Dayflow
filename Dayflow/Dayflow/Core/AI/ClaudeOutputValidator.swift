import Foundation

enum ClaudeOutputValidationError: Error, Equatable, LocalizedError {
  case invalidConfiguration
  case emptyCards
  case invalidTimestamp(String)
  case invalidCardDuration(title: String, seconds: Int)
  case overlappingCards(previous: String, current: String)
  case missingEvidenceCoverage
  case cardCoversEvidenceGap(title: String)
  case outputOutsideEvidence

  var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      return "Card duration limits and evidence tolerance are invalid."
    case .emptyCards:
      return "No activity cards were returned."
    case .invalidTimestamp(let timestamp):
      return "Invalid timestamp: \(timestamp)"
    case .invalidCardDuration(let title, let seconds):
      return "Card '\(title)' has an invalid duration of \(seconds) seconds."
    case .overlappingCards(let previous, let current):
      return "Activity cards overlap: '\(previous)' and '\(current)'."
    case .missingEvidenceCoverage:
      return "Activity cards do not cover all supplied observations and previous cards."
    case .cardCoversEvidenceGap(let title):
      return "Card '\(title)' covers a genuine gap in the source timeline."
    case .outputOutsideEvidence:
      return "Activity cards contain material output outside the supplied source timeline."
    }
  }
}

struct ClaudeOutputValidationOptions {
  let minimumNonFinalCardDurationSeconds: Int
  let maximumCardDurationSeconds: Int
  let evidenceToleranceSeconds: Int
  let calendar: Calendar

  init(
    minimumNonFinalCardDurationSeconds: Int = 10 * 60,
    maximumCardDurationSeconds: Int = 60 * 60,
    evidenceToleranceSeconds: Int = 60,
    calendar: Calendar = .current
  ) {
    self.minimumNonFinalCardDurationSeconds = minimumNonFinalCardDurationSeconds
    self.maximumCardDurationSeconds = maximumCardDurationSeconds
    self.evidenceToleranceSeconds = evidenceToleranceSeconds
    self.calendar = calendar
  }
}

/// Retired strict validator retained for reference and isolated tooling. Production Claude and
/// ChatGPT generation intentionally use the v2.0.0 validators in `AgentCLISupporting` instead.
///
/// Validation never rewrites timestamps, changes semantic fields, drops cards, or fills gaps.
enum ClaudeOutputValidator {
  static func validateActivityCards(
    _ cards: [ActivityCardData],
    existingCards: [ActivityCardData],
    observations: [Observation],
    options: ClaudeOutputValidationOptions = ClaudeOutputValidationOptions()
  ) throws {
    guard !cards.isEmpty else { throw ClaudeOutputValidationError.emptyCards }
    guard options.minimumNonFinalCardDurationSeconds > 0,
      options.maximumCardDurationSeconds >= options.minimumNonFinalCardDurationSeconds,
      options.evidenceToleranceSeconds >= 0
    else {
      throw ClaudeOutputValidationError.invalidConfiguration
    }

    let seeds = try cards.map { card in
      CardSeed(
        card: card,
        start: try parseClockTimestamp(card.startTime),
        end: try parseClockTimestamp(card.endTime)
      )
    }
    let anchor = timelineAnchor(
      observations: observations,
      existingCards: existingCards,
      cardSeeds: seeds
    )
    let parsedCards = seeds.map { seed -> ParsedCard in
      let start = linearTime(
        secondsOfDay: seed.start,
        nearest: anchor,
        calendar: options.calendar
      )
      return ParsedCard(
        card: seed.card,
        start: start,
        end: linearCardEnd(
          start: start,
          startSecondsOfDay: seed.start,
          endSecondsOfDay: seed.end,
          anchor: anchor,
          calendar: options.calendar
        )
      )
    }

    for index in parsedCards.indices {
      let duration = parsedCards[index].end - parsedCards[index].start
      let isFinal = index == parsedCards.count - 1
      if duration <= 0
        || duration > options.maximumCardDurationSeconds
        || (!isFinal && duration < options.minimumNonFinalCardDurationSeconds)
      {
        throw ClaudeOutputValidationError.invalidCardDuration(
          title: parsedCards[index].card.title,
          seconds: duration
        )
      }
      if index > 0, parsedCards[index].start < parsedCards[index - 1].end {
        throw ClaudeOutputValidationError.overlappingCards(
          previous: parsedCards[index - 1].card.title,
          current: parsedCards[index].card.title
        )
      }
    }

    let evidence = mergedEvidenceIntervals(
      observations: observations,
      existingCards: existingCards,
      anchor: anchor,
      calendar: options.calendar
    )
    guard !evidence.isEmpty else { return }

    if evidence.count > 1 {
      for index in 0..<(evidence.count - 1) {
        let gapStart = evidence[index].end
        let gapEnd = evidence[index + 1].start
        guard gapEnd > gapStart else { continue }
        if let card = parsedCards.first(where: { $0.start < gapEnd && $0.end > gapStart }) {
          throw ClaudeOutputValidationError.cardCoversEvidenceGap(title: card.card.title)
        }
      }
    }

    for card in parsedCards {
      guard
        intervalIsCovered(
          card.start..<card.end,
          by: evidence,
          tolerance: options.evidenceToleranceSeconds
        )
      else {
        throw ClaudeOutputValidationError.outputOutsideEvidence
      }
    }

    for evidenceInterval in evidence {
      guard
        intervalIsCovered(
          evidenceInterval.start..<evidenceInterval.end,
          by: parsedCards.map { EvidenceInterval(start: $0.start, end: $0.end) },
          tolerance: options.evidenceToleranceSeconds
        )
      else {
        throw ClaudeOutputValidationError.missingEvidenceCoverage
      }
    }
  }

  /// Exact, order-preserving validation for Claude transcription output.
  ///
  /// Unlike the shared tolerant validator, this does not sort segments or permit boundary drift.
  static func validateTranscriptionSegments(
    _ segments: [SegmentMergeResponse.Segment],
    durationSeconds: Int
  ) -> String? {
    guard durationSeconds > 0 else { return "Transcription duration must be positive." }
    guard !segments.isEmpty else { return "No segments returned." }

    var expectedStart = 0
    for (index, segment) in segments.enumerated() {
      guard let start = strictSegmentTimestamp(segment.start),
        let end = strictSegmentTimestamp(segment.end)
      else {
        return "Segments must use exact HH:MM:SS timestamps: \(segment.start) -> \(segment.end)"
      }
      guard !segment.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "Every segment must include a non-empty factual description."
      }
      guard end > start else {
        return "Segment end time must be after start time: \(segment.start) -> \(segment.end)"
      }

      if index == 0, start != 0 {
        return "First segment must start at 00:00:00 (starts at \(segment.start))."
      }
      if start != expectedStart {
        let relationship = start < expectedStart ? "Overlap" : "Gap"
        return
          "\(relationship) detected between segments: \(formatSegmentTimestamp(expectedStart)) -> \(segment.start)"
      }
      guard end <= durationSeconds else {
        return
          "Segment out of bounds: \(segment.start) -> \(segment.end) (duration \(formatSegmentTimestamp(durationSeconds)))"
      }
      expectedStart = end
    }

    guard expectedStart == durationSeconds else {
      return
        "Last segment must end at \(formatSegmentTimestamp(durationSeconds)) (ends at \(formatSegmentTimestamp(expectedStart)))."
    }
    return nil
  }

  static func validateExactSegments(
    _ segments: [SegmentMergeResponse.Segment],
    duration: TimeInterval
  ) -> String? {
    guard duration.isFinite,
      duration > 0,
      duration.rounded(.towardZero) == duration,
      duration <= TimeInterval(Int.max)
    else {
      return "Transcription duration must be a positive whole number of seconds."
    }
    return validateTranscriptionSegments(segments, durationSeconds: Int(duration))
  }
}

extension ClaudeOutputValidator {
  fileprivate struct CardSeed {
    let card: ActivityCardData
    let start: Int
    let end: Int
  }

  fileprivate struct ParsedCard {
    let card: ActivityCardData
    let start: Int
    let end: Int
  }

  fileprivate enum TimelineAnchor {
    case epoch(Int)
    case clock(Int)
  }

  fileprivate struct EvidenceInterval {
    var start: Int
    var end: Int
  }

  fileprivate static func parseClockTimestamp(_ timestamp: String) throws -> Int {
    let trimmed = timestamp.trimmingCharacters(in: .whitespacesAndNewlines)
    let whitespaceParts = trimmed.split(whereSeparator: { $0.isWhitespace })
    if whitespaceParts.count == 2 {
      let meridiem = whitespaceParts[1].uppercased()
      let parts = whitespaceParts[0].split(separator: ":", omittingEmptySubsequences: false)
      guard meridiem == "AM" || meridiem == "PM",
        parts.count == 2 || parts.count == 3,
        let rawHour = Int(parts[0]),
        let minute = Int(parts[1]),
        (1...12).contains(rawHour),
        (0..<60).contains(minute)
      else {
        throw ClaudeOutputValidationError.invalidTimestamp(timestamp)
      }
      let second: Int
      if parts.count == 3 {
        guard let parsedSecond = Int(parts[2]), (0..<60).contains(parsedSecond) else {
          throw ClaudeOutputValidationError.invalidTimestamp(timestamp)
        }
        second = parsedSecond
      } else {
        second = 0
      }
      return ((rawHour % 12) + (meridiem == "PM" ? 12 : 0)) * 3600 + minute * 60 + second
    }

    let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3,
      let hour = Int(parts[0]),
      let minute = Int(parts[1]),
      let second = Int(parts[2]),
      (0..<24).contains(hour),
      (0..<60).contains(minute),
      (0..<60).contains(second)
    else {
      throw ClaudeOutputValidationError.invalidTimestamp(timestamp)
    }
    return hour * 3600 + minute * 60 + second
  }

  fileprivate static func timelineAnchor(
    observations: [Observation],
    existingCards: [ActivityCardData],
    cardSeeds: [CardSeed]
  ) -> TimelineAnchor {
    if let firstObservationStart = observations.map(\.startTs).min() {
      return .epoch(firstObservationStart)
    }
    if let existingStart = existingCards.first.flatMap({ try? parseClockTimestamp($0.startTime) }) {
      return .clock(existingStart)
    }
    return .clock(cardSeeds[0].start)
  }

  fileprivate static func linearTime(
    secondsOfDay: Int,
    nearest anchor: TimelineAnchor,
    calendar: Calendar
  ) -> Int {
    switch anchor {
    case .clock(let anchorSeconds):
      return [-86_400, 0, 86_400]
        .map { secondsOfDay + $0 }
        .min { abs($0 - anchorSeconds) < abs($1 - anchorSeconds) } ?? secondsOfDay
    case .epoch(let anchorEpoch):
      let anchorDate = Date(timeIntervalSince1970: TimeInterval(anchorEpoch))
      let candidates = (-1...1).flatMap { offset in
        localEpochCandidates(
          secondsOfDay: secondsOfDay,
          dayOffset: offset,
          relativeTo: anchorDate,
          calendar: calendar
        )
      }
      return candidates.min { abs($0 - anchorEpoch) < abs($1 - anchorEpoch) } ?? anchorEpoch
    }
  }

  fileprivate static func linearCardEnd(
    start: Int,
    startSecondsOfDay: Int,
    endSecondsOfDay: Int,
    anchor: TimelineAnchor,
    calendar: Calendar
  ) -> Int {
    switch anchor {
    case .clock:
      if endSecondsOfDay >= startSecondsOfDay {
        return start + endSecondsOfDay - startSecondsOfDay
      }
      if startSecondsOfDay >= 18 * 3600 && endSecondsOfDay <= 6 * 3600 {
        return start + 86_400 - startSecondsOfDay + endSecondsOfDay
      }
      return start - (startSecondsOfDay - endSecondsOfDay)
    case .epoch:
      let isOvernight = startSecondsOfDay >= 18 * 3600 && endSecondsOfDay <= 6 * 3600
      let candidates = localEpochCandidates(
        secondsOfDay: endSecondsOfDay,
        dayOffset: isOvernight ? 1 : 0,
        relativeTo: Date(timeIntervalSince1970: TimeInterval(start)),
        calendar: calendar
      )
      let consistentCandidates: [Int]
      if isOvernight {
        consistentCandidates = candidates.filter { $0 > start }
      } else {
        let forwardCandidates = candidates.filter { $0 > start }
        consistentCandidates = forwardCandidates.isEmpty ? candidates : forwardCandidates
      }
      return consistentCandidates.min { abs($0 - start) < abs($1 - start) }
        ?? candidates.min { abs($0 - start) < abs($1 - start) }
        ?? start
    }
  }

  fileprivate static func localEpochCandidates(
    secondsOfDay: Int,
    dayOffset: Int,
    relativeTo anchorDate: Date,
    calendar: Calendar
  ) -> [Int] {
    guard let targetDay = calendar.date(byAdding: .day, value: dayOffset, to: anchorDate) else {
      return []
    }

    var components = calendar.dateComponents([.era, .year, .month, .day], from: targetDay)
    components.timeZone = calendar.timeZone
    components.hour = secondsOfDay / 3600
    components.minute = (secondsOfDay % 3600) / 60
    components.second = secondsOfDay % 60

    let startOfTargetDay = calendar.startOfDay(for: targetDay)
    guard
      let searchStart = calendar.date(
        byAdding: .second,
        value: -1,
        to: startOfTargetDay
      )
    else {
      return []
    }

    let policies: [Calendar.RepeatedTimePolicy] = [.first, .last]
    let candidates = policies.compactMap { policy -> Int? in
      guard
        let date = calendar.nextDate(
          after: searchStart,
          matching: components,
          matchingPolicy: .strict,
          repeatedTimePolicy: policy,
          direction: .forward
        )
      else {
        return nil
      }
      let resolved = calendar.dateComponents(
        [.era, .year, .month, .day, .hour, .minute, .second],
        from: date
      )
      guard resolved.era == components.era,
        resolved.year == components.year,
        resolved.month == components.month,
        resolved.day == components.day,
        resolved.hour == components.hour,
        resolved.minute == components.minute,
        resolved.second == components.second
      else {
        return nil
      }
      return Int(date.timeIntervalSince1970)
    }
    return Array(Set(candidates)).sorted()
  }

  fileprivate static func mergedEvidenceIntervals(
    observations: [Observation],
    existingCards: [ActivityCardData],
    anchor: TimelineAnchor,
    calendar: Calendar
  ) -> [EvidenceInterval] {
    var intervals = observations.compactMap { observation -> EvidenceInterval? in
      guard observation.endTs > observation.startTs else { return nil }
      return EvidenceInterval(start: observation.startTs, end: observation.endTs)
    }
    for card in existingCards {
      guard let startClock = try? parseClockTimestamp(card.startTime),
        let endClock = try? parseClockTimestamp(card.endTime)
      else { continue }
      let start = linearTime(secondsOfDay: startClock, nearest: anchor, calendar: calendar)
      let end = linearCardEnd(
        start: start,
        startSecondsOfDay: startClock,
        endSecondsOfDay: endClock,
        anchor: anchor,
        calendar: calendar
      )
      if end > start { intervals.append(EvidenceInterval(start: start, end: end)) }
    }

    let sorted = intervals.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
    var merged: [EvidenceInterval] = []
    for interval in sorted {
      guard let last = merged.last else {
        merged.append(interval)
        continue
      }
      if interval.start <= last.end {
        merged[merged.count - 1].end = max(last.end, interval.end)
      } else {
        merged.append(interval)
      }
    }
    return merged
  }

  fileprivate static func intervalIsCovered(
    _ interval: Range<Int>,
    by coverage: [EvidenceInterval],
    tolerance: Int
  ) -> Bool {
    var coveredThrough = interval.lowerBound
    for coveredInterval in coverage
    where coveredInterval.end > coveredThrough
      && coveredInterval.start < interval.upperBound
    {
      if coveredInterval.start > coveredThrough + tolerance { return false }
      coveredThrough = max(coveredThrough, coveredInterval.end)
      if coveredThrough >= interval.upperBound - tolerance { return true }
    }
    return coveredThrough >= interval.upperBound - tolerance
  }

  fileprivate static func strictSegmentTimestamp(_ timestamp: String) -> Int? {
    let bytes = Array(timestamp.utf8)
    guard bytes.count == 8,
      bytes[2] == Character(":").asciiValue,
      bytes[5] == Character(":").asciiValue,
      bytes.enumerated().allSatisfy({ index, byte in
        index == 2 || index == 5
          || (Character("0").asciiValue!...Character("9").asciiValue!)
            .contains(byte)
      })
    else {
      return nil
    }

    guard let hour = Int(timestamp.prefix(2)),
      let minute = Int(timestamp.dropFirst(3).prefix(2)),
      let second = Int(timestamp.suffix(2)),
      (0..<24).contains(hour),
      (0..<60).contains(minute),
      (0..<60).contains(second)
    else {
      return nil
    }
    return hour * 3600 + minute * 60 + second
  }

  fileprivate static func formatSegmentTimestamp(_ seconds: Int) -> String {
    String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
  }
}
