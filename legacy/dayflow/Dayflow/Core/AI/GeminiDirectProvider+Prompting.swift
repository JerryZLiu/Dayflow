import Foundation

extension GeminiDirectProvider {
  func categoriesSection(from descriptors: [LLMCategoryDescriptor]) -> String {
    guard !descriptors.isEmpty else {
      return
        "USER CATEGORIES: No categories configured. Use consistent labels based on the activity story."
    }

    let allowed = descriptors.map { "\"\($0.name)\"" }.joined(separator: ", ")
    var lines: [String] = ["USER CATEGORIES (choose exactly one label):"]

    for (index, descriptor) in descriptors.enumerated() {
      var desc = descriptor.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if descriptor.isIdle && desc.isEmpty {
        desc = "Use when the user is idle for most of this period."
      }
      let suffix = desc.isEmpty ? "" : " — \(desc)"
      lines.append("\(index + 1). \"\(descriptor.name)\"\(suffix)")
    }

    if let idle = descriptors.first(where: { $0.isIdle }) {
      lines.append(
        "Only use \"\(idle.name)\" when the user is idle for more than half of the timeframe. Otherwise pick the closest non-idle label."
      )
    }

    lines.append("Return the category exactly as written. Allowed values: [\(allowed)].")
    return lines.joined(separator: "\n")
  }

  func normalizeCategory(_ raw: String, descriptors: [LLMCategoryDescriptor]) -> String {
    let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return descriptors.first?.name ?? "" }
    let normalized = cleaned.lowercased()
    if let match = descriptors.first(where: {
      $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
    }) {
      return match.name
    }
    if let idle = descriptors.first(where: { $0.isIdle }) {
      let idleLabels = ["idle", "idle time", idle.name.lowercased()]
      if idleLabels.contains(normalized) {
        return idle.name
      }
    }
    return descriptors.first?.name ?? cleaned
  }

  func normalizeCards(_ cards: [ActivityCardData], descriptors: [LLMCategoryDescriptor])
    -> [ActivityCardData]
  {
    cards.map { card in
      ActivityCardData(
        startTime: card.startTime,
        endTime: card.endTime,
        category: normalizeCategory(card.category, descriptors: descriptors),
        subcategory: card.subcategory,
        title: card.title,
        summary: card.summary,
        detailedSummary: card.detailedSummary,
        distractions: card.distractions,
        appSites: card.appSites
      )
    }
  }
}
