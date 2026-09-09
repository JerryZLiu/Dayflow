//
//  DayflowTheme.swift
//  Dayflow
//
//  Single source of truth for light/dark styling. Every value here comes from
//  the Figma "Interface refresh" file. Views read `@Environment(\.dayflowTheme)`
//  instead of hardcoding hex colors so both appearances stay side by side.
//

import SwiftUI

// MARK: - Appearance preference

/// User-facing appearance choice. Defaults to following the system.
enum DayflowAppearance: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  static let storageKey = "dayflowAppearance"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system: return "System"
    case .light: return "Light"
    case .dark: return "Dark"
    }
  }

  /// `nil` means "let the system decide".
  var preferredColorScheme: ColorScheme? {
    switch self {
    case .system: return nil
    case .light: return .light
    case .dark: return .dark
    }
  }
}

// MARK: - Theme tokens

struct DayflowTheme {
  let isDark: Bool

  // Window
  let windowBackground: AnyShapeStyle
  let windowBorder: Color

  // Main content panel (the big rounded card next to the sidebar)
  let panelFill: AnyShapeStyle
  let panelBorder: Color
  let panelShadow: Color
  let panelInnerGlow: Color
  /// Opaque approximation of the panel color, for fades that must hide content.
  let panelSolid: Color

  // Sidebar
  let sidebarSelectedFill: LinearGradient
  let sidebarSelectedBorder: Color
  let sidebarSelectedInnerGlow: Color
  let sidebarSelectedShadow: Color
  let sidebarLabel: Color
  let sidebarLabelActive: Color
  let sidebarIcon: Color
  let sidebarIconActive: Color

  // Text
  let textPrimary: Color
  let textSecondary: Color
  let textTertiary: Color
  let textMuted: Color
  let accent: Color
  let accentText: Color

  // Peach "glass" control (calendar pill, Pause, selected Day/Week segment)
  let controlFill: Color
  let controlBorder: Color
  let controlInnerGlow: Color
  let controlText: Color

  // Day/Week segmented container
  let segmentTrackFill: Color
  let segmentTrackBorder: Color
  let segmentInactiveText: Color

  // Small circular edit (pencil) button
  let editButtonFill: Color
  let editButtonBorder: Color
  let editButtonInnerGlow: Color

  // Category chips in the timeline header
  let chipFill: Color
  let chipBorder: Color
  let chipText: Color

  // Timeline grid
  let hourLabel: Color
  let hourLabelFuture: Color
  let hourLine: Color

  // Day timeline activity cards
  let cardFill: Color
  let cardBorder: Color
  let cardInnerGlow: Color
  let cardTitle: Color
  let cardTime: Color
  let cardFailedFill: Color

  // "Generating your next card…" card
  let generatingGradient: LinearGradient
  let pausedCardGradient: LinearGradient
  let pausedCardText: Color

  // Week timeline cards
  let weekCardFillOpacity: Double

  // Right panel (day summary)
  let rightPanelFill: Color
  let rightPanelBorder: Color
  let rightPanelShadow: Color
  let rightPanelDivider: Color

  // Today's targets header
  let targetsFill: Color
  let targetsBorder: Color
  let targetsTrackFill: Color
  let targetsTrackBorder: Color
  let targetsBubbleFill: Color
  let targetsBubbleBorder: Color
  let targetsInactiveTrack: Color
  let targetsInactiveFill: Color

  // Summary cards (Total focus time, Longest focus, Distractions)
  let summaryCardFill: Color
  let summaryCardBorder: Color
  let summaryCardShadow: Color
  let summaryCardInnerGlow: Color
  let summaryValue: Color

  // Donut chart
  let donutRingBackground: Color
  let donutCenterFill: Color
  let donutShadow: Color
  let legendSwatchOpacity: Double

  // Secondary button (Copy timeline, Cancel)
  let secondaryButtonFill: Color
  let secondaryButtonBorder: Color
  let secondaryButtonText: Color

