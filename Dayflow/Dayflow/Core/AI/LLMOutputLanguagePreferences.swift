import Foundation

enum LLMOutputLanguagePreferences {
  private static let overrideKey = "llmOutputLanguageOverride"
  private static let store = UserDefaults.standard

  static var override: String {
    get { store.string(forKey: overrideKey) ?? "" }
    set { store.set(newValue, forKey: overrideKey) }
  }

  static var normalizedOverride: String? {
    let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.lowercased() == "english" {
      return nil
    }
    return trimmed
  }

  static func languageInstruction(forJSON: Bool) -> String? {
    guard let lang = normalizedOverride else { return nil }
    let verbatimClause =
      "If any rule requires an exact English phrase (e.g., \"Scattered apps and sites\"), keep it verbatim."
    if forJSON {
      return
        "The user only speaks \(lang). Respond in \(lang), but keep JSON keys in English exactly as specified. \(verbatimClause)"
    }
    return "The user only speaks \(lang). Respond in \(lang). \(verbatimClause)"
  }
}
