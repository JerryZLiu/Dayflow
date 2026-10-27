//
//  DailyBriefPageView.swift
//  Dayflow
//
//  The Daily brief page: a painting with the date, yesterday's activity
//  heatmap, the sections the model filled, saved items, and a small footer
//  with Retry and Override instructions.
//

import AppKit
import SwiftUI

/// Header paintings. Add more asset names here; one is picked per day of the year.
enum DailyBriefPaintings {
  static let names = ["DailyBriefPainting1"]

  static func name(for date: Date) -> String {
    let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: date) ?? 0
    return names[dayOfYear % names.count]
  }
}

struct DailyBriefPageView: View {
  @ObservedObject private var store = DailyBriefStore.shared
  @Environment(\.dayflowTheme) private var theme

  var body: some View {
    GeometryReader { geometry in
      let isCompact = geometry.size.width < DailyBriefLayout.compactWidth
      ZStack(alignment: .topTrailing) {
        ScrollView(.vertical) {
          VStack(alignment: .leading, spacing: 0) {
            header(isCompact: isCompact)

            // The painting runs edge to edge; the text column stays readable on wide windows.
            VStack(alignment: .leading, spacing: 0) {
              mainContent
                .padding(.horizontal, DailyBriefLayout.horizontalPadding(isCompact: isCompact))
                .padding(.top, isCompact ? 40 : 64)

              DailyBriefFooter()
                .frame(maxWidth: .infinity)
                .padding(.top, 72)
                .padding(.bottom, 48)
            }
            .frame(maxWidth: DailyBriefLayout.pageMaxWidth)
            .frame(maxWidth: .infinity)
          }
          .frame(width: geometry.size.width)
        }
        .scrollIndicators(.hidden)

        closeButton
          .padding(16)
      }
      .environment(\.dailyBriefIsCompact, isCompact)
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
    .background(DailyBriefColors.pageBackground(theme))
  }

  // MARK: Header

  /// The logical day the page is for: the brief's day, or today while there's no brief.
  private var pageDate: Date {
    DailyBriefDates.date(from: store.brief?.day) ?? Date().getDayInfoFor4AMBoundary().startOfDay
  }

  /// The day the heatmap shows: what the brief was built from, else yesterday.
  private var heatmapDay: String {
    if let sourceDay = store.brief?.sourceDay { return sourceDay }
    let today = Date().getDayInfoFor4AMBoundary()
    return DailyBriefStore.previousDay(before: today.startOfDay).dayString
  }

  private func header(isCompact: Bool) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      ZStack {
        Color.clear
          .overlay(
            Image(DailyBriefPaintings.name(for: pageDate))
              .resizable()
              .aspectRatio(contentMode: .fill)
          )
          .clipped()

        if theme.isDark {
          Color.black.opacity(0.45)
        }

        // Fade the painting's bottom edge into the page.
        VStack(spacing: 0) {
          Spacer()
          LinearGradient(
            colors: [DailyBriefColors.pageTop(theme).opacity(0), DailyBriefColors.pageTop(theme)],
            startPoint: .top,
            endPoint: .bottom
          )
          .frame(height: 140)
        }

        Text(DailyBriefDates.longTitle(pageDate))
          .font(DailyBriefFonts.serif(isCompact ? 44 : 64))
          .foregroundStyle(.white)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 24)
          .shadow(color: Color.black.opacity(0.18), radius: 12, y: 2)
          .padding(.top, 10)
      }
      .frame(height: isCompact ? 300 : 400)
      .frame(maxWidth: .infinity)

      // The legend sits over the faded bottom of the painting, as in Figma.
      DailyBriefHeatmap(day: heatmapDay)
        .frame(maxWidth: DailyBriefLayout.pageMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
        .padding(.top, -45)
    }
  }

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

  // MARK: Content

  @ViewBuilder
  private var mainContent: some View {
    if let brief = store.brief {
      let kinds = DailyBriefSectionItems.visibleKinds(brief, store: store)
      VStack(alignment: .leading, spacing: DailyBriefLayout.sectionSpacing) {
        if kinds.isEmpty {
          DailyBriefStateMessage(
            title: "Nothing worth your time today",
            detail: "Yesterday was quiet, so there's nothing to catch up on. Enjoy the morning.")
        }
        ForEach(kinds, id: \.self) { kind in
          DailyBriefSectionView(kind: kind, brief: brief)
        }
        DailyBriefSavedRow(brief: brief)
      }
    } else {
      VStack(alignment: .leading, spacing: DailyBriefLayout.sectionSpacing) {
        stateContent
        DailyBriefSavedRow(brief: nil)
      }
    }
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
          if let transcriptURL {
            Button("Read transcript") {
              NSWorkspace.shared.open(transcriptURL)
            }
          }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(DailyBriefColors.muted(theme))
        .padding(.top, 2)
        .pointingHandCursor()
      }
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
    var run: [String] = [
      (failed ? "failed after " : "generated in ") + duration(stats.durationSeconds)
    ]
    if let model = stats.model { run.append(model) }
    if let cost = stats.costUSD { run.append(String(format: "$%.2f", cost)) }
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
          store.hasPromptOverride(for: part) ? store.promptOverride(for: part) : part.defaultTemplate
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
