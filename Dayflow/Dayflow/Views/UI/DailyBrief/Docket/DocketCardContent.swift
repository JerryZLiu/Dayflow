//
//  DocketCardContent.swift
//  Dayflow
//
//  What's inside the front card: the title and its counts (Details, Feedback, Links),
//  the panel a count opens, and the prompt for the agent, tucked to two lines or open
//  and editable. Also the count row and panels the list view reuses.
//

import AppKit
import SwiftUI

/// Which count's panel is open.
enum DocketPanel: Equatable {
  case details
  case feedback
  case links
}

// MARK: - Card content

struct DocketCardContent: View {
  let item: DailyBriefDocketItem
  /// The prompt is open (the card is wide).
  let isOpen: Bool
  /// When the prompt last opened, for the text reveal.
  let revealStart: Date?
  @Binding var panel: DocketPanel?
  /// How far the open prompt's text is scrolled, driven by the deck's wheel handling.
  @Binding var promptScroll: CGFloat
  @Binding var promptContentHeight: CGFloat
  @Binding var isEditingPrompt: Bool
  let togglePrompt: () -> Void

  @ObservedObject private var store = DailyBriefStore.shared
  @ObservedObject private var ui = DocketUIState.shared

  /// The title's measured height, and the height of one line of it. A title that wraps
  /// grows upward, so the counts stay where the layout expects them.
  @State private var titleHeight: CGFloat = 0
  @State private var titleLineHeight: CGFloat = 0

  private var inset: CGFloat { isOpen ? 36 : 26 }

  /// How much taller than one line the title is.
  private var titleExtraHeight: CGFloat { max(0, titleHeight - titleLineHeight) }

  /// Where the title and counts sit.
  private var headTop: CGFloat {
    if isOpen { return 46.3 }
    return panel == nil ? 160 : 28
  }

  /// Where the prompt sits. With a panel open on the wide card, it moves below the panel.
  private var promptTop: CGFloat {
    if isOpen { return panel == nil ? 130 : 395 }
    return 313
  }

  private var showsOpenPrompt: Bool { isOpen && panel == nil }

