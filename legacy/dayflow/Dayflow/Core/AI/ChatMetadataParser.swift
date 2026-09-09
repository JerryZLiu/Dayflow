//
//  ChatMetadataParser.swift
//  Dayflow
//
//  Regex extraction of the trailing ```suggestions``` and ```memory``` blocks
//  the chat prompts ask the model to emit. Pure string manipulation.
//

import Foundation

enum ChatMetadataParser {
  struct AssistantMetadata {
    let cleanedText: String
    let suggestions: [String]
    let memoryBlob: String?
  }

  static func extractTaggedBlock(from text: String, pattern: String) -> (String, String)? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard
      let match = regex.firstMatch(in: text, options: [], range: range),
      let contentRange = Range(match.range(at: 1), in: text)
    else {
      return nil
    }

    let content = String(text[contentRange])
    let stripped = regex.stringByReplacingMatches(
      in: text,
      options: [],
      range: range,
      withTemplate: ""
    )
    return (stripped, content)
  }

  static func extractLooseSuggestions(from text: String) -> (String, String)? {
    let pattern =
      "(?ims)(?:^|\\n)\\s*(?:#{1,6}\\s*Suggestions\\s*\\n+|Suggestions:\\s*\\n?)(\\[[\\s\\S]*?\\])(?=\\n\\s*(?:#{1,6}\\s*Memory\\b|Memory:)|\\z)"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard
      let match = regex.firstMatch(in: text, options: [], range: range),
      let contentRange = Range(match.range(at: 1), in: text)
    else {
      return nil
    }

    let content = String(text[contentRange])
    let stripped = regex.stringByReplacingMatches(
      in: text,
      options: [],
      range: range,
      withTemplate: "\n"
    )
    return (stripped, content)
  }

  static func extractLooseMemory(from text: String) -> (String, String)? {
    let pattern =
      "(?ims)(?:^|\\n)\\s*(?:#{1,6}\\s*Memory\\s*\\n+|Memory:\\s*\\n?)(Profile:[\\s\\S]*?Style:[^\\n]*(?:\\n[^#\\n].*)*)(?=\\z)"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard
      let match = regex.firstMatch(in: text, options: [], range: range),
      let contentRange = Range(match.range(at: 1), in: text)
    else {
      return nil
    }

    let content = String(text[contentRange])
    let stripped = regex.stringByReplacingMatches(
      in: text,
      options: [],
      range: range,
      withTemplate: "\n"
    )
    return (stripped, content)
  }

  static func stripResidualMetadataHeadings(from text: String) -> String {
    let patterns = [
      "(?im)^\\s*#{1,6}\\s*Suggestions\\s*$",
      "(?im)^\\s*#{1,6}\\s*Memory\\s*$",
      "(?im)^\\s*Suggestions:\\s*$",
      "(?im)^\\s*Memory:\\s*$",
    ]

    return patterns.reduce(text) { partial, pattern in
      guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
        return partial
      }
      let range = NSRange(partial.startIndex..., in: partial)
      return regex.stringByReplacingMatches(
        in: partial,
        options: [],
        range: range,
        withTemplate: ""
      )
    }
  }

  static func normalizeAutoMemoryBlob(_ raw: String) -> String? {
    let lines =
      raw
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    guard !lines.isEmpty else { return nil }

    var profile: String?
    var style: String?

    for line in lines {
      let lowercased = line.lowercased()
      if lowercased.hasPrefix("profile:") {
        let value = line.dropFirst("profile:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { profile = value }
      } else if lowercased.hasPrefix("style:") {
        let value = line.dropFirst("style:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { style = value }
      }
    }

    var outputLines: [String] = []
    if let profile { outputLines.append("Profile: \(profile)") }
    if let style { outputLines.append("Style: \(style)") }
    guard !outputLines.isEmpty else { return nil }
    return outputLines.joined(separator: "\n")
  }
}
