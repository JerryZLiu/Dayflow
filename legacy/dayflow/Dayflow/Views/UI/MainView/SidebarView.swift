import SwiftUI

private enum SidebarMetrics {
  static let itemSpacing: CGFloat = 5.25
  static let scale: CGFloat = 1.1
  static let itemSize: CGFloat = 56 * scale
  static let selectedBackgroundSize: CGFloat = 30 * scale
  static let selectedBackgroundRadius: CGFloat = 10
  static let iconSize: CGFloat = 16 * scale
  static let fallbackSymbolSize: CGFloat = 15 * scale
  static let badgeSize: CGFloat = 8 * scale
  static let badgeOffsetX: CGFloat = 10 * scale
  static let badgeOffsetY: CGFloat = -10 * scale
  static let iconContainerSize: CGFloat = 34 * scale
  static let iconLabelSpacing: CGFloat = 3
  static let labelFontSize: CGFloat = 11 * scale
}

enum SidebarIcon: CaseIterable {
  case timeline
  case daily
  case weekly
  case chat
  case flow
  case agents
  case journal
  case bug
  case settings

  var assetName: String? {
    switch self {
    case .timeline: return "TimelineIcon"
    case .daily: return "DailyIcon"
    case .weekly: return "WeeklyIcon"
    case .chat: return "ChatIcon"
    case .flow: return "FlowIcon"
    case .agents: return "AgentsIcon"
    case .journal: return "JournalIcon"
    case .bug: return nil
    case .settings: return nil
    }
  }

  var systemNameFallback: String? {
    switch self {
    case .flow: return "water.waves"
    case .agents: return "sparkles"
    case .bug: return "exclamationmark.bubble.fill"
    case .settings: return "gearshape.fill"
    default: return nil
    }
  }

  var displayName: String {
    switch self {
    case .timeline: return "Timeline"
    case .daily: return "Daily"
    case .weekly: return "Weekly"
    case .chat: return "Chat"
    case .flow: return "Flow"
    case .agents: return "Agents"
    case .journal: return "Journal"
    case .bug: return "Report"
    case .settings: return "Settings"
    }
  }

  var analyticsTabName: String {
    switch self {
    case .timeline: return "timeline"
    case .daily: return "daily"
    case .weekly: return "weekly"
    case .chat: return "dashboard"
    case .flow: return "flow"
    case .agents: return "agents"
    case .journal: return "journal"
    case .bug: return "bug_report"
    case .settings: return "settings"
    }
  }
}

struct SidebarView: View {
  @Binding var selectedIcon: SidebarIcon
  @ObservedObject private var badgeManager = NotificationBadgeManager.shared
  @ObservedObject private var authManager = DayflowAuthManager.shared

  private var visibleIcons: [SidebarIcon] {
    SidebarIcon.allCases.filter { icon in
      if icon == .journal { return false }
      if icon == .flow { return SidebarView.showsFlowTab(flowEnabled: authManager.flowEnabled) }
      return true
    }
  }

  /// Flow is a whitelisted beta: the signed-in account must be flagged by the
  /// backend (flow_enabled). Signed out or unflagged → no tab, in all builds.
  static func showsFlowTab(flowEnabled: Bool) -> Bool {
    flowEnabled
  }

  var body: some View {
    VStack(alignment: .center, spacing: SidebarMetrics.itemSpacing) {
      ForEach(visibleIcons, id: \.self) { icon in
        SidebarIconButton(
          icon: icon,
          isSelected: selectedIcon == icon,
          showBadge: shouldShowBadge(for: icon),
          action: { selectedIcon = icon }
        )
        .frame(width: SidebarMetrics.itemSize, height: SidebarMetrics.itemSize)
      }
    }
  }

  private func shouldShowBadge(for icon: SidebarIcon) -> Bool {
    switch icon {
    case .journal:
      return badgeManager.hasPendingJournalReminder
    case .daily:
      return badgeManager.hasPendingDailyRecap
    default:
      return false
    }
  }
}

struct SidebarIconButton: View {
  @Environment(\.dayflowTheme) private var theme

  let icon: SidebarIcon
  let isSelected: Bool
  var showBadge: Bool = false
  let action: () -> Void

  private var iconColor: Color {
    isSelected ? theme.sidebarIconActive : theme.sidebarIcon
  }

  private var labelColor: Color {
    isSelected ? theme.sidebarLabelActive : theme.sidebarLabel
  }

  var body: some View {
    Button(action: action) {
      VStack(spacing: SidebarMetrics.iconLabelSpacing) {
        iconBox

        Text(icon.displayName)
          .font(.custom("Figtree", size: SidebarMetrics.labelFontSize))
          .lineLimit(1)
          .minimumScaleFactor(0.75)
          .foregroundColor(labelColor)
      }
      .frame(width: SidebarMetrics.itemSize, height: SidebarMetrics.itemSize)
      .contentShape(Rectangle())
    }
    .buttonStyle(DayflowPressScaleButtonStyle())
    .contentShape(Rectangle())
    .hoverScaleEffect(scale: 1.02)
    .pointingHandCursor()
  }

  private var iconBox: some View {
    let shape = RoundedRectangle(
      cornerRadius: SidebarMetrics.selectedBackgroundRadius, style: .continuous)

    return ZStack {
      if isSelected {
        shape
          .fill(theme.sidebarSelectedFill)
          .overlay(InnerGlow(shape: shape, color: theme.sidebarSelectedInnerGlow, radius: 3))
          .overlay(shape.strokeBorder(theme.sidebarSelectedBorder, lineWidth: 0.58))
          .shadow(color: theme.sidebarSelectedShadow, radius: 2, x: 0, y: 1)
          .frame(
            width: SidebarMetrics.selectedBackgroundSize,
            height: SidebarMetrics.selectedBackgroundSize
          )
      }

      iconImage
        .frame(width: SidebarMetrics.iconSize, height: SidebarMetrics.iconSize)

      if showBadge {
        Circle()
          .fill(theme.accent)
          .frame(width: SidebarMetrics.badgeSize, height: SidebarMetrics.badgeSize)
          .offset(x: SidebarMetrics.badgeOffsetX, y: SidebarMetrics.badgeOffsetY)
      }
    }
    .frame(width: SidebarMetrics.iconContainerSize, height: SidebarMetrics.iconContainerSize)
  }

  @ViewBuilder
  private var iconImage: some View {
    if let asset = icon.assetName {
      Image(asset)
        .resizable()
        .interpolation(.high)
        .renderingMode(.template)
        .aspectRatio(contentMode: .fit)
        .foregroundColor(iconColor)
    } else if let sys = icon.systemNameFallback {
      Image(systemName: sys)
        .font(.system(size: SidebarMetrics.fallbackSymbolSize))
        .foregroundColor(iconColor)
    }
  }
}
