//
//  ChatMarkdownRenderer.swift
//  Dayflow
//
//  Lightweight markdown renderer for dashboard chat bubbles.
//

import SwiftUI

struct ChatMarkdownContentView: View {
  let content: String

  private let textColor = Color(hex: "333333")

  var body: some View {
    let blocks = ChatMarkdownParser.parse(content)

    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        ChatMarkdownBlockView(block: block, textColor: textColor)
      }
    }
    .textSelection(.enabled)
  }
}

private struct ChatMarkdownBlockView: View {
  let block: ChatMarkdownBlock
  let textColor: Color

  @ViewBuilder
  var body: some View {
    switch block {
    case .paragraph(let text):
      ChatMarkdownInlineText(
        content: text,
        font: .custom("Nunito", size: 13).weight(.medium),
        textColor: textColor
      )
    case .heading(let level, let text):
      ChatMarkdownInlineText(
        content: text,
        font: headingFont(for: level),
        textColor: textColor
      )
    case .list(let items):
      VStack(alignment: .leading, spacing: 6) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          ChatMarkdownListRow(item: item, textColor: textColor)
        }
      }
    case .quote(let text):
      HStack(alignment: .top, spacing: 10) {
        RoundedRectangle(cornerRadius: 999)
          .fill(Color(hex: "E7D7C6"))
          .frame(width: 4)

        ChatMarkdownInlineText(
          content: text,
          font: .custom("Nunito", size: 13).weight(.medium),
          textColor: Color(hex: "5A5147")
        )
      }
      .padding(.vertical, 2)
    case .codeBlock(let language, let code):
      ChatMarkdownCodeBlock(language: language, code: code)
    }
  }

  private func headingFont(for level: Int) -> Font {
    switch level {
    case 1:
      return .custom("Nunito", size: 17).weight(.bold)
    case 2:
      return .custom("Nunito", size: 15).weight(.bold)
    default:
      return .custom("Nunito", size: 14).weight(.semibold)
    }
  }
}

private struct ChatMarkdownListRow: View {
  let item: ChatMarkdownListItem
  let textColor: Color

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Text(item.marker)
        .font(.custom("Nunito", size: 13).weight(.bold))
        .foregroundColor(textColor)
        .frame(width: 18, alignment: .trailing)

      ChatMarkdownInlineText(
        content: item.content,
        font: .custom("Nunito", size: 13).weight(.medium),
        textColor: textColor
      )
    }
    .padding(.leading, CGFloat(item.indentLevel) * 16)
  }
}

private struct ChatMarkdownCodeBlock: View {
  let language: String?
  let code: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let language, !language.isEmpty {
        Text(language.uppercased())
          .font(.custom("Nunito", size: 10).weight(.bold))
          .foregroundColor(Color(hex: "9A7C60"))
      }

      ScrollView(.horizontal, showsIndicators: false) {
        Text(code)
          .font(.system(size: 12, weight: .regular, design: .monospaced))
          .foregroundColor(Color(hex: "333333"))
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .textSelection(.enabled)
    .padding(10)
    .background(Color(hex: "FAF7F2"))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(Color(hex: "E7DDD2"), lineWidth: 1)
    )
  }
}

private struct ChatMarkdownInlineText: View {
  let content: String
  let font: Font
  let textColor: Color

  var body: some View {
    parsedText
      .font(font)
      .foregroundColor(textColor)
      .lineSpacing(2)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var parsedText: Text {
    let normalized =
      content
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")

    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace
    )

    if let parsed = try? AttributedString(markdown: normalized, options: options) {
      return Text(parsed)
    }

    return Text(normalized)
  }
}

enum ChatMarkdownBlock: Equatable {
  case paragraph(String)
  case heading(level: Int, text: String)
  case list([ChatMarkdownListItem])
  case quote(String)
  case codeBlock(language: String?, code: String)
}

struct ChatMarkdownListItem: Equatable {
  let marker: String
  let indentLevel: Int
  let content: String
}

enum ChatMarkdownParser {
  static func parse(_ content: String) -> [ChatMarkdownBlock] {
    let normalized =
      content
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    let lines = normalized.components(separatedBy: "\n")

    var blocks: [ChatMarkdownBlock] = []
    var paragraphLines: [String] = []
    var index = 0

    func flushParagraph() {
      let text =
        paragraphLines
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)

      if !text.isEmpty {
        blocks.append(.paragraph(text))
      }

      paragraphLines.removeAll(keepingCapacity: true)
    }

    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      if trimmed.isEmpty {
        flushParagraph()
        index += 1
        continue
      }

      if let fence = codeFenceInfo(from: line) {
        flushParagraph()
        blocks.append(parseCodeBlock(lines: lines, index: &index, fence: fence))
        continue
      }

      if let heading = headingInfo(from: line) {
        flushParagraph()
        blocks.append(.heading(level: heading.level, text: heading.text))
        index += 1
        continue
      }

      if let listItem = listItemInfo(from: line) {
        flushParagraph()
        blocks.append(parseList(lines: lines, index: &index, firstItem: listItem))
        continue
      }

      if isQuoteLine(line) {
        flushParagraph()
        blocks.append(parseQuote(lines: lines, index: &index))
        continue
      }

