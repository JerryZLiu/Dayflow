import Foundation

/// The deck, its navigation and its badge all use the same pending activities.
struct TimelineReviewQueue {
  let hasEligibleActivities: Bool
  let pendingActivities: [TimelineActivity]
  let ratingSegments: [TimelineReviewRatingSegment]

  static func load(for timelineDate: Date, storage: any StorageManaging = StorageManager.shared)
    -> TimelineReviewQueue
  {
    let day = timelineDate.getDayInfoFor4AMBoundary()
    let cards = storage.fetchTimelineCards(forDay: day.dayString)
    let activities = makeTimelineActivities(from: cards, for: timelineDate)
    return make(from: activities, dayStart: day.startOfDay, dayEnd: day.endOfDay) {
      storage.fetchReviewRatingSegments(overlapping: $0, endTs: $1)
    }
  }

  static func make(
    from activities: [TimelineActivity], dayStart: Date, dayEnd: Date,
    fetchRatings: (Int, Int) -> [TimelineReviewRatingSegment]
  ) -> TimelineReviewQueue {
    let eligible = activities.filter { isEligible(category: $0.category) }
      .sorted { $0.startTime < $1.startTime }
    // A card can run past 4 AM. Its entire interval counts toward review coverage,
    // while the summary still clips historical ratings to the displayed day.
    let start = min(dayStart, eligible.first?.startTime ?? dayStart)
    let end = max(dayEnd, eligible.map(\.endTime).max() ?? dayEnd)
    let ratings = fetchRatings(Int(start.timeIntervalSince1970), Int(end.timeIntervalSince1970))
    return TimelineReviewQueue(
      hasEligibleActivities: !eligible.isEmpty,
      pendingActivities: filterUnreviewedActivities(activities: eligible, ratingSegments: ratings),
      ratingSegments: ratings)
  }

  private static func isEligible(category: String) -> Bool {
    switch category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "idle", "system": return false
    default: return true
    }
  }

  private struct CoverageSegment {
    var start: Int
    var end: Int
  }

  private static func filterUnreviewedActivities(
    activities: [TimelineActivity], ratingSegments: [TimelineReviewRatingSegment]
  ) -> [TimelineActivity] {
    guard ratingSegments.isEmpty == false else { return activities }
    let mergedSegments = mergedCoverageSegments(segments: ratingSegments)
    guard mergedSegments.isEmpty == false else { return activities }

    var unreviewed: [TimelineActivity] = []
    var segmentIndex = 0

    for activity in activities {
      let start = Int(activity.startTime.timeIntervalSince1970)
      let end = Int(activity.endTime.timeIntervalSince1970)
      let duration = max(end - start, 1)
      let covered = overlapSeconds(
        start: start, end: end, segments: mergedSegments, segmentIndex: &segmentIndex)
      let coverageRatio = Double(covered) / Double(duration)
      if coverageRatio < 0.8 {
        unreviewed.append(activity)
      }
    }
    return unreviewed
  }

  private static func mergedCoverageSegments(
    segments: [TimelineReviewRatingSegment]
  ) -> [CoverageSegment] {
    var sorted: [CoverageSegment] = []
    sorted.reserveCapacity(segments.count)

    for segment in segments {
      let start = segment.startTs
      let end = segment.endTs
      if end > start { sorted.append(CoverageSegment(start: start, end: end)) }
    }

    guard sorted.isEmpty == false else { return [] }
    sorted.sort { $0.start < $1.start }

    var merged: [CoverageSegment] = [sorted[0]]
    for segment in sorted.dropFirst() {
      var last = merged[merged.count - 1]
      if segment.start <= last.end {
        last.end = max(last.end, segment.end)
        merged[merged.count - 1] = last
      } else {
        merged.append(segment)
      }
    }
    return merged
  }

  private static func overlapSeconds(
    start: Int, end: Int, segments: [CoverageSegment], segmentIndex: inout Int
  ) -> Int {
    guard end > start else { return 0 }
    while segmentIndex < segments.count, segments[segmentIndex].end <= start {
      segmentIndex += 1
    }
    var covered = 0
    var index = segmentIndex
    while index < segments.count, segments[index].start < end {
      let overlapStart = max(start, segments[index].start)
      let overlapEnd = min(end, segments[index].end)
      if overlapEnd > overlapStart {
        covered += overlapEnd - overlapStart
      }
      if segments[index].end <= end {
        index += 1
      } else {
        break
      }
    }
    return covered
  }
}
