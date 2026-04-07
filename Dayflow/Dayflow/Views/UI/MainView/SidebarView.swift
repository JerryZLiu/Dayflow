import SwiftUI

private enum SidebarMetrics {
  static let itemSpacing: CGFloat = 5.25
  static let scale: CGFloat = 1.1
  static let itemSize: CGFloat = 56 * scale
  static let selectedBackgroundSize: CGFloat = 30 * scale
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
  case journal
  case bug
  case settings

  var assetName: String? {
    switch self {
    case .timeline: return "TimelineIcon"
    case .daily: return "DailyIcon"
    case .weekly: return nil
    case .chat: return "ChatIcon"
    case .journal: return "JournalIcon"
    case .bug: return nil
    case .settings: return nil
    }
  }

  var systemNameFallback: String? {
    switch self {
    case .weekly: return "chart.pie"
    case .bug: return "exclamationmark.bubble"
    case .settings: return "gearshape"
    default: return nil
    }
  }

  var displayName: String {
    switch self {
    case .timeline: return "Timeline"
    case .daily: return "Daily"
    case .weekly: return "Weekly"
    case .chat: return "Chat"
    case .journal: return "Journal"
    case .bug: return "Report"
    case .settings: return "Settings"
    }
  }
}

struct SidebarView: View {
  @Binding var selectedIcon: SidebarIcon
  @ObservedObject private var badgeManager = NotificationBadgeManager.shared

  private var visibleIcons: [SidebarIcon] {
    SidebarIcon.allCases.filter { $0 != .weekly }
  }

  var body: some View {
    VStack(alignment: .center, spacing: SidebarMetrics.itemSpacing) {
      ForEach(visibleIcons, id: \.self) { icon in
        SidebarIconButton(
          icon: icon,
          isSelected: selectedIcon == icon,
          showBadge: icon == .journal && badgeManager.hasPendingReminder,
          action: { selectedIcon = icon }
        )
        .frame(width: SidebarMetrics.itemSize, height: SidebarMetrics.itemSize)
      }
    }
  }
}

struct SidebarIconButton: View {
  let icon: SidebarIcon
  let isSelected: Bool
  var showBadge: Bool = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: SidebarMetrics.iconLabelSpacing) {
        ZStack {
          if isSelected {
            Image("IconBackground")
              .resizable()
              .interpolation(.high)
              .renderingMode(.original)
              .frame(
                width: SidebarMetrics.selectedBackgroundSize,
                height: SidebarMetrics.selectedBackgroundSize
              )
          }

          if let asset = icon.assetName {
            Image(asset)
              .resizable()
              .interpolation(.high)
              .renderingMode(.template)
              .foregroundColor(
                isSelected ? Color(hex: "F96E00") : Color(red: 0.6, green: 0.4, blue: 0.3)
              )
              .aspectRatio(contentMode: .fit)
              .frame(width: SidebarMetrics.iconSize, height: SidebarMetrics.iconSize)
          } else if let sys = icon.systemNameFallback {
            Image(systemName: sys)
              .font(.system(size: SidebarMetrics.fallbackSymbolSize))
              .foregroundColor(
                isSelected ? Color(hex: "F96E00") : Color(red: 0.6, green: 0.4, blue: 0.3))
          }

          if showBadge {
            Circle()
              .fill(Color(hex: "F96E00"))
              .frame(width: SidebarMetrics.badgeSize, height: SidebarMetrics.badgeSize)
              .offset(x: SidebarMetrics.badgeOffsetX, y: SidebarMetrics.badgeOffsetY)
          }
        }
        .frame(width: SidebarMetrics.iconContainerSize, height: SidebarMetrics.iconContainerSize)

        Text(icon.displayName)
          .font(.custom("Nunito", size: SidebarMetrics.labelFontSize))
          .lineLimit(1)
          .minimumScaleFactor(0.75)
          .foregroundColor(
            isSelected ? Color(hex: "F96E00") : Color(red: 0.6, green: 0.4, blue: 0.3))
      }
      .frame(width: SidebarMetrics.itemSize, height: SidebarMetrics.itemSize)
      .contentShape(Rectangle())
    }
    .buttonStyle(PlainButtonStyle())
    .contentShape(Rectangle())
    .hoverScaleEffect(scale: 1.02)
    .pointingHandCursor()
  }
}