      paragraphLines.append(line.trimmingCharacters(in: .whitespaces))
      index += 1
    }

    flushParagraph()

    return blocks
  }

  private static func parseList(
    lines: [String],
    index: inout Int,
    firstItem: ListItemMatch
  ) -> ChatMarkdownBlock {
    var items: [ChatMarkdownListItem] = []
    let listKind = firstItem.kind

    while index < lines.count {
      guard let item = listItemInfo(from: lines[index]), item.kind == listKind else { break }

      var contentLines = [item.content]
      let baseIndent = item.leadingSpaces
      index += 1

      while index < lines.count {
        let nextLine = lines[index]
        let trimmed = nextLine.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty
          || codeFenceInfo(from: nextLine) != nil
          || headingInfo(from: nextLine) != nil
          || isQuoteLine(nextLine)
          || listItemInfo(from: nextLine) != nil
        {
          break
        }

        if leadingSpaceCount(in: nextLine) > baseIndent {
          contentLines.append(trimmed)
          index += 1
          continue
        }

        break
      }

      items.append(
        ChatMarkdownListItem(
          marker: item.marker,
          indentLevel: max(0, item.leadingSpaces / 2),
          content: contentLines.joined(separator: "\n")
        ))
    }

    return .list(items)
  }

  private static func parseQuote(lines: [String], index: inout Int) -> ChatMarkdownBlock {
    var quoteLines: [String] = []

    while index < lines.count, isQuoteLine(lines[index]) {
      var line = lines[index].trimmingCharacters(in: .whitespaces)
      line.removeFirst()
      quoteLines.append(line.trimmingCharacters(in: .whitespaces))
      index += 1
    }

    return .quote(quoteLines.joined(separator: "\n"))
  }

  private static func parseCodeBlock(
    lines: [String],
    index: inout Int,
    fence: CodeFence
  ) -> ChatMarkdownBlock {
    var codeLines: [String] = []
    index += 1

    while index < lines.count {
      if isFenceClosingLine(lines[index]) {
        index += 1
        break
      }

      codeLines.append(lines[index])
      index += 1
    }

    return .codeBlock(language: fence.language, code: codeLines.joined(separator: "\n"))
  }

  private static func headingInfo(from line: String) -> (level: Int, text: String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("#") else { return nil }

    let level = trimmed.prefix(while: { $0 == "#" }).count
    guard (1...6).contains(level) else { return nil }

    let contentStart = trimmed.index(trimmed.startIndex, offsetBy: level)
    guard contentStart < trimmed.endIndex, trimmed[contentStart] == " " else { return nil }

    let text = trimmed[contentStart...].trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }

    return (level, text)
  }

  private static func codeFenceInfo(from line: String) -> CodeFence? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("```") else { return nil }

    let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
    return CodeFence(language: language.isEmpty ? nil : language)
  }

  private static func isFenceClosingLine(_ line: String) -> Bool {
    line.trimmingCharacters(in: .whitespaces) == "```"
  }

  private static func isQuoteLine(_ line: String) -> Bool {
    line.trimmingCharacters(in: .whitespaces).hasPrefix(">")
  }

  private static func listItemInfo(from line: String) -> ListItemMatch? {
    let leadingSpaces = leadingSpaceCount(in: line)
    let trimmedLeading = line.dropFirst(leadingSpaces)

    if let remainder = trimmedLeading.dropMarkdownListPrefix("-")
      ?? trimmedLeading.dropMarkdownListPrefix("*")
      ?? trimmedLeading.dropMarkdownListPrefix("+")
    {
      return ListItemMatch(
        kind: .unordered,
        leadingSpaces: leadingSpaces,
        marker: "•",
        content: String(remainder)
      )
    }

    let digits = trimmedLeading.prefix(while: { $0.isNumber })
    guard !digits.isEmpty else { return nil }

    let dotIndex = trimmedLeading.index(trimmedLeading.startIndex, offsetBy: digits.count)
    guard dotIndex < trimmedLeading.endIndex, trimmedLeading[dotIndex] == "." else { return nil }

    let contentStart = trimmedLeading.index(after: dotIndex)
    guard contentStart < trimmedLeading.endIndex, trimmedLeading[contentStart] == " " else {
      return nil
    }

    let content = trimmedLeading[contentStart...].trimmingCharacters(in: .whitespaces)
    guard !content.isEmpty else { return nil }

    return ListItemMatch(
      kind: .ordered,
      leadingSpaces: leadingSpaces,
      marker: "\(digits).",
      content: content
    )
  }

  private static func leadingSpaceCount(in line: String) -> Int {
    line.prefix(while: { $0 == " " }).count
  }

  private struct CodeFence {
    let language: String?
  }

  private struct ListItemMatch {
    let kind: ListKind
    let leadingSpaces: Int
    let marker: String
    let content: String
  }

  private enum ListKind {
    case unordered
    case ordered
  }
}

extension Substring {
  fileprivate func dropMarkdownListPrefix(_ marker: Character) -> Substring? {
    guard first == marker else { return nil }

    let markerEnd = index(after: startIndex)
    guard markerEnd < endIndex, self[markerEnd] == " " else { return nil }

    let content = self[markerEnd...].trimmingCharacters(in: .whitespaces)
    guard !content.isEmpty else { return nil }

    return content[...]
  }
}
