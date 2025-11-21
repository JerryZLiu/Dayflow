import SwiftUI

struct JournalDayView: View {
    var summary: JournalDaySummary
    var onSetReminders: (() -> Void)?
    var onNavigatePrevious: (() -> Void)?
    var onNavigateNext: (() -> Void)?
    var onReflect: (() -> Void)?

    @State private var selectedPeriod: JournalDayViewPeriod = .day
    @State private var flowState: JournalFlowState = .intro
    @State private var entry = JournalEntryData()

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
        GeometryReader { _ in
            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 10) {
                    toolbar

                    Text(summary.headline)
                        .font(.custom("InstrumentSerif-Regular", size: 36))
                        .foregroundStyle(JournalDayTokens.primaryText)

                    contentForFlowState

                    Spacer(minLength: 0)
                }
                .padding(.top, 10)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                Button("Next state: \(flowState.next.label)") {
                    flowState = flowState.next
                }
                .font(.custom("Nunito-SemiBold", size: 12))
                .padding(10)
                .background(Color.white.opacity(0.8))
                .cornerRadius(12)
                .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 1)
                .padding(14)
            }
        }
    }

    @ViewBuilder
    private var contentForFlowState: some View {
        switch flowState {
        case .intro:
            IntroView(ctaTitle: summary.ctaTitle) {
                flowState = .intentionsEdit
            }
        case .summary:
            SummaryView(copy: JournalDaySummary.placeholderSummaryText) {
                flowState = .intentionsEdit
            }
        case .intentionsEdit:
            IntentionsEditForm(
                entry: $entry,
                onCancel: { flowState = .intro },
                onSave: {
                    entry.normalizeLists()
                    flowState = .boardPending
                }
            )
        case .boardPending:
            BoardViewLeftIntentionsRightSummary(
                intentions: entry.intentionsList,
                notes: entry.notesText,
                goals: entry.goalsList,
                summary: "Summarizing your day recorded on your timeline…",
                reflections: entry.reflectionsText.isEmpty ? nil : entry.reflectionsText,
                showSummarizeButton: true,
                onSummarize: {
                    // Simulate Dayflow summary generation
                    if entry.summaryText.isEmpty {
                        entry.summaryText = JournalDaySummary.placeholderSummaryText
                    }
                    flowState = .boardComplete
                }
            )
        case .boardComplete:
            BoardViewLeftIntentionsRightSummary(
                intentions: entry.intentionsList,
                notes: entry.notesText,
                goals: entry.goalsList,
                summary: entry.summaryText.isEmpty ? nil : entry.summaryText,
                reflections: entry.reflectionsText.isEmpty ? nil : entry.reflectionsText,
                showSummarizeButton: false,
                onSummarize: {}
            )
        }
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
                .padding(.trailing, 20)
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
        ScrollView(.vertical, showsIndicators: true) {
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
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
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

// MARK: - Demo Screen Building Blocks

private struct IntroView: View {
    var ctaTitle: String
    var onTapCTA: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Set daily intentions and track your progress")
                .font(.custom("InstrumentSerif-Regular", size: 34))
                .foregroundStyle(JournalDayTokens.sectionHeader)
                .multilineTextAlignment(.center)

            Text("Some instructions here. Dayflow helps you track your daily and longer term pursuits, and gives you the space to reflect, and generates a summary of each day.")
                .font(.custom("Nunito-Regular", size: 16))
                .foregroundStyle(JournalDayTokens.bodyText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 540)

            Button(action: onTapCTA) {
                Text(ctaTitle)
                    .font(.custom("Nunito-SemiBold", size: 17))
            }
            .buttonStyle(ReflectCapsuleStyle())
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SummaryView: View {
    var copy: String
    var onTapCTA: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Summary from yesterday")
                .font(.custom("InstrumentSerif-Regular", size: 30))
                .foregroundStyle(JournalDayTokens.sectionHeader)
                .multilineTextAlignment(.center)

            Text(copy)
                .font(.custom("Nunito-Regular", size: 17))
                .foregroundStyle(JournalDayTokens.bodyText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 640)

            Button(action: onTapCTA) {
                Text("Set today’s intentions")
                    .font(.custom("Nunito-SemiBold", size: 17))
            }
            .buttonStyle(ReflectCapsuleStyle())
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct IntentionsEditForm: View {
    @Binding var entry: JournalEntryData
    var onCancel: () -> Void
    var onSave: () -> Void

    private let titleLeading: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            let availableHeight = proxy.size.height
            let buttonRowHeight: CGFloat = 46
            let spacing: CGFloat = 10
            let bottomInset: CGFloat = 10
            let cardHeight = max(0, availableHeight - buttonRowHeight - spacing - bottomInset)

            VStack(spacing: spacing) {
                editCard(maxHeight: cardHeight)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)

                HStack(spacing: 12) {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.bordered)

                    Button("Save", action: onSave)
                        .buttonStyle(ReflectCapsuleStyle())
                }
                .frame(height: buttonRowHeight)
                .padding(.horizontal, 10)
                .padding(.bottom, bottomInset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func editCard(maxHeight: CGFloat) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 5) {
            sectionIntentions
            sectionNotes
            sectionGoals
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .top)
        .background(Color.white)
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 0)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .inset(by: 0.5)
                .stroke(Color.white, lineWidth: 1)
        )
    }

    private var sectionIntentions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Today’s intentions")
                .font(.custom("InstrumentSerif-Regular", size: 22))
                .foregroundStyle(JournalDayTokens.sectionHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, titleLeading)

            labeledEditor(
                text: $entry.intentionsText,
                placeholder: "What do you intend on doing today?\nFor example, “complete the first draft of my new article”.",
                minLines: 3
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sectionNotes: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Notes for today")
                    .font(.custom("InstrumentSerif-Regular", size: 22))
                    .foregroundStyle(JournalDayTokens.sectionHeader)
                    .padding(.leading, titleLeading)
                Text("Optional")
                    .font(.custom("Nunito-Regular", size: 10))
                    .foregroundStyle(Color(red: 0.72, green: 0.60, blue: 0.47))
            }

            labeledEditor(
                text: $entry.notesText,
                placeholder: "What do you want to keep in mind for today?\nFor example. “Remember to take breaks,” or “don’t scroll on the phone too much”.",
                minLines: 3
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sectionGoals: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Long term goals")
                    .font(.custom("InstrumentSerif-Regular", size: 22))
                    .foregroundStyle(JournalDayTokens.sectionHeader)
                    .padding(.leading, titleLeading)
                Text("Optional")
                    .font(.custom("Nunito-Regular", size: 10))
                    .foregroundStyle(Color(red: 0.72, green: 0.60, blue: 0.47))
            }

            labeledEditor(
                text: $entry.goalsText,
                placeholder: "What are you working towards? Dayflow helps keep track of your long term goals for easy reference and edit any time.",
                minLines: 3
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func labeledEditor(text: Binding<String>, placeholder: String, minLines: Int) -> some View {
        GrowingTextEditor(
            text: text,
            placeholder: placeholder,
            font: .custom("Nunito-Regular", size: 15),
            placeholderFont: .custom("Nunito-Regular", size: 13),
            placeholderColor: JournalDayTokens.bodyText.opacity(0.45),
            minLines: minLines
        )
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Growing Text Editor

private struct GrowingTextEditor: View {
    @Binding var text: String
    var placeholder: String
    var font: Font
    var placeholderFont: Font
    var placeholderColor: Color
    var minLines: Int = 3

    @State private var measuredHeight: CGFloat = 0
    @State private var availableWidth: CGFloat = 0

    private let horizontalPadding: CGFloat = 0
    private let verticalPadding: CGFloat = 2

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(placeholderFont)
                    .foregroundColor(placeholderColor)
                    .padding(.vertical, verticalPadding)
            }

            TextEditor(text: $text)
                .font(font)
                .foregroundColor(JournalDayTokens.bodyText)
                .scrollContentBackground(.hidden)
                .padding(.vertical, verticalPadding)
                .padding(.horizontal, horizontalPadding)
                .frame(height: max(measuredHeight, minHeight))
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { availableWidth = geo.size.width }
                            .onChange(of: geo.size.width) { newValue in
                                availableWidth = newValue
                            }
                    }
                )
        }
        .background(Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.clear, lineWidth: 0)
        )
        .background(
            HiddenTextMeasurer(
                text: text.isEmpty ? placeholder : text,
                font: font,
                width: availableWidth - horizontalPadding * 2,
                verticalPadding: verticalPadding,
                minHeight: minHeight
            ) { h in
                measuredHeight = h
            }
        )
    }

    private var minHeight: CGFloat {
        // approximate line height from font size
        let lineHeight = 18.0
        return CGFloat(minLines) * lineHeight + verticalPadding * 2
    }
}