  // Primary button (Confirm, Continue)
  let primaryButtonFill: Color
  let primaryButtonBorder: Color
  let primaryButtonInnerGlow: Color
  let primaryButtonText: Color

  // Floating editors / popovers
  let popoverFill: Color
  let popoverBorder: Color

  // Day goal sheet
  let sheetOverlay: Color
  let sheetCardFill: Color
  let sheetCardBorder: Color
  let sheetFocusHeader: Color
  let sheetDistractionHeader: Color
  let sheetFocusStatText: Color
  let sheetDistractionStatText: Color
  let sheetPanelFill: Color
  let sheetPanelBorder: Color
  let sheetInnerBoxFill: Color
  let sheetInnerBoxBorder: Color
  let sheetFooterFill: Color
  let sheetWheelGradient: LinearGradient
  let sheetWheelBorder: Color
  let sheetWheelDimText: Color

  // Daily view
  let dailyGridFill: Color
  let dailyGridBorder: Color
  let dailyTotalsFill: Color
  let dailyEmptyCell: Color
  let dailyDistractionTrack: Color
  let dailyDistractionTrackBorder: Color
  let dailyStatValue: Color
  let standupCardGradient: LinearGradient
  let standupCardBorder: Color
  let standupBlockersFill: Color
  let standupBlockersBorder: Color

  // Standard text field / input
  let inputFill: Color
  let inputBorder: Color

  // Chat
  let chatBackground: AnyShapeStyle
  let chatSoftAccentFill: Color
  let chatSoftAccentBorder: Color
  let chatSidePanelFill: Color
  let chatSidePanelHeaderFill: Color
  let chatCodeFill: Color
}

// MARK: - Light

extension DayflowTheme {
  /// The in-progress "After" light palette.
  static let light = lightPalette(after: true)
  /// The shipped light palette, rendered when the style preview is "Before".
  static let lightBefore = lightPalette(after: false)