  var body: some View {
    ZStack(alignment: .topLeading) {
      head
        .padding(.horizontal, inset)
        .frame(maxWidth: .infinity)
        .offset(y: headTop - titleExtraHeight)

      if let panel {
        DocketPanelView(item: item, panel: panel, isWide: isOpen)
          .frame(width: isOpen ? nil : 600, alignment: .leading)
          .frame(maxHeight: isOpen ? 260 : (panel == .feedback ? 156 : 200), alignment: .top)
          .padding(.horizontal, isOpen ? 36 : 37)
          .offset(y: isOpen ? 116 : 92)
          .transition(DocketPanelView.unroll)
          .id(panel)
      }

      prompt
        .padding(.leading, inset)
        .padding(.trailing, isOpen ? 36 : 27)
        .offset(y: promptTop)

      if showsOpenPrompt {
        // The soft lip at the foot of the open card.
        VStack {
          Spacer()
          Image("DocketPromptFadeOpen")
            .resizable()
            .frame(height: 46)
            .padding(.bottom, 2)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .contentShape(Rectangle())
    .onTapGesture {
      // A click on the card away from a count closes its panel.
      if panel != nil { withAnimation(DocketMotion.ease(0.26)) { panel = nil } }
    }
    .animation(DocketMotion.ease(0.42), value: headTop)
    .animation(DocketMotion.ease(0.42), value: promptTop)
  }

  // MARK: Head

  private var head: some View {
    VStack(spacing: isOpen ? 16 : 10) {
      // Never cut off: a long title wraps onto more lines.
      Text(item.title)
        .font(DailyBriefFonts.sans(18, weight: .medium))
        .foregroundStyle(DocketColors.title)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .background(
          GeometryReader { geometry in
            Color.clear
              .onAppear { titleHeight = geometry.size.height }
              .onChange(of: geometry.size.height) { _, height in titleHeight = height }
          }
        )
        .background(
          // One line of the same text style, measured but never shown.
          Text("Ag")
            .font(DailyBriefFonts.sans(18, weight: .medium))
            .hidden()
            .background(
              GeometryReader { geometry in
                Color.clear
                  .onAppear { titleLineHeight = geometry.size.height }
                  .onChange(of: geometry.size.height) { _, height in titleLineHeight = height }
              }
            )
        )

      DocketCountsRow(item: item, panel: $panel)
    }
    .frame(maxWidth: .infinity)
  }

  // MARK: Prompt

  private var prompt: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 0) {
        Button(action: togglePrompt) {
          HStack(spacing: 2) {
            Text("PROMPT FOR YOUR AGENT")
              .font(DailyBriefFonts.sans(12, weight: .bold))
              .foregroundStyle(showsOpenPrompt ? DocketColors.labelOpen : DocketColors.label)
            Image(showsOpenPrompt ? "DocketChevronLabel" : "DocketChevron16")
              .resizable()
              .frame(width: 16, height: 16)
              .rotationEffect(.degrees(showsOpenPrompt ? 90 : 0))
              .animation(.easeInOut(duration: 0.3), value: showsOpenPrompt)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()

        Spacer(minLength: 12)

        if showsOpenPrompt {
          DocketPromptTools(item: item)
            .transition(.opacity.animation(.easeOut(duration: 0.25).delay(0.15)))
        }
      }
      .frame(height: 20)

      if showsOpenPrompt {
        DocketOpenPrompt(
          item: item, revealStart: revealStart, scroll: $promptScroll,
          contentHeight: $promptContentHeight, isEditing: $isEditingPrompt
        )
        .padding(.top, 21)
      } else {
        tuckedPrompt
      }
    }
  }

  private var tuckedPrompt: some View {
    Text(store.docketPrompt(for: item))
      .font(DailyBriefFonts.sans(16))
      .lineSpacing(3)
      .foregroundStyle(DocketColors.ink)
      .frame(maxWidth: .infinity, maxHeight: 38, alignment: .topLeading)
      .clipped()
      .padding(.top, 4)
      .overlay(alignment: .topLeading) {
        // The second line fades into the card.
        LinearGradient(
          stops: [
            .init(color: Color(hex: "FFFBFA").opacity(0), location: 0),
            .init(color: Color(hex: "FFFBFA").opacity(0.46), location: 0.17),
            .init(color: Color(hex: "FFFBFA").opacity(0.71), location: 0.33),
            .init(color: Color(hex: "FFFBFA").opacity(0.77), location: 0.5),
            .init(color: Color(hex: "FFFBFA").opacity(0.83), location: 0.67),
            .init(color: Color(hex: "FFFBFA").opacity(0.9), location: 1),
          ], startPoint: .top, endPoint: .bottom
        )
        .frame(height: 59.3)
        .padding(.horizontal, -inset)
        .offset(y: 12.7)
        .allowsHitTesting(false)
      }
      .contentShape(Rectangle())
      .onTapGesture(perform: togglePrompt)
      .pointingHandCursor()
  }
}

// MARK: - Open prompt

/// The open prompt's text: revealed on open, scrolled by the deck's wheel handling, and
/// editable after a click (edits are saved per task).
private struct DocketOpenPrompt: View {
  let item: DailyBriefDocketItem
  let revealStart: Date?
  @Binding var scroll: CGFloat
  @Binding var contentHeight: CGFloat
  @Binding var isEditing: Bool

  @ObservedObject private var store = DailyBriefStore.shared
  @State private var draft = ""
  @FocusState private var isFocused: Bool

  private let maxHeight: CGFloat = 260

  var body: some View {
    Group {
      if isEditing {
        TextEditor(text: $draft)
          .font(DailyBriefFonts.sans(16))
          .lineSpacing(4)
          .foregroundStyle(DocketColors.promptOpen)
          .scrollContentBackground(.hidden)
          .scrollIndicators(.hidden)
          .focused($isFocused)
          .padding(8)
          .frame(height: 305)
          .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .fill(Color.white.opacity(0.35))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .strokeBorder(Color(hex: "EFE7E2"), lineWidth: 1)
          )
          .shadow(color: Color(red: 1, green: 114 / 255, blue: 43 / 255).opacity(0.25), radius: 2.5)
          .padding(.horizontal, -13)
          .padding(.top, -5)
          .onAppear {
            draft = store.docketPrompt(for: item)
            isFocused = true
          }
          .onChange(of: isFocused) { _, focused in
            if !focused { finishEditing() }
          }
          .onDisappear(perform: finishEditing)
      } else {
        Text(store.docketPrompt(for: item))
          .font(DailyBriefFonts.sans(16))
          .lineSpacing(4)
          .modifier(DocketPromptReveal(start: revealStart, ink: DocketColors.promptOpen))
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(.bottom, 52)
          .background(
            GeometryReader { geometry in
              Color.clear
                .onAppear { contentHeight = geometry.size.height }
                .onChange(of: geometry.size.height) { _, height in contentHeight = height }
            }
          )
          .offset(y: -scroll)
          .frame(maxHeight: maxHeight, alignment: .top)
          .clipped()
          .contentShape(Rectangle())
          .onTapGesture { isEditing = true }
          .help("Click to edit")
      }
    }
  }

  private func finishEditing() {
    guard isEditing else { return }
    store.setDocketPrompt(draft, for: item)
    isEditing = false
  }
}

/// Copy (shown while hovering the open prompt's head) and the folder picker.
private struct DocketPromptTools: View {
  let item: DailyBriefDocketItem

