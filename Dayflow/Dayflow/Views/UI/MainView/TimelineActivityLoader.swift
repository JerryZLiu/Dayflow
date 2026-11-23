import Foundation

struct TimelineDisplaySegment {
  let activity: TimelineActivity
  private(set) var activities: [TimelineActivity]
  var start: Date
  var end: Date

  init(activity: TimelineActivity, start: Date, end: Date) {
    self.activity = activity
    self.activities = [activity]
    self.start = start
    self.end = end
  }

  var failureCount: Int {
    guard activity.title == "Processing failed" else { return 0 }
    return activities.count
  }

  var batchIds: [Int64] {
    var seen = Set<Int64>()
    return activities.compactMap(\.batchId).filter { seen.insert($0).inserted }
  }

  mutating func appendFailure(_ activity: TimelineActivity) {
    activities.append(activity)
    start = min(start, activity.startTime)
    end = max(end, activity.endTime)
  }
}

struct TimelineRecordingProjectionWindow {
  let start: Date
  let end: Date
}

enum TimelineActivityLoader {
  // Stored card titles are always the English sentinel, regardless of UI language.
  private static let failedTitle = "Processing failed"
  private static let failureGroupingGapTolerance: TimeInterval = 60

  static func dayPayload(
    for selectedDate: Date,
    storageManager: StorageManaging = StorageManager.shared,
    now: Date = Date()
  ) -> (dayString: String, timelineDate: Date, activities: [TimelineActivity]) {
    let timelineDate = timelineDisplayDate(from: selectedDate, now: now)
    let dayString = DateFormatter.yyyyMMdd.string(from: timelineDate)
    let cards = storageManager.fetchTimelineCards(forDay: dayString)
    let visibleCards = displayableCards(cards, storageManager: storageManager)
    return (dayString, timelineDate, buildActivities(from: visibleCards))
  }

  static func activities(
    in weekRange: TimelineWeekRange,
    storageManager: StorageManaging = StorageManager.shared
  ) -> [TimelineActivity] {
    // Fetch by stored day so each card lands in the column for the day it was recorded on.
    guard let firstDay = weekRange.days.first?.dayString,
      let lastDay = weekRange.days.last?.dayString
    else { return [] }
    let cards = storageManager.fetchTimelineCards(fromDay: firstDay, throughDay: lastDay)
    return buildActivities(from: displayableCards(cards, storageManager: storageManager))
  }

  static func shouldDisplay(_ card: TimelineCard, storageManager: StorageManaging) -> Bool {
    guard card.title == "Processing failed" else { return true }
    return isRetryableFailedCard(card, storageManager: storageManager)
  }

  static func isRetryableFailedCard(_ card: TimelineCard, storageManager: StorageManaging) -> Bool {
    guard card.title == "Processing failed", let batchId = card.batchId else { return false }
    return hasRetrySourceScreenshots(for: batchId, storageManager: storageManager)
  }

  private static func displayableCards(
    _ cards: [TimelineCard],
    storageManager: StorageManaging
  ) -> [TimelineCard] {
    cards.filter { shouldDisplay($0, storageManager: storageManager) }
  }

  private static func hasRetrySourceScreenshots(
    for batchId: Int64,
    storageManager: StorageManaging
  ) -> Bool {
    storageManager.screenshotsForBatch(batchId).contains(where: \.isAvailable)
  }

