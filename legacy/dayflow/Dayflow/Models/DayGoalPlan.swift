import AppKit
import Foundation
import SwiftUI

enum DayGoalCategoryKind: String, CaseIterable, Sendable {
  case focus
  case distraction
}

enum DayGoalPreferences {
  static let showDailyGoalPopupsKey = "showDailyGoalPopups"

  static var showDailyGoalPopups: Bool {
    get {
      UserDefaults.standard.object(forKey: showDailyGoalPopupsKey) as? Bool ?? true
    }
    set {
      UserDefaults.standard.set(newValue, forKey: showDailyGoalPopupsKey)
    }
  }
}

struct DayGoalCategorySnapshot: Identifiable, Equatable, Sendable {
  let categoryID: String
  var name: String
  var colorHex: String
  var sortOrder: Int

  var id: String {
    categoryID
  }

  var color: Color {
    if let nsColor = NSColor(hex: colorHex) {
      return Color(nsColor: nsColor)
    }
    return .gray
  }

  init(categoryID: String, name: String, colorHex: String, sortOrder: Int) {
    self.categoryID = categoryID
    self.name = name
    self.colorHex = colorHex
    self.sortOrder = sortOrder
  }

  init(category: TimelineCategory, sortOrder: Int) {
    self.categoryID = category.id.uuidString
    self.name = category.name
    self.colorHex = category.colorHex
    self.sortOrder = sortOrder
  }
}

struct DayGoalPlan: Equatable, Sendable {
  var day: String
  var focusTargetMinutes: Int
  var distractionLimitMinutes: Int
  var focusCategories: [DayGoalCategorySnapshot]
  var distractionCategories: [DayGoalCategorySnapshot]
  var isSkipped: Bool
  var createdAt: Int
  var updatedAt: Int

  var focusTargetDuration: TimeInterval {
    TimeInterval(focusTargetMinutes * 60)
  }

  var distractionLimitDuration: TimeInterval {
    TimeInterval(distractionLimitMinutes * 60)
  }

  func forDay(_ day: String) -> DayGoalPlan {
    var copy = self
    if copy.day != day {
      copy.isSkipped = false
      copy.createdAt = 0
      copy.updatedAt = 0
    }
    copy.day = day
    return copy
  }

  func carriedForward(to day: String, categories: [TimelineCategory]) -> DayGoalPlan {
    var copy = forDay(day)
    copy.focusCategories = Self.resolvedSnapshots(
      copy.focusCategories,
      categories: categories
    )
    copy.distractionCategories = Self.resolvedSnapshots(
      copy.distractionCategories,
      categories: categories
    )
    return copy
  }

  func categorySnapshots(for kind: DayGoalCategoryKind) -> [DayGoalCategorySnapshot] {
    switch kind {
    case .focus:
      return focusCategories
    case .distraction:
      return distractionCategories
    }
  }

  static func defaultPlan(day: String, categories: [TimelineCategory]) -> DayGoalPlan {
    let now = Int(Date().timeIntervalSince1970)
    let selectable =
      categories
      .filter { $0.isSystem == false && $0.isIdle == false }
      .sorted { $0.order < $1.order }

    let distraction = selectable.filter {
      let normalized = $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      return normalized == "distraction" || normalized == "distractions"
    }

    let focusCandidates = selectable.filter { category in
      let normalized = category.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      return normalized != "distraction" && normalized != "distractions"
    }

    return DayGoalPlan(
      day: day,
      focusTargetMinutes: 270,
      distractionLimitMinutes: 120,
      focusCategories: focusCandidates.enumerated().map { index, category in
        DayGoalCategorySnapshot(category: category, sortOrder: index)
      },
      distractionCategories: distraction.enumerated().map { index, category in
        DayGoalCategorySnapshot(category: category, sortOrder: index)
      },
      isSkipped: false,
      createdAt: now,
      updatedAt: now
    )
  }

  private static func resolvedSnapshots(
    _ snapshots: [DayGoalCategorySnapshot],
    categories: [TimelineCategory]
  ) -> [DayGoalCategorySnapshot] {
    let selectable = categories.filter { $0.isSystem == false && $0.isIdle == false }
    let categoryByID = Dictionary(uniqueKeysWithValues: selectable.map { ($0.id.uuidString, $0) })
    let categoryByName = firstCategoryLookup(
      from: selectable, normalizedKey: normalizedCategoryName)

    return snapshots.map { snapshot in
      let current =
        categoryByID[snapshot.categoryID]
        ?? categoryByName[normalizedCategoryName(snapshot.name)]
      guard let current else { return snapshot }

      return DayGoalCategorySnapshot(
        categoryID: current.id.uuidString,
        name: current.name,
        colorHex: current.colorHex,
        sortOrder: snapshot.sortOrder
      )
    }
  }

  private static func normalizedCategoryName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}

struct DayGoalCategoryResult: Identifiable, Equatable, Sendable {
  let id: String
  var name: String
  var colorHex: String
  var duration: TimeInterval

  var color: Color {
    if let nsColor = NSColor(hex: colorHex) {
      return Color(nsColor: nsColor)
    }
    return .gray
  }
}

struct DayGoalReviewSnapshot: Equatable, Sendable {
  let day: String
  var plan: DayGoalPlan
  var focusDuration: TimeInterval
  var distractedDuration: TimeInterval
  var focusCategories: [DayGoalCategoryResult]

  static func empty(day: String, plan: DayGoalPlan) -> DayGoalReviewSnapshot {
    DayGoalReviewSnapshot(
      day: day,
      plan: plan,
      focusDuration: 0,
      distractedDuration: 0,
      focusCategories: []
    )
  }
}
