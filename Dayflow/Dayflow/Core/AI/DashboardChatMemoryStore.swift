//
//  DashboardChatMemoryStore.swift
//  Dayflow
//
//  Persists a single dashboard chat memory blob.
//

import Foundation

enum DashboardChatMemoryStore {
  static let maxCharacters = 10_000

  private static let memoryKey = "dashboardChatMemoryBlob"
  private static let updatedAtKey = "dashboardChatMemoryUpdatedAt"
  private static let store = UserDefaults.standard

  static func load() -> String {
    (store.string(forKey: memoryKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func save(_ text: String) {
    let normalized = normalize(text)
    if normalized.isEmpty {
      clear()
      return
    }
    store.set(normalized, forKey: memoryKey)
    store.set(Date(), forKey: updatedAtKey)
  }

  static func clear() {
    store.removeObject(forKey: memoryKey)
    store.removeObject(forKey: updatedAtKey)
  }

  static func lastUpdatedAt() -> Date? {
    store.object(forKey: updatedAtKey) as? Date
  }

  private static func normalize(_ input: String) -> String {
    var text =
      input
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    while text.contains("\n\n\n") {
      text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }

    if text.count > maxCharacters {
      text = String(text.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return text
  }
}
