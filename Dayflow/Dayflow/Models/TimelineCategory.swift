import Foundation
import SwiftUI

struct TimelineCategory: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var name: String
  var colorHex: String
  var details: String
  var order: Int
  var isSystem: Bool
  var isIdle: Bool
  var isNew: Bool
  var createdAt: Date
  var updatedAt: Date

  init(
    id: UUID = UUID(),
    name: String,
    colorHex: String,
    details: String = "",
    order: Int,
    isSystem: Bool = false,
    isIdle: Bool = false,
    isNew: Bool = false,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.colorHex = colorHex
    self.details = details
    self.order = order
    self.isSystem = isSystem
    self.isIdle = isIdle
    self.isNew = isNew
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

struct LLMCategoryDescriptor: Codable, Equatable, Hashable, Sendable {
  let id: UUID
  let name: String
  let colorHex: String
  let description: String?
  let isSystem: Bool
  let isIdle: Bool
}

func firstCategoryLookup(
  from categories: [TimelineCategory],
  normalizedKey: (String) -> String
) -> [String: TimelineCategory] {
  var lookup: [String: TimelineCategory] = [:]
  lookup.reserveCapacity(categories.count)

  for category in categories {
    let key = normalizedKey(category.name)
    if lookup[key] == nil {
      lookup[key] = category
    }
  }

  return lookup
}

@MainActor
final class CategoryStore: ObservableObject {
  static let shared = CategoryStore()
  enum StoreKeys {
    static let categories = "colorCategories"
    static let hasUsedApp = "hasUsedApp"
    static let onboardingSelectedRole = "onboardingSelectedRole"
    static let onboardingAppliedCategoryPreset = "onboardingAppliedCategoryPreset"
    static let onboardingCategoriesCustomized = "onboardingCategoriesCustomized"
  }

  @Published private(set) var categories: [TimelineCategory] = []

  init() {
    load()
  }

  var editableCategories: [TimelineCategory] {
    categories.filter { !$0.isSystem }.sorted { $0.order < $1.order }
  }

  var idleCategory: TimelineCategory? {
    categories.first(where: { $0.isIdle })
  }

  func setOnboardingRole(_ role: String) {
    UserDefaults.standard.set(role, forKey: StoreKeys.onboardingSelectedRole)
  }

  func applyOnboardingPresetIfNeeded() {
    let defaults = UserDefaults.standard
    guard let roleName = defaults.string(forKey: StoreKeys.onboardingSelectedRole) else {
      return
    }

    if defaults.bool(forKey: StoreKeys.onboardingCategoriesCustomized) {
      return
    }

    let preset = OnboardingCategoryPreset(roleName: roleName)
    let appliedPreset = defaults.string(forKey: StoreKeys.onboardingAppliedCategoryPreset)

    if appliedPreset == preset.rawValue && !categories.isEmpty {
      return
    }

    categories = CategoryPersistence.ensureIdleCategoryPresent(in: preset.categories)
    save()
    defaults.set(preset.rawValue, forKey: StoreKeys.onboardingAppliedCategoryPreset)
    defaults.set(false, forKey: StoreKeys.onboardingCategoriesCustomized)
  }

  func markOnboardingCategoriesCustomized() {
    UserDefaults.standard.set(true, forKey: StoreKeys.onboardingCategoriesCustomized)
  }

  func addCategory(name: String, colorHex: String? = nil) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let nextOrder = (categories.map { $0.order }.max() ?? -1) + 1
    let now = Date()
    let category = TimelineCategory(
      name: trimmed,
      colorHex: colorHex ?? "#E5E7EB",
      details: "",
      order: nextOrder,
      isSystem: false,
      isIdle: false,
      isNew: true,
      createdAt: now,
      updatedAt: now
    )
    categories.append(category)
    save()

    if UserDefaults.standard.bool(forKey: StoreKeys.hasUsedApp) == false {
      UserDefaults.standard.set(true, forKey: StoreKeys.hasUsedApp)
    }
  }

  func updateCategory(id: UUID, mutate: (inout TimelineCategory) -> Void) {
    guard let idx = categories.firstIndex(where: { $0.id == id }) else { return }
    var category = categories[idx]
    mutate(&category)
    category.updatedAt = Date()
    category.isNew = false
    categories[idx] = category
    save()
  }

  func assignColor(_ hex: String, to id: UUID) {
    let previousHex = categories.first(where: { $0.id == id })?.colorHex
    let categoryName = categories.first(where: { $0.id == id })?.name ?? "unknown"
    updateCategory(id: id) { cat in
      cat.colorHex = hex
    }
    if hex != previousHex {
      AnalyticsService.shared.capture(
        "category_color_changed",
        [
          "category_name": categoryName,
          "color_hex": hex,
          "previous_color_hex": previousHex ?? "none",
        ])
    }
  }

  func updateDetails(_ details: String, for id: UUID) {
    updateCategory(id: id) { cat in
      cat.details = details
    }
  }

  func renameCategory(id: UUID, to newName: String) {
    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    updateCategory(id: id) { cat in
      cat.name = trimmed
    }
  }

  func removeCategory(id: UUID) {
    guard let category = categories.first(where: { $0.id == id }) else { return }
    guard category.isSystem == false else { return }
    categories.removeAll { $0.id == id }
    save()
  }

  func persist() {
    save()
  }

  private func load() {
    let decoded = CategoryPersistence.loadPersistedCategories()
    let effective = decoded.isEmpty ? CategoryPersistence.defaultCategories : decoded
    categories = CategoryPersistence.ensureIdleCategoryPresent(in: effective)
  }

  private func save() {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(categories) {
      UserDefaults.standard.set(data, forKey: StoreKeys.categories)
    }
  }

}

