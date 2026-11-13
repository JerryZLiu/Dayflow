//
//  DailyBriefPageView.swift
//  Dayflow
//
//  The Daily brief page: the Daybreak header with the date, "Take these off your plate"
//  (the docket as a card stack or list), the other sections the model filled, saved
//  items, and a small footer with Retry and Override instructions.
//

import AppKit
import SwiftUI

struct DailyBriefPageView: View {
  @ObservedObject private var store = DailyBriefStore.shared
  @ObservedObject private var ui = DocketUIState.shared

  var body: some View {
    GeometryReader { geometry in
      let isCompact = geometry.size.width < DailyBriefLayout.compactWidth
      ZStack(alignment: .topTrailing) {
        ScrollViewReader { proxy in
          ScrollView(.vertical) {
            VStack(spacing: 0) {
              // In the reading-first half of the test, "Take these off your plate" travels
              // down with the cards it introduces instead of staying in the header.
              // The header then holds only the date, so it's shorter too.
              DocketDaybreakHeader(
                date: pageDate, showsIntro: hasDocket && !store.showsReadingFirst,
                isCompact: store.showsReadingFirst
              )
              .id("top")

              topSections(viewportHeight: geometry.size.height, isCompact: isCompact)

              if store.showsReadingFirst, hasDocket {
                DocketDeckHeading()
              }

              // Marks the top of the deck for scrolling to it when a prompt opens.
              Color.clear.frame(height: 0).id("deck")

              docketArea(viewportHeight: geometry.size.height)

              VStack(alignment: .leading, spacing: 0) {
                lowerSections(viewportHeight: geometry.size.height)
                  .padding(.horizontal, DailyBriefLayout.horizontalPadding(isCompact: isCompact))
                  .padding(.top, 40)

                DailyBriefFooter()
                  .frame(maxWidth: .infinity)
                  .padding(.top, 72)
                  .padding(.bottom, 48)
                  .modifier(DailyBriefRiseIn())
                  .modifier(seenMarker(DailyBriefStore.pageBottomName, geometry.size.height))
              }
              .frame(maxWidth: DailyBriefLayout.pageMaxWidth)
              .frame(maxWidth: .infinity)
            }
            .frame(width: geometry.size.width)
            .background(alignment: .top) { DocketTwilightWash() }
          }
          .scrollIndicators(.hidden)
          .coordinateSpace(.named(DailyBriefSeenMarker.scrollSpace))
          .onChange(of: ui.scrollToTopRequest) {
            // Opening a card's prompt scrolls the deck to where it sits under the header
            // in the usual layout, so the deck's centring math works the same in both
            // halves of the test. In the usual layout that's simply the page's top.
            withAnimation(DocketMotion.ease(0.46)) {
              if store.showsReadingFirst {
                let fraction = min(DocketDaybreakHeader.height / max(geometry.size.height, 1), 1)
                proxy.scrollTo("deck", anchor: UnitPoint(x: 0.5, y: fraction))
              } else {
                proxy.scrollTo("top", anchor: .top)
              }
            }
          }
        }

        closeButton
          .padding(16)
          .opacity(ui.isPromptOpen ? 0 : 1)
          .animation(.easeOut(duration: 0.26), value: ui.isPromptOpen)
      }
      .environment(\.dailyBriefIsCompact, isCompact)
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
    .background(pageBackground)
    .overlay(alignment: .bottomTrailing) {
      if let title = ui.askTitle {
        DocketAskPopup(title: title)
          .id(title)
          .padding(24)
          .transition(.opacity.combined(with: .offset(x: 32)))
      }
    }
    .animation(DocketMotion.ease(0.3), value: ui.askTitle)
    .overlayPreferenceValue(DocketAnchorKey.self) { anchors in
      DocketMenuLayer(anchors: anchors)
    }
    // The prototype is light only, so the brief stays light in dark mode.
    .dayflowTheme(.light)
    .onDisappear {
      ui.openMenu = nil
      ui.askTitle = nil
      ui.isPromptOpen = false
    }
  }

  /// The window's peach-to-blue light under a pale, see-through panel.
  private var pageBackground: some View {
    GeometryReader { geometry in
      DocketColors.pageBackground
        .frame(width: 1150, height: 1270)
        .position(x: geometry.size.width * 0.5917, y: geometry.size.height)
    }
    .background(Color(hex: "DAEAFC"))
    .overlay(Color(red: 251 / 255, green: 251 / 255, blue: 251 / 255).opacity(0.55))
    .clipped()
  }

  /// The logical day the page is for: the brief's day, or today while there's no brief.
  private var pageDate: Date {
    DailyBriefDates.date(from: store.brief?.day) ?? Date().getDayInfoFor4AMBoundary().startOfDay
  }

  private var hasDocket: Bool { !store.docketItems.isEmpty }

  private var closeButton: some View {
    Button {
      store.dismiss()
    } label: {
      Image(systemName: "xmark")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 28, height: 28)
        .background(Circle().fill(Color.black.opacity(0.25)))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .keyboardShortcut(.cancelAction)
    .help("Close")
    .pointingHandCursor()
  }

  // MARK: Docket

  /// The card stack, or a short message when there's nothing to stack yet.
  @ViewBuilder
  private func docketArea(viewportHeight: CGFloat) -> some View {
    if store.brief == nil {
      stateContent
        .padding(.horizontal, 32)
    } else if hasDocket {
      // In both layouts the deck sits header-height below the window's top when a
      // prompt opens (see the scrollToTopRequest handler).
      DocketDeckView(viewportHeight: viewportHeight, deckTop: DocketDaybreakHeader.height)
        .frame(maxWidth: .infinity)
        .zIndex(1)
        .modifier(seenMarker(DailyBriefSectionKind.docket.rawValue, viewportHeight))
    } else {
      DailyBriefStateMessage(
        title: "Nothing to hand off today",
        detail: "Dayflow didn't find tasks from yesterday that an agent could pick up.")
    }
  }

  // MARK: Other sections

  /// Reading and news, shown here only for the reading-first half of the layout test.
  /// Everyone else sees them below the stack with the rest.
  @ViewBuilder
  private func topSections(viewportHeight: CGFloat, isCompact: Bool) -> some View {
    if let brief = store.brief {
      let kinds = store.pageSections(brief).aboveDocket
      if !kinds.isEmpty {
        sectionStack(kinds: kinds, brief: brief, viewportHeight: viewportHeight)
          .padding(.horizontal, DailyBriefLayout.horizontalPadding(isCompact: isCompact))
          .padding(.top, 28)
          .padding(.bottom, 56)
          .frame(maxWidth: DailyBriefLayout.pageMaxWidth)
          .frame(maxWidth: .infinity)
      }
    }
  }

  @ViewBuilder
  private func lowerSections(viewportHeight: CGFloat) -> some View {
    let savedMarker = seenMarker(DailyBriefStore.savedRowName, viewportHeight)
    if let brief = store.brief {
      let kinds = store.pageSections(brief).belowDocket
      VStack(alignment: .leading, spacing: 64) {
        sectionStack(kinds: kinds, brief: brief, viewportHeight: viewportHeight)
        DailyBriefSavedRow(brief: brief)
          .modifier(DailyBriefRiseIn())
          .modifier(savedMarker)
      }
    } else {
      DailyBriefSavedRow(brief: nil)
        .modifier(DailyBriefRiseIn())
        .modifier(savedMarker)
    }
  }

  private func sectionStack(
    kinds: [DailyBriefSectionKind], brief: DailyBrief, viewportHeight: CGFloat
  ) -> some View {
    VStack(alignment: .leading, spacing: 64) {
      ForEach(kinds, id: \.self) { kind in
        DailyBriefSectionView(kind: kind, brief: brief)
          .modifier(DailyBriefRiseIn())
          .modifier(seenMarker(kind.rawValue, viewportHeight))
      }
    }
  }

  private func seenMarker(_ section: String, _ viewportHeight: CGFloat) -> DailyBriefSeenMarker {
    DailyBriefSeenMarker(
      section: section, viewportHeight: viewportHeight, visitNumber: store.visitNumber)
  }

  @ViewBuilder
  private var stateContent: some View {
    switch store.runState {
    case .running(let startedAt):
      DailyBriefLoadingView(startedAt: startedAt)
    case .failed(let message):
      DailyBriefStateMessage(
        title: "Your brief didn't come together",
        detail: message,
        showsRetry: true)
    case .idle:
      DailyBriefStateMessage(
        title: "Your brief will appear here tomorrow morning",
        detail:
          "Dayflow puts it together from yesterday's Timeline once you've recorded for a while.")
    }
  }
}

/// Sections rise 16pt and fade in as they scroll into view, and drop back once they
/// leave below the window so they can rise again.
private struct DailyBriefRiseIn: ViewModifier {
  func body(content: Content) -> some View {
    content.scrollTransition(.animated(.timingCurve(0.2, 0.7, 0.2, 1, duration: 0.55))) {
      view, phase in
      view
        .opacity(phase == .bottomTrailing ? 0 : 1)
        .offset(y: phase == .bottomTrailing ? 16 : 0)
    }
  }
}

/// Tells the store the first time a part of the page scrolls into view, for analytics.
/// A part counts as seen once its top is 120pt above the bottom of the window, enough
/// to show its heading and first row. Parts with nothing to show have no height and
/// are never counted. A new visit (`visitNumber`) re-reports parts already on screen,
/// such as the ones that were under the intro walkthrough.
private struct DailyBriefSeenMarker: ViewModifier {
  static let scrollSpace = "dailyBriefScroll"

