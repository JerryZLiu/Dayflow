import Foundation
import GRDB
import Sentry

extension StorageManager {
  /// Check whether a day meets the requested timeline activity threshold. Uses the stored day,
  /// like `fetchTimelineCards(forDay:)`, so a day recorded in another zone counts its own cards.
  func hasMinimumTimelineActivity(forDay day: String, minimumMinutes: Int = 60) -> Bool {
    // Sum total duration of timeline cards for the day
    let totalMinutes: Int? = try? timedRead("hasMinimumTimelineActivity") { db in
      // Calculate sum of (end_ts - start_ts) for all cards, converted to minutes
      let result = try Int.fetchOne(
        db,
        sql: """
              SELECT COALESCE(SUM(end_ts - start_ts), 0) / 60 as total_minutes
              FROM timeline_cards
              WHERE day = ?
                AND is_deleted = 0
          """, arguments: [day])
      return result
    }

    return (totalMinutes ?? 0) >= minimumMinutes
  }

  func hasAnyTimelineCards() -> Bool {
    (try? timedRead("hasAnyTimelineCards") { db in
      try Bool.fetchOne(
        db,
        sql: "SELECT EXISTS(SELECT 1 FROM timeline_cards WHERE is_deleted = 0 LIMIT 1)"
      ) ?? false
    }) ?? false
  }

