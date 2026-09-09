//
//  AgentWriteHandlers.swift
//  Dayflow
//
//  The write operations the agent bridge accepts, mapped onto the same code
//  paths the UI uses: CategoryStore for categories, StorageManager for cards
//  and goals. A fixed verb list, not arbitrary SQL, on purpose.
//

import Foundation

struct AgentWriteError: Error {
  let code: String
  let message: String
}

@MainActor
enum AgentWriteHandlers {

  struct ActivityUpdateRequest: Equatable {
    let recordId: Int64
    let title: String?
    let category: String?

    var changeDescriptions: [String] {
      var changes: [String] = []
      if title != nil { changes.append("title") }
      if let category { changes.append("category → \(category)") }
      return changes
    }
  }

  static func handle(operation: String, arguments: [String: Any]) throws -> [String: Any] {
    switch operation {
    case "category_add": return try categoryAdd(arguments)
    case "category_update": return try categoryUpdate(arguments)
    case "category_remove": return try categoryRemove(arguments)
    case "activity_update": return try activityUpdate(arguments)
    case "activity_delete": return try activityDelete(arguments)
    case "goal_set": return try goalSet(arguments)
    default:
      throw AgentWriteError(code: "unknown_operation", message: "Unknown operation: \(operation)")
    }
  }

  // MARK: - Categories

  private static func resolveCategory(named name: String) throws -> TimelineCategory {
    let matches = CategoryStore.shared.categories.filter {
      $0.name.caseInsensitiveCompare(name) == .orderedSame
    }
    guard let category = matches.first else {
      let names = CategoryStore.shared.categories.map(\.name).joined(separator: ", ")
      throw AgentWriteError(
        code: "not_found", message: "No category named \"\(name)\". Categories: \(names)")
    }
    guard matches.count == 1 else {
      throw AgentWriteError(
        code: "ambiguous", message: "More than one category matches \"\(name)\".")
    }
    return category
  }

  private static func validateHex(_ value: String) throws -> String {
    let hex = value.hasPrefix("#") ? value : "#\(value)"
    let digits = hex.dropFirst()
    guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else {
      throw AgentWriteError(
        code: "invalid_argument", message: "\"\(value)\" is not a hex color like #F96E00.")
    }
    return hex.uppercased()
  }

  private static func categoryAdd(_ arguments: [String: Any]) throws -> [String: Any] {
    guard let name = (arguments["name"] as? String)?.trimmingCharacters(in: .whitespaces),
      !name.isEmpty
    else {
      throw AgentWriteError(code: "invalid_argument", message: "A category name is required.")
    }
    if CategoryStore.shared.categories.contains(where: {
      $0.name.caseInsensitiveCompare(name) == .orderedSame
    }) {
      throw AgentWriteError(
        code: "already_exists", message: "A category named \"\(name)\" already exists.")
    }

    let color = try (arguments["color"] as? String).map(validateHex)
    CategoryStore.shared.addCategory(name: name, colorHex: color)

    if let description = arguments["description"] as? String,
      let created = try? resolveCategory(named: name)
    {
      CategoryStore.shared.updateDetails(description, for: created.id)
    }
    return ["message": "Created \(name)"]
  }

  private static func categoryUpdate(_ arguments: [String: Any]) throws -> [String: Any] {
    guard let name = arguments["name"] as? String else {
      throw AgentWriteError(code: "invalid_argument", message: "A category name is required.")
    }
    let category = try resolveCategory(named: name)
    var changes: [String] = []

    if let newName = (arguments["new_name"] as? String)?.trimmingCharacters(in: .whitespaces),
      !newName.isEmpty, newName != category.name
    {
      CategoryStore.shared.renameCategory(id: category.id, to: newName)
      changes.append("renamed to \(newName)")
    }
    if let colorText = arguments["color"] as? String {
      let color = try validateHex(colorText)
      CategoryStore.shared.assignColor(color, to: category.id)
      changes.append("color \(color)")
    }
    if let description = arguments["description"] as? String {
      CategoryStore.shared.updateDetails(description, for: category.id)
      changes.append("description updated")
    }

    guard !changes.isEmpty else {
      throw AgentWriteError(
        code: "invalid_argument",
        message: "Nothing to change. Pass new_name, color, or description."
      )
    }
    return ["message": "\(category.name): \(changes.joined(separator: ", "))"]
  }

  private static func categoryRemove(_ arguments: [String: Any]) throws -> [String: Any] {
    guard let name = arguments["name"] as? String else {
      throw AgentWriteError(code: "invalid_argument", message: "A category name is required.")
    }
    let category = try resolveCategory(named: name)
    guard !category.isSystem else {
      throw AgentWriteError(
        code: "permission_denied", message: "\"\(category.name)\" is a system category.")
    }

    let affected =
      StorageManager.shared.countTimelineCards(inCategory: category.name)
    CategoryStore.shared.removeCategory(id: category.id)
    return [
      "message":
        "Removed \(category.name). \(affected) past activities keep the label but lose the color.",
      "affected_activities": affected,
    ]
  }

