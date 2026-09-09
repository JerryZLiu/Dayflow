import Foundation

struct ActivityCardPromptOverrides: Codable, Equatable {
  var titleBlock: String?
  var summaryBlock: String?
  var detailedBlock: String?

  var isEmpty: Bool {
    let values = [titleBlock, summaryBlock, detailedBlock]
    return values.allSatisfy { value in
      let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return trimmed.isEmpty
    }
  }
}

enum ProviderPromptPreferencesError: Error {
  case encodingFailed
  case writeVerificationFailed
}