extension CategoryStore {
  nonisolated static func descriptorsForLLM() -> [LLMCategoryDescriptor] {
    let categories = CategoryPersistence.loadPersistedCategories()
    let effective = categories.isEmpty ? CategoryPersistence.defaultCategories : categories
    return
      effective
      .sorted { $0.order < $1.order }
      .map { category in
        LLMCategoryDescriptor(
          id: category.id,
          name: category.name,
          colorHex: category.colorHex,
          description: {
            if category.isIdle {
              return "Use when the user is idle for more than half of this period."
            }
            let trimmed = category.details.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
          }(),
          isSystem: category.isSystem,
          isIdle: category.isIdle
        )
      }
  }
}

extension CategoryStore {
  fileprivate static func ensureIdleCategoryPresent(in categories: [TimelineCategory])
    -> [TimelineCategory]
  {
    CategoryPersistence.ensureIdleCategoryPresent(in: categories)
  }
}

private enum OnboardingCategoryPreset: String {
  case softwareEngineer
  case founderExecutive
  case designer
  case student
  case productManager
  case dataScientist
  case other

  init(roleName: String) {
    switch roleName {
    case "Software Engineer":
      self = .softwareEngineer
    case "Founder / Executive":
      self = .founderExecutive
    case "Designer":
      self = .designer
    case "Student":
      self = .student
    case "Product Manager":
      self = .productManager
    case "Data Scientist":
      self = .dataScientist
    default:
      self = .other
    }
  }

  var categories: [TimelineCategory] {
    let now = Date()
    return categoryDefinitions.enumerated().map { index, definition in
      TimelineCategory(
        name: definition.name,
        colorHex: definition.colorHex,
        details: definition.details,
        order: index,
        isSystem: false,
        isIdle: false,
        isNew: false,
        createdAt: now,
        updatedAt: now
      )
    }
  }