  /// Active cards carrying this exact category label. Used by the agent
  /// bridge to tell the user how many activities a category delete orphans.
  func countTimelineCards(inCategory category: String) -> Int {
    (try? timedRead("countTimelineCards(inCategory:)") { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM timeline_cards WHERE category = ? AND is_deleted = 0",
        arguments: [category]
      ) ?? 0
    }) ?? 0
  }

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

    try? updateTimelineCard(cardId: cardId, title: nil, category: trimmed)
  }

  func updateTimelineCardTitle(cardId: Int64, title: String) {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return }

    try? updateTimelineCard(cardId: cardId, title: trimmed, category: nil)
  }

  /// Applies every requested activity field in one transaction. Agent writes use the
  /// throwing form so a database failure is returned instead of reported as success.
  func updateTimelineCard(cardId: Int64, title: String?, category: String?) throws {
    guard title != nil || category != nil else { return }

    try timedWrite("updateTimelineCard") { db in
      try db.execute(
        sql: """
              UPDATE timeline_cards
              SET title = COALESCE(?, title),
                  category = COALESCE(?, category)
              WHERE id = ?
          """, arguments: [title, category, cardId])
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
                  summary, category, subcategory, detailed_summary, metadata, utc_offset
              )
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
          Calendar.current.timeZone.secondsFromGMT(for: startTime),
        ])
    }
  }

  func buildOnboardingSummary() -> String {
    let selectedProvider = (try? LLMProviderRoutingStore.load())?.primary

    switch selectedProvider {
    case .gemini:
      return
        "You successfully installed Dayflow and configured it with Gemini AI. Come back in 30 minutes to see your first real activity card! ✨ (This is a sample card, so you can see what your timeline will look like.)"

    case .chatGPT:
      return
        "You successfully installed Dayflow with ChatGPT. Come back in 30 minutes to see your first real activity card! ✨ (This is a sample card, so you can see what your timeline will look like.)"

    case .claude:
      return
        "You successfully installed Dayflow with Claude. Come back in 30 minutes to see your first real activity card! ✨ (This is a sample card, so you can see what your timeline will look like.)"

    case .local:
      // Check which local engine they picked
      let localEngine = UserDefaults.standard.string(forKey: "llmLocalEngine") ?? "ollama"
      if localEngine == "lmstudio" {
        return
          "You successfully installed Dayflow with LM Studio, and your data stays 100% on your device. Come back in 30 minutes to see your first real activity card! ✨ (This is a sample card, so you can see what your timeline will look like.)"
      } else {
        return
          "You successfully installed Dayflow with Ollama, and your data stays 100% on your device. Come back in 30 minutes to see your first real activity card! ✨ (This is a sample card, so you can see what your timeline will look like.)"
      }

    case .dayflow:
      return
        "You successfully installed Dayflow with Dayflow Pro. Come back in 30 minutes to see your first real activity card! ✨ (This is a sample card, so you can see what your timeline will look like.)"

    case .openAICompatible:
      return
        "You successfully installed Dayflow with your OpenAI-compatible provider. Come back in 30 minutes to see your first real activity card! ✨ (This is a sample card, so you can see what your timeline will look like.)"

    case nil:
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
        ).map { timelineCard(from: $0, decoder: decoder) }
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

  /// Cards whose stored day is `day`. Each card's day was set in the zone it was recorded in,
  /// so a day recorded in Tokyo stays together when viewed from San Francisco.
  func fetchTimelineCards(forDay day: String) -> [TimelineCard] {
    fetchTimelineCards(fromDay: day, throughDay: day)
  }

  /// Cards whose stored day falls between the two day keys, both included.
  func fetchTimelineCards(fromDay firstDay: String, throughDay lastDay: String) -> [TimelineCard] {
    let decoder = JSONDecoder()
    let cards: [TimelineCard]? = try? timedRead(
      "fetchTimelineCards(fromDay:\(firstDay),throughDay:\(lastDay))"
    ) { db in
      try Row.fetchAll(
        db,
        sql: """
              SELECT * FROM timeline_cards
              WHERE day >= ? AND day <= ?
                AND is_deleted = 0
              ORDER BY start_ts ASC, start ASC
          """, arguments: [firstDay, lastDay]
      )
      .map { timelineCard(from: $0, decoder: decoder) }
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
      .map { timelineCard(from: $0, decoder: decoder) }
    }
    return cards ?? []
  }

  /// Builds a card from a `timeline_cards` row.
  private func timelineCard(from row: Row, decoder: JSONDecoder) -> TimelineCard {
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

    // subcategory/summary/detailed_summary are nullable in the schema —
    // decode NULL as "" because the model fields are non-optional and would trap.
    return TimelineCard(
      recordId: row["id"],
      batchId: row["batch_id"],
      startTimestamp: row["start"] ?? "",
      endTimestamp: row["end"] ?? "",
      category: row["category"],
      subcategory: row["subcategory"] ?? "",
      title: row["title"],
      summary: row["summary"] ?? "",
      detailedSummary: row["detailed_summary"] ?? "",
      day: row["day"],
      distractions: distractions,
      videoSummaryURL: row["video_summary_url"],
      otherVideoSummaryURLs: nil,
      appSites: appSites,
      isBackupGenerated: isBackupGenerated,
      startTs: row["start_ts"],
      endTs: row["end_ts"],
      utcOffset: row["utc_offset"]
    )
  }

  /// The zone a batch was recorded in. Batches saved before zones were stored fall back to the
  /// offset of their own earlier cards, then to the Mac's current zone.
  private func recordedTimeZone(forBatch batchId: Int64?, db: Database) throws -> TimeZone {
    let currentZone = Calendar.current.timeZone
    guard let batchId else { return currentZone }

    if let identifier = try String.fetchOne(
      db, sql: "SELECT time_zone FROM analysis_batches WHERE id = ?", arguments: [batchId]),
      let zone = TimeZone(identifier: identifier)
    {
      return zone
    }

    if let offset = try Int.fetchOne(
      db,
      sql: """
            SELECT utc_offset FROM timeline_cards
            WHERE batch_id = ? AND utc_offset IS NOT NULL
            ORDER BY id DESC LIMIT 1
        """, arguments: [batchId]),
      let zone = TimeZone(secondsFromGMT: offset)
    {
      return zone
    }

    return currentZone
  }

  func hasTimelineCardConnected(
    toBatchStartingAt batchStart: Date,
    maxGap: TimeInterval
  ) -> Bool {
    let batchStartTs = Int(batchStart.timeIntervalSince1970)
    let earliestEndTs = batchStartTs - Int(maxGap)

    return
      (try? timedRead("hasTimelineCardConnected") { db in
        try Bool.fetchOne(
          db,
          sql: """
                SELECT EXISTS(
                  SELECT 1
                  FROM timeline_cards
                  WHERE start_ts <= ?
                    AND end_ts >= ?
                    AND is_deleted = 0
                    AND category != 'System'
                )
            """,
          arguments: [batchStartTs, earliestEndTs]
        ) ?? false
      }) ?? false
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

  /// Minutes of tracked activity on a stored day, counted the same way as the time-range version.
  func fetchTotalMinutesTracked(forDay day: String) -> Double {
    let totalSeconds: Double? = try? timedRead("fetchTotalMinutesTracked(forDay:)") { db in
      try Double.fetchOne(
        db,
        sql: """
              SELECT COALESCE(SUM(end_ts - start_ts), 0)
              FROM timeline_cards
              WHERE day = ?
              AND is_deleted = 0
              AND category != 'System'
          """,
        arguments: [day]
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

      // subcategory/summary/detailed_summary are nullable in the schema —
      // decode NULL as "" because the model fields are non-optional and would trap.
      return TimelineCardWithTimestamps(
        id: id,
        startTimestamp: row["start"] ?? "",
        endTimestamp: row["end"] ?? "",
        startTs: row["start_ts"] ?? 0,
        endTs: row["end_ts"] ?? 0,
        category: row["category"],
        subcategory: row["subcategory"] ?? "",
        title: row["title"],
        summary: row["summary"] ?? "",
        detailedSummary: row["detailed_summary"] ?? "",
        day: row["day"],
        distractions: distractions,
        videoSummaryURL: row["video_summary_url"]
      )
    }
  }

  /// The card right before a batch: of the cards that start before it, the one ending last.
  /// Its end can fall after the batch's start, because card times are rounded to the minute.
  func fetchTimelineCardEndingLast(startingBefore: Date, excludingBatchId: Int64)
    -> TimelineCardWithTimestamps?
  {
    let decoder = JSONDecoder()
    let beforeTs = Int(startingBefore.timeIntervalSince1970)

    return try? timedRead("fetchTimelineCardEndingLast(startingBefore:)") { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
                SELECT *
                FROM timeline_cards
                WHERE start_ts < ?
                  AND batch_id IS NOT ?
                  AND is_deleted = 0
                ORDER BY end_ts DESC, id DESC
                LIMIT 1
            """,
          arguments: [beforeTs, excludingBatchId]
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

      // subcategory/summary/detailed_summary are nullable in the schema —
      // decode NULL as "" because the model fields are non-optional and would trap.
      return TimelineCardWithTimestamps(
        id: row["id"],
        startTimestamp: row["start"] ?? "",
        endTimestamp: row["end"] ?? "",
        startTs: row["start_ts"] ?? 0,
        endTs: row["end_ts"] ?? 0,
        category: row["category"],
        subcategory: row["subcategory"] ?? "",
        title: row["title"],
        summary: row["summary"] ?? "",
        detailedSummary: row["detailed_summary"] ?? "",
        day: row["day"],
        distractions: distractions,
        videoSummaryURL: row["video_summary_url"]
      )
    }
  }

  /// Writes an idle batch's card without touching other batches' cards. The only cards removed
  /// are this batch's own earlier ones: an error card from a failed attempt, or output from an
  /// earlier run. With `extendingCardId`, that previous idle card is stretched to `endTs`
  /// instead of adding a new card.
  func saveIdleBatchCard(
    _ card: TimelineCardShell, startTs: Int, endTs: Int, batchId: Int64, extendingCardId: Int64?
  ) -> (cardId: Int64?, deletedVideoPaths: [String]) {
    let metadata = TimelineMetadata(
      distractions: nil, appSites: nil, isBackupGenerated: nil, idle: card.idleMetadata)
    let metadataString = (try? JSONEncoder().encode(metadata)).flatMap {
      String(data: $0, encoding: .utf8)
    }
    let startDate = Date(timeIntervalSince1970: TimeInterval(startTs))
    let endDate = Date(timeIntervalSince1970: TimeInterval(endTs))

    var cardId: Int64?
    var videoPaths: [String] = []
    try? timedWrite("saveIdleBatchCard") { db in
      let recordedZone = try recordedTimeZone(forBatch: batchId, db: db)
      let (dayString, _, _) = startDate.getDayInfoFor4AMBoundary(
        in: ClockTime.calendar(in: recordedZone))

      videoPaths = try String.fetchAll(
        db,
        sql: """
              SELECT video_summary_url FROM timeline_cards
              WHERE batch_id = ? AND is_deleted = 0 AND video_summary_url IS NOT NULL
          """, arguments: [batchId])
      try db.execute(
        sql: "UPDATE timeline_cards SET is_deleted = 1 WHERE batch_id = ? AND is_deleted = 0",
        arguments: [batchId])

      if let extendingCardId {
        // Label the new end in the zone the extended card was recorded in.
        let extendedBatchId = try Int64.fetchOne(
          db, sql: "SELECT batch_id FROM timeline_cards WHERE id = ?",
          arguments: [extendingCardId])
        let extendedZone =
          extendedBatchId == nil
          ? recordedZone : try recordedTimeZone(forBatch: extendedBatchId, db: db)
        try db.execute(
          sql: """
                UPDATE timeline_cards
                SET end = ?, end_ts = ?, metadata = ?
                WHERE id = ? AND is_deleted = 0
            """,
          arguments: [
            ClockTime.label(for: endDate, in: extendedZone), endTs, metadataString,
            extendingCardId,
          ])
        cardId = db.changesCount > 0 ? extendingCardId : nil
      } else {
        try db.execute(
          sql: """
                INSERT INTO timeline_cards(
                    batch_id, start, end, start_ts, end_ts, day, title,
                    summary, category, subcategory, detailed_summary, metadata, utc_offset
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            batchId,
            ClockTime.label(for: startDate, in: recordedZone),
            ClockTime.label(for: endDate, in: recordedZone),
            startTs, endTs, dayString, card.title,
            card.summary, card.category, card.subcategory, card.detailedSummary, metadataString,
            recordedZone.secondsFromGMT(for: startDate),
          ])
        cardId = db.lastInsertedRowID
      }
    }
    return (cardId, videoPaths)
  }

  func replaceTimelineCardsInRange(
    from: Date, to: Date, with newCards: [TimelineCardShell], batchId: Int64
  ) -> (insertedIds: [Int64], deletedVideoPaths: [String]) {
    replaceTimelineCardsInRange(
      from: from, to: to, with: newCards, batchId: batchId,
      keepingNewerBatchesCardsStartingAfter: nil)
  }

  /// Soft-deletes the cards in the range and inserts the new ones.
  ///
  /// Pass `keepingNewerBatchesCardsStartingAfter` (this batch's start) when the caller never
  /// showed its model the cards of newer batches, which happens when this batch finishes after a
  /// newer one, such as a retry. Cards from batches that started later and that begin after that
  /// moment then stay, even where clock times rounded to the minute make them overlap the range.
  func replaceTimelineCardsInRange(
    from: Date, to: Date, with newCards: [TimelineCardShell], batchId: Int64,
    keepingNewerBatchesCardsStartingAfter keepAfter: Date?
  ) -> (insertedIds: [Int64], deletedVideoPaths: [String]) {
    let fromTs = Int(from.timeIntervalSince1970)
    let toTs = Int(to.timeIntervalSince1970)
    // Without a cutoff, the far-future default keeps nothing back.
    let keepAfterTs = keepAfter.map { Int($0.timeIntervalSince1970) } ?? Int.max

    let encoder = JSONEncoder()
    var insertedIds: [Int64] = []
    var videoPaths: [String] = []

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
                 AND NOT (start_ts > ? AND COALESCE(batch_id, -1) IN (
                   SELECT id FROM analysis_batches WHERE batch_start_ts > ?))
          """, arguments: [toTs, fromTs, fromTs, toTs, batchId, keepAfterTs, keepAfterTs])

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
                 AND NOT (start_ts > ? AND COALESCE(batch_id, -1) IN (
                   SELECT id FROM analysis_batches WHERE batch_start_ts > ?))
          """, arguments: [toTs, fromTs, fromTs, toTs, batchId, keepAfterTs, keepAfterTs])

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
                 AND NOT (start_ts > ? AND COALESCE(batch_id, -1) IN (
                   SELECT id FROM analysis_batches WHERE batch_start_ts > ?))
          """, arguments: [toTs, fromTs, fromTs, toTs, batchId, keepAfterTs, keepAfterTs])

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

      // The model was given clock times in the Mac's current zone, so its answer is read in that
      // zone. What's stored (labels, day, offset) uses the zone the batch was recorded in.
      let processingCalendar = Calendar.current
      let anchor = from.addingTimeInterval(to.timeIntervalSince(from) / 2.0)
      let recordedZone = try recordedTimeZone(forBatch: batchId, db: db)
      let recordedCalendar = ClockTime.calendar(in: recordedZone)

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

        // Resolve clock-only times to the moment nearest the window midpoint
        guard let start = ClockTime.hourAndMinute(of: card.startTimestamp),
          let end = ClockTime.hourAndMinute(of: card.endTimestamp),
          let startDate = ClockTime.resolve(
            hour: start.hour, minute: start.minute, nearest: anchor, calendar: processingCalendar),
          // The end is the first moment at or after the start with that clock time, which also
          // handles midnight and the repeated hour on the night clocks fall back.
          let endDate = ClockTime.resolve(
            hour: end.hour, minute: end.minute, onOrAfter: startDate, calendar: processingCalendar)
        else {
          continue
        }

        let startTs = Int(startDate.timeIntervalSince1970)
        let endTs = Int(endDate.timeIntervalSince1970)

        // Calculate the day string using 4 AM boundary rules
        let (dayString, _, _) = startDate.getDayInfoFor4AMBoundary(in: recordedCalendar)

        try db.execute(
          sql: """
                INSERT INTO timeline_cards(
                    batch_id, start, end, start_ts, end_ts, day, title,
                    summary, category, subcategory, detailed_summary, metadata, utc_offset
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            batchId,
            ClockTime.label(for: startDate, in: recordedZone),
            ClockTime.label(for: endDate, in: recordedZone),
            startTs, endTs, dayString, card.title,
            card.summary, card.category, card.subcategory, card.detailedSummary, metadataString,
            recordedZone.secondsFromGMT(for: startDate),
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
