import Foundation
import GRDB
import Sentry

extension StorageManager {
  func saveTimelineCardShell(batchId: Int64, card: TimelineCardShell) -> Int64? {
    let encoder = JSONEncoder()
    var lastId: Int64? = nil

    // Get the batch's actual start timestamp to use as the base date
    guard let batchStartTs = getBatchStartTimestamp(batchId: batchId) else {
      return nil
    }
    let baseDate = Date(timeIntervalSince1970: TimeInterval(batchStartTs))

    let timeFormatter = DateFormatter()
    timeFormatter.dateFormat = "h:mm a"
    timeFormatter.locale = Locale(identifier: "en_US_POSIX")

    guard let startTime = timeFormatter.date(from: card.startTimestamp),
      let endTime = timeFormatter.date(from: card.endTimestamp)
    else {
      return nil
    }

    let calendar = Calendar.current

    let startComponents = calendar.dateComponents([.hour, .minute], from: startTime)
    guard let startHour = startComponents.hour, let startMinute = startComponents.minute else {
      return nil
    }

    var startDate =
      calendar.date(bySettingHour: startHour, minute: startMinute, second: 0, of: baseDate)
      ?? baseDate

    // If the parsed time is between midnight and 4 AM, and it's earlier than baseDate,
    // disambiguate whether it's same day (before batch) or next day (after midnight crossing)
    if startHour < 4 && startDate < baseDate {
      let nextDayStartDate = calendar.date(byAdding: .day, value: 1, to: startDate) ?? startDate

      // Pick whichever is closer to batch start time
      let sameDayDistance = abs(startDate.timeIntervalSince(baseDate))
      let nextDayDistance = abs(nextDayStartDate.timeIntervalSince(baseDate))

      if nextDayDistance < sameDayDistance {
        // Next day is closer - legitimate midnight crossing
        startDate = nextDayStartDate
      }
      // Otherwise keep same day (LLM provided time before batch started)
    }

    let startTs = Int(startDate.timeIntervalSince1970)

    let endComponents = calendar.dateComponents([.hour, .minute], from: endTime)
    guard let endHour = endComponents.hour, let endMinute = endComponents.minute else { return nil }

    var endDate =
      calendar.date(bySettingHour: endHour, minute: endMinute, second: 0, of: baseDate) ?? baseDate

    // Disambiguate end time day using same logic as start time
    if endHour < 4 && endDate < baseDate {
      let nextDayEndDate = calendar.date(byAdding: .day, value: 1, to: endDate) ?? endDate

      let sameDayDistance = abs(endDate.timeIntervalSince(baseDate))
      let nextDayDistance = abs(nextDayEndDate.timeIntervalSince(baseDate))

      if nextDayDistance < sameDayDistance {
        endDate = nextDayEndDate
      }
    }

    // Handle midnight crossing: if end time is before start time, it must be the next day
    if endDate < startDate {
      endDate = calendar.date(byAdding: .day, value: 1, to: endDate) ?? endDate
    }

    let endTs = Int(endDate.timeIntervalSince1970)

    try? timedWrite("saveTimelineCardShell") {
      db in
      // Encode metadata as an object for forward-compatibility
      let meta = TimelineMetadata(
        distractions: card.distractions,
        appSites: card.appSites,
        isBackupGenerated: card.isBackupGenerated,
        idle: card.idleMetadata
      )
      let metadataString: String? = (try? encoder.encode(meta)).flatMap {
        String(data: $0, encoding: .utf8)
      }

      // Calculate the day string using 4 AM boundary rules
      let (dayString, _, _) = startDate.getDayInfoFor4AMBoundary()

      try db.execute(
        sql: """
              INSERT INTO timeline_cards(
                  batch_id, start, end, start_ts, end_ts, day, title,
                  summary, category, subcategory, detailed_summary, metadata
                  -- video_summary_url is omitted here
              )
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          batchId, card.startTimestamp, card.endTimestamp, startTs, endTs, dayString, card.title,
          card.summary, card.category, card.subcategory, card.detailedSummary, metadataString,
        ])
      lastId = db.lastInsertedRowID
    }
    return lastId
  }

  func updateTimelineCardVideoURL(cardId: Int64, videoSummaryURL: String) {
    try? timedWrite("updateTimelineCardVideoURL") {
      db in
      try db.execute(
        sql: """
              UPDATE timeline_cards
              SET video_summary_url = ?
              WHERE id = ?
          """, arguments: [videoSummaryURL, cardId])
    }
  }

  func deleteTimelineCard(recordId: Int64) -> String? {
    var videoPath: String? = nil

    try? timedWrite("deleteTimelineCard(recordId:\(recordId))") { db in
      guard
        let cardRow = try Row.fetchOne(
          db,
          sql: """
                SELECT video_summary_url, start_ts, end_ts, batch_id
                FROM timeline_cards
                WHERE id = ?
                  AND is_deleted = 0
            """,
          arguments: [recordId]
        )
      else {
        return
      }

      videoPath = cardRow["video_summary_url"]

      let startTs: Int = cardRow["start_ts"] ?? 0
      let endTs: Int = cardRow["end_ts"] ?? 0
      let batchId: Int64? = cardRow["batch_id"]

      try db.execute(
        sql: """
              UPDATE timeline_cards
              SET is_deleted = 1
              WHERE id = ?
                AND is_deleted = 0
          """,
        arguments: [recordId]
      )

      guard endTs > startTs else { return }

      if let batchId {
        try db.execute(
          sql: """
                DELETE FROM observations
                WHERE batch_id = ?
                  AND ((start_ts < ? AND end_ts > ?)
                    OR (start_ts >= ? AND start_ts < ?))
            """,
          arguments: [batchId, endTs, startTs, startTs, endTs]
        )
      } else {
        try db.execute(
          sql: """
                DELETE FROM observations
                WHERE (start_ts < ? AND end_ts > ?)
                   OR (start_ts >= ? AND start_ts < ?)
            """,
          arguments: [endTs, startTs, startTs, endTs]
        )
      }
    }

    return videoPath
  }

  func updateTimelineCardCategory(cardId: Int64, category: String) {
    let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return }

    try? timedWrite("updateTimelineCardCategory") { db in
      try db.execute(
        sql: """
              UPDATE timeline_cards
              SET category = ?
              WHERE id = ?
          """, arguments: [trimmed, cardId])
    }
  }

  // MARK: - Onboarding Card

  /// Creates a dummy "Installed Dayflow!" card when onboarding completes.
  /// This gives users an immediate example of what cards look like.
  func createOnboardingCard() {
    let now = Date()
    let startTime = now.addingTimeInterval(-13 * 60)  // 13 minute card

    // Format times as "h:mm a" (e.g., "2:30 PM")
    let timeFormatter = DateFormatter()
    timeFormatter.dateFormat = "h:mm a"
    timeFormatter.locale = Locale(identifier: "en_US_POSIX")

    let startTimeString = timeFormatter.string(from: startTime)
    let endTimeString = timeFormatter.string(from: now)

    let startTs = Int(startTime.timeIntervalSince1970)
    let endTs = Int(now.timeIntervalSince1970)

    // Calculate day using 4AM boundary
    let (dayString, _, _) = startTime.getDayInfoFor4AMBoundary()

    // Get the first non-idle category, fallback to "Work"
    let categories = CategoryPersistence.loadPersistedCategories()
    let category = categories.first(where: { !$0.isIdle })?.name ?? "Work"

    // Build summary based on selected LLM provider
    let summary = buildOnboardingSummary()

    // Build metadata with appSites
    let encoder = JSONEncoder()
    let meta = TimelineMetadata(
      distractions: nil,
      appSites: AppSites(primary: "dayflow.so", secondary: nil),
      isBackupGenerated: nil,
      idle: nil
    )
    let metadataString: String? = (try? encoder.encode(meta)).flatMap {
      String(data: $0, encoding: .utf8)
    }

    try? timedWrite("createOnboardingCard") { db in
      try db.execute(
        sql: """
              INSERT INTO timeline_cards(
                  batch_id, start, end, start_ts, end_ts, day, title,
                  summary, category, subcategory, detailed_summary, metadata
              )
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          nil,  // batch_id is NULL for onboarding card
          startTimeString,
          endTimeString,
          startTs,
          endTs,
          dayString,
          "Installed Dayflow!",
          summary,
          category,
          "Setup",
          "",  // detailed_summary - empty string (not NULL, as GRDB decode expects non-optional)
          metadataString,
        ])
    }
  }

  func buildOnboardingSummary() -> String {
    let selectedProvider = UserDefaults.standard.string(forKey: "selectedLLMProvider") ?? "gemini"

    switch selectedProvider {
    case "gemini":
      return
        "You successfully installed Dayflow and configured it with Gemini AI. Come back in 30 minutes to see your first real activity card! ✨ (This is a sample card, so you can see what your timeline will look like.)"

    case "chatgpt_claude":
      // Check which CLI tool they picked
      let cliTool = UserDefaults.standard.string(forKey: "chatCLIPreferredTool") ?? "claude"
      if cliTool == "codex" {
        return
          "You successfully installed Dayflow with ChatGPT. Come back in 30 minutes to see your first real activity card! ✨ (This is a sample card, so you can see what your timeline will look like.)"
      } else {
        return
          "You successfully installed Dayflow with Claude. Come back in 30 minutes to see your first real activity card! ✨ (This is a sample card, so you can see what your timeline will look like.)"
      }

    case "ollama":
      // Check which local engine they picked
      let localEngine = UserDefaults.standard.string(forKey: "llmLocalEngine") ?? "ollama"
      if localEngine == "lmstudio" {
        return
          "You successfully installed Dayflow with LM Studio — your data stays 100% on your device. Come back in 30 minutes to see your first real activity card! ✨ (This is a sample card, so you can see what your timeline will look like.)"
      } else {
        return
          "You successfully installed Dayflow with Ollama — your data stays 100% on your device. Come back in 30 minutes to see your first real activity card! ✨ (This is a sample card, so you can see what your timeline will look like.)"
      }

    default:
      return
        "You successfully installed Dayflow. Come back in 30 minutes to see your first real activity card! ✨ (This is a sample card, so you can see what your timeline will look like.)"
    }
  }

  func fetchTimelineCards(forBatch batchId: Int64) -> [TimelineCard] {
    let decoder = JSONDecoder()
    return
      (try? timedRead("fetchTimelineCards(forBatch)") { db in
        try Row.fetchAll(
          db,
          sql: """
                SELECT * FROM timeline_cards
                WHERE batch_id = ?
                  AND is_deleted = 0
                ORDER BY start ASC
            """, arguments: [batchId]
        ).map { row in
          var distractions: [Distraction]? = nil
          var appSites: AppSites? = nil
          var isBackupGenerated: Bool? = nil
          if let metadataString: String = row["metadata"],
            let jsonData = metadataString.data(using: .utf8)
          {
            if let meta = try? decoder.decode(TimelineMetadata.self, from: jsonData) {
              distractions = meta.distractions
              appSites = meta.appSites
              isBackupGenerated = meta.isBackupGenerated
            } else if let legacy = try? decoder.decode([Distraction].self, from: jsonData) {
              distractions = legacy
            }
          }
          return TimelineCard(
            recordId: row["id"],
            batchId: batchId,
            startTimestamp: row["start"] ?? "",
            endTimestamp: row["end"] ?? "",
            category: row["category"],
            subcategory: row["subcategory"],
            title: row["title"],
            summary: row["summary"],
            detailedSummary: row["detailed_summary"],
            day: row["day"],
            distractions: distractions,
            videoSummaryURL: row["video_summary_url"],
            otherVideoSummaryURLs: nil,
            appSites: appSites,
            isBackupGenerated: isBackupGenerated
          )
        }
      }) ?? []
  }

  // All batches, newest first
  func allBatches() -> [(id: Int64, start: Int, end: Int, status: String)] {
    (try? db.read { db in
      try Row.fetchAll(
        db,
        sql:
          "SELECT id, batch_start_ts, batch_end_ts, status FROM analysis_batches ORDER BY id DESC"
      ).map { row in
        (row["id"], row["batch_start_ts"], row["batch_end_ts"], row["status"])
      }
    }) ?? []
  }

  func fetchRecentAnalysisBatchesForDebug(limit: Int) -> [AnalysisBatchDebugEntry] {
    guard limit > 0 else { return [] }

    return
      (try? db.read { db in
        try Row.fetchAll(
          db,
          sql: """
                SELECT id, status, batch_start_ts, batch_end_ts, created_at, reason
                FROM analysis_batches
                ORDER BY id DESC
                LIMIT ?
            """, arguments: [limit]
        ).map { row in
          AnalysisBatchDebugEntry(
            id: row["id"],
            status: row["status"] ?? "unknown",
            startTs: row["batch_start_ts"] ?? 0,
            endTs: row["batch_end_ts"] ?? 0,
            createdAt: row["created_at"],
            reason: row["reason"]
          )
        }
      }) ?? []
  }

  func fetchTimelineCards(forDay day: String) -> [TimelineCard] {
    let decoder = JSONDecoder()

    guard let dayDate = dateFormatter.date(from: day) else {
      return []
    }

    let calendar = Calendar.current

    // Get 4 AM of the given day as the start
    var startComponents = calendar.dateComponents([.year, .month, .day], from: dayDate)
    startComponents.hour = 4
    startComponents.minute = 0
    startComponents.second = 0
    guard let dayStart = calendar.date(from: startComponents) else { return [] }

    // Get 4 AM of the next day as the end
    guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayDate) else { return [] }
    var endComponents = calendar.dateComponents([.year, .month, .day], from: nextDay)
    endComponents.hour = 4
    endComponents.minute = 0
    endComponents.second = 0
    guard let dayEnd = calendar.date(from: endComponents) else { return [] }

    let startTs = Int(dayStart.timeIntervalSince1970)
    let endTs = Int(dayEnd.timeIntervalSince1970)

    let cards: [TimelineCard]? = try? timedRead("fetchTimelineCards(forDay:\(day))") { db in
      try Row.fetchAll(
        db,
        sql: """
              SELECT * FROM timeline_cards
              WHERE start_ts >= ? AND start_ts < ?
                AND is_deleted = 0
              ORDER BY start_ts ASC, start ASC
          """, arguments: [startTs, endTs]
      )
      .map { row in
        // Decode metadata JSON (supports object or legacy array)
        var distractions: [Distraction]? = nil
        var appSites: AppSites? = nil
        var isBackupGenerated: Bool? = nil
        if let metadataString: String = row["metadata"],
          let jsonData = metadataString.data(using: .utf8)
        {
          if let meta = try? decoder.decode(TimelineMetadata.self, from: jsonData) {
            distractions = meta.distractions
            appSites = meta.appSites
            isBackupGenerated = meta.isBackupGenerated
          } else if let legacy = try? decoder.decode([Distraction].self, from: jsonData) {
            distractions = legacy
          }
        }

        // Create TimelineCard instance using renamed columns
        return TimelineCard(
          recordId: row["id"],
          batchId: row["batch_id"],
          startTimestamp: row["start"] ?? "",  // Use row["start"]
          endTimestamp: row["end"] ?? "",  // Use row["end"]
          category: row["category"],
          subcategory: row["subcategory"],
          title: row["title"],
          summary: row["summary"],
          detailedSummary: row["detailed_summary"],
          day: row["day"],
          distractions: distractions,
          videoSummaryURL: row["video_summary_url"],
          otherVideoSummaryURLs: nil,
          appSites: appSites,
          isBackupGenerated: isBackupGenerated
        )
      }
    }
    return cards ?? []
  }

  func fetchTimelineCardsByTimeRange(from: Date, to: Date) -> [TimelineCard] {
    let decoder = JSONDecoder()
    let fromTs = Int(from.timeIntervalSince1970)
    let toTs = Int(to.timeIntervalSince1970)

    let cards: [TimelineCard]? = try? timedRead("fetchTimelineCardsByTimeRange") { db in
      // Intentionally NO `category != 'System'` filter — System/"Processing
      // failed" cards surface in Day view via `fetchTimelineCards(forDay:)`
      // and should be visible in Week view too for parity. Rendering in
      // Week's card layer handles System cards via the generic category
      // palette (falls back to a neutral accent).
      try Row.fetchAll(
        db,
        sql: """
              SELECT * FROM timeline_cards
              WHERE ((start_ts < ? AND end_ts > ?)
                 OR (start_ts >= ? AND start_ts < ?))
                AND is_deleted = 0
              ORDER BY start_ts ASC
          """, arguments: [toTs, fromTs, fromTs, toTs]
      )
      .map { row in
        // Decode metadata JSON (supports object or legacy array)
        var distractions: [Distraction]? = nil
        var appSites: AppSites? = nil
        var isBackupGenerated: Bool? = nil
        if let metadataString: String = row["metadata"],
          let jsonData = metadataString.data(using: .utf8)
        {
          if let meta = try? decoder.decode(TimelineMetadata.self, from: jsonData) {
            distractions = meta.distractions
            appSites = meta.appSites
            isBackupGenerated = meta.isBackupGenerated
          } else if let legacy = try? decoder.decode([Distraction].self, from: jsonData) {
            distractions = legacy
          }
        }

        // Create TimelineCard instance using renamed columns
        return TimelineCard(
          recordId: row["id"],
          batchId: row["batch_id"],
          startTimestamp: row["start"] ?? "",
          endTimestamp: row["end"] ?? "",
          category: row["category"],
          subcategory: row["subcategory"],
          title: row["title"],
          summary: row["summary"],
          detailedSummary: row["detailed_summary"],
          day: row["day"],
          distractions: distractions,
          videoSummaryURL: row["video_summary_url"],
          otherVideoSummaryURLs: nil,
          appSites: appSites,
          isBackupGenerated: isBackupGenerated
        )
      }
    }
    let result = cards ?? []
    return result
  }

  func fetchTotalMinutesTracked(from: Date, to: Date) -> Double {
    let startTs = Int(from.timeIntervalSince1970)
    let endTs = Int(to.timeIntervalSince1970)

    let totalSeconds: Double? = try? timedRead("fetchTotalMinutesTracked") { db in
      try Double.fetchOne(
        db,
        sql: """
              SELECT COALESCE(SUM(end_ts - start_ts), 0)
              FROM timeline_cards
              WHERE start_ts >= ? AND start_ts < ?
              AND is_deleted = 0
              AND category != 'System'
          """,
        arguments: [startTs, endTs]
      )
    }

    return (totalSeconds ?? 0) / 60.0
  }

  /// Returns total minutes of tracked activities for the week containing the given date.
  /// Week starts on Monday at 4 AM and ends the following Monday at 4 AM.
  func fetchTotalMinutesTrackedForWeek(containing date: Date) -> Double {
    let calendar = Calendar.current

    // Find the Monday of the week containing this date
    var weekStart = calendar.date(
      from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date))!
    // Set to 4 AM on that Monday
    weekStart = calendar.date(bySettingHour: 4, minute: 0, second: 0, of: weekStart) ?? weekStart

    // If current date is before 4 AM Monday, go back one week
    if date < weekStart {
      weekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: weekStart) ?? weekStart
    }

    // Week ends at 4 AM the following Monday
    let weekEnd = calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart) ?? weekStart

    return fetchTotalMinutesTracked(from: weekStart, to: weekEnd)
  }

  func fetchRecentTimelineCardsForDebug(limit: Int) -> [TimelineCardDebugEntry] {
    guard limit > 0 else { return [] }

    return
      (try? db.read { db in
        try Row.fetchAll(
          db,
          sql: """
                SELECT batch_id, day, start, end, category, subcategory, title, summary, detailed_summary, created_at
                FROM timeline_cards
                WHERE is_deleted = 0
                ORDER BY created_at DESC, id DESC
                LIMIT ?
            """, arguments: [limit]
        ).map { row in
          TimelineCardDebugEntry(
            createdAt: row["created_at"],
            batchId: row["batch_id"],
            day: row["day"] ?? "",
            startTime: row["start"] ?? "",
            endTime: row["end"] ?? "",
            category: row["category"],
            subcategory: row["subcategory"],
            title: row["title"],
            summary: row["summary"],
            detailedSummary: row["detailed_summary"]
          )
        }
      }) ?? []
  }

  func fetchRecentLLMCallsForDebug(limit: Int) -> [LLMCallDebugEntry] {
    guard limit > 0 else { return [] }

    return
      (try? db.read { db in
        try Row.fetchAll(
          db,
          sql: """
                SELECT created_at, batch_id, call_group_id, attempt, provider, model, operation, status, latency_ms, http_status, request_method, request_url, request_body, response_body, error_message
                FROM llm_calls
                ORDER BY created_at DESC, id DESC
                LIMIT ?
            """, arguments: [limit]
        ).map { row in
          LLMCallDebugEntry(
            createdAt: row["created_at"],
            batchId: row["batch_id"],
            callGroupId: row["call_group_id"],
            attempt: row["attempt"] ?? 0,
            provider: row["provider"] ?? "",
            model: row["model"],
            operation: row["operation"] ?? "",
            status: row["status"] ?? "",
            latencyMs: row["latency_ms"],
            httpStatus: row["http_status"],
            requestMethod: row["request_method"],
            requestURL: row["request_url"],
            requestBody: row["request_body"],
            responseBody: row["response_body"],
            errorMessage: row["error_message"]
          )
        }
      }) ?? []
  }

  func updateStorageLimit(bytes: Int64) {
    let previous = StoragePreferences.recordingsLimitBytes
    StoragePreferences.recordingsLimitBytes = bytes

    if bytes < previous {
      purgeIfNeeded()
    }
  }

  func fetchLLMCallsForBatches(batchIds: [Int64], limit: Int) -> [LLMCallDebugEntry] {
    guard !batchIds.isEmpty, limit > 0 else { return [] }

    // Create SQL placeholders for batch IDs
    let placeholders = Array(repeating: "?", count: batchIds.count).joined(separator: ",")

    return
      (try? db.read { db in
        try Row.fetchAll(
          db,
          sql: """
                SELECT created_at, batch_id, call_group_id, attempt, provider, model, operation, status, latency_ms, http_status, request_method, request_url, request_body, response_body, error_message
                FROM llm_calls
                WHERE batch_id IN (\(placeholders))
                ORDER BY created_at DESC, id DESC
                LIMIT ?
            """, arguments: StatementArguments(batchIds + [Int64(limit)])
        ).map { row in
          LLMCallDebugEntry(
            createdAt: row["created_at"],
            batchId: row["batch_id"],
            callGroupId: row["call_group_id"],
            attempt: row["attempt"] ?? 0,
            provider: row["provider"] ?? "",
            model: row["model"],
            operation: row["operation"] ?? "",
            status: row["status"] ?? "",
            latencyMs: row["latency_ms"],
            httpStatus: row["http_status"],
            requestMethod: row["request_method"],
            requestURL: row["request_url"],
            requestBody: row["request_body"],
            responseBody: row["response_body"],
            errorMessage: row["error_message"]
          )
        }
      }) ?? []
  }

  /// Fetch a specific timeline card by ID including timestamp fields
  func fetchTimelineCard(byId id: Int64) -> TimelineCardWithTimestamps? {
    let decoder = JSONDecoder()

    return try? timedRead("fetchTimelineCard(byId)") { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
                SELECT * FROM timeline_cards
                WHERE id = ?
                  AND is_deleted = 0
            """, arguments: [id])
      else { return nil }

      // Decode distractions from metadata JSON
      var distractions: [Distraction]? = nil
      if let metadataString: String = row["metadata"],
        let jsonData = metadataString.data(using: .utf8)
      {
        if let meta = try? decoder.decode(TimelineMetadata.self, from: jsonData) {
          distractions = meta.distractions
        } else if let legacy = try? decoder.decode([Distraction].self, from: jsonData) {
          distractions = legacy
        }
      }

      return TimelineCardWithTimestamps(
        id: id,
        startTimestamp: row["start"] ?? "",
        endTimestamp: row["end"] ?? "",
        startTs: row["start_ts"] ?? 0,
        endTs: row["end_ts"] ?? 0,
        category: row["category"],
        subcategory: row["subcategory"],
        title: row["title"],
        summary: row["summary"],
        detailedSummary: row["detailed_summary"],
        day: row["day"],
        distractions: distractions,
        videoSummaryURL: row["video_summary_url"]
      )
    }
  }

  func fetchLastTimelineCard(endingBefore: Date) -> TimelineCardWithTimestamps? {
    let decoder = JSONDecoder()
    let beforeTs = Int(endingBefore.timeIntervalSince1970)

    return try? timedRead("fetchLastTimelineCard(endingBefore:)") { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
                SELECT *
                FROM timeline_cards
                WHERE end_ts <= ?
                  AND is_deleted = 0
                ORDER BY end_ts DESC, id DESC
                LIMIT 1
            """,
          arguments: [beforeTs]
        )
      else {
        return nil
      }

      var distractions: [Distraction]? = nil
      if let metadataString: String = row["metadata"],
        let jsonData = metadataString.data(using: .utf8)
      {
        if let meta = try? decoder.decode(TimelineMetadata.self, from: jsonData) {
          distractions = meta.distractions
        } else if let legacy = try? decoder.decode([Distraction].self, from: jsonData) {
          distractions = legacy
        }
      }

      return TimelineCardWithTimestamps(
        id: row["id"],
        startTimestamp: row["start"] ?? "",
        endTimestamp: row["end"] ?? "",
        startTs: row["start_ts"] ?? 0,
        endTs: row["end_ts"] ?? 0,
        category: row["category"],
        subcategory: row["subcategory"],
        title: row["title"],
        summary: row["summary"],
        detailedSummary: row["detailed_summary"],
        day: row["day"],
        distractions: distractions,
        videoSummaryURL: row["video_summary_url"]
      )
    }
  }

  func replaceTimelineCardsInRange(
    from: Date, to: Date, with newCards: [TimelineCardShell], batchId: Int64
  ) -> (insertedIds: [Int64], deletedVideoPaths: [String]) {
    let fromTs = Int(from.timeIntervalSince1970)
    let toTs = Int(to.timeIntervalSince1970)

    let encoder = JSONEncoder()
    var insertedIds: [Int64] = []
    var videoPaths: [String] = []

    // Setup date formatter for parsing clock times
    let timeFormatter = DateFormatter()
    timeFormatter.dateFormat = "h:mm a"
    timeFormatter.locale = Locale(identifier: "en_US_POSIX")

    try? timedWrite("replaceTimelineCardsInRange(\(newCards.count)_cards)") { db in
      // First, fetch the video paths that will be soft-deleted
      // Note: We exclude error cards (category='System') from other batches to preserve them
      let videoRows = try Row.fetchAll(
        db,
        sql: """
              SELECT video_summary_url FROM timeline_cards
              WHERE ((start_ts < ? AND end_ts > ?)
                 OR (start_ts >= ? AND start_ts < ?))
                 AND video_summary_url IS NOT NULL
                 AND is_deleted = 0
                 AND (category != 'System' OR batch_id = ?)
          """, arguments: [toTs, fromTs, fromTs, toTs, batchId])

      videoPaths = videoRows.compactMap { $0["video_summary_url"] as? String }

      // Fetch the cards that will be deleted for debugging
      let cardsToDelete = try Row.fetchAll(
        db,
        sql: """
              SELECT id, start, end, title FROM timeline_cards
              WHERE ((start_ts < ? AND end_ts > ?)
                 OR (start_ts >= ? AND start_ts < ?))
                 AND is_deleted = 0
                 AND (category != 'System' OR batch_id = ?)
          """, arguments: [toTs, fromTs, fromTs, toTs, batchId])

      for _ in cardsToDelete {
        // Cards being deleted - no-op needed, just iterating to trigger side effects
      }

      // Soft delete existing cards in the range using timestamp columns
      // Preserve error cards (category='System') from other batches so they remain visible
      try db.execute(
        sql: """
              UPDATE timeline_cards
              SET is_deleted = 1
              WHERE ((start_ts < ? AND end_ts > ?)
                 OR (start_ts >= ? AND start_ts < ?))
                 AND is_deleted = 0
                 AND (category != 'System' OR batch_id = ?)
          """, arguments: [toTs, fromTs, fromTs, toTs, batchId])

      // Verify soft deletion (count remaining active cards)
      let remainingCount =
        try Int.fetchOne(
          db,
          sql: """
                SELECT COUNT(*) FROM timeline_cards
                WHERE ((start_ts < ? AND end_ts > ?)
                   OR (start_ts >= ? AND start_ts < ?))
                   AND is_deleted = 0
            """, arguments: [toTs, fromTs, fromTs, toTs]) ?? 0

      if remainingCount > 0 {
      } else {
      }

      // Insert new cards
      for card in newCards {
        // Encode metadata object with distractions and appSites
        let meta = TimelineMetadata(
          distractions: card.distractions,
          appSites: card.appSites,
          isBackupGenerated: card.isBackupGenerated,
          idle: card.idleMetadata
        )
        let metadataString: String? = (try? encoder.encode(meta)).flatMap {
          String(data: $0, encoding: .utf8)
        }

        // Resolve clock-only timestamps by picking the nearest day to the window midpoint
        let calendar = Calendar.current
        let anchor = from.addingTimeInterval(to.timeIntervalSince(from) / 2.0)

        let resolveClock: (Int, Int) -> Date = { hour, minute in
          guard
            let sameDay = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: anchor)
          else {
            return anchor
          }
          let previousDay = calendar.date(byAdding: .day, value: -1, to: sameDay) ?? sameDay
          let nextDay = calendar.date(byAdding: .day, value: 1, to: sameDay) ?? sameDay

          let candidates = [previousDay, sameDay, nextDay]
          return candidates.min { lhs, rhs in
            abs(lhs.timeIntervalSince(anchor)) < abs(rhs.timeIntervalSince(anchor))
          } ?? sameDay
        }

        guard let startTime = timeFormatter.date(from: card.startTimestamp),
          let endTime = timeFormatter.date(from: card.endTimestamp)
        else {
          continue
        }

        let startComponents = calendar.dateComponents([.hour, .minute], from: startTime)
        guard let startHour = startComponents.hour, let startMinute = startComponents.minute else {
          continue
        }

        let startDate = resolveClock(startHour, startMinute)

        let startTs = Int(startDate.timeIntervalSince1970)

        let endComponents = calendar.dateComponents([.hour, .minute], from: endTime)
        guard let endHour = endComponents.hour, let endMinute = endComponents.minute else {
          continue
        }

        var endDate = resolveClock(endHour, endMinute)

        // Handle midnight crossing: if end time is before start time, it must be the next day
        if endDate < startDate {
          endDate = calendar.date(byAdding: .day, value: 1, to: endDate) ?? endDate
        }

        let endTs = Int(endDate.timeIntervalSince1970)

        // Calculate the day string using 4 AM boundary rules
        let (dayString, _, _) = startDate.getDayInfoFor4AMBoundary()

        try db.execute(
          sql: """
                INSERT INTO timeline_cards(
                    batch_id, start, end, start_ts, end_ts, day, title,
                    summary, category, subcategory, detailed_summary, metadata
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            batchId, card.startTimestamp, card.endTimestamp, startTs, endTs, dayString, card.title,
            card.summary, card.category, card.subcategory, card.detailedSummary, metadataString,
          ])

        // Capture the ID of the inserted card
        let insertedId = db.lastInsertedRowID
        insertedIds.append(insertedId)
      }
    }

    return (insertedIds, videoPaths)
  }

  // Note: Transcript storage methods removed in favor of Observations table

}
