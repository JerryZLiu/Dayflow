import AVFoundation
import AppKit
import ImageIO
import QuartzCore
import SwiftUI

// MARK: - Time Optimizations

/// O(1) Cache for display times to prevent severe UI thread stutter when formatting strings rapidly.
@MainActor
final class TimelineReviewTimeCache {
  static let shared = TimelineReviewTimeCache()
  private var cache: [Int: String] = [:]

  private let formatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "h:mm a"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()

  func string(from date: Date) -> String {
    let minute = Int(date.timeIntervalSince1970) / 60
    if let str = cache[minute] {
      return str
    }
    // Prevent unbounded memory growth over long app sessions
    if cache.count > 500 {
      cache.removeAll(keepingCapacity: true)
    }
    let str = formatter.string(from: date)
    cache[minute] = str
    return str
  }
}

let cachedReviewTimeFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "h:mm a"
  formatter.locale = Locale(identifier: "en_US_POSIX")
  return formatter
}()

// MARK: - Enums

enum TimelineReviewRating: String, CaseIterable, Identifiable {
  case distracted
  case neutral
  case focused

  var id: String { rawValue }

  var title: String {
    switch self {
    case .distracted: return "Distracted"
    case .neutral: return "Neutral"
    case .focused: return "Focused"
    }
  }

  var overlayColor: Color {
    switch self {
    case .distracted: return Color(hex: "975D57").opacity(0.6)
    case .neutral: return Color(hex: "8C8379").opacity(0.55)
    case .focused: return Color(hex: "43765E").opacity(0.6)
    }
  }

  var overlayTextColor: Color {
    switch self {
    case .distracted: return Color(hex: "F9D8D4")
    case .neutral: return Color(hex: "F4F0ED")
    case .focused: return Color(hex: "D9F7E4")
    }
  }

  var barGradient: LinearGradient {
    switch self {
    case .distracted:
      return LinearGradient(
        colors: [Color(hex: "FFBDB1"), Color(hex: "FF8772")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    case .neutral:
      return LinearGradient(
        colors: [Color(hex: "FFFEFE"), Color(hex: "EAE0DB")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    case .focused:
      return LinearGradient(
        colors: [Color(hex: "92F1E3"), Color(hex: "42D0BB")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    }
  }

  var barStroke: Color {
    switch self {
    case .distracted: return Color(hex: "FF8772")
    case .neutral: return Color(hex: "EAE0DB")
    case .focused: return Color(hex: "42D0BB")
    }
  }

  var labelColor: Color { Color(hex: "707070") }

  var iconTint: Color {
    switch self {
    case .distracted: return Color(hex: "FF7B67")
    case .neutral: return Color(hex: "C8C8C8")
    case .focused: return Color(hex: "47D2BD")
    }
  }

  var swipeOffset: CGSize {
    switch self {
    case .distracted: return CGSize(width: -560, height: 40)
    case .neutral: return CGSize(width: 0, height: -560)
    case .focused: return CGSize(width: 560, height: 40)
    }
  }

  var swipeRotation: Double {
    switch self {
    case .distracted: return -14
    case .neutral: return 0
    case .focused: return 14
    }
  }
}

enum TimelineReviewInput: String {
  case drag
  case trackpad
  case keyboard
  case button
}

struct IndexedActivity: Identifiable {
  let id: String
  let index: Int
  let activity: TimelineActivity
}

struct TimelineReviewSummary {
  let durationByRating: [TimelineReviewRating: TimeInterval]
  var totalDuration: TimeInterval { durationByRating.values.reduce(0, +) }
  var nonZeroRatings: [TimelineReviewRating] {
    TimelineReviewRating.allCases.filter { (durationByRating[$0, default: 0]) > 0 }
  }

  func ratio(for rating: TimelineReviewRating) -> CGFloat {
    let total = totalDuration
    guard total > 0 else { return 0 }
    return CGFloat(durationByRating[rating, default: 0] / total)
  }
}

func makeTimelineActivities(from cards: [TimelineCard], for date: Date)
  -> [TimelineActivity]
{
  let calendar = Calendar.current
  let baseDate = calendar.startOfDay(for: date)

  var results: [TimelineActivity] = []
  var idCounts: [String: Int] = [:]
  results.reserveCapacity(cards.count)

  let timeFormatter = DateFormatter()
  timeFormatter.dateFormat = "h:mm a"
  timeFormatter.locale = Locale(identifier: "en_US_POSIX")

  for card in cards {
    guard let startDate = timeFormatter.date(from: card.startTimestamp),
      let endDate = timeFormatter.date(from: card.endTimestamp)
    else { continue }

    let startComponents = calendar.dateComponents([.hour, .minute], from: startDate)
    let endComponents = calendar.dateComponents([.hour, .minute], from: endDate)

    guard
      let finalStartDate = calendar.date(
        bySettingHour: startComponents.hour ?? 0, minute: startComponents.minute ?? 0, second: 0,
        of: baseDate),
      let finalEndDate = calendar.date(
        bySettingHour: endComponents.hour ?? 0, minute: endComponents.minute ?? 0, second: 0,
        of: baseDate)
    else { continue }

    var adjustedStartDate = finalStartDate
    var adjustedEndDate = finalEndDate

    if calendar.component(.hour, from: finalStartDate) < 4 {
      adjustedStartDate =
        calendar.date(byAdding: .day, value: 1, to: finalStartDate) ?? finalStartDate
    }
    if calendar.component(.hour, from: finalEndDate) < 4 {
      adjustedEndDate = calendar.date(byAdding: .day, value: 1, to: finalEndDate) ?? finalEndDate
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
      ))
  }

  return results
}