  static func buildActivities(from cards: [TimelineCard]) -> [TimelineActivity] {
    let calendar = Calendar.current
    let dayOffsets = displayOffsetsByDay(cards)
    var results: [TimelineActivity] = []
    var idCounts: [String: Int] = [:]
    results.reserveCapacity(cards.count)

    for card in cards {
      guard
        let baseDay = DateFormatter.yyyyMMdd.date(from: card.day),
        let clocks = clockTimes(for: card, dayOffset: dayOffsets[card.day])
      else {
        continue
      }

      let baseDate = calendar.startOfDay(for: baseDay)
      // Times before 4 AM belong to the next calendar date. The date is picked before setting
      // the time, so a 2:30 AM card isn't placed in the hour skipped on spring-forward day.
      let nextDate = calendar.date(byAdding: .day, value: 1, to: baseDate) ?? baseDate
      let startBase = clocks.start.hour < 4 ? nextDate : baseDate
      let endBase = clocks.end.hour < 4 ? nextDate : baseDate

      guard
        let adjustedStartDate = calendar.date(
          bySettingHour: clocks.start.hour,
          minute: clocks.start.minute,
          second: 0,
          of: startBase
        ),
        var adjustedEndDate = calendar.date(
          bySettingHour: clocks.end.hour,
          minute: clocks.end.minute,
          second: 0,
          of: endBase
        )
      else {
        continue
      }

      if adjustedEndDate < adjustedStartDate {
        adjustedEndDate =
          calendar.date(byAdding: .day, value: 1, to: adjustedEndDate) ?? adjustedEndDate
      }

      let baseId = TimelineActivity.stableId(
        recordId: card.recordId,
        batchId: card.batchId,
        startTime: adjustedStartDate,
        endTime: adjustedEndDate,
        title: card.title,
        category: card.category,
        subcategory: card.subcategory
      )

      let seenCount = idCounts[baseId, default: 0]
      idCounts[baseId] = seenCount + 1
      let finalId = seenCount == 0 ? baseId : "\(baseId)-\(seenCount)"

      results.append(
        TimelineActivity(
          id: finalId,
          recordId: card.recordId,
          batchId: card.batchId,
          startTime: adjustedStartDate,
          endTime: adjustedEndDate,
          title: card.title,
          summary: card.summary,
          detailedSummary: card.detailedSummary,
          category: card.category,
          subcategory: card.subcategory,
          distractions: card.distractions,
          videoSummaryURL: card.videoSummaryURL,
          screenshot: nil,
          appSites: card.appSites,
          isBackupGenerated: card.isBackupGenerated
        )
      )
    }

    return results
  }

  /// The clock times a card is drawn at. Cards are drawn in the zone they were recorded in. On a
  /// day recorded in more than one zone, cards more than an hour away from the day's main zone
  /// are drawn in that main zone instead, so travel days don't overlap, as long as that keeps
  /// them on the same day. A one-hour difference is a daylight saving change, which keeps its
  /// own clock times.
  static func clockTimes(for card: TimelineCard, dayOffset: Int?) -> (
    start: (hour: Int, minute: Int), end: (hour: Int, minute: Int)
  )? {
    if let startTs = card.startTs, let endTs = card.endTs, let ownOffset = card.utcOffset,
      let dayOffset, abs(ownOffset - dayOffset) > 3600,
      ClockTime.logicalDay(of: startTs, offset: dayOffset) == card.day
    {
      return (clockTime(at: startTs, offset: dayOffset), clockTime(at: endTs, offset: dayOffset))
    }

    // Otherwise the stored labels, which are the clock times in the zone the card was recorded
    // in, including across a daylight saving change inside the card.
    guard let start = ClockTime.hourAndMinute(of: card.startTimestamp),
      let end = ClockTime.hourAndMinute(of: card.endTimestamp)
    else { return nil }
    return (start, end)
  }

  /// For each day, the UTC offset that covers the most of that day's cards.
  static func displayOffsetsByDay(_ cards: [TimelineCard]) -> [String: Int] {
    var secondsByDayAndOffset: [String: [Int: Int]] = [:]
    for card in cards {
      guard let startTs = card.startTs, let endTs = card.endTs, let offset = card.utcOffset
      else { continue }
      secondsByDayAndOffset[card.day, default: [:]][offset, default: 0] += max(60, endTs - startTs)
    }
    return secondsByDayAndOffset.compactMapValues { seconds in
      seconds.max { lhs, rhs in
        lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value
      }?.key
    }
  }

  /// The hour and minute a clock shows at `timestamp` in a zone `offset` seconds east of UTC.
  private static func clockTime(at timestamp: Int, offset: Int) -> (hour: Int, minute: Int) {
    let secondsOfDay = ((timestamp + offset) % 86_400 + 86_400) % 86_400
    return (secondsOfDay / 3600, secondsOfDay % 3600 / 60)
  }