  private var categoryDefinitions: [(name: String, colorHex: String, details: String)] {
    switch self {
    case .softwareEngineer:
      return [
        (
          "Coding / Debugging",
          "#6A7EFF",
          "Writing, refactoring, and fixing code in an IDE or terminal"
        ),
        (
          "Code Review",
          "#56CFEE",
          "Reviewing PRs, reading diffs, and leaving comments"
        ),
        (
          "Research",
          "#C787F7",
          "Reading docs, Stack Overflow, exploring tools and APIs, and writing design docs or technical specs"
        ),
        (
          "Communication",
          "#FFAE8C",
          "Meetings, standups, Slack, email, video calls, messaging, and syncs"
        ),
        (
          "Distraction",
          "#FF4721",
          "Unfocused browsing and passive content consumption: social media feeds, random videos, idle scrolling, entertainment with no clear intent, and gaming"
        ),
        (
          "Personal",
          "#ADE3E3",
          "Intentional non-work activity with a purpose: messaging friends and family, managing finances, booking travel, errands, life admin, and hobbies"
        ),
      ]

    case .founderExecutive:
      return [
        (
          "Engineering / Product",
          "#6A7EFF",
          "Coding, design work, shipping features, and hands-on building"
        ),
        (
          "Research & Strategy",
          "#56CFEE",
          "Competitive research, positioning, long-form thinking, and investor prep"
        ),
        (
          "Data & Insights",
          "#C787F7",
          "Dashboards, retention data, funnels, and financials"
        ),
        (
          "Communication",
          "#FFAE8C",
          "Team syncs, investor calls, user demos, and hiring"
        ),
        (
          "Distraction",
          "#FF4721",
          "Unfocused browsing and passive content consumption: social media feeds, random videos, idle scrolling, entertainment with no clear intent, and gaming"
        ),
        (
          "Personal",
          "#ADE3E3",
          "Intentional non-work activity with a purpose: messaging friends and family, managing finances, booking travel, errands, life admin, and hobbies"
        ),
      ]

    case .designer:
      return [
        (
          "Design",
          "#6A7EFF",
          "Prototyping, UI components, user flows, visual design, and handoff specs"
        ),
        (
          "Research",
          "#56CFEE",
          "Browsing patterns, competitive audits, user studies, and reviewing metrics"
        ),
        (
          "Communication",
          "#FFAE8C",
          "Design reviews, standups, critique sessions, and presenting concepts"
        ),
        (
          "Distraction",
          "#FF4721",
          "Unfocused browsing and passive content consumption: social media feeds, random videos, idle scrolling, entertainment with no clear intent, and gaming"
        ),
        (
          "Personal",
          "#ADE3E3",
          "Intentional non-work activity with a purpose: messaging friends and family, managing finances, booking travel, errands, life admin, and hobbies"
        ),
      ]

    case .student:
      return [
        (
          "Studying",
          "#6A7EFF",
          "Lectures, reading, reviewing slides, flashcards, and course material"
        ),
        (
          "Assignments",
          "#56CFEE",
          "Papers, problem sets, coding projects, and lab reports"
        ),
        (
          "Communication",
          "#FFAE8C",
          "Study groups, office hours, group chats, and emailing professors"
        ),
        (
          "Distraction",
          "#FF4721",
          "Unfocused browsing and passive content consumption: social media feeds, random videos, idle scrolling, entertainment with no clear intent, and gaming"
        ),
        (
          "Personal",
          "#ADE3E3",
          "Intentional non-work activity with a purpose: messaging friends and family, managing finances, booking travel, errands, life admin, and hobbies"
        ),
      ]

    case .productManager:
      return [
        (
          "Specs & Planning",
          "#6A7EFF",
          "PRDs, roadmaps, backlog grooming, sprint planning, and tickets"
        ),
        (
          "Research & Analysis",
          "#56CFEE",
          "User research, metrics review, competitive analysis, and A/B tests"
        ),
        (
          "Communication",
          "#FFAE8C",
          "Standups, stakeholder syncs, design reviews, and engineering check-ins"
        ),
        (
          "Distraction",
          "#FF4721",
          "Unfocused browsing and passive content consumption: social media feeds, random videos, idle scrolling, entertainment with no clear intent, and gaming"
        ),
        (
          "Personal",
          "#ADE3E3",
          "Intentional non-work activity with a purpose: messaging friends and family, managing finances, booking travel, errands, life admin, and hobbies"
        ),
      ]

    case .dataScientist:
      return [
        (
          "Analysis & Modeling",
          "#6A7EFF",
          "Notebooks, statistical analysis, ML training, and data exploration"
        ),
        (
          "Data Engineering",
          "#56CFEE",
          "SQL queries, pipelines, data cleaning, and ETL scripts"
        ),
        (
          "Research",
          "#C787F7",
          "Reading papers, docs, and exploring new methods and tools"
        ),
        (
          "Communication",
          "#FFAE8C",
          "Presenting findings, stakeholder syncs, and team discussions"
        ),
        (
          "Distraction",
          "#FF4721",
          "Unfocused browsing and passive content consumption: social media feeds, random videos, idle scrolling, entertainment with no clear intent, and gaming"
        ),
        (
          "Personal",
          "#ADE3E3",
          "Intentional non-work activity with a purpose: messaging friends and family, managing finances, booking travel, errands, life admin, and hobbies"
        ),
      ]

    case .other:
      return [
        (
          "Work",
          "#6A7EFF",
          "Focused work tasks and professional responsibilities that do not fit a more specific category"
        ),
        (
          "Communication",
          "#FFAE8C",
          "Meetings, standups, Slack, email, video calls, messaging, and syncs"
        ),
        (
          "Distraction",
          "#FF4721",
          "Unfocused browsing and passive content consumption: social media feeds, random videos, idle scrolling, entertainment with no clear intent, and gaming"
        ),
        (
          "Personal",
          "#ADE3E3",
          "Intentional non-work activity with a purpose: messaging friends and family, managing finances, booking travel, errands, life admin, and hobbies"
        ),
      ]
    }
  }
}

