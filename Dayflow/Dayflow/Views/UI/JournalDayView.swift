import SwiftUI

/// Day-focused journal surface inspired by the "Journal" exploration in Figma.
struct JournalDayView: View {
    var summary: JournalDaySummary
    var onSetReminders: (() -> Void)?
    var onNavigatePrevious: (() -> Void)?
    var onNavigateNext: (() -> Void)?
    var onReflect: (() -> Void)?

    @State private var selectedPeriod: JournalDayViewPeriod = .day

    init(
        summary: JournalDaySummary = .placeholder,
        onSetReminders: (() -> Void)? = nil,
        onNavigatePrevious: (() -> Void)? = nil,
        onNavigateNext: (() -> Void)? = nil,
        onReflect: (() -> Void)? = nil
    ) {
        self.summary = summary
        self.onSetReminders = onSetReminders
        self.onNavigatePrevious = onNavigatePrevious
        self.onNavigateNext = onNavigateNext
        self.onReflect = onReflect
    }

    var body: some View {
        ZStack {
            JournalDayTokens.canvasBackground
                .ignoresSafeArea()

            VStack(spacing: 26) {
                toolbar

                Text(summary.headline)
                    .font(.custom("InstrumentSerif-Regular", size: 36))
                    .foregroundStyle(JournalDayTokens.primaryText)
                    .padding(.top, 4)

                HStack(alignment: .top, spacing: 24) {
                    JournalDayCard(sections: summary.sections)

                    JournalDayEditorToolbar()
                        .padding(.top, 12)
                }

                Button(action: { onReflect?() }) {
                    Text(summary.ctaTitle)
                        .font(.custom("Nunito-SemiBold", size: 15))
                        .foregroundStyle(JournalDayTokens.ctaText)
                        .padding(.horizontal, 34)
                        .padding(.vertical, 12)
                        .frame(minWidth: 0)
                }
                .buttonStyle(.plain)
                .background(JournalDayTokens.ctaBackground)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(JournalDayTokens.ctaBorder, lineWidth: 1)
                )
                .shadow(color: JournalDayTokens.ctaShadow, radius: 18, y: 10)
            }
            .padding(.vertical, 34)
            .padding(.horizontal, 38)
            .frame(maxWidth: 820)
            .background(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(JournalDayTokens.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .stroke(JournalDayTokens.outerStroke, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 32, y: 24)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                JournalDayCircleButton(iconName: "chevron.left") {
                    onNavigatePrevious?()
                }

                JournalDaySegmentedControl(selection: $selectedPeriod)

                JournalDayCircleButton(
                    iconName: "chevron.right",
                    isDisabled: summary.isForwardNavigationDisabled
                ) {
                    onNavigateNext?()
                }
            }

            Spacer()

            Button(action: { onSetReminders?() }) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(JournalDayTokens.reminderBadge)
                            .frame(width: 24, height: 24)
                        Image(systemName: "sun.max.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.white)
                    }

                    Text(summary.reminderTitle)
                        .font(.custom("Nunito-SemiBold", size: 13))
                        .foregroundStyle(JournalDayTokens.reminderText)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(JournalDayTokens.reminderBackground)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(JournalDayTokens.reminderBorder, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Card content

private struct JournalDayCard: View {
    let sections: [JournalDaySection]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(sections) { section in
                JournalDaySectionView(section: section)

                if section.showsDividerAfter {
                    Divider()
                        .background(JournalDayTokens.divider)
                        .overlay(JournalDayTokens.divider)
                        .padding(.top, 6)
                }
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 28)
        .frame(maxWidth: 520, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(JournalDayTokens.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(JournalDayTokens.cardStroke, lineWidth: 1)
        )
        .shadow(color: JournalDayTokens.cardShadow, radius: 26, y: 18)
    }
}

private struct JournalDaySectionView: View {
    let section: JournalDaySection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.title)
                .font(.custom("InstrumentSerif-Regular", size: 24))
                .foregroundStyle(JournalDayTokens.sectionHeader)

            switch section.content {
            case let .list(items):
                JournalDayBulletList(items: items)
            case let .text(value):
                Text(value)
                    .font(.custom("Nunito-Regular", size: 15))
                    .foregroundStyle(JournalDayTokens.bodyText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct JournalDayBulletList: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(JournalDayTokens.bullet)
                        .frame(width: 6, height: 6)
                        .padding(.top, 6)

                    Text(item)
                        .font(.custom("Nunito-Regular", size: 15))
                        .foregroundStyle(JournalDayTokens.bodyText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct JournalDayEditorToolbar: View {
    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 0) {
                JournalDayEditorToggle(label: "I", isActive: true)

                Divider()
                    .frame(maxWidth: .infinity)
                    .background(JournalDayTokens.toolbarDivider)

                JournalDayEditorToggle(label: "B", isActive: false)
            }
            .frame(width: 42)
            .padding(.vertical, 10)
            .background(JournalDayTokens.toolbarBackground)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(JournalDayTokens.toolbarStroke, lineWidth: 1)
            )

            Button(action: {}) {
                Image(systemName: "pencil")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(JournalDayTokens.toolbarIcon)
                    .frame(width: 38, height: 38)
                    .background(JournalDayTokens.toolbarBackground)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(JournalDayTokens.toolbarStroke, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(true)
            .opacity(0.85)
        }
    }
}

private struct JournalDayEditorToggle: View {
    var label: String
    var isActive: Bool

    var body: some View {
        Text(label)
            .font(.custom("InstrumentSerif-Regular", size: 18))
            .foregroundStyle(isActive ? JournalDayTokens.toolbarActiveText : JournalDayTokens.toolbarIcon)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(isActive ? JournalDayTokens.toolbarActiveBackground : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 6)
    }
}

// MARK: - Toolbar helpers

private struct JournalDayCircleButton: View {
    var iconName: String
    var isDisabled: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isDisabled ? JournalDayTokens.secondaryText.opacity(0.5) : JournalDayTokens.primaryText)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(Color.white)
                        .shadow(color: Color.black.opacity(0.08), radius: 8, y: 4)
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
    }
}

private struct JournalDaySegmentedControl: View {
    @Binding var selection: JournalDayViewPeriod

    var body: some View {
        HStack(spacing: 4) {
            ForEach(JournalDayViewPeriod.allCases) { option in
                Button(action: { selection = option }) {
                    Text(option.rawValue)
                        .font(.custom("Nunito-SemiBold", size: 13))
                        .foregroundStyle(selection == option ? Color.white : JournalDayTokens.secondaryText)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 6)
                        .background(
                            Group {
                                if selection == option {
                                    Capsule().fill(JournalDayTokens.segmentActive)
                                } else {
                                    Capsule().fill(JournalDayTokens.segmentBackground)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(JournalDayTokens.segmentContainer)
        .clipShape(Capsule())
    }
}

// MARK: - Models

struct JournalDaySummary {
    var headline: String
    var reminderTitle: String
    var ctaTitle: String
    var sections: [JournalDaySection]
    var isForwardNavigationDisabled: Bool

    static let placeholder = JournalDaySummary(
        headline: "Today, October 20",
        reminderTitle: "Set reminders",
        ctaTitle: "Reflect with Dayflow",
        sections: [
            JournalDaySection(
                title: "Today’s intentions",
                content: .list([
                    "Work on designs for xyz",
                    "Learn about abc",
                    "Look into recent user research",
                    "Share design directions with stakeholders"
                ]),
                showsDividerAfter: false
            ),
            JournalDaySection(
                title: "Notes for today",
                content: .text("Remember to take breaks and drink water."),
                showsDividerAfter: true
            ),
            JournalDaySection(
                title: "Long term goals",
                content: .list([
                    "Complete project A",
                    "Publish article on Substack"
                ]),
                showsDividerAfter: false
            )
        ],
        isForwardNavigationDisabled: true
    )
}

struct JournalDaySection: Identifiable {
    enum Content: Equatable {
        case list([String])
        case text(String)
    }

    let id = UUID()
    var title: String
    var content: Content
    var showsDividerAfter: Bool
}

enum JournalDayViewPeriod: String, CaseIterable, Identifiable {
    case day = "Day"
    case week = "Week"

    var id: String { rawValue }
}

// MARK: - Tokens

private enum JournalDayTokens {
    static let canvasBackground = LinearGradient(
        colors: [Color(hex: "F8F1EA"), Color(hex: "FDF5ED")],
        startPoint: .top,
        endPoint: .bottom
    )
    static let background = LinearGradient(
        colors: [Color(hex: "FFF8F2"), Color(hex: "FFE8D5"), Color(hex: "FFD5B4")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let outerStroke = Color.white.opacity(0.35)
    static let primaryText = Color(hex: "2F1607")
    static let secondaryText = Color(hex: "66503E")
    static let reminderText = Color(hex: "5A320E")
    static let reminderBackground = LinearGradient(colors: [Color(hex: "FFE8CF"), Color(hex: "FFD2A4")], startPoint: .top, endPoint: .bottom)
    static let reminderBorder = Color(hex: "FFC688").opacity(0.8)
    static let reminderBadge = Color(hex: "FFB14F")
    static let cardBackground = Color.white
    static let cardStroke = Color.white.opacity(0.8)
    static let cardShadow = Color.black.opacity(0.06)
    static let bodyText = Color(hex: "2D1B10")
    static let bullet = Color(hex: "F4923C")
    static let sectionHeader = Color(hex: "D96F0A")
    static let divider = Color(hex: "E6D8CB")
    static let ctaBackground = LinearGradient(colors: [Color(hex: "FFE9D2"), Color(hex: "FFC99A")], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let ctaBorder = Color(hex: "FFC287")
    static let ctaText = Color(hex: "5A320E")
    static let ctaShadow = Color(hex: "FFCEAA").opacity(0.5)
    static let segmentBackground = Color(hex: "F6EEE7")
    static let segmentActive = Color(hex: "FFB859")
    static let segmentContainer = Color.white.opacity(0.8)
    static let toolbarBackground = Color(hex: "F8EBDE")
    static let toolbarStroke = Color.white.opacity(0.9)
    static let toolbarDivider = Color.white.opacity(0.7)
    static let toolbarIcon = Color(hex: "6B4D3A")
    static let toolbarActiveBackground = Color(hex: "FFE3C5")
    static let toolbarActiveText = Color(hex: "C45D04")
}

struct JournalDayView_Previews: PreviewProvider {
    static var previews: some View {
        JournalDayView()
            .padding(40)
            .background(Color(hex: "F6F0EA"))
            .previewLayout(.sizeThatFits)
            .preferredColorScheme(.light)
    }
}
