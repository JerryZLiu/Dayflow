//
//  DailyBriefMenuBarNotice.swift
//  Dayflow
//
//  The "your brief is ready" card that floats just under the Dayflow menu bar
//  icon when today's brief finishes. Clicking it opens Dayflow on the Timeline
//  with the brief on top. Design: Daily Figma file, node 177:5337.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class DailyBriefMenuBarNotice {
  static let shared = DailyBriefMenuBarNotice()

  /// Room around the card for its shadow.
  private static let margin: CGFloat = 16
  /// Gap between the menu bar icon and the top of the card.
  private static let gapBelowIcon: CGFloat = 6

  private var panel: NSPanel?
  private var cancellables: Set<AnyCancellable> = []

  /// When the card appeared, so every event says how long it had been up.
  private var shownAt: Date?
  /// Set once the card is opened or dismissed, so going away on its own (the brief
  /// was opened from the Timeline instead) isn't counted as either.
  private var wasActedOn = false

  private init() {}

  /// What every event on this card carries: which wording the test showed, how many
  /// tasks there were (the "tasks" wording falls back to the control's with none), and
  /// how many seconds the card had been on screen.
  private func noticeProperties(_ action: String) -> [String: Any] {
    var properties: [String: Any] = [
      "action": action, "copy": DailyBriefNoticeCopy.analyticsName,
      "task_count": DailyBriefStore.shared.docketItems.count,
    ]
    if let shownAt {
      properties["seconds_shown"] = Int(Date().timeIntervalSince(shownAt))
    }
    return properties
  }

  /// Call once at app launch, after the status bar exists.
  func start() {
    let store = DailyBriefStore.shared
    store.$showsReadyNotice
      .combineLatest(store.$isPresented)
      .removeDuplicates { $0 == $1 }
      .receive(on: DispatchQueue.main)
      .sink { [weak self] showsNotice, isPresented in
        if showsNotice && !isPresented {
          self?.show()
        } else {
          self?.hide()
        }
      }
      .store(in: &cancellables)
  }

  // MARK: - Actions

  /// `target` is what the click landed on: the "button" or the "card" behind it.
  private func open(target: String) {
    wasActedOn = true
    var properties = noticeProperties("open")
    properties["target"] = target
    AnalyticsService.shared.capture("daily_brief_menu_bar_notice", properties)

    let showDockIcon = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true
    if showDockIcon {
      NSApp.setActivationPolicy(.regular)
    }
    NSApp.unhide(nil)
    MainWindowController.shared.showMainWindow()
    NSApp.activate(ignoringOtherApps: true)

    // The brief lives over the Timeline, so switch there first.
    NotificationCenter.default.post(name: .navigateToTimeline, object: nil)
    DailyBriefStore.shared.present(source: "menu_bar_notice")
  }

  private func close() {
    wasActedOn = true
    AnalyticsService.shared.capture("daily_brief_menu_bar_notice", noticeProperties("close"))
    DailyBriefStore.shared.dismissReadyNotice()
  }

  // MARK: - Panel

  private func show() {
    // Before the card draws, so it draws in its test wording from the first frame.
    if panel?.isVisible != true { DailyBriefNoticeCopy.resolve() }
    let panel = self.panel ?? makePanel()
    self.panel = panel
    position(panel)
    guard !panel.isVisible else { return }

    shownAt = Date()
    wasActedOn = false
    AnalyticsService.shared.capture("daily_brief_menu_bar_notice", noticeProperties("shown"))
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      panel.animator().alphaValue = 1
    }
  }

  private func hide() {
    guard let panel, panel.isVisible else { return }
    // The card went away without being clicked or dismissed, so the brief was opened
    // some other way (the Timeline's sun button) or the run was superseded.
    if !wasActedOn {
      AnalyticsService.shared.capture("daily_brief_menu_bar_notice", noticeProperties("passed_by"))
    }
    shownAt = nil
    NSAnimationContext.runAnimationGroup(
      { context in
        context.duration = 0.2
        panel.animator().alphaValue = 0
      },
      completionHandler: {
        Task { @MainActor in
          if panel.alphaValue == 0 { panel.orderOut(nil) }
        }
      })
  }

  private func makePanel() -> NSPanel {
    let size = NSSize(
      width: DailyBriefMenuBarNoticeCard.size.width + Self.margin * 2,
      height: DailyBriefMenuBarNoticeCard.size.height + Self.margin * 2)
    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isMovableByWindowBackground = false
    panel.hidesOnDeactivate = false

    let card = DailyBriefMenuBarNoticeCard(
      onOpen: { [weak self] target in self?.open(target: target) },
      onClose: { [weak self] in self?.close() }
    )
    .padding(Self.margin)

    let hostingView = NSHostingView(rootView: card)
    hostingView.frame = NSRect(origin: .zero, size: size)
    hostingView.autoresizingMask = [.width, .height]
    hostingView.sizingOptions = []
    panel.contentView = hostingView
    return panel
  }

  /// Centered under the menu bar icon. Falls back to the top right of the main
  /// screen when macOS is hiding the icon (for example, a crowded menu bar).
  private func position(_ panel: NSPanel) {
    let size = panel.frame.size
    var origin: NSPoint

    if let icon = StatusBarController.current?.iconFrameOnScreen(),
      let screen = NSScreen.screens.first(where: { $0.frame.intersects(icon) })
    {
      let visible = screen.visibleFrame
      let x = icon.midX - size.width / 2
      origin = NSPoint(
        x: min(max(x, visible.minX + 8 - Self.margin), visible.maxX - size.width + Self.margin - 8),
        y: icon.minY - Self.gapBelowIcon - size.height + Self.margin)
    } else if let screen = NSScreen.main {
      let visible = screen.visibleFrame
      origin = NSPoint(
        x: visible.maxX - size.width - 8,
        y: visible.maxY - size.height + Self.margin - Self.gapBelowIcon)
    } else {
      return
    }

    // Step below any other Dayflow card already floating there (e.g. Flow's early-bird card).
    let proposed = NSRect(origin: origin, size: size).insetBy(dx: Self.margin, dy: Self.margin)
    for window in NSApp.windows where window !== panel && window.isVisible && window is NSPanel {
      if window.level >= .floating, window.frame.intersects(proposed) {
        origin.y = window.frame.minY - size.height + Self.margin
      }
    }
    panel.setFrameOrigin(origin)
  }
}

