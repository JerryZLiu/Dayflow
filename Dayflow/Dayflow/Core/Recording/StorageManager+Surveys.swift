//
//  StorageManager+Surveys.swift
//  Dayflow
//
//  Local usage facts that decide which in-app surveys someone qualifies for.
//  They're computed on the device and never sent anywhere on their own.
//

import Foundation
import GRDB

struct SurveyActivitySummary {
  /// Start of the earliest timeline card, or nil before the first card.
  let firstCardStart: Date?
  /// Distinct days with at least one timeline card, ever.
  let activeDaysTotal: Int
  /// Distinct days with at least one timeline card in the last 7 days.
  let activeDaysLastWeek: Int
}

extension StorageManager {
  func surveyActivitySummary(now: Date = Date()) -> SurveyActivitySummary {
    let weekAgo = Int(now.addingTimeInterval(-7 * 24 * 60 * 60).timeIntervalSince1970)

    let summary: SurveyActivitySummary? = try? timedRead("surveyActivitySummary") { db in
      let firstStart = try Int.fetchOne(
        db,
        sql:
          "SELECT MIN(start_ts) FROM timeline_cards WHERE is_deleted = 0 AND start_ts IS NOT NULL"
      )
      let totalDays =
        try Int.fetchOne(
          db,
          sql: "SELECT COUNT(DISTINCT day) FROM timeline_cards WHERE is_deleted = 0"
        ) ?? 0
      let lastWeekDays =
        try Int.fetchOne(
          db,
          sql:
            "SELECT COUNT(DISTINCT day) FROM timeline_cards WHERE is_deleted = 0 AND start_ts >= ?",
          arguments: [weekAgo]
        ) ?? 0

      return SurveyActivitySummary(
        firstCardStart: firstStart.map { Date(timeIntervalSince1970: TimeInterval($0)) },
        activeDaysTotal: totalDays,
        activeDaysLastWeek: lastWeekDays
      )
    }

    return summary
      ?? SurveyActivitySummary(firstCardStart: nil, activeDaysTotal: 0, activeDaysLastWeek: 0)
  }
}
