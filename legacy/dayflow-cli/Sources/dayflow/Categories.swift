//
//  Categories.swift
//  dayflow-cli
//
//  Categories live in the app's preferences (the `colorCategories` key in
//  teleportlabs.com.Dayflow), not in SQLite. We read that domain directly —
//  reads across processes are what CFPreferences is for — and fall back to
//  the app's own default set when the key is absent, which is exactly what
//  CategoryStore does on load.
//

import Foundation

struct Category {
  let name: String
  let colorHex: String
  let isSystem: Bool
  let isIdle: Bool
}

private let dayflowDefaultsDomain = "teleportlabs.com.Dayflow"

/// Matches CategoryPersistence.defaultCategories in the app.
private let defaultCategories: [Category] = [
  Category(
    name: "Work", colorHex: "#B984FF", isSystem: false, isIdle: false),
  Category(
    name: "Personal", colorHex: "#6AADFF", isSystem: false, isIdle: false),
  Category(
    name: "Distraction", colorHex: "#FF5950", isSystem: false, isIdle: false),
  Category(
    name: "Idle", colorHex: "#A0AEC0", isSystem: true, isIdle: true),
]

func loadCategories() -> [Category] {
  // The stored value is a JSON-encoded [TimelineCategory] written by the app.
  guard
    let defaults = UserDefaults(suiteName: dayflowDefaultsDomain),
    let data = defaults.data(forKey: "colorCategories")
  else { return defaultCategories }

  struct StoredCategory: Decodable {
    let name: String
    let colorHex: String
    let order: Int?
    let isSystem: Bool?
    let isIdle: Bool?
  }

  guard let stored = try? JSONDecoder().decode([StoredCategory].self, from: data),
    !stored.isEmpty
  else { return defaultCategories }

  return
    stored
    .sorted { ($0.order ?? 0) < ($1.order ?? 0) }
    .map {
      Category(
        name: $0.name,
        colorHex: $0.colorHex,
        isSystem: $0.isSystem ?? false,
        isIdle: $0.isIdle ?? false
      )
    }
}