// MARK: - Wording test

/// The A/B test on this card's wording. Each variant is one idea about what makes
/// someone open the brief: `control` says it's ready, `morning` greets them with the
/// date, and `tasks` leads with how many jobs their agents could take today.
@MainActor
enum DailyBriefNoticeCopy: String {
  case control
  case morning
  case tasks

  /// PostHog multivariate flag. Its variant keys are these raw values; anything
  /// else, a missing flag, or analytics being off all show the control wording.
  static let flagKey = "daily-brief-notice-copy"

  /// nil until PostHog has answered.
  private static var resolved: DailyBriefNoticeCopy?

  /// Asks PostHog for this user's variant, once it has an answer. Called as the card
  /// appears, so the wording can't change while it's on screen.
  static func resolve() {
    guard resolved == nil,
      let name = AnalyticsService.shared.featureFlagValue(flagKey) as? String
    else { return }
    resolved = DailyBriefNoticeCopy(rawValue: name) ?? .control
  }

  /// The wording to show: the control's until PostHog has answered.
  static var current: DailyBriefNoticeCopy { resolved ?? .control }

  /// The variant name for analytics. "unassigned" means PostHog hadn't answered and the
  /// control wording was shown; leave those out of the test's numbers.
  static var analyticsName: String { resolved?.rawValue ?? "unassigned" }

  /// The serif line. Two lines at most in the card's 123pt column, so about 29
  /// characters; a task count that isn't there falls back to the control line.
  func title(date: Date, taskCount: Int) -> String {
    switch self {
    case .control: return "Your brief is ready"
    case .morning: return "Good morning"
    case .tasks:
      guard taskCount > 0 else { return Self.control.title(date: date, taskCount: 0) }
      let noun = taskCount == 1 ? "thing" : "things"
      return "Hand \(taskCount) \(noun) to your agents"
    }
  }

  /// The grey line under it. Two lines at most, so about 40 characters.
  func subtitle(date: Date, taskCount: Int) -> String {
    switch self {
    case .control: return "What you did, and what to read today."
    case .morning:
      let day = date.formatted(.dateTime.month(.abbreviated).day())
      return "Your \(day) brief is ready."
    case .tasks:
      guard taskCount > 0 else { return Self.control.subtitle(date: date, taskCount: 0) }
      return "They'll work while you read."
    }
  }
}

// MARK: - Card

/// The tinted-glass card from Figma. The painted background (gradient, sleeve,
/// photos, sticker) is one image; the text, button, and date are live.
struct DailyBriefMenuBarNoticeCard: View {
  static let size = CGSize(width: 266, height: 145)

  /// Called with what the click landed on: "button" or "card".
  let onOpen: (String) -> Void
  let onClose: () -> Void

  /// The panel is built once and reused on later days, so the card watches the store
  /// to keep its date and task count current.
  @ObservedObject private var store = DailyBriefStore.shared
  @State private var isHovering = false

