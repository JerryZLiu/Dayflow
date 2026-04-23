import Foundation

extension GeminiDirectProvider {
  func describeDashboardFunctionCall(_ call: DashboardFunctionCall) -> String {
    let argsText =
      (try? JSONSerialization.data(withJSONObject: call.args))
      .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    return "\(call.name) \(argsText)"
  }

  func dashboardFunctionCallFingerprint(_ call: DashboardFunctionCall) -> String {
    let argsData = try? JSONSerialization.data(withJSONObject: call.args, options: [.sortedKeys])
    let argsString = argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    return "\(call.name)|\(argsString)"
  }

  func executeDashboardFunction(_ call: DashboardFunctionCall) -> [String: Any] {
    guard let toolName = DashboardToolName(rawValue: call.name) else {
      return [
        "summary": "Unknown tool '\(call.name)'.",
        "error": [
          "code": "unknown_tool",
          "message": "Unknown tool '\(call.name)'.",
        ],
      ]
    }

    do {
      switch toolName {
      case .fetchTimeline:
        return try dashboardFetchTimeline(args: call.args)
      case .fetchObservations:
        return try dashboardFetchObservations(args: call.args)
      }
    } catch {
      return [
        "summary": error.localizedDescription,
        "error": [
          "code": "validation_error",
          "message": error.localizedDescription,
        ],
      ]
    }
  }

  func dashboardFetchTimeline(args: [String: Any]) throws -> [String: Any] {
    let includeDetailedSummary = boolArg(args["includeDetailedSummary"]) ?? true
    let requestedLimit = positiveIntArg(args["limit"])
    let dateRange = try parseDashboardDateRange(args: args)

    let cards: [TimelineCard]
    if dateRange.mode == "date", let date = dateRange.date {
      cards = StorageManager.shared.fetchTimelineCards(forDay: date)
    } else {
      cards = StorageManager.shared.fetchTimelineCardsByTimeRange(
        from: dateRange.from, to: dateRange.to)
    }

    let limitedCards: [TimelineCard]
    if let requestedLimit {
      limitedCards = Array(cards.prefix(requestedLimit))
    } else {
      limitedCards = cards
    }

    var items: [[String: Any]] = limitedCards.map { card in
      var item: [String: Any] = [
        "day": card.day,
        "startTime": card.startTimestamp,
        "endTime": card.endTimestamp,
        "title": card.title,
        "summary": card.summary,
        "category": card.category,
        "subcategory": card.subcategory,
        "distractionsCount": card.distractions?.count ?? 0,
      ]

      if let appSites = card.appSites {
        item["appSites"] = [
          "primary": jsonOptional(appSites.primary),
          "secondary": jsonOptional(appSites.secondary),
        ]
      }

      if includeDetailedSummary && !card.detailedSummary.isEmpty {
        item["detailedSummary"] = card.detailedSummary
      }

      return item
    }

    var truncated = false
    if includeDetailedSummary {
      let payloadSize = (try? JSONSerialization.data(withJSONObject: items).count) ?? 0
      if payloadSize > Self.dashboardChatTimelinePayloadSoftLimitBytes {
        truncated = true
        items = items.map { row in
          var updated = row
          updated.removeValue(forKey: "detailedSummary")
          return updated
        }
      }
    }

    let dateDescription = dashboardFetchDateDescription(for: dateRange)
    var summary =
      "Fetched \(items.count) timeline card\(items.count == 1 ? "" : "s") for \(dateDescription)."
    if truncated {
      summary += " Detailed summaries were omitted due to payload size."
    }

    return [
      "request": [
        "mode": dateRange.mode,
        "date": jsonOptional(dateRange.date),
        "startDate": jsonOptional(dateRange.startDate),
        "endDate": jsonOptional(dateRange.endDate),
        "includeDetailedSummary": includeDetailedSummary,
        "limit": jsonOptional(requestedLimit),
      ],
      "summary": summary,
      "itemCount": items.count,
      "truncated": truncated,
      "items": items,
    ]
  }

  func dashboardFetchObservations(args: [String: Any]) throws -> [String: Any] {
    let requestedLimit = positiveIntArg(args["limit"])
    let dateRange = try parseDashboardDateRange(args: args)

    let observations: [Observation]
    if dateRange.mode == "date", let date = dateRange.date {
      let dayBounds = try dashboardDayBounds(for: date)
      observations = StorageManager.shared.fetchObservationsByTimeRange(
        from: dayBounds.start,
        to: dayBounds.end
      )
    } else {
      observations = StorageManager.shared.fetchObservationsByTimeRange(
        from: dateRange.from,
        to: dateRange.to
      )
    }

    let limitedObservations: [Observation]
    if let requestedLimit {
      limitedObservations = Array(observations.prefix(requestedLimit))
    } else {
      limitedObservations = observations
    }

    let effectiveObservations = limitedObservations
    let items = dashboardObservationDayGroups(from: effectiveObservations)

    let itemCount = effectiveObservations.count
    let dayCount = items.count
    let dateDescription = dashboardFetchDateDescription(for: dateRange)
    var summary =
      "Fetched \(itemCount) observation\(itemCount == 1 ? "" : "s") for \(dateDescription)"
    if dayCount > 0 {
      summary += " across \(dayCount) day\(dayCount == 1 ? "" : "s")"
    }
    summary += "."

    return [
      "request": [
        "mode": dateRange.mode,
        "date": jsonOptional(dateRange.date),
        "startDate": jsonOptional(dateRange.startDate),
        "endDate": jsonOptional(dateRange.endDate),
        "limit": jsonOptional(requestedLimit),
      ],
      "summary": summary,
      "dayCount": dayCount,
      "itemCount": itemCount,
      "truncated": false,
      "items": items,
    ]
  }

