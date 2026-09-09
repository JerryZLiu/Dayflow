import Foundation
import GRDB

extension StorageManager {
  func fetchDayGoalPlan(forDay day: String) -> DayGoalPlan? {
    fetchDayGoalPlan(whereSQL: "day = ?", arguments: [day], label: "fetchDayGoalPlan")
  }

  func fetchMostRecentDayGoalPlan(beforeOrOn day: String) -> DayGoalPlan? {
    fetchDayGoalPlan(
      whereSQL: "day <= ?",
      arguments: [day],
      orderSQL: "ORDER BY day DESC",
      label: "fetchMostRecentDayGoalPlan"
    )
  }

  /// Number of distinct timeline days with recorded activity, excluding the
  /// given day. Used to hold the daily goal prompt back until a new user has
  /// actually used Dayflow for a few days.
  func countDistinctTimelineDays(excludingDay day: String) -> Int {
    (try? timedRead("countDistinctTimelineDays") { db in
      try Int.fetchOne(
        db,
        sql: """
              SELECT COUNT(DISTINCT day)
              FROM timeline_cards
              WHERE is_deleted = 0 AND day != ?
          """,
        arguments: [day]
      ) ?? 0
    }) ?? 0
  }

  /// How many of the most recent day-goal answers before the given day were
  /// skips, counting back from the newest until the first confirmed plan.
  /// Days with no row (app not opened, so no prompt) don't affect the streak.
  func consecutiveSkippedDayGoalCount(before day: String, limit: Int) -> Int {
    (try? timedRead("consecutiveSkippedDayGoalCount") { db in
      let skipFlags = try Int.fetchAll(
        db,
        sql: """
              SELECT is_skipped
              FROM day_goals
              WHERE day < ?
              ORDER BY day DESC
              LIMIT ?
          """,
        arguments: [day, limit]
      )

      var streak = 0
      for flag in skipFlags {
        guard flag != 0 else { break }
        streak += 1
      }
      return streak
    }) ?? 0
  }

  func saveDayGoalPlan(_ plan: DayGoalPlan) {
    let now = Int(Date().timeIntervalSince1970)
    let createdAt = plan.createdAt > 0 ? plan.createdAt : now

    try? timedWrite("saveDayGoalPlan") { db in
      try db.execute(
        sql: """
              INSERT INTO day_goals(
                  day, focus_target_minutes, distraction_limit_minutes, is_skipped,
                  created_at, updated_at
              )
              VALUES (?, ?, ?, ?, ?, ?)
              ON CONFLICT(day) DO UPDATE SET
                  focus_target_minutes = excluded.focus_target_minutes,
                  distraction_limit_minutes = excluded.distraction_limit_minutes,
                  is_skipped = excluded.is_skipped,
                  updated_at = excluded.updated_at
          """,
        arguments: [
          plan.day,
          plan.focusTargetMinutes,
          plan.distractionLimitMinutes,
          plan.isSkipped ? 1 : 0,
          createdAt,
          now,
        ])

      try db.execute(
        sql: "DELETE FROM day_goal_categories WHERE day = ?",
        arguments: [plan.day]
      )

      try insertGoalCategories(plan.focusCategories, kind: .focus, day: plan.day, db: db)
      try insertGoalCategories(
        plan.distractionCategories, kind: .distraction, day: plan.day, db: db)
    }
  }

  private func fetchDayGoalPlan(
    whereSQL: String,
    arguments: StatementArguments,
    orderSQL: String = "",
    label: String
  ) -> DayGoalPlan? {
    try? timedRead(label) { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
                SELECT day, focus_target_minutes, distraction_limit_minutes, is_skipped,
                       created_at, updated_at
                FROM day_goals
                WHERE \(whereSQL)
                \(orderSQL)
                LIMIT 1
            """,
          arguments: arguments
        )
      else {
        return nil
      }

      let day: String = row["day"]
      let categories = try Row.fetchAll(
        db,
        sql: """
              SELECT kind, category_id, category_name, category_color_hex, sort_order
              FROM day_goal_categories
              WHERE day = ?
              ORDER BY kind, sort_order
          """,
        arguments: [day]
      )

      var focusCategories: [DayGoalCategorySnapshot] = []
      var distractionCategories: [DayGoalCategorySnapshot] = []

      for categoryRow in categories {
        let kindRaw: String = categoryRow["kind"]
        guard let kind = DayGoalCategoryKind(rawValue: kindRaw) else { continue }

        let snapshot = DayGoalCategorySnapshot(
          categoryID: categoryRow["category_id"],
          name: categoryRow["category_name"],
          colorHex: categoryRow["category_color_hex"],
          sortOrder: categoryRow["sort_order"]
        )

        switch kind {
        case .focus:
          focusCategories.append(snapshot)
        case .distraction:
          distractionCategories.append(snapshot)
        }
      }

      let isSkipped: Int = row["is_skipped"]

      return DayGoalPlan(
        day: day,
        focusTargetMinutes: row["focus_target_minutes"],
        distractionLimitMinutes: row["distraction_limit_minutes"],
        focusCategories: focusCategories,
        distractionCategories: distractionCategories,
        isSkipped: isSkipped != 0,
        createdAt: row["created_at"],
        updatedAt: row["updated_at"]
      )
    }
  }

  private func insertGoalCategories(
    _ categories: [DayGoalCategorySnapshot],
    kind: DayGoalCategoryKind,
    day: String,
    db: Database
  ) throws {
    for (index, category) in categories.enumerated() {
      try db.execute(
        sql: """
              INSERT INTO day_goal_categories(
                  day, kind, category_id, category_name, category_color_hex, sort_order
              )
              VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          day,
          kind.rawValue,
          category.categoryID,
          category.name,
          category.colorHex,
          index,
        ])
    }
  }
}