  @ObservedObject private var store = DailyBriefStore.shared
  @ObservedObject private var ui = DocketUIState.shared
  @State private var isCopied = false
  @State private var isHovering = false
  @State private var isFolderHovered = false

  var body: some View {
    HStack(spacing: 12) {
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.docketPrompt(for: item), forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { isCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
          withAnimation(.easeOut(duration: 0.15)) { isCopied = false }
        }
      } label: {
        ZStack {
          Image("DocketCopy16")
            .resizable()
            .frame(width: 16, height: 16)
            .opacity(isCopied ? 0 : 1)
          Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color(hex: "8FAE8F"))
            .opacity(isCopied ? 1 : 0)
        }
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .opacity(isHovering || isCopied ? 1 : 0)
      .animation(.easeOut(duration: 0.15), value: isHovering)
      .help("Copy the prompt")
      .pointingHandCursor()

      folderPicker
    }
    .onHover { isHovering = $0 }
  }

  private var folderPicker: some View {
    let folder = store.docketFolder(for: item.title)
    return Button {
      ui.openMenu = ui.openMenu == .folder(title: item.title) ? nil : .folder(title: item.title)
    } label: {
      HStack(spacing: 6) {
        Image(store.docketAgent.iconAsset)
          .resizable()
          .interpolation(.high)
          .frame(width: 16, height: 16)
        Image("DocketFolderOpen")
          .resizable()
          .frame(width: 16, height: 16)
          .opacity(folder == nil ? 0.6 : 1)
        Text(folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No folder")
          .font(DailyBriefFonts.sans(12))
          .foregroundStyle(folder == nil ? DocketColors.labelOpen : DocketColors.folder)
          .underline(isFolderHovered && folder != nil)
          .lineLimit(1)
      }
      .frame(height: 20)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isFolderHovered = $0 }
    .help(folder ?? "Pick the folder the agent works in")
    .pointingHandCursor()
    .anchorPreference(key: DocketAnchorKey.self, value: .bounds) {
      ["folder:\(item.title)": $0]
    }
  }
}

/// Positions of the gear and folder pickers, so the page can draw their menus on top.
struct DocketAnchorKey: PreferenceKey {
  static let defaultValue: [String: Anchor<CGRect>] = [:]
  static func reduce(
    value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]
  ) {
    value.merge(nextValue()) { $1 }
  }
}

// MARK: - Counts

/// "Details", feedback avatars, and link icons. Clicking one toggles its panel.
struct DocketCountsRow: View {
  let item: DailyBriefDocketItem
  @Binding var panel: DocketPanel?
  /// The list view uses a fainter background for the open count.
  var openFill = Color(hex: "F8F1F0")