  let section: String
  let viewportHeight: CGFloat
  let visitNumber: Int

  private struct SeenState: Equatable {
    let isSeen: Bool
    let visitNumber: Int
  }

  func body(content: Content) -> some View {
    content.background {
      GeometryReader { proxy in
        let frame = proxy.frame(in: .named(Self.scrollSpace))
        let isSeen = frame.height > 0 && frame.minY < viewportHeight - min(120, frame.height)
        Color.clear
          .onChange(of: SeenState(isSeen: isSeen, visitNumber: visitNumber), initial: true) {
            _, state in
            if state.isSeen { DailyBriefStore.shared.markSectionSeen(section) }
          }
      }
    }
  }
}

// MARK: - States

private struct DailyBriefStateMessage: View {
  let title: String
  let detail: String?
  var showsRetry = false

  @ObservedObject private var store = DailyBriefStore.shared
  @Environment(\.dayflowTheme) private var theme

  var body: some View {
    VStack(spacing: 10) {
      Text(title)
        .font(DailyBriefFonts.serif(32))
        .foregroundStyle(DailyBriefColors.heading(theme))
        .multilineTextAlignment(.center)
      if let detail, !detail.isEmpty {
        Text(detail)
          .font(DailyBriefFonts.sans(14))
          .foregroundStyle(DailyBriefColors.muted(theme))
          .multilineTextAlignment(.center)
          .frame(maxWidth: 460)
      }
      if showsRetry {
        Button("Try again") { store.retry() }
          .buttonStyle(.plain)
          .font(DailyBriefFonts.sans(13, weight: .medium))
          .foregroundStyle(theme.accent)
          .padding(.top, 4)
          .disabled(store.isRunning)
          .pointingHandCursor()
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 40)
  }
}

/// "Putting together your morning…" with a slow shimmer and elapsed minutes.
private struct DailyBriefLoadingView: View {
  let startedAt: Date