  var body: some View {
    ZStack(alignment: .topLeading) {
      Image("DailyBriefNoticeCard")
        .resizable()
        .frame(width: Self.size.width, height: Self.size.height)

      VStack(alignment: .leading, spacing: 2) {
        Text(copy.title(date: briefDate, taskCount: taskCount))
          .font(.custom("InstrumentSerif-Regular", size: 20))
          .foregroundStyle(Color(hex: "113111"))
          .lineSpacing(-3)
        // Two lines at most: the button starts right under this.
        Text(copy.subtitle(date: briefDate, taskCount: taskCount))
          .font(.custom("Figtree", size: 13))
          .foregroundStyle(Color(hex: "888888"))
          .lineSpacing(0.5)
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(width: 123, alignment: .leading)
      .offset(x: 12, y: 15)

      rundownButton
        .offset(x: 11.6, y: 100.7)

      DailyBriefNoticeDate(date: briefDate)
        .frame(width: 45.4, height: 37.1, alignment: .bottom)
        .rotationEffect(.degrees(9.15))
        .offset(x: 203, y: 93)

      if isHovering {
        closeButton
          .offset(x: Self.size.width - 26, y: 8)
          .transition(.opacity)
      }
    }
    .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      // Inset white highlight along the top edge.
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(
          LinearGradient(
            colors: [.white, .white.opacity(0)], startPoint: .top, endPoint: .init(x: 0.5, y: 0.08)),
          lineWidth: 1)
    )
    .shadow(
      color: Color(red: 26 / 255, green: 31 / 255, blue: 31 / 255).opacity(0.05), radius: 1, y: 1
    )
    .shadow(
      color: Color(red: 26 / 255, green: 31 / 255, blue: 31 / 255).opacity(0.25), radius: 8, y: 4
    )
    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .onTapGesture { onOpen("card") }
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
    }
    .pointingHandCursor()
  }

  private var rundownButton: some View {
    Button {
      onOpen("button")
    } label: {
      Text("Read it")
        .font(.custom("Figtree", size: 12).weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(Color(hex: "FF9F6F")))
        .overlay(
          InnerGlow(
            shape: Capsule(), color: Color(red: 1, green: 220 / 255, blue: 203 / 255).opacity(0.9),
            radius: 3)
        )
        .overlay(Capsule().strokeBorder(Color(hex: "F4C8B1"), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.06), radius: 1, y: 2)
    }
    .buttonStyle(DayflowPressScaleButtonStyle())
  }

  private var closeButton: some View {
    Button(action: onClose) {
      Image(systemName: "xmark")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(Color(hex: "888888"))
        .frame(width: 18, height: 18)
        .background(Circle().fill(.white.opacity(0.85)))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Dismiss")
  }

  private var copy: DailyBriefNoticeCopy { DailyBriefNoticeCopy.current }

  /// Tasks waiting in the stack, for the wording that counts them.
  private var taskCount: Int { store.docketItems.count }

  /// The brief's own day, so the calendar matches the brief even after midnight.
  private var briefDate: Date {
    store.brief.flatMap { DateFormatter.yyyyMMdd.date(from: $0.day) } ?? Date()
  }
}

/// "OCTOBER" over a dot-matrix day number, printed on the folder sleeve.
private struct DailyBriefNoticeDate: View {
  let date: Date

  var body: some View {
    VStack(spacing: 4) {
      Text(date.formatted(.dateTime.month(.wide)).uppercased())
        .font(.custom("Figtree", size: 8).weight(.medium))
        .foregroundStyle(.white)
      DotMatrixNumber(text: String(Calendar.current.component(.day, from: date)))
    }
  }
}

/// Digits drawn as square dots on a 5×7 grid, standing in for the design's
/// Doto font (not bundled with the app).
private struct DotMatrixNumber: View {
  let text: String

  private static let cell: CGFloat = 3.5
  private static let dot: CGFloat = 3.1
  private static let digitGap: CGFloat = 3.5

  private static let glyphs: [Character: [String]] = [
    "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
    "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
    "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
    "3": ["11110", "00001", "00001", "01110", "00001", "00001", "11110"],
    "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
    "5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
    "6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
    "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
    "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
    "9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
  ]

  var body: some View {
    let digits = Array(text)
    let width =
      CGFloat(digits.count) * 5 * Self.cell + CGFloat(max(digits.count - 1, 0)) * Self.digitGap
    Canvas { context, _ in
      for (index, digit) in digits.enumerated() {
        guard let rows = Self.glyphs[digit] else { continue }
        let originX = CGFloat(index) * (5 * Self.cell + Self.digitGap)
        for (row, bits) in rows.enumerated() {
          for (column, bit) in bits.enumerated() where bit == "1" {
            let rect = CGRect(
              x: originX + CGFloat(column) * Self.cell,
              y: CGFloat(row) * Self.cell,
              width: Self.dot, height: Self.dot)
            context.fill(Path(rect), with: .color(.white))
          }
        }
      }
    }
    .frame(width: width, height: 7 * Self.cell)
  }
}
