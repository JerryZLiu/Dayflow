import Foundation

struct TimelineDisplaySegment {
  let activity: TimelineActivity
  var start: Date
  var end: Date
}

struct TimelineRecordingProjectionWindow {
  let start: Date
  let end: Date
}

enum TimelineActivityLoader {
  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
  }()

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
    let cards = storageManager.fetchTimelineCardsByTimeRange(
      from: weekRange.weekStart, to: weekRange.weekEnd)
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
    storageManager.screenshotsForBatch(batchId).contains { screenshot in
      FileManager.default.fileExists(atPath: screenshot.filePath)
    }
  }

  static func buildActivities(from cards: [TimelineCard]) -> [TimelineActivity] {
    let calendar = Calendar.current
    var results: [TimelineActivity] = []
    var idCounts: [String: Int] = [:]
    results.reserveCapacity(cards.count)

    for card in cards {
      guard
        let baseDay = DateFormatter.yyyyMMdd.date(from: card.day),
        let parsedStart = timeFormatter.date(from: card.startTimestamp),
        let parsedEnd = timeFormatter.date(from: card.endTimestamp)
      else {
        continue
      }

      let baseDate = calendar.startOfDay(for: baseDay)
      let startComponents = calendar.dateComponents([.hour, .minute], from: parsedStart)
      let endComponents = calendar.dateComponents([.hour, .minute], from: parsedEnd)

      guard
        let startDate = calendar.date(
          bySettingHour: startComponents.hour ?? 0,
          minute: startComponents.minute ?? 0,
          second: 0,
          of: baseDate
        ),
        let endDate = calendar.date(
          bySettingHour: endComponents.hour ?? 0,
          minute: endComponents.minute ?? 0,
          second: 0,
          of: baseDate
        )
      else {
        continue
      }

      var adjustedStartDate = startDate
      var adjustedEndDate = endDate

      if calendar.component(.hour, from: startDate) < 4 {
        adjustedStartDate = calendar.date(byAdding: .day, value: 1, to: startDate) ?? startDate
      }

      if calendar.component(.hour, from: endDate) < 4 {
        adjustedEndDate = calendar.date(byAdding: .day, value: 1, to: endDate) ?? endDate
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

  static func resolveDisplaySegments(from activities: [TimelineActivity])
    -> [TimelineDisplaySegment]
  {
    var segments = activities.map {
      TimelineDisplaySegment(activity: $0, start: $0.startTime, end: $0.endTime)
    }
    guard segments.count > 1 else { return segments }

    segments.sort { $0.start < $1.start }

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