  @Environment(\.dayflowTheme) private var theme
  @State private var phase: CGFloat = 0

  private let message = "Putting together your morning…"

  var body: some View {
    VStack(spacing: 10) {
      shimmeringTitle

      TimelineView(.periodic(from: .now, by: 30)) { context in
        Text(elapsedText(now: context.date))
          .font(DailyBriefFonts.sans(13))
          .foregroundStyle(DailyBriefColors.muted(theme))
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 40)
    .onAppear {
      withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) {
        phase = 1
      }
    }
  }

  private var shimmeringTitle: some View {
    Text(message)
      .font(DailyBriefFonts.serif(34))
      .foregroundStyle(DailyBriefColors.heading(theme).opacity(0.75))
      .overlay {
        GeometryReader { geometry in
          let bandWidth = geometry.size.width * 0.35
          LinearGradient(
            colors: [.clear, Color(hex: "FFB38A"), .clear],
            startPoint: .leading,
            endPoint: .trailing
          )
          .frame(width: bandWidth)
          .offset(x: -bandWidth + phase * (geometry.size.width + bandWidth))
        }
        .mask {
          Text(message)
            .font(DailyBriefFonts.serif(34))
        }
      }
  }

  private func elapsedText(now: Date) -> String {
    let minutes = Int(now.timeIntervalSince(startedAt) / 60)
    if minutes < 1 { return "Started just now. This usually takes a few minutes." }
    if minutes == 1 { return "Started 1 minute ago. This usually takes a few minutes." }
    return "Started \(minutes) minutes ago. This usually takes a few minutes."
  }
}

// MARK: - Saved for your reference

/// Two stacks: today's completed work (opens Everything you completed) and
/// saved images (opens What you saved). Hidden when both are empty.
private struct DailyBriefSavedRow: View {
  let brief: DailyBrief?

