//
//  DailyRecapScheduler.swift
//  Dayflow
//

import Foundation

final class DailyRecapScheduler: @unchecked Sendable {
  static let shared = DailyRecapScheduler()

  private let queue = DispatchQueue(label: "com.dayflow.dailyRecapScheduler", qos: .utility)
  private var timer: DispatchSourceTimer?
  private var isRunningCheck = false

  private let checkInterval: TimeInterval = 5 * 60
  private let bootstrapBackfillWindowDays = 7
  private let priorStandupHistoryLimit = 3

  private init() {}

  func start() {
    queue.async { [weak self] in
      self?.startOnQueue()
    }
  }

  func stop() {
    queue.async { [weak self] in
      self?.stopOnQueue()
    }
  }

  private func startOnQueue() {
    stopOnQueue()

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + checkInterval, repeating: checkInterval)
    timer.setEventHandler { [weak self] in
      self?.triggerCheckOnQueue(reason: "interval")
    }
    timer.resume()
    self.timer = timer

    triggerCheckOnQueue(reason: "startup")
  }

  private func stopOnQueue() {
    timer?.setEventHandler {}
    timer?.cancel()
    timer = nil
    isRunningCheck = false
  }

  private func triggerCheckOnQueue(reason: String) {
    guard !isRunningCheck else {
      return
    }

    isRunningCheck = true
    Task.detached(priority: .utility) { [weak self] in
      await self?.runCheck(reason: reason)
    }
  }

  private func runCheck(reason: String) async {
    defer {
      queue.async { [weak self] in
        self?.isRunningCheck = false
      }
    }

    guard UserDefaults.standard.bool(forKey: "isDailyUnlocked") else {
      return
    }

    let now = Date()
    let hour = Calendar.current.component(.hour, from: now)

    guard hour >= 4 else {
      return
    }

    let currentDay = now.getDayInfoFor4AMBoundary()
    guard
      let yesterdayStart = Calendar.current.date(
        byAdding: .day, value: -1, to: currentDay.startOfDay)
    else {
      AnalyticsService.shared.capture(
        "daily_auto_generation_check_failed",
        [
          "reason": "day_calculation_failed",
          "trigger": reason,
        ])
      return
    }

    let minimumActivityMinutes = 180
    guard
      let recapTarget = nextRecapTargetDay(
        fromYesterday: yesterdayStart,
        minimumActivityMinutes: minimumActivityMinutes,
        trigger: reason
      )
    else {
      return
    }

    let recapDay = recapTarget.dayString
    let recapStart = recapTarget.startOfDay
    let recapEnd = recapTarget.endOfDay
    let selectedProvider = DailyRecapGenerator.shared.selectedProvider()
    let providerAvailability =
      DailyRecapGenerator.shared.availabilitySnapshot()[selectedProvider]
      ?? DailyRecapProviderAvailability(
        isAvailable: true,
        detail: selectedProvider.pickerSubtitle
      )
    let providerProps: [String: Any] = [
      "daily_provider": selectedProvider.analyticsName,
      "daily_provider_label": selectedProvider.displayName,
      "daily_runtime": selectedProvider.runtimeLabel,
      "daily_model_or_tool": selectedProvider.modelOrTool as Any,
    ]

    guard selectedProvider.canGenerate else {
      AnalyticsService.shared.capture(
        "daily_auto_generation_check_skipped",
        providerProps.merging(
          [
            "trigger": reason,
            "target_day": recapDay,
            "reason": "no_provider_selected",
          ],
          uniquingKeysWith: { _, new in new }
        ))
      return
    }

    guard providerAvailability.isAvailable else {
      AnalyticsService.shared.capture(
        "daily_auto_generation_check_skipped",
        providerProps.merging(
          [
            "trigger": reason,
            "target_day": recapDay,
            "reason": "provider_unavailable",
            "provider_detail": providerAvailability.detail,
          ],
          uniquingKeysWith: { _, new in new }
        ))
      return
    }

    let usesDayflowInputs = selectedProvider.usesDayflowInputs

    let cards = StorageManager.shared.fetchTimelineCards(forDay: recapDay)
    let observations =
      usesDayflowInputs
      ? StorageManager.shared.fetchObservations(
        startTs: Int(recapStart.timeIntervalSince1970),
        endTs: Int(recapEnd.timeIntervalSince1970)
      ) : []
    let priorEntries =
      usesDayflowInputs
      ? StorageManager.shared.fetchRecentDailyStandups(
        limit: priorStandupHistoryLimit,
        excludingDay: recapDay
      ) : []

    let cardsText = DailyRecapGenerator.makeCardsText(day: recapDay, cards: cards)
    let observationsText =
      usesDayflowInputs
      ? DailyRecapGenerator.makeObservationsText(day: recapDay, observations: observations) : ""
    let priorDailyText =
      usesDayflowInputs ? DailyRecapGenerator.makePriorDailyText(entries: priorEntries) : ""
    let preferencesText =
      usesDayflowInputs
      ? DailyRecapGenerator.makePreferencesText(
        highlightsTitle: "Yesterday's highlights",
        tasksTitle: "Today's tasks",
        blockersTitle: "Blockers"
      ) : ""
    AnalyticsService.shared.capture(
      "daily_auto_generation_check_started",
      providerProps.merging(
        [
          "trigger": reason,
          "target_day": recapDay,
        ],
        uniquingKeysWith: { _, new in new }
      ))

    AnalyticsService.shared.capture(
      "daily_auto_generation_payload_built",
      providerProps.merging(
        [
          "trigger": reason,
          "target_day": recapDay,
          "input_mode": usesDayflowInputs ? "cards_observations_prior" : "cards_only",
          "cards_count": cards.count,
          "observations_count": observations.count,
          "prior_daily_count": priorEntries.count,
          "cards_text_chars": cardsText.count,
          "observations_text_chars": observationsText.count,
          "prior_daily_text_chars": priorDailyText.count,
          "preferences_text_chars": preferencesText.count,
        ],
        uniquingKeysWith: { _, new in new }
      ))

    let startedAt = Date()
    do {
      let context = DailyRecapGenerationContext(
        targetDayString: recapDay,
        sourceDayString: recapDay,
        cards: cards,
        observations: observations,
        priorEntries: priorEntries,
        highlightsTitle: "Yesterday's highlights",
        tasksTitle: "Today's tasks",
        blockersTitle: "Blockers"
      )
      let draft = try await DailyRecapGenerator.shared.generate(context: context)
      guard let payloadJSON = draft.encodedJSONString() else {
        AnalyticsService.shared.capture(
          "daily_auto_generation_failed",
          providerProps.merging(
            [
              "trigger": reason,
              "target_day": recapDay,
              "failure_reason": "payload_encoding_failed",
            ],
            uniquingKeysWith: { _, new in new }
          ))
        return
      }

      StorageManager.shared.saveDailyStandup(forDay: recapDay, payloadJSON: payloadJSON)
      guard StorageManager.shared.fetchDailyStandup(forDay: recapDay) != nil else {
        AnalyticsService.shared.capture(
          "daily_auto_generation_failed",
          providerProps.merging(
            [
              "trigger": reason,
              "target_day": recapDay,
              "failure_reason": "db_save_verification_failed",
            ],
            uniquingKeysWith: { _, new in new }
          ))
        return
      }
      AnalyticsService.shared.capture(
        "daily_auto_generation_succeeded",
        providerProps.merging(
          [
            "trigger": reason,
            "target_day": recapDay,
            "latency_ms": Int(Date().timeIntervalSince(startedAt) * 1000),
            "highlights_count": draft.highlights.count,
            "tasks_count": draft.tasks.count,
            "unfinished_count": draft.tasks.count,
            "blockers_count": draft.blockersBody
              .split(whereSeparator: \.isNewline)
              .count,
          ],
          uniquingKeysWith: { _, new in new }
        ))

      await MainActor.run {
        NotificationService.shared.scheduleDailyRecapReadyNotification(forDay: recapDay)
      }
      NotificationCenter.default.post(name: Notification.Name.dayflowDailyRecapCompleted, object: recapDay)
    } catch {
      let nsError = error as NSError
      AnalyticsService.shared.capture(
        "daily_auto_generation_failed",
        providerProps.merging(
          [
            "trigger": reason,
            "target_day": recapDay,
            "failure_reason": "api_error",
            "error_domain": nsError.domain,
            "error_code": nsError.code,
            "error_message": String(nsError.localizedDescription.prefix(500)),
          ],
          uniquingKeysWith: { _, new in new }
        ))
    }
  }

  private func nextRecapTargetDay(
    fromYesterday yesterdayStart: Date,
    minimumActivityMinutes: Int,
    trigger: String
  ) -> (dayString: String, startOfDay: Date, endOfDay: Date)? {
    let calendar = Calendar.current
    guard bootstrapBackfillWindowDays > 0,
      let windowStart = calendar.date(
        byAdding: .day,
        value: -(bootstrapBackfillWindowDays - 1),
        to: yesterdayStart
      )
    else {
      return nil
    }

    var scanStart = windowStart
    if let latestStandupDay = StorageManager.shared.fetchLatestDailyStandupDay() {
      if let latestStandupDate = DateFormatter.yyyyMMdd.date(from: latestStandupDay),
        let nextDayAfterLatest = calendar.date(byAdding: .day, value: 1, to: latestStandupDate)
      {
        scanStart = max(windowStart, nextDayAfterLatest)
      } else {
        AnalyticsService.shared.capture(
          "daily_auto_generation_check_failed",
          [
            "reason": "latest_standup_day_parse_failed",
            "trigger": trigger,
            "latest_standup_day": latestStandupDay,
          ])
      }
    }

    guard scanStart <= yesterdayStart else {
      return nil
    }

    var cursor = scanStart
    while cursor <= yesterdayStart {
      let dayString = DateFormatter.yyyyMMdd.string(from: cursor)
      let hasStandup = StorageManager.shared.fetchDailyStandup(forDay: dayString) != nil
      let hasMinimumActivity = StorageManager.shared.hasMinimumTimelineActivity(
        forDay: dayString,
        minimumMinutes: minimumActivityMinutes
      )

      if !hasStandup && hasMinimumActivity,
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: cursor)
      {
        return (dayString: dayString, startOfDay: cursor, endOfDay: endOfDay)
      }

      guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else {
        break
      }
      cursor = next
    }

    return nil
  }

  private static func resolvedDayflowEndpoint(
    defaultEndpoint: String,
    infoPlistKey: String,
    overrideDefaultsKey: String
  ) -> String {
    let defaults = UserDefaults.standard

    if let override = defaults.string(forKey: overrideDefaultsKey)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !override.isEmpty
    {
      return override
    }

    if let infoEndpoint = Bundle.main.infoDictionary?[infoPlistKey] as? String {
      let trimmed = infoEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        return trimmed
      }
    }

    if case .dayflowBackend(let savedEndpoint) = LLMProviderType.load(from: defaults) {
      let trimmed = savedEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        return trimmed
      }
    }

    return defaultEndpoint
  }

  private static func makeCardsText(day: String, cards: [TimelineCard]) -> String {
    let ordered = cards.sorted { lhs, rhs in
      if lhs.startTimestamp == rhs.startTimestamp {
        return lhs.endTimestamp < rhs.endTimestamp
      }
      return lhs.startTimestamp < rhs.startTimestamp
    }

    guard !ordered.isEmpty else {
      return "No timeline activities were recorded for \(day)."
    }

    var lines: [String] = ["Timeline activities for \(day):", ""]
    for (index, card) in ordered.enumerated() {
      let title = standupLine(from: card) ?? "Untitled activity"
      let start = humanReadableClockTime(card.startTimestamp)
      let end = humanReadableClockTime(card.endTimestamp)
      lines.append("\(index + 1). \(start) - \(end): \(title)")

      let summary = card.summary.trimmingCharacters(in: .whitespacesAndNewlines)
      if !summary.isEmpty, summary != title {
        lines.append("   \(summary)")
      }
    }

    return lines.joined(separator: "\n")
  }

  private static func makeObservationsText(day: String, observations: [Observation]) -> String {
    guard !observations.isEmpty else {
      return "No observations were recorded for \(day)."
    }

    let ordered = observations.sorted { $0.startTs < $1.startTs }
    var lines: [String] = ["Observations for \(day):", ""]

    for observation in ordered {
      let text = observation.observation.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { continue }
      let start = humanReadableClockTime(unixTimestamp: observation.startTs)
      let end = humanReadableClockTime(unixTimestamp: observation.endTs)
      lines.append("\(start) - \(end): \(text)")
    }

    if lines.count <= 2 {
      return "No observations were recorded for \(day)."
    }
    return lines.joined(separator: "\n")
  }

  private static func makePriorDailyText(entries: [DailyStandupEntry]) -> String {
    guard !entries.isEmpty else { return "" }

    return entries.map { entry in
      let payload = entry.payloadJSON.trimmingCharacters(in: .whitespacesAndNewlines)
      return """
        Day \(entry.standupDay):
        \(payload)
        """
    }
    .joined(separator: "\n\n")
  }

  private static func makeDefaultPreferencesText() -> String {
    let preferences: [String: String] = [
      "highlights_title": "Yesterday's highlights",
      "tasks_title": "Today's tasks",
      "blockers_title": "Blockers",
    ]

    guard
      let jsonData = try? JSONSerialization.data(
        withJSONObject: preferences, options: [.sortedKeys]),
      let jsonString = String(data: jsonData, encoding: .utf8)
    else {
      return ""
    }
    return jsonString
  }

  private static func humanReadableClockTime(_ input: String) -> String {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let minuteOfDay = parseTimeHMMA(timeString: trimmed) else {
      return trimmed.lowercased()
    }

    let hour24 = (minuteOfDay / 60) % 24
    let minute = minuteOfDay % 60
    let meridiem = hour24 >= 12 ? "pm" : "am"
    let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
    return String(format: "%d:%02d%@", hour12, minute, meridiem)
  }

  private static func humanReadableClockTime(unixTimestamp: Int) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(unixTimestamp))
    let calendar = Calendar.current
    let hour24 = calendar.component(.hour, from: date)
    let minute = calendar.component(.minute, from: date)
    let meridiem = hour24 >= 12 ? "pm" : "am"
    let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
    return String(format: "%d:%02d%@", hour12, minute, meridiem)
  }

  private static func standupLine(from card: TimelineCard) -> String? {
    let trimmedTitle = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedTitle.isEmpty {
      return trimmedTitle
    }

    let trimmedSummary = card.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedSummary.isEmpty ? nil : trimmedSummary
  }

  private static func makePersistedDailyDraftJSON(from response: DayflowDailyGenerationResponse)
    -> String?
  {
    let highlights = normalizedUniqueLines(from: response.highlights).map {
      PersistedDailyBulletItem(text: $0)
    }
    let tasks = normalizedUniqueLines(from: response.unfinished).map {
      PersistedDailyBulletItem(text: $0)
    }
    let blockers = normalizedBlockersText(from: response.blockers)

    let draft = PersistedDailyStandupDraft(
      highlightsTitle: "Yesterday's highlights",
      highlights: highlights,
      tasksTitle: "Today's tasks",
      tasks: tasks,
      blockersTitle: "Blockers",
      blockersBody: blockers
    )

    guard let data = try? JSONEncoder().encode(draft) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func normalizedUniqueLines(from values: [String]) -> [String] {
    var seen: Set<String> = []
    return values.compactMap { raw in
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      guard seen.insert(trimmed).inserted else { return nil }
      return trimmed
    }
  }

  private static func normalizedBlockersText(from values: [String]) -> String {
    values
      .compactMap { value -> String? in
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
      }
      .joined(separator: "\n")
  }
}

private struct PersistedDailyBulletItem: Codable {
  let id: UUID
  let text: String

  init(text: String) {
    self.id = UUID()
    self.text = text
  }
}

private struct PersistedDailyStandupDraft: Codable {
  let highlightsTitle: String
  let highlights: [PersistedDailyBulletItem]
  let tasksTitle: String
  let tasks: [PersistedDailyBulletItem]
  let blockersTitle: String
  let blockersBody: String
}