  func dashboardObservationDayGroups(from observations: [Observation]) -> [[String: Any]] {
    var groups: [[String: Any]] = []
    var currentDay: String?
    var currentDayObservations: [[String: Any]] = []

    for observation in observations {
      let start = Date(timeIntervalSince1970: TimeInterval(observation.startTs))
      let end = Date(timeIntervalSince1970: TimeInterval(observation.endTs))
      let day = start.getDayInfoFor4AMBoundary().dayString
      let item: [String: Any] = [
        "startTime": dashboardTimeFormatter.string(from: start),
        "endTime": dashboardTimeFormatter.string(from: end),
        "observation": observation.observation,
      ]

      if currentDay == day {
        currentDayObservations.append(item)
        continue
      }

      if let currentDay {
        groups.append(
          [
            "day": currentDay,
            "observations": currentDayObservations,
          ])
      }

      currentDay = day
      currentDayObservations = [item]
    }

    if let currentDay {
      groups.append(
        [
          "day": currentDay,
          "observations": currentDayObservations,
        ])
    }

    return groups
  }

  func parseDashboardDateRange(args: [String: Any]) throws -> DashboardDateRange {
    let date = stringArg(args["date"])
    let startDate = stringArg(args["startDate"])
    let endDate = stringArg(args["endDate"])

    if let date {
      if startDate != nil || endDate != nil {
        throw DashboardToolArgError.invalidCombination
      }

      let bounds = try dashboardDayBounds(for: date)
      return DashboardDateRange(
        mode: "date",
        date: date,
        startDate: nil,
        endDate: nil,
        from: bounds.start,
        to: bounds.end
      )
    }

    guard let startDate, let endDate else {
      throw DashboardToolArgError.invalidCombination
    }

    let startBounds = try dashboardDayBounds(for: startDate)
    let endBounds = try dashboardDayBounds(for: endDate)

    guard startBounds.start <= endBounds.start else {
      throw DashboardToolArgError.invalidRange
    }

    return DashboardDateRange(
      mode: "range",
      date: nil,
      startDate: startDate,
      endDate: endDate,
      from: startBounds.start,
      to: endBounds.end
    )
  }

  func dashboardDayBounds(for dateString: String) throws -> (start: Date, end: Date) {
    guard let dayDate = dashboardDateFormatter.date(from: dateString) else {
      throw DashboardToolArgError.invalidDate(dateString)
    }

    let calendar = Calendar.current
    var startComponents = calendar.dateComponents([.year, .month, .day], from: dayDate)
    startComponents.hour = 4
    startComponents.minute = 0
    startComponents.second = 0
    guard let dayStart = calendar.date(from: startComponents) else {
      throw DashboardToolArgError.invalidDate(dateString)
    }

    guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayDate) else {
      throw DashboardToolArgError.invalidDate(dateString)
    }
    var endComponents = calendar.dateComponents([.year, .month, .day], from: nextDay)
    endComponents.hour = 4
    endComponents.minute = 0
    endComponents.second = 0
    guard let dayEnd = calendar.date(from: endComponents) else {
      throw DashboardToolArgError.invalidDate(dateString)
    }

    return (dayStart, dayEnd)
  }

  func dashboardFetchDateDescription(for dateRange: DashboardDateRange) -> String {
    if dateRange.mode == "date", let date = dateRange.date {
      return formattedDashboardSingleDate(date) ?? date
    }

    if let startDate = dateRange.startDate, let endDate = dateRange.endDate {
      let formattedStart = formattedDashboardRangeDate(startDate) ?? startDate
      let formattedEnd = formattedDashboardRangeDate(endDate) ?? endDate
      return formattedStart == formattedEnd
        ? formattedStart : "\(formattedStart) to \(formattedEnd)"
    }

    return "the requested dates"
  }

  func formattedDashboardSingleDate(_ dateString: String) -> String? {
    guard let date = dashboardDateFormatter.date(from: dateString) else { return nil }
    return dashboardSingleDateDisplayFormatter.string(from: date)
  }

  func formattedDashboardRangeDate(_ dateString: String) -> String? {
    guard let date = dashboardDateFormatter.date(from: dateString) else { return nil }
    return dashboardRangeDateDisplayFormatter.string(from: date)
  }

  func stringArg(_ value: Any?) -> String? {
    guard let value else { return nil }
    if let stringValue = value as? String {
      let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    return nil
  }

  func boolArg(_ value: Any?) -> Bool? {
    guard let value else { return nil }
    if let boolValue = value as? Bool { return boolValue }
    if let numberValue = value as? NSNumber { return numberValue.boolValue }
    if let stringValue = value as? String {
      switch stringValue.lowercased() {
      case "true", "1", "yes":
        return true
      case "false", "0", "no":
        return false
      default:
        return nil
      }
    }
    return nil
  }

  func positiveIntArg(_ value: Any?) -> Int? {
    guard let value else { return nil }
    if let intValue = value as? Int {
      return intValue > 0 ? intValue : nil
    }
    if let numberValue = value as? NSNumber {
      let intValue = numberValue.intValue
      return intValue > 0 ? intValue : nil
    }
    if let stringValue = value as? String,
      let intValue = Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    {
      return intValue > 0 ? intValue : nil
    }
    return nil
  }

  func jsonOptional(_ value: Any?) -> Any {
    value ?? NSNull()
  }
}