  @ObservedObject private var store = DailyBriefStore.shared
  @Environment(\.dayflowTheme) private var theme

  private var completed: [DailyBriefCompletedItem] {
    Array((brief?.content.completedYesterday ?? []).prefix(3))
  }

  private var saved: [DailyBriefSavedItem] {
    Array(store.savedItems.prefix(4))
  }

  var body: some View {
    if !completed.isEmpty || !saved.isEmpty {
      DailyBriefSectionRow(title: "Saved for your reference") {
        HStack(alignment: .top, spacing: 60) {
          if let brief, !completed.isEmpty {
            stackButton(label: "Everything you completed") {
              store.route = .completedHistory
            } stack: {
              completedStack(brief: brief)
            }
          }
          if !saved.isEmpty {
            stackButton(label: "Saved info") {
              store.route = .saved
            } stack: {
              savedStack
            }
          }
        }
      }
    }
  }

  private func stackButton<Stack: View>(
    label: String, action: @escaping () -> Void, @ViewBuilder stack: () -> Stack
  ) -> some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 18) {
        stack()
          .frame(width: 240, height: 160, alignment: .bottomTrailing)
        Text(label)
          .font(DailyBriefFonts.sans(14))
          .foregroundStyle(theme.textPrimary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }

  /// Completed cards fanned behind each other; the first item sits in front.
  private func completedStack(brief: DailyBrief) -> some View {
    ZStack(alignment: .bottomTrailing) {
      ForEach(Array(completed.enumerated().reversed()), id: \.offset) { index, item in
        DailyBriefCompletedCard(item: item, briefDay: brief.day, width: 180, height: 116)
          .shadow(color: Color.black.opacity(0.12), radius: 6, y: 3)
          .rotationEffect(.degrees(Double(index) * -3))
          .offset(x: CGFloat(index) * -22, y: CGFloat(index) * -10)
          .allowsHitTesting(false)
      }
    }
  }

  /// Saved images fanned behind each other; the newest sits in front.
  private var savedStack: some View {
    ZStack(alignment: .bottomTrailing) {
      ForEach(Array(saved.enumerated().reversed()), id: \.element.id) { index, item in
        DailyBriefFileImage(url: DailyBriefStore.savedImageURL(item))
          .frame(width: 170, height: 112)
          .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
          .shadow(color: Color.black.opacity(0.15), radius: 6, y: 3)
          .rotationEffect(.degrees(Double(index) * -4))
          .offset(x: CGFloat(index) * -20, y: CGFloat(index) * -8)
      }
    }
  }
}

// MARK: - Footer

/// Retry, Override instructions, and Edit prompt, small and centered at the
/// very bottom, with the last run's debug stats underneath.
private struct DailyBriefFooter: View {
  @ObservedObject private var store = DailyBriefStore.shared
  @Environment(\.dayflowTheme) private var theme
  @State private var isEditingInstructions = false
  @State private var isEditingPrompt = false

