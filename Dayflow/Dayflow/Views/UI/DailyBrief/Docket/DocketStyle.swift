//
//  DocketStyle.swift
//  Dayflow
//
//  Shared pieces for the "Take these off your plate" docket: the page-wide UI state
//  (prompt open, which menu or pop-up is showing), the prototype's easing curves,
//  its colors, and the button skins (Peach · Lilac pills and the round lilac buttons).
//

import SwiftUI

// MARK: - Shared UI state

/// State the docket shares with the rest of the brief page: the header dims while a
/// prompt is open, the dismiss pop-up sits in the page's corner, and menus draw above
/// everything so a click anywhere else can close them.
@MainActor
final class DocketUIState: ObservableObject {
  static let shared = DocketUIState()

  enum Menu: Equatable {
    case gear
    case folder(title: String)
  }

  /// The front card's prompt is open (the card is wide and lifted).
  @Published var isPromptOpen = false
  @Published var openMenu: Menu?
  /// The task the "Tell us why" pop-up asks about.
  @Published var askTitle: String?
  /// When the page last appeared, so the entrance animations share one clock.
  @Published var entranceStart = Date()
  /// The page should scroll to the top (the prompt opened).
  @Published var scrollToTopRequest = 0

  /// Escape closes menus first, then the pop-up. Returns false when nothing was open.
  func closeTopPopup() -> Bool {
    if openMenu != nil {
      openMenu = nil
      return true
    }
    if askTitle != nil {
      withAnimation(DocketMotion.ease(0.3)) { askTitle = nil }
      return true
    }
    return false
  }

  /// Seconds since the entrance started.
  func entranceElapsed(at date: Date = Date()) -> Double {
    date.timeIntervalSince(entranceStart)
  }
}

// MARK: - Motion

enum DocketMotion {
  /// `--do-ease`, used for almost every move.
  static let curve = UnitCurve.bezier(
    startControlPoint: UnitPoint(x: 0.22, y: 0.8), endControlPoint: UnitPoint(x: 0.24, y: 1))
  /// `--do-enter-ease`, used for the entrance.
  static let enterCurve = UnitCurve.bezier(
    startControlPoint: UnitPoint(x: 0.22, y: 1), endControlPoint: UnitPoint(x: 0.36, y: 1))

  static func ease(_ duration: Double) -> Animation {
    .timingCurve(0.22, 0.8, 0.24, 1, duration: duration)
  }

  static func enter(_ duration: Double) -> Animation {
    .timingCurve(0.22, 1, 0.36, 1, duration: duration)
  }

  /// The card's shrink when the prompt closes.
  static let collapse = Animation.timingCurve(0.45, 0, 0.2, 1, duration: 0.6)

  /// 0…1 progress of a step that starts at `start` and lasts `duration`, through `curve`.
  static func progress(
    _ elapsed: Double, start: Double, duration: Double, curve: UnitCurve = .linear
  ) -> Double {
    let raw = min(max((elapsed - start) / duration, 0), 1)
    return curve.value(at: raw)
  }

  /// Plain linear blend between two numbers.
  static func mix(_ from: Double, _ to: Double, _ amount: Double) -> Double {
    from + (to - from) * amount
  }
}

// MARK: - Colors

enum DocketColors {
  static let ink = Color(hex: "333333")
  static let title = Color(hex: "000000")
  static let count = Color(hex: "9D9D9D")
  static let countHover = Color(hex: "6F6F6F")
  static let label = Color(hex: "C0B6B6")
  static let labelOpen = Color(hex: "C9B7B4")
  static let promptOpen = Color(hex: "7D7D7D")
  static let folder = Color(hex: "E08858")
  static let panel = Color(hex: "F1E9E7")
  static let divider = Color(hex: "ECE7E4")
  static let cardFront = Color(hex: "FBF5F3")
  static let cardSecond = Color(hex: "F8F2F1")
  static let cardThird = Color(hex: "F4EDEC")
  static let roundFill = Color(hex: "D8DFF4")
  static let roundBorder = Color(hex: "D4D5D9")

  /// The window background: peach low and slightly right of center, pale blue at the top.
  static let pageBackground = EllipticalGradient(
    stops: [
      .init(color: Color(hex: "FFE6CF"), location: 0),
      .init(color: Color(hex: "FFE6E0"), location: 0.3702),
      .init(color: Color(hex: "DAEAFC"), location: 0.9891),
    ],
    center: UnitPoint(x: 0.5917, y: 1),
    startRadiusFraction: 0,
    endRadiusFraction: 0.5)
}

// MARK: - Skins