  private static func lightPalette(after: Bool) -> DayflowTheme {
    DayflowTheme(
      isDark: false,
      windowBackground: AnyShapeStyle(
        after
          ? RadialGradient(
            stops: [
              .init(color: Color(hex: "FFE6CF"), location: 0.17),
              .init(color: Color(hex: "FFE6E0"), location: 0.33),
              .init(color: Color(hex: "D6E8FF"), location: 1),
            ],
            center: UnitPoint(x: 0.64, y: 1.0),
            startRadius: 0,
            endRadius: 1250
          )
          : RadialGradient(
            stops: [
              .init(color: Color(hex: "FFE6CF"), location: 0),
              .init(color: Color(hex: "FFE6E0"), location: 0.37),
              .init(color: Color(hex: "DAEAFC"), location: 0.99),
            ],
            center: UnitPoint(x: 0.59, y: 1.0),
            startRadius: 0,
            endRadius: 1250
          )
      ),
      windowBorder: Color(hex: "DBDBDB"),

      panelFill: AnyShapeStyle(Color(hex: "FBFBFB").opacity(0.55)),
      panelBorder: Color(hex: "FAFAFA"),
      panelShadow: Color.black.opacity(0.08),
      panelInnerGlow: after ? Color.white.opacity(0.25) : .clear,
      panelSolid: Color(hex: "FBF6F4"),

      sidebarSelectedFill: LinearGradient(
        colors: [Color.white.opacity(0.7), Color.white.opacity(0.35)],
        startPoint: .top,
        endPoint: .bottom
      ),
      sidebarSelectedBorder: Color.white.opacity(0.2),
      sidebarSelectedInnerGlow: Color.white.opacity(0.8),
      sidebarSelectedShadow: Color(hex: "D5D3D9"),
      sidebarLabel: Color(hex: "727272"),
      sidebarLabelActive: Color(hex: "333333"),
      sidebarIcon: Color(hex: "727272"),
      sidebarIconActive: Color(hex: "333333"),

      textPrimary: Color(hex: "333333"),
      textSecondary: Color(hex: "707070"),
      textTertiary: Color(hex: "787878"),
      textMuted: Color(hex: "979797"),
      accent: Color(hex: "F3854B"),
      accentText: Color(hex: "FFA376"),

      controlFill: Color(hex: "FFD2B9"),
      controlBorder: Color(hex: "EAD5CD"),
      controlInnerGlow: Color(hex: "FFECE6"),
      controlText: Color(hex: "606060"),

      segmentTrackFill: Color(hex: "E7E6E5"),
      segmentTrackBorder: Color(hex: "D5D5D5"),
      segmentInactiveText: Color(hex: "727272"),

      editButtonFill: Color(hex: "DBCFCB"),
      editButtonBorder: Color(hex: "D9CECA"),
      editButtonInnerGlow: Color.white.opacity(0.25),

      chipFill: Color.white.opacity(0.9),
      chipBorder: Color(hex: "E1E1E1"),
      chipText: Color(hex: "333333"),

      hourLabel: Color(hex: "727272"),
      hourLabelFuture: Color(hex: "594838"),
      hourLine: Color.black.opacity(0.12),

      cardFill: Color.white.opacity(after ? 0.61 : 0.9),
      cardBorder: Color(hex: "D0D0D0"),
      cardInnerGlow: Color.white,
      cardTitle: Color(hex: "333333"),
      cardTime: Color(hex: "979797"),
      cardFailedFill: Color(hex: "FFECE4"),

      generatingGradient: LinearGradient(
        colors: [
          Color(red: 50 / 255, green: 135 / 255, blue: 1).opacity(0.55),
          Color(red: 1, green: 165 / 255, blue: 153 / 255).opacity(0.36),
        ],
        startPoint: .leading,
        endPoint: .trailing
      ),
      pausedCardGradient: LinearGradient(
        stops: [
          .init(color: Color(hex: "F7E6D5"), location: 0.13),
          .init(color: Color(hex: "DADEE4"), location: 1.00),
        ],
        startPoint: .leading,
        endPoint: .trailing
      ),
      pausedCardText: Color(hex: "888D95"),

      weekCardFillOpacity: 0.2,

      rightPanelFill: Color.white.opacity(after ? 0.6 : 0.3),
      rightPanelBorder: Color(hex: "ECECEC"),
      rightPanelShadow: Color.black.opacity(0.05),
      rightPanelDivider: Color(hex: "E7E5E3"),

      targetsFill: Color.white.opacity(0.2),
      targetsBorder: Color(hex: "EDE5E1"),
      targetsTrackFill: Color(hex: "EEEEEE"),
      targetsTrackBorder: Color(hex: "DEDEDE"),
      targetsBubbleFill: Color(hex: "E7E7E7"),
      targetsBubbleBorder: Color(hex: "FDFBFB"),
      targetsInactiveTrack: Color(hex: "E4E4E4"),
      targetsInactiveFill: Color(hex: "F6F6F6"),

      summaryCardFill: Color.white.opacity(0.75),
      summaryCardBorder: Color(hex: "F2EEEC"),
      summaryCardShadow: Color.black.opacity(0.05),
      summaryCardInnerGlow: .clear,
      summaryValue: Color(hex: "FFA376"),

      donutRingBackground: Color(red: 0.95, green: 0.94, blue: 0.94),
      donutCenterFill: .white,
      donutShadow: Color(red: 0.39, green: 0.28, blue: 0.22).opacity(0.35),
      legendSwatchOpacity: 0.4,

      secondaryButtonFill: Color(hex: "FCF9F7"),
      secondaryButtonBorder: Color(hex: "D0D0D0"),
      secondaryButtonText: Color(hex: "727272"),

      primaryButtonFill: Color(hex: "FF9F6F"),
      primaryButtonBorder: Color(hex: "F4C8B1"),
      primaryButtonInnerGlow: Color(red: 1, green: 220 / 255, blue: 203 / 255).opacity(0.9),
      primaryButtonText: .white,

      popoverFill: Color(red: 0.98, green: 0.96, blue: 0.95).opacity(0.86),
      popoverBorder: Color(red: 0.91, green: 0.88, blue: 0.87),

      sheetOverlay: Color(red: 214 / 255, green: 188 / 255, blue: 180 / 255).opacity(0.25),
      sheetCardFill: Color.white.opacity(0.6),
      sheetCardBorder: Color(hex: "E1DADA"),
      sheetFocusHeader: Color(hex: "628CFF"),
      sheetDistractionHeader: Color(hex: "FA8282"),
      sheetFocusStatText: Color(hex: "628CFF"),
      sheetDistractionStatText: Color(hex: "FF706B"),
      sheetPanelFill: Color.white.opacity(0.4),
      sheetPanelBorder: Color(hex: "E1DADA"),
      sheetInnerBoxFill: Color.white.opacity(0.3),
      sheetInnerBoxBorder: Color(hex: "E6DDD5"),
      sheetFooterFill: Color.white.opacity(0.6),
      sheetWheelGradient: LinearGradient(
        stops: [
          .init(color: Color(hex: "E9E4E2"), location: 0),
          .init(color: Color(hex: "FFFDFC"), location: 0.25),
          .init(color: Color(hex: "FFFDFC"), location: 0.75),
          .init(color: Color(hex: "E9E4E2"), location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
      ),
      sheetWheelBorder: Color(hex: "E6DDD9"),
      sheetWheelDimText: Color(hex: "AAA6A3"),

      dailyGridFill: Color.white.opacity(after ? 0.46 : 0.75),
      dailyGridBorder: Color(hex: "EBE6E3"),
      dailyTotalsFill: Color(hex: "FAF7F5"),
      dailyEmptyCell: Color(hex: "989898").opacity(0.1),
      dailyDistractionTrack: Color(hex: "F3F3F3"),
      dailyDistractionTrackBorder: .clear,
      dailyStatValue: Color(hex: "A49D98"),
      standupCardGradient: LinearGradient(
        stops: [
          .init(color: Color.white.opacity(0.2), location: 0),
          .init(color: Color.white.opacity(0.7), location: 0.5),
          .init(color: Color.white.opacity(0.2), location: 1),
        ],
        startPoint: .leading,
        endPoint: .trailing
      ),
      standupCardBorder: Color(hex: "E5E5E5"),
      standupBlockersFill: Color(hex: "E3DBD2").opacity(0.25),
      standupBlockersBorder: Color(hex: "E5E5E5"),

      inputFill: Color.white.opacity(0.9),
      inputBorder: Color(hex: "E1E1E1"),

      // "After" is clear so the chat page shows the shared main-panel background
      // (FBFBFB @ 55% with FAFAFA stroke, inner glow, drop shadow).
      chatBackground: after
        ? AnyShapeStyle(Color.clear)
        : AnyShapeStyle(
          LinearGradient(
            colors: [Color(hex: "FFFAF5"), Color(hex: "FFF6EC")],
            startPoint: .top,
            endPoint: .bottom
          )
        ),
      chatSoftAccentFill: Color(hex: "FFF4E9"),
      chatSoftAccentBorder: Color(hex: "F96E00").opacity(0.25),
      chatSidePanelFill: Color.white,
      chatSidePanelHeaderFill: Color(hex: "F5F5F5"),
      chatCodeFill: Color(hex: "FAF7F2")
    )
  }
}

// MARK: - Dark

extension DayflowTheme {
  /// The in-progress "After" dark palette.
  static let dark = darkPalette(after: true)
  /// The shipped dark palette, rendered when the style preview is "Before".
  static let darkBefore = darkPalette(after: false)

  private static func darkPalette(after: Bool) -> DayflowTheme {
    DayflowTheme(
      isDark: true,
      windowBackground: AnyShapeStyle(
        LinearGradient(
          stops: [
            .init(color: Color(red: 48 / 255, green: 60 / 255, blue: 91 / 255), location: 0.21),
            .init(color: Color(red: 49 / 255, green: 51 / 255, blue: 72 / 255), location: 0.53),
            .init(color: Color(red: 59 / 255, green: 41 / 255, blue: 75 / 255), location: 1.05),
          ],
          // CSS -15deg: runs from bottom-left toward top-right, nearly horizontal.
          startPoint: UnitPoint(x: 0, y: 0.63),
          endPoint: UnitPoint(x: 1, y: 0.37)
        )
      ),
      windowBorder: Color(hex: "DBDBDB"),

      panelFill: AnyShapeStyle(
        LinearGradient(
          stops: [
            .init(
              color: Color(red: 39 / 255, green: 41 / 255, blue: 58 / 255).opacity(0.8),
              location: 0.09),
            .init(
              color: Color(red: 32 / 255, green: 39 / 255, blue: 51 / 255).opacity(0.8),
              location: 0.80),
          ],
          // CSS 140deg: top-left toward bottom-right.
          startPoint: UnitPoint(x: 0.1, y: 0),
          endPoint: UnitPoint(x: 0.9, y: 1)
        )
      ),
      panelBorder: Color(hex: "414141"),
      panelShadow: Color.black.opacity(0.12),
      panelInnerGlow: Color.white.opacity(0.2),
      panelSolid: Color(hex: "272A3C"),

      sidebarSelectedFill: LinearGradient(
        colors: [
          Color(red: 116 / 255, green: 114 / 255, blue: 1).opacity(0.3),
          Color(red: 167 / 255, green: 167 / 255, blue: 167 / 255).opacity(0.05),
        ],
        startPoint: .top,
        endPoint: .bottom
      ),
      sidebarSelectedBorder: Color(hex: "848484"),
      sidebarSelectedInnerGlow: Color.white.opacity(0.2),
      sidebarSelectedShadow: .clear,
      sidebarLabel: Color(hex: "A2A2A2"),
      sidebarLabelActive: .white,
      sidebarIcon: Color(hex: "A2A2A2"),
      sidebarIconActive: .white,

      textPrimary: .white,
      textSecondary: Color(hex: "DDDDDD"),
      textTertiary: Color(hex: "B3B3B3"),
      textMuted: Color(hex: "B4B4B4"),
      accent: Color(hex: "F3854B"),
      accentText: Color(hex: "F77952"),

      controlFill: Color(red: 226 / 255, green: 160 / 255, blue: 121 / 255).opacity(0.4),
      controlBorder: Color(hex: "875C46"),
      controlInnerGlow: Color(red: 243 / 255, green: 182 / 255, blue: 152 / 255).opacity(0.5),
      controlText: .white,

      segmentTrackFill: Color.black.opacity(0.35),
      segmentTrackBorder: Color(hex: "3F3F3F"),
      segmentInactiveText: Color(hex: "9D9D9D"),

      editButtonFill: Color(red: 149 / 255, green: 126 / 255, blue: 112 / 255).opacity(0.5),
      editButtonBorder: Color(hex: "777777"),
      editButtonInnerGlow: Color(red: 166 / 255, green: 154 / 255, blue: 148 / 255).opacity(0.5),

      chipFill: Color.white.opacity(0.15),
      chipBorder: Color(hex: "888888"),
      chipText: .white,

      hourLabel: Color(hex: "DDDDDD"),
      hourLabelFuture: Color(hex: "DDDDDD").opacity(0.4),
      hourLine: Color.white.opacity(0.18),

      cardFill: after ? Color(hex: "3A3A4C") : Color.white.opacity(0.15),
      cardBorder: Color(hex: "999999"),
      cardInnerGlow: Color.white.opacity(after ? 0.08 : 0.15),
      cardTitle: .white,
      cardTime: Color(hex: "B4B4B4"),
      cardFailedFill: Color(red: 1, green: 89 / 255, blue: 80 / 255).opacity(0.22),

      generatingGradient: LinearGradient(
        colors: [
          Color(red: 50 / 255, green: 135 / 255, blue: 1).opacity(0.55),
          Color(red: 1, green: 165 / 255, blue: 153 / 255).opacity(0.36),
        ],
        startPoint: .leading,
        endPoint: .trailing
      ),
      pausedCardGradient: LinearGradient(
        colors: [Color.white.opacity(0.18), Color.white.opacity(0.08)],
        startPoint: .leading,
        endPoint: .trailing
      ),
      pausedCardText: Color(hex: "DDDDDD"),

      weekCardFillOpacity: 0.25,

      rightPanelFill: Color(red: 102 / 255, green: 108 / 255, blue: 161 / 255).opacity(0.18),
      rightPanelBorder: Color(hex: "4E4E4E"),
      rightPanelShadow: Color.black.opacity(0.2),
      rightPanelDivider: Color(hex: "585858"),

      targetsFill: Color(red: 127 / 255, green: 122 / 255, blue: 148 / 255).opacity(0.12),
      targetsBorder: Color(hex: "585858"),
      targetsTrackFill: Color.black.opacity(0.3),
      targetsTrackBorder: Color(hex: "666666"),
      targetsBubbleFill: Color(hex: "272634"),
      targetsBubbleBorder: Color(hex: "666666"),
      targetsInactiveTrack: Color.black.opacity(0.3),
      targetsInactiveFill: Color.white.opacity(0.08),

      summaryCardFill: Color.white.opacity(0.12),
      summaryCardBorder: Color(hex: "717171"),
      summaryCardShadow: .clear,
      summaryCardInnerGlow: Color.white.opacity(after ? 0.12 : 0.25),
      summaryValue: Color(hex: "F77952"),

      donutRingBackground: Color.white.opacity(0.2),
      donutCenterFill: Color(hex: "2B2D44"),
      donutShadow: Color.black.opacity(0.35),
      legendSwatchOpacity: 0.6,

      secondaryButtonFill: Color(red: 104 / 255, green: 109 / 255, blue: 138 / 255).opacity(0.4),
      secondaryButtonBorder: Color(hex: "777777"),
      secondaryButtonText: Color(hex: "DDDDDD"),

      primaryButtonFill: Color(hex: "D1653E"),
      primaryButtonBorder: Color(hex: "EA9265"),
      primaryButtonInnerGlow: Color(red: 1, green: 135 / 255, blue: 77 / 255).opacity(0.9),
      primaryButtonText: .white,

      popoverFill: Color(red: 39 / 255, green: 41 / 255, blue: 58 / 255).opacity(0.92),
      popoverBorder: Color(hex: "585858"),

      sheetOverlay: Color.black.opacity(0.4),
      sheetCardFill: Color(red: 127 / 255, green: 122 / 255, blue: 148 / 255).opacity(0.25),
      sheetCardBorder: Color(hex: "686868"),
      sheetFocusHeader: Color(hex: "3362E3"),
      sheetDistractionHeader: Color(hex: "E55A3E"),
      sheetFocusStatText: Color(hex: "59A6FF"),
      sheetDistractionStatText: Color(hex: "FF7053"),
      sheetPanelFill: Color(hex: "6A6A6A").opacity(0.22),
      sheetPanelBorder: Color(hex: "585858"),
      sheetInnerBoxFill: Color.black.opacity(0.15),
      sheetInnerBoxBorder: Color(hex: "444444"),
      sheetFooterFill: Color(hex: "D6D6D6").opacity(0.2),
      sheetWheelGradient: LinearGradient(
        stops: [
          .init(color: Color(hex: "4F4F4F").opacity(0.8), location: 0),
          .init(color: Color(hex: "787878").opacity(0.8), location: 0.3),
          .init(color: Color(hex: "999999").opacity(0.8), location: 0.5),
          .init(color: Color(hex: "787878").opacity(0.8), location: 0.7),
          .init(color: Color(hex: "4F4F4F").opacity(0.8), location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
      ),
      sheetWheelBorder: Color(hex: "5A5A5A"),
      sheetWheelDimText: Color(hex: "B7B7B7"),

      dailyGridFill: Color(hex: "7F7A94").opacity(0.1),
      dailyGridBorder: Color(hex: "4E4E4E"),
      dailyTotalsFill: Color(hex: "ABA8B9").opacity(0.2),
      dailyEmptyCell: Color.white.opacity(0.08),
      dailyDistractionTrack: Color.black.opacity(0.2),
      dailyDistractionTrackBorder: Color(hex: "4D4D4D"),
      dailyStatValue: Color(hex: "909ECD"),
      standupCardGradient: LinearGradient(
        stops: [
          .init(color: Color(hex: "807B93").opacity(0.152), location: 0),
          .init(color: Color(hex: "DEDAEF").opacity(0.152), location: 0.5),
          .init(color: Color(hex: "807B93").opacity(0.152), location: 1),
        ],
        startPoint: .leading,
        endPoint: .trailing
      ),
      standupCardBorder: Color(hex: "4E4E4E"),
      standupBlockersFill: Color(hex: "ABA8B9").opacity(0.2),
      standupBlockersBorder: Color(hex: "4E4E4E"),

      inputFill: Color.white.opacity(0.1),
      inputBorder: Color(hex: "666666"),

      chatBackground: AnyShapeStyle(Color.clear),
      chatSoftAccentFill: Color(hex: "F3854B").opacity(0.18),
      chatSoftAccentBorder: Color(hex: "F77952").opacity(0.4),
      chatSidePanelFill: Color(hex: "272A3C"),
      chatSidePanelHeaderFill: Color.white.opacity(0.06),
      chatCodeFill: Color.black.opacity(0.25)
    )
  }
}

// MARK: - Environment plumbing

private struct DayflowThemeKey: EnvironmentKey {
  static let defaultValue = DayflowTheme.light
}

extension EnvironmentValues {
  var dayflowTheme: DayflowTheme {
    get { self[DayflowThemeKey.self] }
    set { self[DayflowThemeKey.self] = newValue }
  }
}

/// Resolves the theme from the effective color scheme and injects it.
/// Attach once at the root of a window; every descendant reads
/// `@Environment(\.dayflowTheme)`.
private struct DayflowThemeResolver: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  @ObservedObject private var preview = StylePreview.shared

  func body(content: Content) -> some View {
    content.environment(
      \.dayflowTheme,
      colorScheme == .dark
        ? (preview.showAfter ? .dark : .darkBefore)
        : (preview.showAfter ? .light : .lightBefore))
  }
}

extension View {
  func resolveDayflowTheme() -> some View {
    modifier(DayflowThemeResolver())
  }

  /// Forces a subtree to a specific theme regardless of the system appearance.
  /// Used by onboarding, which is designed light-only.
  func dayflowTheme(_ theme: DayflowTheme) -> some View {
    environment(\.dayflowTheme, theme)
      .environment(\.colorScheme, theme.isDark ? .dark : .light)
  }
}

// MARK: - Adaptive colors

extension Color {
  /// A color that resolves per appearance (light / dark) automatically, for
  /// static design tokens like `SettingsStyle` that can't read the environment.
  static func dayflowAdaptive(light: NSColor, dark: NSColor) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? dark : light
      }
    )
  }
}

// MARK: - Shared shapes

/// Faux "inset box-shadow" glow used all over the Figma: a soft stroke drawn
/// just inside the shape's edge.
struct InnerGlow<S: InsettableShape>: View {
  let shape: S
  let color: Color
  var radius: CGFloat = 4
  /// Stroke width of the glow band; defaults to `radius`.
  var spread: CGFloat? = nil
  /// Softness of the band's edges; defaults to `radius`.
  var blur: CGFloat? = nil

  var body: some View {
    shape
      .strokeBorder(color, lineWidth: spread ?? radius)
      .blur(radius: blur ?? radius)
      .clipShape(shape)
      .allowsHitTesting(false)
  }
}
