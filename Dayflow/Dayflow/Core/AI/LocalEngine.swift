import Foundation

enum LocalEngine: String, CaseIterable, Identifiable, Codable {
  case ollama
  case lmstudio
  case custom

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .ollama: return "Ollama"
    case .lmstudio: return "LM Studio"
    case .custom: return "Custom"
    }
  }

  var defaultBaseURL: String {
    switch self {
    case .ollama: return "http://localhost:11434"
    case .lmstudio: return "http://localhost:1234"
    case .custom: return "http://localhost:11434"
    }
  }
}