  var body: some View {
    VStack(spacing: 10) {
      HStack(spacing: 18) {
        Button {
          store.retry()
        } label: {
          HStack(spacing: 5) {
            if store.isRunning {
              ProgressView()
                .controlSize(.mini)
              Text("Regenerating…")
            } else {
              Image(systemName: "arrow.clockwise")
                .font(.system(size: 10, weight: .medium))
              Text("Retry")
            }
          }
        }
        .disabled(store.isRunning)

        Button {
          isEditingInstructions = true
        } label: {
          HStack(spacing: 5) {
            Image(systemName: "slider.horizontal.3")
              .font(.system(size: 10, weight: .medium))
            Text("Override instructions")
          }
        }
        .popover(isPresented: $isEditingInstructions, arrowEdge: .top) {
          DailyBriefOverrideEditor(isPresented: $isEditingInstructions)
        }

        Button {
          isEditingPrompt = true
        } label: {
          HStack(spacing: 5) {
            Image(systemName: "text.alignleft")
              .font(.system(size: 10, weight: .medium))
            Text("Edit prompt")
            if store.hasAnyPromptOverride {
              Text("Custom prompt")
                .font(DailyBriefFonts.sans(10, weight: .semibold))
                .foregroundStyle(theme.accent)
                .padding(.vertical, 1)
                .padding(.horizontal, 5)
                .background(Capsule().fill(theme.accent.opacity(0.15)))
            }
          }
        }
        .sheet(isPresented: $isEditingPrompt) {
          DailyBriefPromptEditor(isPresented: $isEditingPrompt)
        }
      }
      .buttonStyle(.plain)
      .font(DailyBriefFonts.sans(12, weight: .medium))
      .foregroundStyle(DailyBriefColors.muted(theme))

      if store.brief != nil, case .failed(let message) = store.runState {
        Text("The last retry failed: \(message)")
          .font(DailyBriefFonts.sans(11))
          .foregroundStyle(DailyBriefColors.muted(theme))
          .multilineTextAlignment(.center)
          .frame(maxWidth: 420)
      }

      DailyBriefDebugStats()
        .padding(.top, 6)
    }
  }
}

/// Small monospaced numbers about the last run (or the live elapsed time while
/// one is going), plus a "Copy stats" button that copies them as JSON.
private struct DailyBriefDebugStats: View {
  @ObservedObject private var store = DailyBriefStore.shared
  @Environment(\.dayflowTheme) private var theme

  private var isFailed: Bool {
    if case .failed = store.runState { return true }
    return false
  }

  /// The failed run's stats when the last run failed, else the brief's.
  private var stats: DailyBriefRunStats? {
    isFailed ? store.lastFailedRunStats : store.brief?.stats
  }

  /// One part's saved Claude transcript from the last run, when there is one. Runs are
  /// always for today, so a failed retry's transcripts live in the same folder.
  private func transcriptURL(_ part: DailyBriefGenerator.Part) -> URL? {
    let day = store.brief?.day ?? Date().getDayInfoFor4AMBoundary().dayString
    let url = DailyBriefStore.transcriptURL(for: day, part: part)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  /// Only meaningful when the stats belong to the brief on screen.
  private var generatedAt: Date? {
    isFailed ? nil : store.brief?.generatedAt
  }

  var body: some View {
    VStack(spacing: 4) {
      if case .running(let startedAt) = store.runState {
        TimelineView(.periodic(from: .now, by: 1)) { context in
          statLine("running for \(Self.duration(context.date.timeIntervalSince(startedAt)))")
        }
      }

      if let stats {
        ForEach(Self.lines(stats, generatedAt: generatedAt, failed: isFailed), id: \.self) { line in
          statLine(line)
        }

        HStack(spacing: 14) {
          Button("Copy stats") {
            Self.copyJSON(stats, generatedAt: generatedAt)
          }
          Button("Reset tasks") {
            DocketUIState.shared.askTitle = nil
            DocketUIState.shared.isPromptOpen = false
            store.resetDocket()
          }
          .help("Put every task back in the stack as new")
          ForEach(DailyBriefGenerator.Part.allCases, id: \.self) { part in
            if let url = transcriptURL(part) {
              Button("\(part.displayName) transcript") {
                NSWorkspace.shared.open(url)
              }
            }
          }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(DailyBriefColors.muted(theme))
        .padding(.top, 2)
        .pointingHandCursor()
      }

      // Always here, even before the first run has stats.
      HStack(spacing: 14) {
        Button("Replay intro") {
          store.debugReplayIntro()
        }
        .help("Show the Introducing Daily Briefs walkthrough again")
        Button("Show ready notice") {
          store.debugShowReadyNotice()
        }
        .help("Close the brief and show the menu bar card that says it's ready")
        Button("Layout: \(store.layoutVariant)") {
          store.debugToggleReadingFirst()
        }
        .help("Switch between the two halves of the reading-first layout test")
      }
      .buttonStyle(.plain)
      .font(.system(size: 10, weight: .medium, design: .monospaced))
      .foregroundStyle(DailyBriefColors.muted(theme))
      .padding(.top, 2)
      .pointingHandCursor()
    }
    .frame(maxWidth: 620)
  }

  private func statLine(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 10, design: .monospaced))
      .foregroundStyle(DailyBriefColors.muted(theme))
      .multilineTextAlignment(.center)
      .textSelection(.enabled)
  }

