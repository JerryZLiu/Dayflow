//
//  DocketListView.swift
//  Dayflow
//
//  The docket as a list: every task today with its prompt and where it stands (New,
//  Dismissed, In progress, Ready for review, Reviewed). Clicking a row's title opens it to
//  show its counts, the full, editable prompt and the count panels.
//

import SwiftUI

struct DocketListView: View {
  @ObservedObject private var store = DailyBriefStore.shared
  /// Only one row is open at a time.
  @State private var openTitle: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 0) {
        header("Title").frame(width: 400, alignment: .leading)
        header("Agent prompt").frame(width: 298, alignment: .leading)
        header("Status")
        Spacer(minLength: 0)
      }
      .padding(.bottom, 8)

      ForEach(store.docketItems, id: \.title) { item in
        DocketListRow(
          item: item,
          isOpen: openTitle == item.title,
          toggle: {
            withAnimation(DocketMotion.ease(0.28)) {
              openTitle = openTitle == item.title ? nil : item.title
            }
          })
      }
    }
    .padding(.vertical, 20)
    .padding(.horizontal, 24)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(Color(red: 1, green: 248 / 255, blue: 246 / 255).opacity(0.8))
        .shadow(color: Color.black.opacity(0.1), radius: 4, y: 2)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .strokeBorder(Color(hex: "FAFAFA"), lineWidth: 1)
    )
    .onAppear { store.refreshDocketRuns() }
  }

  private func header(_ text: String) -> some View {
    Text(text.uppercased())
      .font(DailyBriefFonts.sans(11, weight: .bold))
      .foregroundStyle(DocketColors.labelOpen)
  }
}

// MARK: - Row

private struct DocketListRow: View {
  let item: DailyBriefDocketItem
  let isOpen: Bool
  let toggle: () -> Void

  @ObservedObject private var store = DailyBriefStore.shared
  @State private var isHovered = false
  @State private var panel: DocketPanel?
  @State private var isEditing = false
  @State private var draft = ""
  @FocusState private var isFocused: Bool

  /// Hovering only shows the chevron and the hand-off button, so rows don't change
  /// height as the pointer moves over the list.
  private var showsChevron: Bool { isHovered || isOpen }

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      titleColumn
        .frame(width: 400, alignment: .leading)
      promptColumn
        .frame(width: 298, alignment: .leading)
      statusColumn
        .padding(.top, 5)
      Spacer(minLength: 0)
    }
    .padding(.top, 7.75)
    .padding(.bottom, 15.75)
    .frame(minHeight: 50, alignment: .top)
    .overlay(alignment: .top) {
      Rectangle().fill(DocketColors.divider).frame(height: 1)
    }
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .onChange(of: isOpen) { _, open in
      if !open {
        panel = nil
        finishEditing()
      }
    }
  }

  // MARK: Title

  private var titleColumn: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button(action: toggle) {
        Text(item.title)
          .font(DailyBriefFonts.sans(15))
          .foregroundStyle(DocketColors.title)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .pointingHandCursor()
      .overlay(alignment: .topLeading) {
        Button(action: toggle) {
          Image("DocketChevron16")
            .resizable()
            .frame(width: 16, height: 16)
            .rotationEffect(.degrees(isOpen ? -90 : 90))
            .animation(DocketMotion.ease(0.2), value: isOpen)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(showsChevron ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: showsChevron)
        .offset(x: -19, y: -1)
      }

      if isOpen {
        DocketCountsRow(
          item: item, panel: $panel,
          openFill: Color(red: 150 / 255, green: 100 / 255, blue: 90 / 255).opacity(0.03)
        )
        .frame(height: 16)
        .padding(.top, 8)
        .padding(.leading, 6)
        .transition(.opacity.combined(with: .offset(y: -4)))
      }

      if isOpen, let panel {
        DocketPanelView(item: item, panel: panel, isList: true)
          .frame(width: 384, alignment: .leading)
          .frame(maxHeight: 200, alignment: .top)
          .padding(.top, 10)
          .transition(DocketPanelView.unroll)
          .id(panel)
      }
    }
    .padding(.top, 8.5)
    .padding(.trailing, 24)
  }

  // MARK: Prompt

  private var promptColumn: some View {
    Group {
      if isOpen && isEditing {
        TextEditor(text: $draft)
          .font(DailyBriefFonts.sans(12))
          .foregroundStyle(DocketColors.promptOpen)
          .scrollContentBackground(.hidden)
          .scrollIndicators(.hidden)
          .focused($isFocused)
          .frame(height: 190)
          .padding(.vertical, 8)
          .padding(.horizontal, 7)
          .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.4))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
              .strokeBorder(Color(hex: "EFE7E2"), lineWidth: 1)
          )
          .shadow(color: Color(red: 1, green: 114 / 255, blue: 43 / 255).opacity(0.25), radius: 2.5)
          .padding(.horizontal, -7)
          .padding(.top, -8)
          .onAppear {
            draft = store.docketPrompt(for: item)
            isFocused = true
          }
          .onChange(of: isFocused) { _, focused in
            if !focused { finishEditing() }
          }
      } else if isOpen {
        ScrollView(.vertical) {
          promptText.padding(.bottom, 22)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: 190)
        .fixedSize(horizontal: false, vertical: true)
        .mask(
          LinearGradient(
            stops: [.init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
            startPoint: .top, endPoint: .bottom)
        )
        .contentShape(Rectangle())
        .onTapGesture { isEditing = true }
        .help("Click to edit")
      } else {
        promptText
          .lineLimit(1)
          .onTapGesture(perform: toggle)
      }
    }
    .padding(.top, 10.75)
    .padding(.horizontal, 7)
    .padding(.bottom, isOpen ? 5 : 0)
    .frame(width: 266, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.1))
    )
  }

  private var promptText: some View {
    Text(store.docketPrompt(for: item))
      .font(DailyBriefFonts.sans(12))
      .lineSpacing(2)
      .foregroundStyle(DocketColors.promptOpen)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func finishEditing() {
    guard isEditing else { return }
    store.setDocketPrompt(draft, for: item)
    isEditing = false
  }

  // MARK: Status

  private var statusColumn: some View {
    let status = store.docketStatus(for: item.title)
    return HStack(spacing: 8) {
      DocketStatusTag(title: item.title, status: status, isRowHovered: isHovered)
      if isHovered, status == .new || status == .dismissed {
        DocketListHandOffButton { store.handOffDocket(item) }
          .transition(.opacity)
      }
    }
    .animation(.easeOut(duration: 0.15), value: isHovered)
  }
}

