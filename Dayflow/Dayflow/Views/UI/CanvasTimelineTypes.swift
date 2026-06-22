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
      return "Reg"
    case .medium:
      return "Med"
    case .semibold:
      return "Semi"
    case .bold:
      return "Bold"
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

struct TimelineTimeLabelFramesPreferenceKey: PreferenceKey {
  static var defaultValue: [CGRect] = []

  static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
    value.append(contentsOf: nextValue())
  }
}
