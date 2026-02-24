import Foundation

enum LocalEndpointUtilities {
  /// Builds a chat-completions endpoint URL from a user-provided base URL.
  /// The base may already include `/v1` (e.g., https://openrouter.ai/api/v1) or a full `/v1/chat/completions` path.
  static func chatCompletionsURL(baseURL: String) -> URL? {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard var components = URLComponents(string: trimmed) else { return nil }

    var normalizedPath = sanitize(components.path)
    let targetPath = "/v1/chat/completions"

    if normalizedPath.isEmpty {
      normalizedPath = targetPath
    } else if normalizedPath.hasSuffix(targetPath) {
      // already points to /v1/chat/completions – keep as-is
    } else if normalizedPath.hasSuffix("/v1") {
      normalizedPath.append(contentsOf: "/chat/completions")
    } else {
      if normalizedPath == "/" {
        normalizedPath = targetPath
      } else {
        normalizedPath.append(contentsOf: targetPath)
      }
    }

    if !normalizedPath.hasPrefix("/") {
      normalizedPath = "/" + normalizedPath
    }

    components.path = normalizedPath
    return components.url
  }

  private static func sanitize(_ path: String) -> String {
    guard !path.isEmpty else { return "" }
    var normalized = path
    while normalized.contains("//") {
      normalized = normalized.replacingOccurrences(of: "//", with: "/")
    }
    while normalized.count > 1 && normalized.hasSuffix("/") {
      normalized.removeLast()
    }
    return normalized
  }
}
