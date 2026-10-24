import SwiftUI

enum TimelineScale {
  static let hourHeight: CGFloat = 168
}

enum TimelineCardLayout {
  static let iconLeadingInset: CGFloat = 16
  static let iconTextSpacing: CGFloat = 6
  static let faviconSize: CGFloat = 18
  static let faviconVerticalOffset: CGFloat = 0
  static let compactDurationThreshold: CGFloat = 13
  static let compactVerticalPadding: CGFloat = 0
  static let normalVerticalPadding: CGFloat = 6
  static let hoverScale: CGFloat = 1.005
  static let pressedScale: CGFloat = 0.992
}

enum TimelineTypography {
  static let cardTextFontSize: CGFloat = 16
  static let cardTextFontWeight: TimelineCardTextWeight = .regular
  static let timeLabelFontSize: CGFloat = 12

  static func cardSecondaryTextFontSize(for cardTextFontSize: CGFloat) -> CGFloat {
    max(8, cardTextFontSize - 3)
  }
}

enum TimelineCardTextWeight: String, CaseIterable, Identifiable {
  case regular
  case medium
  case semibold
  case bold

  var id: String { rawValue }

  var label: String {
    switch self {
    case .regular:
      return String(localized: "Reg")
    case .medium:
      return String(localized: "Med")
    case .semibold:
      return String(localized: "Semi")
    case .bold:
      return String(localized: "Bold")
    }
  }

  var fontWeight: Font.Weight {
    switch self {
    case .regular:
      return .regular
    case .medium:
      return .medium
    case .semibold:
      return .semibold
    case .bold:
      return .bold
    }
  }
}

/// Geometry of a scrolling timeline. The content frame changes on every
/// scroll frame, so it lives in a plain reference box instead of @State:
/// writing to it never re-renders the timeline. Only touched on the main thread.
final class TimelineScrollGeometry {
  /// The scroll content's frame in the "TimelinePane" coordinate space.
  var contentFrame: CGRect = .zero
  /// Height of one hour label. Measured once; labels and cards are otherwise
  /// placed at known offsets inside the content, so their frames are computed.
  var timeLabelHeight: CGFloat = 0
}

/// What the "X hours tracked" footer needs to know about the timeline that
/// scrolls under it. The Day and Week views write it while scrolling and only
/// the footer view reads it, so scrolling never re-renders MainView.
/// This is an ObservableObject rather than @Observable because the app's own
/// `Observation` model type shadows the Observation framework the macro needs.
final class TimelineFooterState: ObservableObject {
  static let fadeDistance: CGFloat = 12

  /// 1 = fully visible; fades to 0 as an hour label slides under the footer.
  @Published private(set) var labelFadeOpacity: Double = 1
  /// True while an activity card or the status card sits under the footer.
  @Published private(set) var overlapsCard = false

  var opacity: Double {
    overlapsCard ? 0 : labelFadeOpacity
  }

  func update(footerFrame: CGRect, labelFrames: [CGRect], cardFrames: [CGRect]) {
    guard footerFrame != .zero else {
      set(labelFadeOpacity: 1, overlapsCard: false)
      return
    }

    var maxOverlap: CGFloat = 0
    for frame in labelFrames {
      let intersection = footerFrame.intersection(frame)
      if !intersection.isNull {
        maxOverlap = max(maxOverlap, intersection.height)
      }
    }
    let clamped = min(maxOverlap, Self.fadeDistance)
    // Rounded to tenths so a label crossing the footer causes ~10 updates,
    // not one per scrolled pixel.
    let fade = (Double(1 - clamped / Self.fadeDistance) * 10).rounded() / 10

    let overlaps = cardFrames.contains { $0.intersects(footerFrame) }
    set(labelFadeOpacity: fade, overlapsCard: overlaps)
  }

  func clearCardOverlap() {
    set(labelFadeOpacity: labelFadeOpacity, overlapsCard: false)
  }

  // @Published notifies readers on every assignment, even an unchanged one,
  // so only assign when the value actually changes.
  private func set(labelFadeOpacity newFade: Double, overlapsCard newOverlaps: Bool) {
    if labelFadeOpacity != newFade {
      labelFadeOpacity = newFade
    }
    if overlapsCard != newOverlaps {
      overlapsCard = newOverlaps
    }
  }
}

struct TimelineTimeLabelFramesPreferenceKey: PreferenceKey {
  static var defaultValue: [CGRect] = []

  static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
    value.append(contentsOf: nextValue())
  }
}