private struct HiddenTextMeasurer: View {
    var text: String
    var font: Font
    var width: CGFloat
    var verticalPadding: CGFloat
    var minHeight: CGFloat
    var onMeasure: (CGFloat) -> Void

    var body: some View {
        Text(text + " ")
            .font(font)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: max(0, width), alignment: .leading)
            .padding(.vertical, verticalPadding)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { onMeasure(max(minHeight, geo.size.height)) }
                        .onChange(of: geo.size.height) { newHeight in
                            onMeasure(max(minHeight, newHeight))
                        }
                }
            )
            .hidden()
    }
}

private struct BoardViewLeftIntentionsRightSummary: View {
    var intentions: [String]
    var notes: String
    var goals: [String]
    var summary: String?
    var reflections: String?
    var showSummarizeButton: Bool
    var onSummarize: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Left card with gradient treatment
            VStack(alignment: .leading, spacing: 18) {
                section("Today’s intentions", content: {
                    bulletList(intentions)
                })

                section("Notes for the day", content: {
                    Text(notes)
                        .font(.custom("Nunito-Regular", size: 15))
                        .foregroundStyle(JournalDayTokens.bodyText)
                })

                section("Long term goals", content: {
                    bulletList(goals)
                })

                Spacer(minLength: 0)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.3), location: 0.00),
                        .init(color: Color.white.opacity(0.8), location: 0.51),
                        .init(color: Color.white.opacity(0.3), location: 1.00)
                    ],
                    startPoint: UnitPoint(x: 1, y: 0.14),
                    endPoint: UnitPoint(x: 0, y: 0.78)
                )
            )
            .cornerRadius(12)
            .shadow(color: Color.black.opacity(0.1), radius: 6, x: 0, y: 0)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .inset(by: 0.5)
                    .stroke(Color.white, lineWidth: 1)
            )

            // Right card (keep vanilla fill/shadow)
            VStack(alignment: .leading, spacing: 14) {
                Text("Dayflow summary")
                    .font(.custom("InstrumentSerif-Regular", size: 22))
                    .foregroundStyle(JournalDayTokens.sectionHeader)

                if let summary {
                    Text(summary)
                        .font(.custom("Nunito-Regular", size: 15))
                        .foregroundStyle(JournalDayTokens.bodyText)
                } else {
                    Text("Summarizing your day recorded on your timeline…")
                        .font(.custom("Nunito-Regular", size: 15))
                        .foregroundStyle(JournalDayTokens.bodyText.opacity(0.7))
                }

                Text("Your reflections")
                    .font(.custom("InstrumentSerif-Regular", size: 22))
                    .foregroundStyle(JournalDayTokens.sectionHeader)

                if let reflections {
                    Text(reflections)
                        .font(.custom("Nunito-Regular", size: 15))
                        .foregroundStyle(JournalDayTokens.bodyText)
                } else {
                    Text("Return near the end of your day to reflect on your intentions.")
                        .font(.custom("Nunito-Regular", size: 15))
                        .foregroundStyle(JournalDayTokens.bodyText.opacity(0.7))
                }

                Spacer(minLength: 0)

                if showSummarizeButton {
                    HStack {
                        Spacer()
                        Button("Summarize with Dayflow", action: onSummarize)
                            .buttonStyle(ReflectCapsuleStyle())
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color.white.opacity(0.92))
            .cornerRadius(12)
            .shadow(color: Color.black.opacity(0.1), radius: 6, x: 0, y: 0)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.8), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func section(_ title: String, content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.custom("InstrumentSerif-Regular", size: 20))
                .foregroundStyle(JournalDayTokens.sectionHeader)
            content()
        }
    }

    @ViewBuilder
    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(JournalDayTokens.bullet)
                        .frame(width: 6, height: 6)
                    Text(item)
                        .font(.custom("Nunito-Regular", size: 15))
                        .foregroundStyle(JournalDayTokens.bodyText)
                }
            }
        }
    }
}

