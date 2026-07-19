//
//  TimelineDataModels.swift
//  Dayflow
//
//  Data models for the new UI timeline components
//

import Foundation
import SwiftUI

/// Represents an activity in the timeline view
struct TimelineActivity: Identifiable {

  /// Compact "Provider · Model" string the UI can render directly next
  /// to a card (timeline list or detail panel). Returns `nil` when both
  /// the provider id and model id are missing — i.e. the card was saved
  /// before this metadata existed — so callers can simply hide the
  /// badge instead of inventing a placeholder.
  ///
  /// Provider ids stored in `metadata` are stable enum raw values
  /// (`gemini`, `ollama`, `chatgpt`, `claude`, `dayflow`,
  /// `openai_compatible`) so we map them to human-friendly labels here
  /// rather than in storage. Model ids are passed through verbatim —
  /// those are the exact strings the user picked in Settings and want to
  /// see confirmed. For Claude/Codex the user picks an *alias* (e.g.
  /// `sonnet`, `opus`, `gpt-5.6-luna`); we map the alias to a friendly
  /// display name when we recognise it, and fall back to the raw
  /// string otherwise so a new alias we haven't catalogued yet still
  /// surfaces something useful.
  var providerBadge: String? {
    let rawProvider = (providerId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let rawModel = (modelId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if rawProvider.isEmpty && rawModel.isEmpty { return nil }

    let providerLabel: String
    switch rawProvider {
    case "gemini":
      providerLabel = "Gemini"
    case "local", "ollama":
      providerLabel = "Local"
    case "chatgpt":
      providerLabel = "ChatGPT"
    case "claude":
      providerLabel = "Claude"
    case "openai_compatible":
      providerLabel = "OpenAI"
    case "dayflow":
      providerLabel = "Dayflow Pro"
    case "chatgpt_claude":
      // Legacy shared id used before ChatGPT and Claude were split.
      // Disambiguate from the model name so users still see the
      // specific tool.
      let lowered = rawModel.lowercased()
      if lowered.contains("claude") {
        providerLabel = "Claude"
      } else if lowered.contains("gpt") || lowered.contains("codex") {
        providerLabel = "ChatGPT"
      } else {
        providerLabel = "AI"
      }
    case "":
      providerLabel = "AI"
    default:
      providerLabel = rawProvider
    }

    if rawModel.isEmpty { return providerLabel }
    let displayModel = Self.prettyModelName(providerId: rawProvider, alias: rawModel)
    return "\(providerLabel) · \(displayModel)"
  }

  /// Maps a known Chat CLI alias to a friendlier display name for the
  /// card badge. Falls back to the raw alias when we don't recognise
  /// it — that keeps the badge useful when a new alias lands before
  /// Dayflow is updated.
  private static func prettyModelName(providerId: String, alias: String) -> String {
    let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
    switch providerId {
    case "claude":
      if let parsed = ClaudeModel(rawValue: trimmed) {
        return parsed.displayName
      }
      return trimmed
    case "chatgpt":
      if let parsed = CodexModel(rawValue: trimmed) {
        return parsed.displayName
      }
      return trimmed
    default:
      return trimmed
    }
  }

  let id: String
  let recordId: Int64?
  let batchId: Int64?  // Tracks source batch for retry functionality
  let startTime: Date
  let endTime: Date
  let title: String
  let summary: String
  let detailedSummary: String
  let category: String
  let subcategory: String
  let distractions: [Distraction]?
  let videoSummaryURL: String?
  let screenshot: NSImage?
  let appSites: AppSites?
  let isBackupGenerated: Bool?
  /// Which Dayflow provider produced this activity (e.g. "gemini",
  /// "ollama", "chatgpt", "claude", "dayflow", "openai_compatible").
  /// Optional because older saved cards don't carry the metadata.
  let providerId: String?
  /// Which model the provider used (e.g. "gemini-3.5-flash",
  /// "gpt-5.6-luna", "claude-sonnet-4.5"). Optional for the same
  /// reason as `providerId`.
  let modelId: String?

  static func stableId(
    recordId: Int64?, batchId: Int64?, startTime: Date, endTime: Date, title: String,
    category: String, subcategory: String
  ) -> String {
    if let recordId {
      return "record:\(recordId)"
    }
    let batchPart = batchId.map { "batch:\($0)" } ?? "batch:unknown"
    let startMs = Int64((startTime.timeIntervalSince1970 * 1000).rounded())
    let endMs = Int64((endTime.timeIntervalSince1970 * 1000).rounded())
    let contentHash = stableHash("\(title)|\(category)|\(subcategory)")
    return "\(batchPart)-\(startMs)-\(endMs)-\(contentHash)"
  }

  private static func stableHash(_ input: String) -> String {
    var hash: UInt64 = 5381
    for byte in input.utf8 {
      hash = ((hash << 5) &+ hash) &+ UInt64(byte)
    }
    return String(hash, radix: 36)
  }

  func withCategory(_ newCategory: String) -> TimelineActivity {
    TimelineActivity(
      id: id,
      recordId: recordId,
      batchId: batchId,
      startTime: startTime,
      endTime: endTime,
      title: title,
      summary: summary,
      detailedSummary: detailedSummary,
      category: newCategory,
      subcategory: subcategory,
      distractions: distractions,
      videoSummaryURL: videoSummaryURL,
      screenshot: screenshot,
      appSites: appSites,
      isBackupGenerated: isBackupGenerated,
      providerId: providerId,
      modelId: modelId
    )
  }

  func withTitle(_ newTitle: String) -> TimelineActivity {
    TimelineActivity(
      id: id,
      recordId: recordId,
      batchId: batchId,
      startTime: startTime,
      endTime: endTime,
      title: newTitle,
      summary: summary,
      detailedSummary: detailedSummary,
      category: category,
      subcategory: subcategory,
      distractions: distractions,
      videoSummaryURL: videoSummaryURL,
      screenshot: screenshot,
      appSites: appSites,
      isBackupGenerated: isBackupGenerated,
      providerId: providerId,
      modelId: modelId
    )
  }

  func withVideoSummaryURL(_ newVideoSummaryURL: String?) -> TimelineActivity {
    TimelineActivity(
      id: id,
      recordId: recordId,
      batchId: batchId,
      startTime: startTime,
      endTime: endTime,
      title: title,
      summary: summary,
      detailedSummary: detailedSummary,
      category: category,
      subcategory: subcategory,
      distractions: distractions,
      videoSummaryURL: newVideoSummaryURL,
      screenshot: screenshot,
      appSites: appSites,
      isBackupGenerated: isBackupGenerated,
      providerId: providerId,
      modelId: modelId
    )
  }
}

/// Sheet view for selecting a date
struct DatePickerSheet: View {
  @Binding var selectedDate: Date
  @Binding var isPresented: Bool

  var body: some View {
    VStack(spacing: 20) {
      Text("Select Date")
        .font(.title2)
        .fontWeight(.semibold)

      DatePicker(
        "",
        selection: $selectedDate,
        in: ...Date(),  // Only allow past dates and today
        displayedComponents: .date
      )
      .datePickerStyle(.graphical)
      .frame(width: 350)

      HStack(spacing: 12) {
        Button("Cancel") {
          isPresented = false
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.2))
        .cornerRadius(8)

        Button("Select") {
          isPresented = false
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.accentColor)
        .foregroundColor(.white)
        .cornerRadius(8)
      }
    }
    .padding(30)
    .frame(width: 420)
  }
}
