//
//  StylePreview.swift
//  Dayflow
//
//  The refreshed styling shipped as the only mode; `showAfter` is now a
//  constant so the many views branching on `\.stylePreviewAfter` (or
//  `StylePreview.shared.showAfter` outside the view hierarchy) always get
//  the refreshed look.
//

import SwiftUI

@MainActor
final class StylePreview: ObservableObject {
  static let shared = StylePreview()

  let showAfter = true

  private init() {}
}

// MARK: - Standup style constants (light mode)

/// Fixed styling for the standup card's light mode, arrived at with the
/// (now removed) dev tuning tools.
enum StandupStyle {
  static let strokeColor = Color(hex: "DADADA")
  static let headingColor = Color(hex: "90837A")
  static let shadowColor = Color(hex: "000000").opacity(0.1)
  static let shadowBlur: Double = 8
  static let shadowDistance: Double = 4
  static let bottomSpace: Double = 52
  static let horizontalMargin: Double = 52
  // Extra inset applied to the "today so far" grid within the content column.
  static let todayPadding: Double = 0
  // Total gap between the "today so far" grid and the standup section.
  static let sectionGap: Double = 60
}

// MARK: - Environment plumbing

private struct StylePreviewAfterKey: EnvironmentKey {
  static let defaultValue = true
}

extension EnvironmentValues {
  /// Always true now that the refreshed styling shipped.
  var stylePreviewAfter: Bool {
    get { self[StylePreviewAfterKey.self] }
    set { self[StylePreviewAfterKey.self] = newValue }
  }
}

extension View {
  /// Attach once at the window root; descendants read `\.stylePreviewAfter`.
  func resolveStylePreview() -> some View {
    modifier(StylePreviewResolver())
  }
}

private struct StylePreviewResolver: ViewModifier {
  @ObservedObject private var preview = StylePreview.shared

  func body(content: Content) -> some View {
    content.environment(\.stylePreviewAfter, preview.showAfter)
  }
}