  static func resolveDisplaySegments(from activities: [TimelineActivity])
    -> [TimelineDisplaySegment]
  {
    let sortedActivities = activities.sorted { lhs, rhs in
      if lhs.startTime == rhs.startTime {
        return lhs.endTime < rhs.endTime
      }
      return lhs.startTime < rhs.startTime
    }

    var segments: [TimelineDisplaySegment] = []
    segments.reserveCapacity(sortedActivities.count)

    for activity in sortedActivities {
      if activity.title == failedTitle,
        let lastIndex = segments.indices.last,
        segments[lastIndex].activity.title == failedTitle,
        // Waiting and failed stretches look and read differently, so they stay apart.
        segments[lastIndex].activity.waitingTitle == activity.waitingTitle,
        activity.startTime.timeIntervalSince(segments[lastIndex].end)
          <= failureGroupingGapTolerance
      {
        segments[lastIndex].appendFailure(activity)
      } else {
        segments.append(
          TimelineDisplaySegment(
            activity: activity,
            start: activity.startTime,
            end: activity.endTime
          ))
      }
    }

    guard segments.count > 1 else { return segments }

    var changed = true
    var passes = 0
    let maxPasses = 8

    while changed && passes < maxPasses {
      changed = false
      passes += 1

      var i = 0
      while i < segments.count {
        var j = i + 1
        while j < segments.count {
          if segments[j].start >= segments[i].end { break }

          let first = segments[i]
          let second = segments[j]
          let overlapStart = max(first.start, second.start)
          let overlapEnd = min(first.end, second.end)

          if overlapEnd > overlapStart {
            let firstDuration = first.end.timeIntervalSince(first.start)
            let secondDuration = second.end.timeIntervalSince(second.start)
            let smallIndex = firstDuration <= secondDuration ? i : j
            let largeIndex = firstDuration <= secondDuration ? j : i

            let smaller = segments[smallIndex]
            var larger = segments[largeIndex]

            if larger.start < smaller.start && smaller.end < larger.end {
              let leftDuration = smaller.start.timeIntervalSince(larger.start)
              let rightDuration = larger.end.timeIntervalSince(smaller.end)
              if rightDuration >= leftDuration {
                larger.start = smaller.end
              } else {
                larger.end = smaller.start
              }
            } else if smaller.start <= larger.start && larger.start < smaller.end {
              larger.start = smaller.end
            } else if smaller.start < larger.end && larger.end <= smaller.end {
              larger.end = smaller.start
            }

            if larger.end <= larger.start {
              segments.remove(at: largeIndex)
              changed = true
              j = i + 1
              continue
            } else if larger.start != segments[largeIndex].start
              || larger.end != segments[largeIndex].end
            {
              segments[largeIndex] = larger
              segments.sort { $0.start < $1.start }
              changed = true
              j = i + 1
              continue
            }
          }

          j += 1
        }
        i += 1
      }
    }

    return segments
  }

  static func recordingProjectionWindow(
    for timelineDate: Date,
    displaySegments: [TimelineDisplaySegment],
    now: Date = Date()
  ) -> TimelineRecordingProjectionWindow? {
    guard timelineIsToday(timelineDate, now: now) else { return nil }

    let dayInfo = timelineDate.getDayInfoFor4AMBoundary()
    let dayStart = dayInfo.startOfDay
    let dayEnd = dayInfo.endOfDay
    let cycleDuration: TimeInterval = 15 * 60
    let hardCap: TimeInterval = 40 * 60

    let centeredStart = now.addingTimeInterval(-(cycleDuration / 2))
    var windowStart = max(dayStart, centeredStart)
    var windowEnd = windowStart.addingTimeInterval(cycleDuration)

    if windowEnd > dayEnd {
      windowEnd = dayEnd
      windowStart = max(dayStart, windowEnd.addingTimeInterval(-cycleDuration))
    }

    windowEnd = min(windowEnd, windowStart.addingTimeInterval(hardCap))

    if windowEnd <= windowStart {
      return nil
    }

    let sortedSegments = displaySegments.sorted { $0.start < $1.start }
    var moved = true
    var iterations = 0
    let maxIterations = max(1, sortedSegments.count + 2)

    while moved {
      moved = false
      let previousStart = windowStart
      let previousEnd = windowEnd

      for segment in sortedSegments {
        let intersects = segment.end > windowStart && segment.start < windowEnd
        if intersects {
          windowStart = segment.end
          windowEnd = windowStart.addingTimeInterval(cycleDuration)

          if windowEnd > dayEnd {
            windowEnd = dayEnd
            windowStart = max(dayStart, windowEnd.addingTimeInterval(-cycleDuration))
          }

          windowEnd = min(windowEnd, windowStart.addingTimeInterval(hardCap))
          moved = true
          break
        }
      }

      if windowStart >= dayEnd {
        return nil
      }

      if moved {
        iterations += 1
        if windowStart == previousStart && windowEnd == previousEnd {
          return nil
        }
        if iterations >= maxIterations {
          return nil
        }
      }
    }

    guard windowEnd > windowStart else { return nil }
    return TimelineRecordingProjectionWindow(start: windowStart, end: windowEnd)
  }
}