// MARK: - Models

enum JournalFlowState: CaseIterable {
    case intro
    case summary
    case intentionsEdit
    case boardPending
    case boardComplete

    var label: String {
        switch self {
        case .intro: return "Intro"
        case .summary: return "Summary"
        case .intentionsEdit: return "Intentions"
        case .boardPending: return "Board pending"
        case .boardComplete: return "Board complete"
        }
    }

    var next: JournalFlowState {
        let all = JournalFlowState.allCases
        guard let idx = all.firstIndex(of: self) else { return .intro }
        let nextIdx = all.index(after: idx)
        return nextIdx < all.endIndex ? all[nextIdx] : all.first ?? .intro
    }
}

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

    static let placeholderSummaryText = "Started the day reviewing design discussions in Slack, then briefly organized the Notion workspace, checked email, and updated Dayflow tasks. Spent a long time working in Figma—refining layouts, documenting updates, and troubleshooting with teammates."

    static let placeholderIntentions: [String] = [
        "Work on designs for xyz",
        "Learn about abc",
        "Look into recent user research",
        "Share design directions with stakeholders"
    ]

    static let placeholderGoals: [String] = [
        "Complete project A",
        "Publish article on Substack"
    ]
}

struct JournalEntryData {
    var intentionsText: String = JournalDaySummary.placeholderIntentions.joined(separator: "\n")
    var notesText: String = "Remember to take breaks and drink water."
    var goalsText: String = JournalDaySummary.placeholderGoals.joined(separator: "\n")
    var summaryText: String = ""
    var reflectionsText: String = ""

    var intentionsList: [String] {
        splitLines(intentionsText)
    }

    var goalsList: [String] {
        splitLines(goalsText)
    }

    mutating func normalizeLists() {
        intentionsText = splitLines(intentionsText).joined(separator: "\n")
        goalsText = splitLines(goalsText).joined(separator: "\n")
    }

    private func splitLines(_ text: String) -> [String] {
        text
            .split(whereSeparator: \ .isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
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
