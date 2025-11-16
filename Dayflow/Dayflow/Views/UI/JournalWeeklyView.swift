import SwiftUI

/// Weekly journal overview replicating the highlighted Figma exploration.
struct JournalWeeklyView: View {
    var summary: JournalWeeklySummary
    var onSetReminders: (() -> Void)?
    var onNavigatePrevious: (() -> Void)?
    var onNavigateNext: (() -> Void)?

    @State private var selectedPeriod: JournalWeeklyViewPeriod = .week

    init(
        summary: JournalWeeklySummary = .placeholder,
        onSetReminders: (() -> Void)? = nil,
        onNavigatePrevious: (() -> Void)? = nil,
        onNavigateNext: (() -> Void)? = nil
    ) {
        self.summary = summary
        self.onSetReminders = onSetReminders
        self.onNavigatePrevious = onNavigatePrevious
        self.onNavigateNext = onNavigateNext
    }

    var body: some View {
        VStack(spacing: 26) {
            headerToolbar

            VStack(spacing: 6) {
                Text(summary.title)
                    .font(.custom("InstrumentSerif-Regular", size: 32))
                    .kerning(-0.5)
                    .foregroundStyle(JournalWeeklyTokens.primaryText)

                Text(summary.dateRange)
                    .font(.custom("InstrumentSerif-Regular", size: 22))
                    .foregroundStyle(JournalWeeklyTokens.primaryText.opacity(0.85))

                Text(summary.description)
                    .font(.custom("Nunito-Regular", size: 14))
                    .foregroundStyle(JournalWeeklyTokens.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            .frame(maxWidth: .infinity)

            timeline
        }
        .padding(.vertical, 34)
        .padding(.horizontal, 38)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(JournalWeeklyTokens.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.35), lineWidth: 1)
        )
    }

    private var headerToolbar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                JournalWeeklyCircleButton(iconName: "chevron.left") {
                    onNavigatePrevious?()
                }

                JournalWeeklySegmentedControl(
                    selection: $selectedPeriod,
                    options: JournalWeeklyViewPeriod.allCases
                )

                JournalWeeklyCircleButton(
                    iconName: "chevron.right",
                    isDisabled: summary.disableForwardNavigation
                ) {
                    onNavigateNext?()
                }
            }

            Spacer()

            Button(action: { onSetReminders?() }) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(JournalWeeklyTokens.setReminderBadge)
                            .frame(width: 24, height: 24)
                        Image(systemName: "sun.max.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.white)
                    }

                    Text("Set reminders")
                        .font(.custom("Nunito-SemiBold", size: 13))
                        .foregroundStyle(JournalWeeklyTokens.accentText)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(JournalWeeklyTokens.setReminderBackground)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(JournalWeeklyTokens.setReminderBorder, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var timeline: some View {
        GeometryReader { geo in
            TimelineCanvas(summary: summary, size: geo.size)
        }
        .frame(height: 320)
        .padding(.top, 8)
    }
}

// MARK: - Timeline Canvas

private struct TimelineCanvas: View {
    let summary: JournalWeeklySummary
    let size: CGSize

    private struct TimelinePoint: Identifiable {
        let id = UUID()
        let day: JournalWeeklyDay
        let point: CGPoint
    }

    private var curveRect: CGRect {
        let horizontalPadding: CGFloat = 32
        let width = max(size.width - horizontalPadding * 2, 1)
        let height = min(size.height * 0.5, 160)
        let originY = max((size.height - height) / 2 - 10, 0)
        return CGRect(x: horizontalPadding, y: originY, width: width, height: height)
    }

    private var points: [TimelinePoint] {
        guard !summary.days.isEmpty else { return [] }
        let denominator = max(summary.days.count - 1, 1)

        return summary.days.enumerated().map { index, day in
            let progress = day.progress ?? CGFloat(index) / CGFloat(denominator)
            let normalized = JournalWeeklyReferenceCurve.normalizedPoint(forXProgress: progress)
            let absolutePoint = curveRect.point(fromNormalized: normalized)
            return TimelinePoint(day: day, point: absolutePoint)
        }
    }