  // MARK: - Activities

  private static func activityUpdate(_ arguments: [String: Any]) throws -> [String: Any] {
    let request = try validatedActivityUpdate(arguments) { name in
      try resolveCategory(named: name).name
    }

    try StorageManager.shared.updateTimelineCard(
      cardId: request.recordId,
      title: request.title,
      category: request.category
    )
    NotificationCenter.default.post(name: .timelineCardUpdatedExternally, object: nil)
    return [
      "message":
        "Updated \(request.recordId): \(request.changeDescriptions.joined(separator: ", "))"
    ]
  }

  static func validatedActivityUpdate(
    _ arguments: [String: Any],
    resolveCategoryName: (String) throws -> String
  ) throws -> ActivityUpdateRequest {
    guard let recordId = arguments["record_id"] as? Int else {
      throw AgentWriteError(code: "invalid_argument", message: "record_id is required.")
    }

    let trimmedTitle =
      (arguments["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = trimmedTitle?.isEmpty == false ? trimmedTitle : nil

    var category: String?
    if let categoryName = arguments["category"] as? String {
      // Resolve every requested value before the database write so a typo can't partially apply.
      category = try resolveCategoryName(categoryName)
    }

    guard title != nil || category != nil else {
      throw AgentWriteError(
        code: "invalid_argument", message: "Nothing to change. Pass title and/or category.")
    }

    return ActivityUpdateRequest(
      recordId: Int64(recordId),
      title: title,
      category: category
    )
  }

  private static func activityDelete(_ arguments: [String: Any]) throws -> [String: Any] {
    guard let recordId = arguments["record_id"] as? Int else {
      throw AgentWriteError(code: "invalid_argument", message: "record_id is required.")
    }
    let videoPath = StorageManager.shared.deleteTimelineCard(recordId: Int64(recordId))
    if let videoPath, !videoPath.isEmpty {
      try? FileManager.default.removeItem(atPath: videoPath)
    }
    NotificationCenter.default.post(name: .timelineCardUpdatedExternally, object: nil)
    return ["message": "Deleted activity \(recordId)"]
  }

  // MARK: - Goals

  private static func goalSet(_ arguments: [String: Any]) throws -> [String: Any] {
    guard let focusMinutes = arguments["focus_minutes"] as? Int, focusMinutes > 0 else {
      throw AgentWriteError(
        code: "invalid_argument", message: "A positive focus_minutes value is required.")
    }
    let day = try resolvedGoalDay(arguments)

    let existing = StorageManager.shared.fetchDayGoalPlan(forDay: day)
    let limit =
      arguments["distraction_limit_minutes"] as? Int
      ?? existing?.distractionLimitMinutes ?? 60

    func snapshots(fromNames key: String, fallback: [DayGoalCategorySnapshot]) throws
      -> [DayGoalCategorySnapshot]
    {
      guard let names = arguments[key] as? [String] else { return fallback }
      return try names.enumerated().map { index, name in
        DayGoalCategorySnapshot(category: try resolveCategory(named: name), sortOrder: index)
      }
    }

    let plan = DayGoalPlan(
      day: day,
      focusTargetMinutes: focusMinutes,
      distractionLimitMinutes: limit,
      focusCategories: try snapshots(
        fromNames: "focus_categories", fallback: existing?.focusCategories ?? []),
      distractionCategories: try snapshots(
        fromNames: "distraction_categories", fallback: existing?.distractionCategories ?? []),
      isSkipped: false,
      createdAt: existing?.createdAt ?? 0,
      updatedAt: 0
    )
    StorageManager.shared.saveDayGoalPlan(plan)
    return [
      "message":
        "\(day): \(focusMinutes)m focus target, \(limit)m distraction limit"
    ]
  }

  static func resolvedGoalDay(_ arguments: [String: Any], now: Date = Date()) throws -> String {
    guard let suppliedDate = arguments["date"] else {
      return now.getDayInfoFor4AMBoundary().dayString
    }
    guard let date = suppliedDate as? String else {
      throw AgentWriteError(
        code: "invalid_argument", message: "date must be a YYYY-MM-DD string when provided.")
    }

    let trimmedDate = date.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedDate.isEmpty else {
      throw AgentWriteError(
        code: "invalid_argument", message: "date cannot be empty when provided.")
    }
    return trimmedDate
  }
}

extension Notification.Name {
  /// Posted after the agent bridge changes timeline data, so open views refresh.
  static let timelineCardUpdatedExternally = Notification.Name("timelineCardUpdatedExternally")
}
