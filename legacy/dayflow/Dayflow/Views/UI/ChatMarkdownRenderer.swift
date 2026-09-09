//
//  ChatMarkdownRenderer.swift
//  Dayflow
//
//  Markdown rendering for dashboard chat bubbles, backed by MarkdownUI so
//  assistant replies get full GitHub-flavored markdown (tables, nested lists,
//  task lists, thematic breaks) with Dayflow's warm visual style.
//

import AppKit
import MarkdownUI
import SwiftUI

struct ChatMarkdownContentView: View {
  @Environment(\.dayflowTheme) private var theme

  let content: String

  var body: some View {
    Markdown(content)
      .markdownTheme(.dayflowChat(theme))
      .textSelection(.enabled)
  }
}

// MARK: - Dayflow chat theme

extension Theme {
  /// Matches the previous hand-rolled renderer: Figtree 13pt medium body text
  /// in #333333, warm parchment code blocks, and the soft tan quote bar.
  static func dayflowChat(_ theme: DayflowTheme) -> Theme {
    Theme()
      .text {
        FontFamily(.custom("Figtree"))
        FontSize(13)
        FontWeight(.medium)
        ForegroundColor(theme.textPrimary)
      }
      .code {
        FontFamilyVariant(.monospaced)
        FontSize(12)
        BackgroundColor(theme.chatCodeFill)
      }
      .strong {
        FontWeight(.bold)
      }
      .link {
        ForegroundColor(theme.accentText)
      }
      .paragraph { configuration in
        configuration.label
          .relativeLineSpacing(.em(0.18))
          .markdownMargin(top: 0, bottom: 8)
      }
      .heading1 { configuration in
        configuration.label
          .markdownTextStyle {
            FontSize(17)
            FontWeight(.bold)
          }
          .markdownMargin(top: 10, bottom: 4)
      }
      .heading2 { configuration in
        configuration.label
          .markdownTextStyle {
            FontSize(15)
            FontWeight(.bold)
          }
          .markdownMargin(top: 10, bottom: 4)
      }
      .heading3 { configuration in
        configuration.label
          .markdownTextStyle {
            FontSize(14)
            FontWeight(.semibold)
          }
          .markdownMargin(top: 8, bottom: 4)
      }
      .heading4 { configuration in
        configuration.label
          .markdownTextStyle {
            FontSize(13)
            FontWeight(.semibold)
          }
          .markdownMargin(top: 8, bottom: 4)
      }
      .blockquote { configuration in
        HStack(alignment: .top, spacing: 10) {
          RoundedRectangle(cornerRadius: 999)
            .fill(theme.dailyGridBorder)
            .frame(width: 4)
          configuration.label
            .markdownTextStyle {
              ForegroundColor(theme.textSecondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .markdownMargin(top: 2, bottom: 8)
      }
      .codeBlock { configuration in
        ChatCodeBlockView(configuration: configuration, theme: theme)
      }
      .listItem { configuration in
        configuration.label
          .markdownMargin(top: 3)
      }
      .table { configuration in
        configuration.label
          .markdownTableBorderStyle(.init(color: theme.dailyGridBorder))
          .markdownTableBackgroundStyle(
            .alternatingRows(Color.clear, theme.chatCodeFill)
          )
          .markdownMargin(top: 4, bottom: 8)
      }
      .tableCell { configuration in
        configuration.label
          .markdownTextStyle {
            FontSize(12.5)
            if configuration.row == 0 {
              FontWeight(.bold)
            }
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .relativeLineSpacing(.em(0.15))
      }
      .thematicBreak {
        Divider()
          .overlay(theme.dailyGridBorder)
          .markdownMargin(top: 12, bottom: 12)
      }
  }
}

// MARK: - Code block with language label and copy button

private struct ChatCodeBlockView: View {
  let configuration: CodeBlockConfiguration
  let theme: DayflowTheme

  @State private var didCopy = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        if let language = configuration.language, !language.isEmpty {
          Text(language.uppercased())
            .font(.custom("Figtree", size: 10).weight(.bold))
            .foregroundColor(theme.textMuted)
        }

        Spacer()

        Button(action: copyCode) {
          HStack(spacing: 4) {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
              .font(.system(size: 10, weight: .semibold))
            if didCopy {
              Text("Copied")
                .font(.custom("Figtree", size: 10).weight(.semibold))
            }
          }
          .foregroundColor(didCopy ? Color(hex: "34C759") : theme.textMuted)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .accessibilityLabel(Text("Copy code"))
      }
      .padding(.horizontal, 10)
      .padding(.top, 8)
      .padding(.bottom, 6)

      ScrollView(.horizontal, showsIndicators: false) {
        configuration.label
          .fixedSize(horizontal: false, vertical: true)
          .relativeLineSpacing(.em(0.2))
          .markdownTextStyle {
            FontFamilyVariant(.monospaced)
            FontSize(12)
            ForegroundColor(theme.textPrimary)
          }
          .padding(.horizontal, 10)
          .padding(.bottom, 10)
      }
    }
    .background(theme.chatCodeFill)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(theme.dailyGridBorder, lineWidth: 1)
    )
    .markdownMargin(top: 4, bottom: 8)
  }

  private func copyCode() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(
      configuration.content.trimmingCharacters(in: .whitespacesAndNewlines),
      forType: .string
    )
    didCopy = true
    Task {
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      didCopy = false
    }
  }
}