  var body: some View {
    HStack(spacing: 19) {
      if let detail = item.detail, !detail.isEmpty {
        count(.details) {
          Image("DocketStickyNote")
            .resizable()
            .frame(width: 16, height: 16)
          Text("Details")
        }
      }

      let people = DocketFeedback.people(for: item)
      if !people.isEmpty {
        count(.feedback) {
          HStack(spacing: -5) {
            ForEach(Array(people.enumerated()), id: \.offset) { index, name in
              Circle()
                .fill(DailyBriefPalette.avatarGradient(for: name).linear)
                .overlay(Circle().strokeBorder(Color(hex: "FDF2EF"), lineWidth: 1))
                .frame(width: 16, height: 16)
                .zIndex(Double(people.count - index))
            }
          }
          let entries = DocketFeedback.entries(for: item).count
          Text(entries == 1 ? "Feedback" : "\(entries) Feedback")
        }
      }

      let links = item.links ?? []
      if !links.isEmpty {
        count(.links) {
          HStack(spacing: -4) {
            ForEach(Array(links.prefix(3).enumerated()), id: \.offset) { index, link in
              DocketLinkIcon(link: link, size: 16)
                .zIndex(Double(3 - index))
            }
          }
          Text(links.count == 1 ? "Link" : "Links")
        }
      }
    }
  }

  private func count<Label: View>(_ kind: DocketPanel, @ViewBuilder label: @escaping () -> Label)
    -> some View
  {
    DocketCountButton(isOpen: panel == kind, openFill: openFill) {
      withAnimation(DocketMotion.ease(0.42)) { panel = panel == kind ? nil : kind }
    } label: {
      label()
    }
  }
}

private struct DocketCountButton<Label: View>: View {
  let isOpen: Bool
  let openFill: Color
  let action: () -> Void
  @ViewBuilder let label: () -> Label

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) { label() }
        .font(DailyBriefFonts.sans(14))
        .foregroundStyle(
          isOpen ? Color(hex: "696868") : (isHovered ? DocketColors.countHover : DocketColors.count)
        )
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
          Capsule().fill(
            isOpen
              ? openFill
              : (isHovered
                ? Color(red: 193 / 255, green: 160 / 255, blue: 144 / 255).opacity(0.1) : .clear))
        )
        .padding(.vertical, -3)
        .padding(.horizontal, -6)
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: 0.15), value: isHovered)
    .pointingHandCursor()
  }
}

/// A link's round icon: the app's icon in a small white-to-grey circle.
struct DocketLinkIcon: View {
  let link: DailyBriefLink
  var size: CGFloat = 16

  var body: some View {
    Circle()
      .fill(
        LinearGradient(colors: [.white, Color(hex: "E4E4E4")], startPoint: .top, endPoint: .bottom)
      )
      .overlay(Circle().strokeBorder(Color(hex: "DBDBDB"), lineWidth: 0.5))
      .overlay(icon)
      .frame(width: size, height: size)
      .shadow(color: Color.black.opacity(0.06), radius: 2)
  }

  @ViewBuilder
  private var icon: some View {
    let app = link.app?.lowercased() ?? "web"
    if app == "web"
      || (DailyBriefApps.host(app) == nil && DailyBriefLinks.host(of: link.url) == nil)
    {
      Image(systemName: "globe")
        .font(.system(size: size * 0.55))
        .foregroundStyle(Color(hex: "8A9BB0"))
    } else if DailyBriefApps.host(app) != nil {
      DailyBriefAppIcon(app: app, size: size * 0.62)
    } else {
      FaviconImageView(
        primaryRaw: link.url ?? app, secondaryRaw: nil,
        primaryHost: DailyBriefLinks.host(of: link.url), secondaryHost: nil,
        size: size * 0.62, cornerRadius: 2)
    }
  }
}

// MARK: - Panels

struct DocketPanelView: View {
  let item: DailyBriefDocketItem
  let panel: DocketPanel
  var isWide = false
  /// The list's panels are narrower and less padded.
  var isList = false

  /// Unrolls from the top on open; fades out on close.
  static let unroll = AnyTransition.asymmetric(
    insertion: .modifier(active: DocketUnroll(progress: 0), identity: DocketUnroll(progress: 1)),
    removal: .opacity.animation(.easeOut(duration: 0.26)))

  @State private var contentShown = false