    var body: some View {
        ZStack {
            curvePath

            ForEach(points) { entry in
                dayNode(for: entry)

                if let card = entry.day.entry {
                    connector(for: entry, card: card)
                    cardView(for: entry, card: card)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var curvePath: some View {
        JournalWeeklyReferenceCurve.path(in: curveRect.size)
            .offset(x: curveRect.minX, y: curveRect.minY)
            .stroke(
                JournalWeeklyTokens.timelineGradient,
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
            .shadow(color: JournalWeeklyTokens.timelineShadow.opacity(0.35), radius: 14, y: 12)
    }

    private func dayNode(for timelinePoint: TimelinePoint) -> some View {
        VStack(spacing: 6) {
            Text(timelinePoint.day.label)
                .font(.custom("Nunito-SemiBold", size: 13))
                .foregroundStyle(timelinePoint.day.isMuted ? JournalWeeklyTokens.secondaryText : .white)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(
                            timelinePoint.day.isMuted
                                ? JournalWeeklyTokens.dayMuted
                                : JournalWeeklyTokens.dayActive
                        )
                )
        }
        .position(timelinePoint.point)
    }

    private func connector(for entry: TimelinePoint, card: JournalWeeklyEntry) -> some View {
        let anchor = entry.point
        let verticalDistance: CGFloat = card.position == .above ? -112 : 112
        let lineHeight = abs(verticalDistance) - 34

        return Rectangle()
            .fill(JournalWeeklyTokens.dayConnector)
            .frame(width: 2, height: max(lineHeight, 16))
            .position(
                x: anchor.x,
                y: anchor.y + (verticalDistance / 2)
            )
    }

    private func cardView(for entry: TimelinePoint, card: JournalWeeklyEntry) -> some View {
        let anchor = entry.point
        let verticalDistance: CGFloat = card.position == .above ? -140 : 140

        return JournalWeeklyEntryCard(entry: card)
            .frame(width: card.preferredWidth)
            .position(
                x: anchor.x,
                y: anchor.y + verticalDistance
            )
    }
}

// MARK: - Supporting Views & Models

private struct JournalWeeklyCircleButton: View {
    var iconName: String
    var isDisabled: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isDisabled ? JournalWeeklyTokens.secondaryText.opacity(0.6) : JournalWeeklyTokens.primaryText)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(Color.white)
                        .shadow(color: Color.black.opacity(0.08), radius: 8, y: 4)
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
    }
}

private struct JournalWeeklySegmentedControl: View {
    @Binding var selection: JournalWeeklyViewPeriod
    var options: [JournalWeeklyViewPeriod]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { option in
                Button(action: { selection = option }) {
                    Text(option.rawValue)
                        .font(.custom("Nunito-SemiBold", size: 13))
                        .foregroundStyle(selection == option ? Color.white : JournalWeeklyTokens.secondaryText)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 6)
                        .background(
                            Group {
                                if selection == option {
                                    Capsule().fill(JournalWeeklyTokens.dayActive)
                                } else {
                                    Capsule().fill(JournalWeeklyTokens.toggleBackground)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(JournalWeeklyTokens.toggleContainer)
        .clipShape(Capsule())
    }
}

private struct JournalWeeklyEntryCard: View {
    let entry: JournalWeeklyEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(entry.summary)
                .font(.custom("Nunito-Regular", size: 14))
                .foregroundStyle(JournalWeeklyTokens.primaryText)
                .multilineTextAlignment(.leading)

            if !entry.icons.isEmpty {
                HStack(spacing: 6) {
                    ForEach(entry.icons) { icon in
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(icon.background)
                            .frame(width: 26, height: 26)
                            .overlay(
                                Image(systemName: icon.systemName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(icon.foreground)
                            )
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.08), radius: 14, y: 10)
    }
}

// MARK: - Models

struct JournalWeeklySummary {
    var title: String
    var dateRange: String
    var description: String
    var disableForwardNavigation: Bool
    var days: [JournalWeeklyDay]

    static let placeholder = JournalWeeklySummary(
        title: "Week in review",
        dateRange: "October 19 – 25",
        description: "Made progress on the redesign project, shared updates with the leads by the end of the week. Looked at design references and shopped for groceries and necessities.",
        disableForwardNavigation: true,
        days: JournalWeeklyDay.placeholder
    )
}

struct JournalWeeklyDay: Identifiable {
    let id = UUID()
    var label: String
    var progress: CGFloat?
    var isMuted: Bool
    var entry: JournalWeeklyEntry?

    static var placeholder: [JournalWeeklyDay] {
        [
            JournalWeeklyDay(label: "S", progress: 0.02, isMuted: true, entry: JournalWeeklyEntry(
                summary: "Worked on design directions with the team. Watched a new episode of Curb Your Enthusiasm.",
                position: .below,
                icons: [.figma, .tv]
            )),
            JournalWeeklyDay(label: "M", progress: 0.18, isMuted: false, entry: JournalWeeklyEntry(
                summary: "Refined design directions. Shopped for groceries.",
                position: .above,
                icons: [.figma, .cart]
            )),
            JournalWeeklyDay(label: "T", progress: 0.34, isMuted: false, entry: JournalWeeklyEntry(
                summary: "Prepared presentation and troubleshooted with Jason. Shopped for home necessities on Amazon.",
                position: .below,
                icons: [.slides, .cart]
            )),
            JournalWeeklyDay(label: "W", progress: 0.5, isMuted: false, entry: JournalWeeklyEntry(
                summary: "Updated mockups and presentation based on new feedback. Spent some time watching YouTube videos.",
                position: .above,
                icons: [.figma, .video]
            )),
            JournalWeeklyDay(label: "T", progress: 0.66, isMuted: false, entry: JournalWeeklyEntry(
                summary: "Refined design directions and shared with them with the leads.",
                position: .below,
                icons: [.figma]
            )),
            JournalWeeklyDay(label: "F", progress: 0.82, isMuted: false, entry: JournalWeeklyEntry(
                summary: "Read some articles on Substack and jotting down notes. Spent most of the day away from the computer.",
                position: .above,
                icons: [.books, .moon]
            )),
            JournalWeeklyDay(label: "S", progress: 0.98, isMuted: true, entry: nil)
        ]
    }
}

struct JournalWeeklyEntry: Identifiable {
    let id = UUID()
    var summary: String
    var position: JournalWeeklyEntry.Position
    var icons: [JournalWeeklyIcon]
    var preferredWidth: CGFloat = 215

    enum Position {
        case above
        case below
    }
}

struct JournalWeeklyIcon: Identifiable {
    let id = UUID()
    var systemName: String
    var background: Color
    var foreground: Color

    static let figma = JournalWeeklyIcon(systemName: "paintpalette.fill", background: Color(hex: "FFB859"), foreground: .white)
    static let cart = JournalWeeklyIcon(systemName: "cart.fill", background: Color(hex: "553000"), foreground: Color(hex: "F9E2C9"))
    static let slides = JournalWeeklyIcon(systemName: "rectangle.and.pencil.and.ellipsis", background: Color(hex: "FFD082"), foreground: Color(hex: "4A2606"))
    static let video = JournalWeeklyIcon(systemName: "play.rectangle.fill", background: Color(hex: "F06543"), foreground: .white)
    static let books = JournalWeeklyIcon(systemName: "book.fill", background: Color(hex: "5B3A2E"), foreground: Color(hex: "F9E2C9"))
    static let moon = JournalWeeklyIcon(systemName: "moon.stars.fill", background: Color(hex: "2D1E2F"), foreground: .white)
    static let tv = JournalWeeklyIcon(systemName: "tv.fill", background: Color(hex: "FFB2A6"), foreground: Color(hex: "4A1D12"))
}

enum JournalWeeklyViewPeriod: String, CaseIterable, Identifiable {
    case day = "Day"
    case week = "Week"

    var id: String { rawValue }
}

private enum JournalWeeklyTokens {
    static let background = LinearGradient(
        colors: [Color(hex: "FFF6EE"), Color(hex: "FFE0C8"), Color(hex: "FFD9BD")],
        startPoint: .top,
        endPoint: .bottom
    )
    static let primaryText = Color(hex: "2F1607")
    static let secondaryText = Color(hex: "6B4D3A")
    static let accentText = Color(hex: "5A320E")
    static let timelineGradient = LinearGradient(
        colors: [Color(hex: "FFB859"), Color(hex: "FF8F4A")],
        startPoint: .leading,
        endPoint: .trailing
    )
    static let timelineShadow = Color(hex: "F7B47C")
    static let dayActive = Color(hex: "FFB859")
    static let dayMuted = Color(hex: "F2E4D4")
    static let toggleBackground = Color(hex: "F5EEE6")
    static let toggleContainer = Color.white.opacity(0.8)
    static let setReminderBackground = LinearGradient(colors: [Color(hex: "FFE5C5"), Color(hex: "FFD29D")], startPoint: .top, endPoint: .bottom)
    static let setReminderBorder = Color(hex: "FFC689").opacity(0.7)
    static let setReminderBadge = Color(hex: "FFAA5F")
    static let dayConnector = Color(hex: "FFB859").opacity(0.4)
}

#Preview("Weekly Review", traits: .fixedLayout(width: 1000, height: 600)) {
    JournalWeeklyView()
        .padding()
        .background(Color(hex: "F6F0EA"))
}

// MARK: - Reference curve helpers

private enum JournalWeeklyReferenceCurve {
    private static let minX: CGFloat = 4
    private static let maxX: CGFloat = 1017.84
    private static let minY: CGFloat = 1
    private static let maxY: CGFloat = 64.3301
    private static let width = maxX - minX
    private static let height = maxY - minY

    private static let segments: [BezierSegment] = [
        BezierSegment(
            p0: CGPoint(x: 4, y: 17.378),
            p1: CGPoint(x: 155.747, y: 17.378),
            p2: CGPoint(x: 178.595, y: 64.3301),
            p3: CGPoint(x: 341.819, y: 64.3301)
        ),
        BezierSegment(
            p0: CGPoint(x: 341.819, y: 64.3301),
            p1: CGPoint(x: 493.566, y: 64.3301),
            p2: CGPoint(x: 510.312, y: 1),
            p3: CGPoint(x: 660.784, y: 1)
        ),
        BezierSegment(
            p0: CGPoint(x: 660.784, y: 1),
            p1: CGPoint(x: 821.458, y: 1),
            p2: CGPoint(x: 885.217, y: 32.9104),
            p3: CGPoint(x: 1017.84, y: 32.9104)
        )
    ]

    private static let samples: [CurveSample] = {
        var values: [CurveSample] = []
        let stepsPerSegment = 180

        for segment in segments {
            for step in 0...stepsPerSegment {
                let t = CGFloat(step) / CGFloat(stepsPerSegment)
                let point = segment.point(at: t)
                values.append(
                    CurveSample(
                        x: normalizeX(point.x),
                        y: normalizeY(point.y)
                    )
                )
            }
        }

        values.sort { $0.x < $1.x }
        return values
    }()

    static func path(in size: CGSize) -> Path {
        var path = Path()
        guard let first = segments.first else { return path }
        path.move(to: convert(first.p0, size: size))

        for segment in segments {
            path.addCurve(
                to: convert(segment.p3, size: size),
                control1: convert(segment.p1, size: size),
                control2: convert(segment.p2, size: size)
            )
        }

        return path
    }

    private static let amplitudeScale: CGFloat = 0.5

    static func normalizedPoint(forXProgress progress: CGFloat) -> CGPoint {
        guard let first = samples.first, let last = samples.last else { return .zero }
        let target = progress.clamped(to: 0...1)

        if target <= first.x { return CGPoint(x: first.x, y: first.y) }
        if target >= last.x { return CGPoint(x: last.x, y: last.y) }

        var low = 0
        var high = samples.count - 1

        while low <= high {
            let mid = (low + high) / 2
            let sample = samples[mid]
            if sample.x < target {
                low = mid + 1
            } else if sample.x > target {
                high = mid - 1
            } else {
                return CGPoint(x: sample.x, y: sample.y)
            }
        }

        let upper = samples[low]
        let lower = samples[low - 1]
        let t = (target - lower.x) / (upper.x - lower.x)
        let y = lower.y + (upper.y - lower.y) * t
        let scaledY = 0.5 + (y - 0.5) * amplitudeScale
        return CGPoint(x: target, y: scaledY.clamped(to: 0...1))
    }

    private static func convert(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(
            x: normalizeX(point.x) * size.width,
            y: normalizeY(point.y) * size.height
        )
    }

    private static func normalizeX(_ rawX: CGFloat) -> CGFloat {
        (rawX - minX) / width
    }

    private static func normalizeY(_ rawY: CGFloat) -> CGFloat {
        (rawY - minY) / height
    }
}

private struct BezierSegment {
    let p0: CGPoint
    let p1: CGPoint
    let p2: CGPoint
    let p3: CGPoint

    func point(at t: CGFloat) -> CGPoint {
        let clampedT = t.clamped(to: 0...1)
        let oneMinusT = 1 - clampedT
        let a = oneMinusT * oneMinusT * oneMinusT
        let b = 3 * oneMinusT * oneMinusT * clampedT
        let c = 3 * oneMinusT * clampedT * clampedT
        let d = clampedT * clampedT * clampedT

        let x = a * p0.x + b * p1.x + c * p2.x + d * p3.x
        let y = a * p0.y + b * p1.y + c * p2.y + d * p3.y
        return CGPoint(x: x, y: y)
    }
}

private struct CurveSample {
    let x: CGFloat
    let y: CGFloat
}

private extension CGRect {
    func point(fromNormalized point: CGPoint) -> CGPoint {
        CGPoint(
            x: minX + point.x * width,
            y: minY + point.y * height
        )
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
