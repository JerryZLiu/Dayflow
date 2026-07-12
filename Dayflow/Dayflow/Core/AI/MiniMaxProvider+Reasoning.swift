//
//  MiniMaxProvider+Reasoning.swift
//  Dayflow
//
//  MiniMax M3 emits `<think>...</think>` reasoning blocks inside the
//  `content` field of chat completions responses. We strip those before
//  parsing/returning the answer so the downstream JSON parsers and UI
//  text consumers don't have to care about them.
//

import Foundation

enum MiniMaxReasoning {
  /// Removes one or more `<think>...</think>` blocks from the model output.
  /// Handles the case where reasoning is not closed (defensive).
  static func stripThinkTags(in text: String) -> String {
    guard !text.isEmpty else { return text }

    var result = ""
    var remaining = text

    while let openRange = remaining.range(of: "<think>") {
      // Append everything before the open tag.
      result += String(remaining[remaining.startIndex..<openRange.lowerBound])
      let afterOpen = remaining[openRange.upperBound...]

      if let closeRange = afterOpen.range(of: "</think>") {
        // Skip the entire reasoning block.
        remaining = String(afterOpen[closeRange.upperBound...])
      } else {
        // Unterminated think block — drop the rest.
        remaining = ""
        break
      }
    }

    result += remaining
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// If the response contains reasoning, return it separately from the answer.
  /// Useful for logging or surfacing a "thinking" indicator in the UI.
  static func split(_ text: String) -> (reasoning: String, answer: String) {
    guard !text.isEmpty else { return ("", "") }
    var reasoningPieces: [String] = []
    var remaining = text
    var answer = ""

    while let openRange = remaining.range(of: "<think>") {
      answer += String(remaining[remaining.startIndex..<openRange.lowerBound])
      let afterOpen = remaining[openRange.upperBound...]
      if let closeRange = afterOpen.range(of: "</think>") {
        reasoningPieces.append(String(afterOpen[afterOpen.startIndex..<closeRange.lowerBound]))
        remaining = String(afterOpen[closeRange.upperBound...])
      } else {
        reasoningPieces.append(String(afterOpen))
        remaining = ""
        break
      }
    }
    answer += remaining

    return (
      reasoning: reasoningPieces.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines),
      answer: answer.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }
}