  // MARK: Formatting

  /// 462 → "7m 42s", 42 → "42s".
  static func duration(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let minutes = total / 60
    let remainder = total % 60
    return minutes > 0 ? "\(minutes)m \(remainder)s" : "\(remainder)s"
  }

  /// A few short lines; nil fields are skipped.
  static func lines(_ stats: DailyBriefRunStats, generatedAt: Date?, failed: Bool) -> [String] {
    // The clock time includes any time the Mac spent asleep; the API time doesn't.
    var time = (failed ? "failed after " : "generated in ") + duration(stats.durationSeconds)
    if let apiSeconds = stats.apiSeconds { time += " (\(duration(apiSeconds)) in API calls)" }
    var run: [String] = [time]
    if let model = stats.model { run.append(model) }
    // The CLI's own estimate at list prices, not a charge. Per model when it reports that.
    if let cost = stats.costUSD {
      var text = String(format: "CLI estimate $%.2f", cost)
      if let modelCosts = stats.modelCosts, modelCosts.count > 1 {
        let parts = modelCosts.sorted { $0.value > $1.value }
          .map { String(format: "%@ $%.2f", $0.key, $0.value) }
        text += " (" + parts.joined(separator: ", ") + ")"
      }
      run.append(text)
    }
    if let trigger = stats.trigger { run.append("trigger: \(trigger)") }
    if let generatedAt {
      run.append(generatedAt.formatted(date: .abbreviated, time: .shortened))
    }

    var tokens: [String] = []
    if let input = stats.inputTokens { tokens.append("in \(input.formatted())") }
    if let output = stats.outputTokens { tokens.append("out \(output.formatted())") }
    if let cacheRead = stats.cacheReadTokens {
      tokens.append("cache read \(cacheRead.formatted())")
    }
    if let cacheWrite = stats.cacheWriteTokens {
      tokens.append("cache write \(cacheWrite.formatted())")
    }
    if let turns = stats.numTurns { tokens.append("\(turns) turns") }

    var work: [String] = []
    if let toolCalls = stats.toolCalls, !toolCalls.isEmpty {
      let total = toolCalls.values.reduce(0, +)
      let top = toolCalls.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        .prefix(4)
        .map { "\($0.key) \($0.value)" }
        .joined(separator: ", ")
      work.append("\(total) tool calls (\(top))")
    }
    if let cards = stats.cardCount { work.append("\(cards) cards") }
    if let images = stats.candidateImageCount { work.append("\(images) candidate images") }
    if let characters = stats.promptCharacters {
      work.append("prompt \(characters.formatted()) chars")
    }
    if let connectors = stats.connectors, !connectors.isEmpty {
      let names = connectors.sorted { $0.key < $1.key }
        .map { $0.value == "connected" ? $0.key : "\($0.key) (\($0.value))" }
      work.append("connectors: " + names.joined(separator: ", "))
    }

    var flags: [String] = []
    flags.append(stats.usedPromptOverride ? "custom prompt" : "default prompt")
    if stats.usedOverrideInstructions { flags.append("override instructions") }

    // A run that failed while the other one succeeded gets its own line.
    let failures = (stats.failedParts ?? [:]).sorted { $0.key < $1.key }.map { part, message in
      let name = DailyBriefGenerator.Part(rawValue: part)?.displayName ?? part
      return ["\(name) run failed: \(message)"]
    }

    return ([run, tokens, work, flags] + failures)
      .filter { !$0.isEmpty }
      .map { $0.joined(separator: " · ") }
  }

  static func copyJSON(_ stats: DailyBriefRunStats, generatedAt: Date?) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(stats),
      var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return }
    if let generatedAt {
      object["generatedAt"] = ISO8601DateFormatter().string(from: generatedAt)
    }
    guard
      let output = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
      let text = String(data: output, encoding: .utf8)
    else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

/// Edits the two prompt templates (docket, and other sections). An empty override means
/// that part uses its default.
private struct DailyBriefPromptEditor: View {
  @Binding var isPresented: Bool