enum CategoryPersistence {
  static func loadPersistedCategories() -> [TimelineCategory] {
    guard let data = UserDefaults.standard.data(forKey: CategoryStore.StoreKeys.categories) else {
      return []
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    if let categories = try? decoder.decode([TimelineCategory].self, from: data) {
      return ensureIdleCategoryPresent(in: categories)
    }
    struct LegacyColorCategory: Codable {
      let id: Int64
      var name: String
      var color: String?
      var details: String
      var isNew: Bool?
    }
    if let legacy = try? decoder.decode([LegacyColorCategory].self, from: data) {
      var order = 0
      let converted = legacy.map { item -> TimelineCategory in
        defer { order += 1 }
        return TimelineCategory(
          id: UUID(),
          name: item.name,
          colorHex: item.color ?? "#E5E7EB",
          details: item.details,
          order: order,
          isSystem: false,
          isIdle: false,
          isNew: item.isNew ?? false
        )
      }
      return ensureIdleCategoryPresent(in: converted)
    }
    return []
  }

  static var defaultCategories: [TimelineCategory] {
    let now = Date()
    let base: [(String, String, Bool, Bool, String)] = [
      (
        "Work",
        "#B984FF",
        false,
        false,
        "Career, school, or productivity-focused activities (projects, emails, assignments, video calls, learning skills, etc.)"
      ),
      (
        "Personal",
        "#6AADFF",
        false,
        false,
        "Purposeful non-work activities or life tasks (paying bills, fitness tracking, meal planning, personal research, creative hobbies, etc.)"
      ),
      (
        "Distraction",
        "#FF5950",
        false,
        false,
        "Passive consumption or aimless browsing (scrolling feeds, watching random videos, clicking through news, mindless games, etc.)"
      ),
      (
        "Idle",
        "#A0AEC0",
        true,
        true,
        "For when the user is idle for most of the time."
      ),
    ]
    return base.enumerated().map { idx, entry in
      TimelineCategory(
        name: entry.0,
        colorHex: entry.1,
        details: entry.4,
        order: idx,
        isSystem: entry.2,
        isIdle: entry.3,
        isNew: false,
        createdAt: now,
        updatedAt: now
      )
    }
  }

  static func ensureIdleCategoryPresent(in categories: [TimelineCategory]) -> [TimelineCategory] {
    if categories.contains(where: { $0.isIdle }) {
      return categories.sorted { $0.order < $1.order }
    }

    var updated = categories
    let order = (categories.map { $0.order }.max() ?? -1) + 1
    let now = Date()
    let idle = TimelineCategory(
      name: "Idle",
      colorHex: "#A0AEC0",
      details: "Mark sessions where the user is idle for most of the time.",
      order: order,
      isSystem: true,
      isIdle: true,
      isNew: false,
      createdAt: now,
      updatedAt: now
    )
    updated.append(idle)
    return updated.sorted { $0.order < $1.order }
  }
}
