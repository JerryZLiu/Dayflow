import SwiftUI

enum SidebarIcon: CaseIterable {
  case timeline
  case dashboard
  case journal
  case bug
  case settings

  var assetName: String? {
    switch self {
    case .timeline: return "TimelineIcon"
    case .dashboard: return "DashboardIcon"
    case .journal: return "JournalIcon"
    case .bug: return nil
    case .settings: return nil
    }
  }

  var systemNameFallback: String? {
    switch self {
    case .bug: return "exclamationmark.bubble"
    case .settings: return "gearshape"
    default: return nil
    }
  }

  var displayName: String {
    switch self {
    case .timeline: return "Timeline"
    case .dashboard: return "Dashboard"
    case .journal: return "Journal"
    case .bug: return "Report"
    case .settings: return "Settings"
    }
  }
}

struct SidebarView: View {
  @Binding var selectedIcon: SidebarIcon
  @ObservedObject private var badgeManager = NotificationBadgeManager.shared

  var body: some View {
    VStack(alignment: .center, spacing: 5.25) {
      ForEach(SidebarIcon.allCases, id: \.self) { icon in
        SidebarIconButton(
          icon: icon,
          isSelected: selectedIcon == icon,
          showBadge: icon == .journal && badgeManager.hasPendingReminder,
          action: { selectedIcon = icon }
        )
        .frame(width: 56, height: 56)
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
      VStack(spacing: 3) {
        ZStack {
          if isSelected {
            Image("IconBackground")
              .resizable()
              .interpolation(.high)
              .renderingMode(.original)
              .frame(width: 30, height: 30)
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
              .frame(width: 16, height: 16)
          } else if let sys = icon.systemNameFallback {
            Image(systemName: sys)
              .font(.system(size: 15))
              .foregroundColor(
                isSelected ? Color(hex: "F96E00") : Color(red: 0.6, green: 0.4, blue: 0.3))
          }

          if showBadge {
            Circle()
              .fill(Color(hex: "F96E00"))
              .frame(width: 8, height: 8)
              .offset(x: 10, y: -10)
          }
        }
        .frame(width: 34, height: 34)

        Text(icon.displayName)
          .font(.custom("Nunito", size: 11))
          .lineLimit(1)
          .minimumScaleFactor(0.75)
          .foregroundColor(
            isSelected ? Color(hex: "F96E00") : Color(red: 0.6, green: 0.4, blue: 0.3))
      }
      .frame(width: 56, height: 56)
      .contentShape(Rectangle())
    }
    .buttonStyle(PlainButtonStyle())
    .contentShape(Rectangle())
    .hoverScaleEffect(scale: 1.02)
    .pointingHandCursor()
  }
}