  @ObservedObject private var store = DailyBriefStore.shared
  @Environment(\.dayflowTheme) private var theme
  @State private var part: DailyBriefGenerator.Part = .docket
  /// One draft per part, so switching between them keeps unsaved edits.
  @State private var drafts: [DailyBriefGenerator.Part: String] = [:]

  private var draft: Binding<String> {
    Binding(
      get: { drafts[part] ?? "" },
      set: { drafts[part] = $0 }
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Edit prompt")
        .font(DailyBriefFonts.sans(15, weight: .semibold))
        .foregroundStyle(theme.textPrimary)

      Text(
        "The brief is written by two Claude runs at once: one for the docket, one for every other section. Placeholders are filled in at run time. Used from the next run, so Retry picks it up."
      )
      .font(DailyBriefFonts.sans(12))
      .foregroundStyle(DailyBriefColors.muted(theme))
      .fixedSize(horizontal: false, vertical: true)

      Picker("Prompt", selection: $part) {
        ForEach(DailyBriefGenerator.Part.allCases, id: \.self) { part in
          Text(part.displayName).tag(part)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      placeholderChips

      TextEditor(text: draft)
        .font(.system(size: 12, design: .monospaced))
        .scrollContentBackground(.hidden)
        .padding(8)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(theme.inputFill)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(theme.inputBorder, lineWidth: 1)
        )

      HStack {
        Button("Reset \(part.displayName.lowercased()) to default") {
          drafts[part] = part.defaultTemplate
        }
        Spacer()
        Button("Cancel") { isPresented = false }
          .keyboardShortcut(.cancelAction)
        Button("Save") {
          for part in DailyBriefGenerator.Part.allCases {
            let draft = drafts[part] ?? ""
            let isDefault =
              draft.trimmingCharacters(in: .whitespacesAndNewlines)
              == part.defaultTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
            store.setPromptOverride(isDefault ? "" : draft, for: part)
          }
          isPresented = false
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 760, height: 600)
    .onAppear {
      for part in DailyBriefGenerator.Part.allCases {
        drafts[part] =
          store.hasPromptOverride(for: part)
          ? store.promptOverride(for: part) : part.defaultTemplate
      }
    }
  }

  private var placeholderChips: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach(part.placeholderNames, id: \.self) { name in
          Text(name.contains("{{") ? name : "{{\(name)}}")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(DailyBriefColors.body(theme))
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(
              RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(DailyBriefColors.cardFill(theme))
            )
            .overlay(
              RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(DailyBriefColors.cardBorder(theme), lineWidth: 1)
            )
            .textSelection(.enabled)
        }
      }
    }
  }
}

private struct DailyBriefOverrideEditor: View {
  @Binding var isPresented: Bool

  @ObservedObject private var store = DailyBriefStore.shared
  @Environment(\.dayflowTheme) private var theme
  @State private var draft = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Override instructions")
        .font(DailyBriefFonts.sans(14, weight: .semibold))
        .foregroundStyle(theme.textPrimary)

      Text(
        "Extra preferences for your brief, like 'skip industry news' or 'more design inspiration'. Used from the next run."
      )
      .font(DailyBriefFonts.sans(12))
      .foregroundStyle(DailyBriefColors.muted(theme))
      .fixedSize(horizontal: false, vertical: true)

      TextEditor(text: $draft)
        .font(DailyBriefFonts.sans(13))
        .scrollContentBackground(.hidden)
        .padding(6)
        .frame(height: 130)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(theme.inputFill)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(theme.inputBorder, lineWidth: 1)
        )

      HStack {
        Spacer()
        Button("Cancel") { isPresented = false }
          .keyboardShortcut(.cancelAction)
        Button("Save") {
          store.overrideInstructions = draft.trimmingCharacters(in: .whitespacesAndNewlines)
          isPresented = false
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(16)
    .frame(width: 380)
    .onAppear { draft = store.overrideInstructions }
  }
}

#Preview {
  DailyBriefPageView()
    .frame(width: 1200, height: 900)
}
