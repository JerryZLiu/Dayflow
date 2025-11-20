import SwiftUI

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
        VStack(spacing: 26) {
            toolbar

            Text(summary.headline)
                .font(.custom("InstrumentSerif-Regular", size: 36))
                .foregroundStyle(JournalDayTokens.primaryText)
                .padding(.top, 4)

            HStack(alignment: .top, spacing: 0) {
                JournalDayCard(sections: summary.sections)
            }

            Button(action: { onReflect?() }) {
                Text(summary.ctaTitle)
                    .font(.custom("Nunito-SemiBold", size: 17))
            }
            .buttonStyle(ReflectCapsuleStyle())
        }
        .padding(.vertical, 34)
        .padding(.horizontal, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var toolbar: some View {
        ZStack {
            // Centered navigation + period selector
            HStack(spacing: 10) {
                JournalDayCircleButton(direction: .left) {
                    onNavigatePrevious?()
                }

                JournalDaySegmentedControl(selection: $selectedPeriod)
                    .fixedSize()

                JournalDayCircleButton(direction: .right, isDisabled: summary.isForwardNavigationDisabled) {
                    onNavigateNext?()
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            // Right-aligned reminder pill
            HStack {
                Spacer()
                Button(action: { onSetReminders?() }) {
                    HStack(alignment: .center, spacing: 4) {
                        Image("JournalReminderIcon")
                            .resizable()
                            .renderingMode(.template)
                            .foregroundStyle(JournalDayTokens.reminderText)
                            .frame(width: 16, height: 16)

                        Text(summary.reminderTitle)
                            .font(.custom("Nunito-SemiBold", size: 12))
                            .foregroundStyle(JournalDayTokens.reminderText)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.2), location: 0.00),
                                .init(color: Color(red: 1, green: 0.91, blue: 0.79), location: 1.00),
                            ],
                            startPoint: .init(x: 0.5, y: 0),
                            endPoint: .init(x: 0.5, y: 1)
                        )
                    )
                    .cornerRadius(100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 100)
                            .inset(by: 0.5)
                            .stroke(Color(red: 1, green: 0.79, blue: 0.62), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Figma Specific Toolbar Components

private struct JournalDayCircleButton: View {
    enum Direction { case left, right }
    var direction: Direction
    var isDisabled: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(JournalDayTokens.navCircleFill)
                Circle()
                    .stroke(JournalDayTokens.navCircleStroke, lineWidth: 1)

                Image("JournalArrow")
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 9, height: 9)
                    .foregroundStyle(JournalDayTokens.navArrow.opacity(isDisabled ? 0.35 : 1))
                    .scaleEffect(x: direction == .right ? -1 : 1, y: 1)
            }
            .frame(width: 26, height: 26)
            .shadow(color: JournalDayTokens.navCircleShadow, radius: 2, x: 0, y: 0)
            .opacity(isDisabled ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

private struct JournalDaySegmentedControl: View {
    @Binding var selection: JournalDayViewPeriod

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(JournalDayViewPeriod.allCases) { option in
                Button(action: { selection = option }) {
                    Text(option.rawValue)
                        .font(.custom("Nunito-Regular", size: 12))
                        .tracking(-0.12)
                        .foregroundStyle(selection == option ? Color.white : JournalDayTokens.segmentInactiveText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                        .frame(width: 64, alignment: .center)
                        .background(selection == option ? JournalDayTokens.segmentActiveFill : JournalDayTokens.segmentInactiveFill)
                        .cornerRadius(200)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            Capsule()
                .fill(JournalDayTokens.segmentContainerFill)
                .overlay(
                    Capsule()
                        .inset(by: 0.5)
                        .stroke(Color.white.opacity(0.6), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.10), radius: 2, x: 0, y: 1)
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
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
        .frame(width: 489, height: 458, alignment: .topLeading)
        .background(
            LinearGradient(
                stops: [
                    .init(color: Color.white.opacity(0.3), location: 0.00),
                    .init(color: Color.white.opacity(0.8), location: 0.51),
                    .init(color: Color.white.opacity(0.3), location: 1.00)
                ],
                startPoint: .init(x: 1, y: 0.14),
                endPoint: .init(x: 0, y: 0.78)
            )
        )
        .cornerRadius(8)
        .shadow(color: Color.black.opacity(0.1), radius: 6, x: 0, y: 0)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .inset(by: 0.5)
                .stroke(Color.white, lineWidth: 1)
        )
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

// MARK: - Reflect Button Style

private struct ReflectCapsuleStyle: ButtonStyle {
    // Gradient stops from Figma
    private let strokeStops: [Gradient.Stop] = [
        .init(color: Color(red: 1.0, green: 0.66, blue: 0.38), location: 0.08), // Orange
        .init(color: Color(red: 0.93, green: 0.92, blue: 0.92), location: 0.22), // White/Grey
        .init(color: Color(red: 0.76, green: 0.69, blue: 0.65), location: 0.32), // Darker Grey
        .init(color: Color(red: 1.0, green: 0.66, blue: 0.38), location: 0.57), // Orange
        .init(color: Color(red: 0.93, green: 0.92, blue: 0.92), location: 0.71), // White/Grey
        .init(color: Color(red: 0.76, green: 0.69, blue: 0.65), location: 0.83)  // Darker Grey
    ]

    func makeBody(configuration: Configuration) -> some View {
        let borderGradient = AngularGradient(
            gradient: Gradient(stops: strokeStops),
            center: .center,
            startAngle: .degrees(-30),
            endAngle: .degrees(330)
        )
    
        configuration.label
            .font(.custom("Nunito-SemiBold", size: 17))
            .foregroundColor(Color(red: 0.52, green: 0.46, blue: 0.42)) // "84766C"
            .padding(.horizontal, 34)
            .padding(.vertical, 13)
            .background(
                Capsule()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [
                                Color.white.opacity(0.95),
                                Color(red: 1.0, green: 0.92, blue: 0.83).opacity(0.4)
                            ]),
                            center: .center,
                            startRadius: 20,
                            endRadius: 200
                        )
                    )
            )
            .overlay(
                Capsule()
                    .strokeBorder(borderGradient, lineWidth: 1)
            )
            .shadow(color: Color(red: 0.77, green: 0.36, blue: 0.02).opacity(0.12), radius: 4, x: 0, y: 2)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: configuration.isPressed)
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
    static let primaryText = Color(red: 0.18, green: 0.09, blue: 0.03) // "2F1607"
    static let reminderText = Color(red: 0.35, green: 0.20, blue: 0.05) // "5A320E"
    static let reminderBackground = LinearGradient(
        stops: [
            .init(color: Color.white.opacity(0.2), location: 0.0),
            .init(color: Color(red: 1, green: 0.91, blue: 0.79), location: 1.0)
        ],
        startPoint: .top,
        endPoint: .bottom
    )
    static let reminderBorder = Color(red: 1, green: 0.79, blue: 0.62)
    
    static let cardBackground = Color.white
    static let cardStroke = Color.white.opacity(0.8)
    static let cardShadow = Color.black.opacity(0.06)
    
    static let bodyText = Color(red: 0.18, green: 0.11, blue: 0.06) // "2D1B10"
    static let bullet = Color(red: 0.96, green: 0.57, blue: 0.24) // "F4923C"
    static let sectionHeader = Color(red: 0.85, green: 0.44, blue: 0.04) // "D96F0A"
    static let divider = Color(red: 0.90, green: 0.85, blue: 0.80) // "E6D8CB"

    // Navigation arrows
    static let navCircleFill = Color(red: 0.996, green: 0.976, blue: 0.953) // #FEF9F3
    static let navCircleStroke = Color.white
    static let navCircleShadow = Color.black.opacity(0.04)
    static let navArrow = Color(red: 1.0, green: 0.74, blue: 0.35)
    
    // Segmented control specifics
    static let segmentActiveFill = Color(red: 1, green: 0.72, blue: 0.35) // #FFB859
    static let segmentInactiveFill = Color(red: 0.95, green: 0.94, blue: 0.93) // #F2EFEE
    static let segmentInactiveText = Color(red: 0.80, green: 0.78, blue: 0.77) // #CDC8C4
    static let segmentContainerFill = Color(red: 1.0, green: 0.976, blue: 0.953) // #FFF9F3
    
}

struct JournalDayView_Previews: PreviewProvider {
    static var previews: some View {
        JournalDayView()
            .background(Color(red: 0.96, green: 0.94, blue: 0.92))
            .previewLayout(.sizeThatFits)
            .preferredColorScheme(.light)
    }
}