/// The Peach · Lilac pill used by Dismiss and Hand off.
struct DocketPillSkin: ViewModifier {
  func body(content: Content) -> some View {
    content
      .background(
        Capsule().fill(
          LinearGradient(
            stops: [
              .init(color: Color(hex: "F7D5C3"), location: 0),
              .init(color: Color(hex: "F0E1DD"), location: 0.5),
              .init(color: Color(hex: "EBEEFA"), location: 1),
            ], startPoint: .top, endPoint: .bottom))
      )
      .overlay(InnerGlow(shape: Capsule(), color: Color.white.opacity(0.6), radius: 5))
      .overlay(
        Capsule()
          .inset(by: 1)
          .stroke(Color.white.opacity(0.85), lineWidth: 1)
          .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center))
          .allowsHitTesting(false)
      )
      .overlay(
        Capsule().strokeBorder(
          LinearGradient(
            stops: [
              .init(color: Color(hex: "F7F7F9"), location: 0),
              .init(color: Color(hex: "DFE0E5"), location: 0.35),
              .init(color: Color(hex: "D6D7DD"), location: 1),
            ], startPoint: .top, endPoint: .bottom),
          lineWidth: 1)
      )
  }
}

/// The round lilac skin used by Undo, the gear, the list's send button and the
/// toggle's selected segment.
struct DocketRoundSkin<S: InsettableShape>: ViewModifier {
  let shape: S
  var glow: CGFloat = 9

  func body(content: Content) -> some View {
    content
      .background(shape.fill(DocketColors.roundFill))
      .overlay(InnerGlow(shape: shape, color: Color.white.opacity(0.8), radius: glow / 2))
      .overlay(shape.strokeBorder(DocketColors.roundBorder, lineWidth: 0.75))
  }
}

extension View {
  func docketPillSkin() -> some View { modifier(DocketPillSkin()) }

  func docketRoundSkin() -> some View { modifier(DocketRoundSkin(shape: Circle())) }

  /// Brightens slightly on hover and darkens while pressed, like the prototype's buttons.
  func docketHoverBrightness(_ isHovered: Bool) -> some View {
    brightness(isHovered ? 0.03 : 0)
      .animation(.easeOut(duration: 0.15), value: isHovered)
  }
}

/// A plain button style that dims a little while pressed (`brightness(0.97)`).
struct DocketPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .brightness(configuration.isPressed ? -0.03 : 0)
      .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
  }
}

// MARK: - Small icons

/// The outward arrow shown on hover next to links ("M6 6v2h8.59L5 17.59 6.41 19 16 9.41V18h2V6z").
struct DocketOutwardArrow: Shape {
  func path(in rect: CGRect) -> Path {
    let scale = min(rect.width, rect.height) / 24
    var path = Path()
    let points: [CGPoint] = [
      .init(x: 6, y: 6), .init(x: 6, y: 8), .init(x: 14.59, y: 8), .init(x: 5, y: 17.59),
      .init(x: 6.41, y: 19), .init(x: 16, y: 9.41), .init(x: 16, y: 18), .init(x: 18, y: 18),
      .init(x: 18, y: 6),
    ]
    path.addLines(points.map { CGPoint(x: rect.minX + $0.x * scale, y: rect.minY + $0.y * scale) })
    path.closeSubpath()
    return path
  }
}

/// A docket task's people with feedback, collapsed the way the prototype does it: when a
/// summary exists, one entry per person that carries the summary instead of each note.
struct DocketFeedbackEntry: Hashable {
  var name: String
  var source: String?
  var text: String
  var url: String?
  /// True when `source` should read "Summarized from Slack" and link to `url`.
  var isSummary: Bool
}

enum DocketFeedback {
  static func entries(for item: DailyBriefDocketItem) -> [DocketFeedbackEntry] {
    let notes = item.feedback ?? []
    guard !notes.isEmpty else { return [] }
    if let summary = item.feedbackSummary, !summary.isEmpty {
      var names: [String] = []
      for note in notes where !names.contains(note.name) { names.append(note.name) }
      let url = item.feedbackUrl ?? notes.first?.url
      let source = (url ?? "").contains("slack") ? "Summarized from Slack" : "Summarized"
      return names.map { name in
        DocketFeedbackEntry(name: name, source: source, text: summary, url: url, isSummary: true)
      }
    }
    return notes.map {
      DocketFeedbackEntry(
        name: $0.name, source: $0.source, text: $0.text, url: $0.url, isSummary: false)
    }
  }

  /// Distinct people, in order, for the avatar dots.
  static func people(for item: DailyBriefDocketItem) -> [String] {
    var names: [String] = []
    for note in item.feedback ?? [] where !names.contains(note.name) { names.append(note.name) }
    return names
  }
}