// MARK: - Status tag

struct DocketStatusTag: View {
  let title: String
  let status: DailyBriefStore.DocketStatus
  var isRowHovered = false

  @ObservedObject private var store = DailyBriefStore.shared

  var body: some View {
    switch status {
    case .new:
      tag("New", fill: "FFE6D3") {
        Image(systemName: "rectangle.stack")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(DocketColors.ink)
      }
    case .dismissed:
      tag("Dismissed", fill: "ECE7E6") {
        Image(systemName: "arrow.uturn.backward")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(DocketColors.ink)
      }
    case .inProgress(let agent):
      agentTag("In progress", fill: "FFEDCF", agent: agent)
    case .ready(let agent):
      agentTag("Ready for review", fill: "E0F2EC", agent: agent)
    case .reviewed(let agent):
      agentTag("Reviewed", fill: "E7F0F9", agent: agent)
    case .failed(let agent):
      agentTag("Didn't finish", fill: "F9E1E1", agent: agent)
    }
  }

  private func tag<Icon: View>(
    _ label: String, fill: String, spacing: CGFloat = 6, @ViewBuilder icon: () -> Icon
  )
    -> some View
  {
    HStack(spacing: spacing) {
      icon().frame(width: 12, height: 12)
      Text(label)
        .font(DailyBriefFonts.sans(14))
        .foregroundStyle(DocketColors.ink)
    }
    .padding(.vertical, 4)
    .padding(.horizontal, 6)
    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(hex: fill)))
  }

  /// A handed-off tag opens what the agent did; opening a ready one marks it reviewed.
  private func agentTag(_ label: String, fill: String, agent: DailyBriefAgent) -> some View {
    Button {
      store.openDocketResult(title)
    } label: {
      HStack(spacing: 2) {
        tag(label, fill: fill, spacing: 4) {
          Image(agent.iconAsset)
            .resizable()
            .interpolation(.high)
        }
        DocketOutwardArrow()
          .fill(DocketColors.ink)
          .frame(width: 12, height: 12)
          .opacity(isRowHovered ? 1 : 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(openHelp(agent))
    .pointingHandCursor()
  }

  private func openHelp(_ agent: DailyBriefAgent) -> String {
    if store.handoff(for: title)?.outputFile != nil {
      return "Open what \(agent.displayName) wrote"
    }
    return "Open in \(agent.displayName)"
  }
}

/// The round send button on a New or Dismissed row, with a dark tooltip above it.
private struct DocketListHandOffButton: View {
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      Image("DocketSend")
        .resizable()
        .frame(width: 16, height: 16)
        .frame(width: 28, height: 28)
        .docketRoundSkin()
        .contentShape(Circle())
    }
    .buttonStyle(DocketPressStyle())
    .onHover { isHovered = $0 }
    .overlay(alignment: .top) {
      Text("Hand off to agent")
        .font(DailyBriefFonts.sans(12))
        .foregroundStyle(.white)
        .fixedSize()
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(hex: "3A3A3A"))
        )
        .offset(y: -29)
        .opacity(isHovered ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .allowsHitTesting(false)
    }
    .pointingHandCursor()
  }
}
