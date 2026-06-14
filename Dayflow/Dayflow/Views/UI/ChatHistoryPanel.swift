//
//  ChatHistoryPanel.swift
//  Dayflow
//
//  Side panel listing saved chat conversations, grouped by recency.
//

import SwiftUI

struct ChatHistoryPanel: View {
  let conversations: [ChatConversationRecord]
  let currentConversationID: UUID?
  let isProcessing: Bool
  let onSelect: (ChatConversationRecord) -> Void
  let onDelete: (ChatConversationRecord) -> Void
  let onNewChat: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("History")
          .font(.custom("Figtree", size: 12).weight(.bold))
          .foregroundColor(Color(hex: "666666"))

        Spacer()

        Button(action: onNewChat) {
          HStack(spacing: 4) {
            Image(systemName: "square.and.pencil")
              .font(.system(size: 10, weight: .semibold))
            Text("New chat")
              .font(.custom("Figtree", size: 11).weight(.semibold))
          }
          .foregroundColor(Color(hex: "F96E00"))
        }
        .buttonStyle(.plain)
        .disabled(isProcessing)
        .pointingHandCursor(enabled: !isProcessing)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(Color(hex: "F5F5F5"))

      Divider()

      if conversations.isEmpty {
        VStack(spacing: 6) {
          Image(systemName: "clock.arrow.circlepath")
            .font(.system(size: 20))
            .foregroundColor(Color(hex: "C9C2B8"))
          Text("No saved chats yet")
            .font(.custom("Figtree", size: 12))
            .foregroundColor(Color(hex: "999999"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(groupedConversations, id: \.title) { group in
              Text(group.title)
                .font(.custom("Figtree", size: 10).weight(.bold))
                .foregroundColor(Color(hex: "9A8B79"))
                .padding(.horizontal, 8)
                .padding(.top, 10)

              ForEach(group.conversations) { conversation in
                ChatHistoryRow(
                  conversation: conversation,
                  isCurrent: conversation.id == currentConversationID,
                  isEnabled: !isProcessing,
                  onSelect: { onSelect(conversation) },
                  onDelete: { onDelete(conversation) }
                )
              }
            }
          }
          .padding(8)
        }
      }
    }
    .frame(width: 280)
    .background(Color.white)
    .overlay(
      Rectangle()
        .fill(Color(hex: "E0E0E0"))
        .frame(width: 1),
      alignment: .leading
    )
  }

  private struct ConversationGroup {
    let title: String
    let conversations: [ChatConversationRecord]
  }

  private var groupedConversations: [ConversationGroup] {
    let calendar = Calendar.current
    let now = Date()

    var today: [ChatConversationRecord] = []
    var yesterday: [ChatConversationRecord] = []
    var thisWeek: [ChatConversationRecord] = []
    var earlier: [ChatConversationRecord] = []

    for conversation in conversations {
      if calendar.isDateInToday(conversation.updatedAt) {
        today.append(conversation)
      } else if calendar.isDateInYesterday(conversation.updatedAt) {
        yesterday.append(conversation)
      } else if let days = calendar.dateComponents(
        [.day], from: conversation.updatedAt, to: now
      ).day, days < 7 {
        thisWeek.append(conversation)
      } else {
        earlier.append(conversation)
      }
    }

    return [
      ConversationGroup(title: "TODAY", conversations: today),
      ConversationGroup(title: "YESTERDAY", conversations: yesterday),
      ConversationGroup(title: "THIS WEEK", conversations: thisWeek),
      ConversationGroup(title: "EARLIER", conversations: earlier),
    ].filter { !$0.conversations.isEmpty }
  }
}

private struct ChatHistoryRow: View {
  let conversation: ChatConversationRecord
  let isCurrent: Bool
  let isEnabled: Bool
  let onSelect: () -> Void
  let onDelete: () -> Void

  @State private var isHovered = false

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    return formatter
  }()

  private static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d"
    return formatter
  }()

  private var subtitle: String {
    let calendar = Calendar.current
    let time =
      calendar.isDateInToday(conversation.updatedAt)
        || calendar.isDateInYesterday(conversation.updatedAt)
      ? Self.timeFormatter.string(from: conversation.updatedAt)
      : Self.dayFormatter.string(from: conversation.updatedAt)
    let provider = DashboardChatProvider.fromStoredValue(conversation.provider)
    let providerLabel: String
    switch provider {
    case .gemini: providerLabel = "Gemini"
    case .codex: providerLabel = "Codex"
    case .claude: providerLabel = "Claude"
    }
    return "\(time) · \(providerLabel)"
  }

  var body: some View {
    Button(action: onSelect) {
      HStack(alignment: .top, spacing: 6) {
        VStack(alignment: .leading, spacing: 2) {
          Text(conversation.title)
            .font(.custom("Figtree", size: 12).weight(isCurrent ? .bold : .medium))
            .foregroundColor(Color(hex: isCurrent ? "C9670D" : "3A3A3A"))
            .lineLimit(2)
            .multilineTextAlignment(.leading)

          Text(subtitle)
            .font(.custom("Figtree", size: 10))
            .foregroundColor(Color(hex: "A39B90"))
        }

        Spacer(minLength: 0)

        if isHovered && isEnabled {
          Button(action: onDelete) {
            Image(systemName: "trash")
              .font(.system(size: 10))
              .foregroundColor(Color(hex: "B0655A"))
          }
          .buttonStyle(.plain)
          .pointingHandCursor()
          .accessibilityLabel(Text("Delete conversation"))
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(
            isCurrent
              ? Color(hex: "FFF4E9")
              : (isHovered ? Color(hex: "FAF7F2") : Color.clear))
      )
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .pointingHandCursor(enabled: isEnabled)
    .onHover { isHovered = $0 }
  }
}
