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
}

struct SidebarView: View {
    @Binding var selectedIcon: SidebarIcon
    @ObservedObject private var badgeManager = NotificationBadgeManager.shared

    var body: some View {
        VStack(alignment: .center, spacing: 10.501) {
            ForEach(SidebarIcon.allCases, id: \.self) { icon in
                SidebarIconButton(
                    icon: icon,
                    isSelected: selectedIcon == icon,
                    showBadge: icon == .journal && badgeManager.hasPendingReminder,
                    action: { selectedIcon = icon }
                )
                .frame(width: 40, height: 40)
            }
        }
        // Outer rounded container removed per design
    }
}

struct SidebarIconButton: View {
    let icon: SidebarIcon
    let isSelected: Bool
    var showBadge: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isSelected {
                    Image("IconBackground")
                        .resizable()
                        .interpolation(.high)
                        .renderingMode(.original)
                }

                if let asset = icon.assetName {
                    Image(asset)
                        .resizable()
                        .interpolation(.high)
                        .renderingMode(.template)
                        .foregroundColor(isSelected ? Color(hex: "F96E00") : Color(red: 0.6, green: 0.4, blue: 0.3))
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20)
                } else if let sys = icon.systemNameFallback {
                    Image(systemName: sys)
                        .font(.system(size: 18))
                        .foregroundColor(isSelected ? Color(hex: "F96E00") : Color(red: 0.6, green: 0.4, blue: 0.3))
                }

                // Badge indicator (top-right orange dot)
                if showBadge {
                    Circle()
                        .fill(Color(hex: "F96E00"))
                        .frame(width: 8, height: 8)
                        .offset(x: 12, y: -12)
                }
            }
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .contentShape(Rectangle())
    }
}