  private var shownContent: some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .opacity(contentShown ? 1 : 0)
  }

  var body: some View {
    // Short content sits as is; content taller than the space the caller allows scrolls.
    ViewThatFits(in: .vertical) {
      shownContent
      ScrollView(.vertical) { shownContent }
        .scrollIndicators(.hidden)
    }
    .padding(.vertical, verticalPadding)
    .padding(.horizontal, horizontalPadding)
    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(DocketColors.panel))
    .onAppear {
      withAnimation(.easeOut(duration: 0.42).delay(0.08)) { contentShown = true }
    }
  }

  private var verticalPadding: CGFloat {
    if panel == .feedback { return 12 }
    return isList ? 8 : 7.69
  }

  private var horizontalPadding: CGFloat {
    if panel == .feedback { return 14 }
    return isList ? 12 : 15.64
  }

  @ViewBuilder
  private var content: some View {
    switch panel {
    case .details:
      Text(item.detail ?? "")
        .font(DailyBriefFonts.sans(14))
        .lineSpacing(4)
        .foregroundStyle(DocketColors.promptOpen)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    case .feedback:
      VStack(alignment: .leading, spacing: 14) {
        ForEach(DocketFeedback.entries(for: item), id: \.self) { entry in
          DocketFeedbackRow(entry: entry)
        }
      }
    case .links:
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array((item.links ?? []).enumerated()), id: \.offset) { _, link in
          DocketLinkRow(link: link)
        }
      }
    }
  }
}

/// Clips from the top, unrolling downward.
private struct DocketUnroll: ViewModifier, Animatable {
  var progress: Double

  var animatableData: Double {
    get { progress }
    set { progress = newValue }
  }

  func body(content: Content) -> some View {
    content.mask(alignment: .top) {
      Rectangle().scaleEffect(x: 1, y: progress, anchor: .top)
    }
  }
}

private struct DocketFeedbackRow: View {
  let entry: DocketFeedbackEntry

  @State private var isSourceHovered = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 5) {
        Circle()
          .fill(DailyBriefPalette.avatarGradient(for: entry.name).linear)
          .overlay(Circle().strokeBorder(Color(hex: "FDF2EF"), lineWidth: 2))
          .overlay(
            Text(DailyBriefPalette.initials(for: entry.name))
              .font(DailyBriefFonts.sans(8, weight: .medium))
              .foregroundStyle(Color(hex: "868686"))
          )
          .frame(width: 20, height: 20)
        Text(entry.name)
          .font(DailyBriefFonts.sans(14, weight: .semibold))
          .foregroundStyle(DocketColors.ink)
        source
      }
      Text(entry.text)
        .font(DailyBriefFonts.sans(14))
        .lineSpacing(4)
        .foregroundStyle(Color(hex: "727272"))
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .padding(.leading, 25)
    }
  }

  @ViewBuilder
  private var source: some View {
    if let text = entry.source, !text.isEmpty {
      if let url = entry.url {
        Button {
          DailyBriefLinks.open(url)
        } label: {
          HStack(spacing: 0) {
            Text(text)
            DocketOutwardArrow()
              .frame(width: 16, height: 16)
              .opacity(isSourceHovered ? 1 : 0)
              .offset(x: isSourceHovered ? 0 : -3, y: isSourceHovered ? 0 : 3)
          }
          .font(DailyBriefFonts.sans(12))
          .foregroundStyle(isSourceHovered ? DocketColors.countHover : DocketColors.count)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isSourceHovered = $0 }
        .animation(.easeOut(duration: 0.2), value: isSourceHovered)
        .pointingHandCursor()
      } else {
        Text(text)
          .font(DailyBriefFonts.sans(12))
          .foregroundStyle(DocketColors.count)
      }
    }
  }
}

private struct DocketLinkRow: View {
  let link: DailyBriefLink

  @State private var isHovered = false

  var body: some View {
    Button {
      DailyBriefLinks.open(link.url)
    } label: {
      HStack(spacing: 12) {
        DocketLinkIcon(link: link, size: 28)
        Text(link.title)
          .font(DailyBriefFonts.sans(14))
          .foregroundStyle(isHovered ? DocketColors.ink : Color(hex: "727272"))
          .lineLimit(1)
        DocketOutwardArrow()
          .fill(isHovered ? DocketColors.ink : Color(hex: "727272"))
          .frame(width: 16, height: 16)
          .opacity(isHovered ? 1 : 0)
          .offset(x: isHovered ? 0 : -3, y: isHovered ? 0 : 3)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(link.url == nil)
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: 0.2), value: isHovered)
    .pointingHandCursor()
  }
}
