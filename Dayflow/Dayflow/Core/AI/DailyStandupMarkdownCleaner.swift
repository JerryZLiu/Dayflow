import Foundation

enum DailyStandupMarkdownCleaner {
  static func clean(_ raw: String) -> String? {
    let normalized =
      raw
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")

    let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).compactMap {
      cleanLine(String($0))
    }

    let cleaned = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? nil : cleaned
  }

  private static func cleanLine(_ raw: String) -> String? {
    var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty else { return nil }

    line = replace("^>+\\s*", in: line, with: "")
    line = replace("^#{1,6}\\s*", in: line, with: "")
    line = replace("^[-*+]\\s+\\[[ xX]\\]\\s*", in: line, with: "")
    line = replace("^([-*+]|\\d+[.)])\\s+", in: line, with: "")
    line = replace("!\\[([^\\]]*)\\]\\([^)]*\\)", in: line, with: "$1")
    line = replace("\\[([^\\]]+)\\]\\([^)]*\\)", in: line, with: "$1")
    line = replace("`([^`]+)`", in: line, with: "$1")
    line = replace("\\*\\*([^*]+)\\*\\*", in: line, with: "$1")
    line = replace("__(.+?)__", in: line, with: "$1")
    line = replace("\\*([^*]+)\\*", in: line, with: "$1")
    line = replace("_(.+?)_", in: line, with: "$1")
    line = replace("~~(.+?)~~", in: line, with: "$1")
    line = line.replacingOccurrences(of: "\\", with: "")
    line = line.trimmingCharacters(in: .whitespacesAndNewlines)
    line = line.trimmingCharacters(in: CharacterSet(charactersIn: "#*-_`> "))

    return line.isEmpty ? nil : line
  }

  private static func replace(_ pattern: String, in text: String, with template: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
  }
}
