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
        // Main container
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 10) {
                toolbar

                Text(summary.headline)
                    .font(.custom("InstrumentSerif-Regular", size: 36))
                    .foregroundStyle(JournalDayTokens.primaryText)

                // Main content area
                contentForFlowState
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                Spacer(minLength: 0)
            }
            .padding(.top, 10)
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // Debug/Demo state switcher
            Button("Next state: \(flowState.next.label)") {
                withAnimation {
                    flowState = flowState.next
                }
            }
            .font(.custom("Nunito-SemiBold", size: 12))
            .padding(10)
            .background(Color.white.opacity(0.8))
            .cornerRadius(12)
            .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 1)
            .padding(14)
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
                    flowState = .reflectionPrompt
                }
            )
        case .reflectionPrompt:
            JournalBoardLayout(
                intentions: entry.intentionsList,
                notes: entry.notesText,
                goals: entry.goalsList
            ) {
                ReflectionPromptCard {
                    flowState = .reflectionEdit
                }
            }
        case .reflectionEdit:
            JournalBoardLayout(
                intentions: entry.intentionsList,
                notes: entry.notesText,
                goals: entry.goalsList
            ) {
                ReflectionEditorCard(
                    text: $entry.reflectionsText,
                    onSave: {
                        entry.reflectionsText = entry.reflectionsText.trimmingCharacters(in: .whitespacesAndNewlines)
                        flowState = .reflectionSaved
                    },
                    onSkip: {
                        entry.reflectionsText = ""
                        flowState = .reflectionSaved
                    }
                )
            }
        case .reflectionSaved:
            JournalBoardLayout(
                intentions: entry.intentionsList,
                notes: entry.notesText,
                goals: entry.goalsList
            ) {
                ReflectionSavedCard(
                    reflections: entry.reflectionsText,
                    onSummarize: {
                        if entry.summaryText.isEmpty {
                            entry.summaryText = JournalDaySummary.placeholderSummaryText
                        }
                        flowState = .boardComplete
                    }
                )
            }
        case .boardComplete:
            JournalBoardLayout(
                intentions: entry.intentionsList,
                notes: entry.notesText,
                goals: entry.goalsList
            ) {
                SummaryCard(
                    summary: entry.summaryText.isEmpty ? JournalDaySummary.placeholderSummaryText : entry.summaryText,
                    reflections: entry.reflectionsText.isEmpty ? nil : entry.reflectionsText
                )
            }
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
                }
                .buttonStyle(JournalPillButtonStyle(horizontalPadding: 12, verticalPadding: 6, font: .custom("Nunito-SemiBold", size: 12)))
                .padding(.trailing, 20)
            }
        }
    }
}

// MARK: - Reusable Modern Text Editor

private struct JournalTextEditor: View {
    @Binding var text: String
    var placeholder: String
    var minLines: Int = 3
    
    // 1. Define the font and padding constants once so the math matches perfectly
    private let font = NSFont(name: "Nunito-Regular", size: 15) ?? .systemFont(ofSize: 15)
    private let verticalInset: CGFloat = 4 // Matches MacTextView.textContainerInset
    
    // Initialize with a calculated default so it doesn't jump on load
    @State private var height: CGFloat = 0
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            // Placeholder
            if text.isEmpty {
                Text(placeholder)
                    .font(.custom("Nunito-Regular", size: 15))
                    .foregroundStyle(JournalDayTokens.bodyText.opacity(0.45))
                    .padding(.top, verticalInset)
                    // 2. Adjust placeholder to match cursor position (LineFragmentPadding is 4 inside MacTextView)
                    .padding(.leading, 4)
                    .allowsHitTesting(false)
            }
            
            MacTextView(
                text: $text,
                height: $height,
                minLines: minLines,
                font: font
            )
            // 3. FIX: Use calculated height instead of hardcoded * 22
            .frame(height: max(height, calculateMinHeight()))
        }
        .padding(.vertical, 2)
        // 4. FIX: Removed .padding(.horizontal, 4) to shift the box left
        // We keep trailing padding if you want the right edge to stay indented,
        // or remove it entirely to widen the box.
        .padding(.horizontal, 2)
    }
    
    // Calculates the exact height 3 lines of this specific font will take up
    private func calculateMinHeight() -> CGFloat {
        // Get the real line height (Ascender + Descender + Leading)
        // For Nunito 15, this is usually around 20.5pt, not 22pt.
        guard let layoutManager = NSLayoutManager() as? NSLayoutManager else {
            return CGFloat(minLines * 22) // Fallback if something weird happens
        }
        let lineHeight = layoutManager.defaultLineHeight(for: font)
        
        // (LineHeight * Lines) + (Top Padding + Bottom Padding)
        return (lineHeight * CGFloat(minLines)) + (verticalInset * 2)
    }
}

// MARK: - The AppKit Wrapper (Fixes Enter Key & Layout Loops & Clicks)

private struct MacTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var minLines: Int
    var font: NSFont
    
    func makeCoordinator() -> Coordinator {
        return Coordinator(parent: self)
    }
    
    func makeNSView(context: Context) -> JournalClickableTextView {
        let textView = JournalClickableTextView()
        textView.delegate = context.coordinator
        
        // Appearance
        textView.font = font
        textView.textColor = NSColor(red: 0.18, green: 0.11, blue: 0.06, alpha: 1.0)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        
        // Layout Config
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        
        // Padding/Insets
        textView.textContainerInset = NSSize(width: 0, height: 4)
        
        if let container = textView.textContainer {
            container.lineFragmentPadding = 4
            container.widthTracksTextView = true
            // Initialize with a massive height so it doesn't feel cramped immediately
            container.containerSize = NSSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
        }
        
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(red: 1.0, green: 0.93, blue: 0.82, alpha: 1.0),
            .foregroundColor: NSColor(red: 0.18, green: 0.11, blue: 0.06, alpha: 1.0)
        ]
        
        return textView
    }
    
    func updateNSView(_ nsView: JournalClickableTextView, context: Context) {
        // FIX 2: Handle Cursor Jump on Enter
        // Only update if the text is actually different
        if nsView.string != text {
            // 1. Capture current selection
            let selectedRange = nsView.selectedRange()
            
            // 2. Update text
            nsView.string = text
            
            // 3. Restore selection (clamped to safety in case text length changed drastically)
            let newLength = (text as NSString).length
            let location = min(selectedRange.location, newLength)
            let length = min(selectedRange.length, newLength - location)
            
            if location >= 0 {
                nsView.setSelectedRange(NSRange(location: location, length: length))
            }
        }
        
        // Ensure container width is correct on update
        if let container = nsView.textContainer, container.containerSize.width != nsView.bounds.width {
            container.containerSize = NSSize(width: nsView.bounds.width, height: .greatestFiniteMagnitude)
        }

        // FIX 1: Layout Loops
        // We do NOT use DispatchQueue.main.async here for height calculation during updates,
        // as it causes the "pop" effect. We calculate immediately.
        context.coordinator.recalculateHeight(view: nsView)
    }
    
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacTextView
        
        init(parent: MacTextView) {
            self.parent = parent
        }
        
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            
            // Update Binding
            parent.text = textView.string
            
            // Calculate height synchronously to ensure the SwiftUI frame expands *as* you type,
            // not one frame later.
            recalculateHeight(view: textView)
        }
        
        func recalculateHeight(view: NSTextView) {
            guard let layoutManager = view.layoutManager,
                  let textContainer = view.textContainer else { return }
            
            // Force layout calculation
            layoutManager.ensureLayout(for: textContainer)
            
            let usedRect = layoutManager.usedRect(for: textContainer)
            let newHeight = usedRect.height + view.textContainerInset.height * 2
            
            // Only update binding if the difference is significant to avoid infinite loops
            if abs(parent.height - newHeight) > 0.5 {
                DispatchQueue.main.async {
                    self.parent.height = newHeight
                }
            }
        }
    }
}

// MARK: - Custom NSTextView Subclass (The Fix)

/// A custom NSTextView that claims clicks in its empty space.
/// This fixes the issue where clicking the "padding" area of a tall text editor
/// (minLines > 1) would otherwise be ignored by the text system.
private class JournalClickableTextView: NSTextView {
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        // 1. Ask the system who should receive the click
        let hitView = super.hitTest(point)
        
        // 2. If the system found a subview (like an attachment) or self, return it.
        if hitView != nil {
            return hitView
        }
        
        // 3. If the system returned nil, but the click is physically inside our bounds,
        // force return 'self'. This happens when clicking the empty space below the text.
        // NSTextView will then handle the mouseDown and place the cursor at the end.
        if self.bounds.contains(point) {
            return self
        }
        
        return nil
    }
}

// MARK: - Intentions Edit Form

private struct IntentionsEditForm: View {
    @Binding var entry: JournalEntryData
    var onCancel: () -> Void
    var onSave: () -> Void

    private let titleLeading: CGFloat = 5

    var body: some View {
        VStack(spacing: 10) {
            editCard
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
            
            HStack(spacing: 12) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)

                Button("Save", action: onSave)
                    .buttonStyle(JournalPillButtonStyle(horizontalPadding: 22, verticalPadding: 9))
            }
            .frame(height: 46)
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
    }

    private var editCard: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 5) {
                sectionIntentions
                sectionNotes
                sectionGoals
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(
            LinearGradient(
                stops: [
                    .init(color: Color.white.opacity(0.3), location: 0.00),
                    .init(color: Color.white.opacity(0.8), location: 0.50),
                    .init(color: Color.white.opacity(0.3), location: 1.00)
                ],
                startPoint: UnitPoint(x: 1, y: 0.14),
                endPoint: UnitPoint(x: 0, y: 0.78)
            )
        )
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 0)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .inset(by: 0.5)
                .stroke(Color.white, lineWidth: 1)
        )
    }

    private var sectionIntentions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Today’s intentions")
                .font(.custom("InstrumentSerif-Regular", size: 22))
                .foregroundStyle(JournalDayTokens.sectionHeader)
                .padding(.leading, titleLeading)

            JournalTextEditor(
                text: $entry.intentionsText,
                placeholder: "What do you intend on doing today?\nFor example, “complete the first draft of my new article”.",
                minLines: 3
            )
        }
    }

    private var sectionNotes: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Notes for today")
                    .font(.custom("InstrumentSerif-Regular", size: 22))
                    .foregroundStyle(JournalDayTokens.sectionHeader)
                    .padding(.leading, titleLeading)
            }

            JournalTextEditor(
                text: $entry.notesText,
                placeholder: "What do you want to keep in mind for today?\nFor example. “Remember to take breaks,” or “don’t scroll on the phone too much”.",
                minLines: 3
            )
        }
    }

    private var sectionGoals: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Long term goals")
                    .font(.custom("InstrumentSerif-Regular", size: 22))
                    .foregroundStyle(JournalDayTokens.sectionHeader)
                    .padding(.leading, titleLeading)
            }

            JournalTextEditor(
                text: $entry.goalsText,
                placeholder: "What are you working towards? Dayflow helps keep track of your long term goals for easy reference and edit any time.",
                minLines: 3
            )
        }
    }
}

// MARK: - Reflection Prompt & Edit

private struct ReflectionPromptCard: View {
    var onReflect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Today’s reflections")
                .font(.custom("InstrumentSerif-Regular", size: 22))
                .foregroundStyle(JournalDayTokens.sectionHeader.opacity(0.4))

            Text("Return near the end of your day to reflect on your intentions. Let Dayflow generate a narrative summary based on the activities on your Timeline.")
                .font(.custom("Nunito-Regular", size: 15))
                .foregroundStyle(JournalDayTokens.bodyText.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Reflect on your day", action: onReflect)
                    .buttonStyle(JournalPillButtonStyle(horizontalPadding: 20, verticalPadding: 10))
            }
        }
    }
}

private struct ReflectionEditorCard: View {
    @Binding var text: String
    var onSave: () -> Void
    var onSkip: () -> Void

    private var isSaveDisabled: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your reflections")
                .font(.custom("InstrumentSerif-Regular", size: 22))
                .foregroundStyle(JournalDayTokens.sectionHeader)

            JournalTextEditor(
                text: $text,
                placeholder: "How was your day? What did you do? How do you feel?",
                minLines: 6
            )
            .padding(.leading, -4)
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Button("Save", action: onSave)
                    .buttonStyle(JournalPillButtonStyle(horizontalPadding: 18, verticalPadding: 8))
                    .disabled(isSaveDisabled)
                    .opacity(isSaveDisabled ? 0.55 : 1)

                Button("Skip", action: onSkip)
                    .buttonStyle(.plain)
                    .foregroundStyle(JournalDayTokens.bodyText.opacity(0.6))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

private struct ReflectionSavedCard: View {
    var reflections: String
    var onSummarize: () -> Void

    private var hasReflections: Bool {
        !reflections.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your reflections")
                .font(.custom("InstrumentSerif-Regular", size: 22))
                .foregroundStyle(JournalDayTokens.sectionHeader)

            if hasReflections {
                ScrollView {
                    Text(reflections)
                        .font(.custom("Nunito-Regular", size: 15))
                        .foregroundStyle(JournalDayTokens.bodyText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                        .padding(.leading, 0)
                        .padding(.horizontal, 2)
                }
            } else {
                Text("Return near the end of your day to reflect on your intentions.")
                    .font(.custom("Nunito-Regular", size: 15))
                    .foregroundStyle(JournalDayTokens.bodyText.opacity(0.65))
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Summarize with Dayflow", action: onSummarize)
                    .buttonStyle(JournalPillButtonStyle(horizontalPadding: 24, verticalPadding: 11))
            }
        }
    }
}

private struct SummaryCard: View {
    var summary: String?
    var reflections: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Dayflow summary")
                    .font(.custom("InstrumentSerif-Regular", size: 22))
                    .foregroundStyle(JournalDayTokens.sectionHeader)

                if let summary {
                    Text(summary)
                        .font(.custom("Nunito-Regular", size: 15))
                        .foregroundStyle(JournalDayTokens.bodyText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Summarizing your day recorded on your timeline…")
                        .font(.custom("Nunito-Regular", size: 15))
                        .foregroundStyle(JournalDayTokens.bodyText.opacity(0.65))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Your reflections")
                    .font(.custom("InstrumentSerif-Regular", size: 22))
                    .foregroundStyle(JournalDayTokens.sectionHeader)

                if let reflections, !reflections.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(reflections)
                        .font(.custom("Nunito-Regular", size: 15))
                        .foregroundStyle(JournalDayTokens.bodyText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Return near the end of your day to reflect on your intentions.")
                        .font(.custom("Nunito-Regular", size: 15))
                        .foregroundStyle(JournalDayTokens.bodyText.opacity(0.65))
                }
            }

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Layout & Utility Components

private struct JournalBoardLayout<RightContent: View>: View {
    var intentions: [String]
    var notes: String
    var goals: [String]
    var rightContent: RightContent

    init(intentions: [String], notes: String, goals: [String], @ViewBuilder rightContent: () -> RightContent) {
        self.intentions = intentions
        self.notes = notes
        self.goals = goals
        self.rightContent = rightContent()
    }

    var body: some View {
        HStack(spacing: 0) {
            JournalLeftCardView(intentions: intentions, notes: notes, goals: goals)
            JournalRightCard { rightContent }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct JournalLeftCardView: View {
    var intentions: [String]
    var notes: String
    var goals: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Today’s intentions") {
                JournalDayBulletList(items: intentions)
            }

            section("Notes for the day") {
                Text(notes)
                    .font(.custom("Nunito-Regular", size: 15))
                    .foregroundStyle(JournalDayTokens.bodyText)
            }

            Divider()
                .foregroundStyle(JournalDayTokens.divider)
                .overlay(JournalDayTokens.divider)
                .padding(.vertical, 6)

            section("Long term goals") {
                JournalDayBulletList(items: goals)
            }

            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
}

private struct JournalRightCard<Content: View>: View {
    var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            content
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.92))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.1), radius: 6, x: 0, y: 0)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.8), lineWidth: 1)
        )
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

private struct JournalPillButtonStyle: ButtonStyle {
    var horizontalPadding: CGFloat = 18
    var verticalPadding: CGFloat = 9
    var font: Font = .custom("Nunito-SemiBold", size: 16)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(JournalDayTokens.primaryText.opacity(0.8))
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                Color(red: 1, green: 0.96, blue: 0.92)
                    .opacity(configuration.isPressed ? 0.7 : 0.6)
            )
            .cornerRadius(100)
            .overlay(
                RoundedRectangle(cornerRadius: 100)
                    .inset(by: 0.5)
                    .stroke(Color(red: 0.95, green: 0.86, blue: 0.84), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: configuration.isPressed)
    }
}

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
            .buttonStyle(JournalPillButtonStyle(horizontalPadding: 28, verticalPadding: 10))
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
            .buttonStyle(JournalPillButtonStyle(horizontalPadding: 28, verticalPadding: 10))
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Models & Tokens

enum JournalFlowState: CaseIterable {
    case intro
    case summary
    case intentionsEdit
    case reflectionPrompt
    case reflectionEdit
    case reflectionSaved
    case boardComplete

    var label: String {
        switch self {
        case .intro: return "Intro"
        case .summary: return "Summary"
        case .intentionsEdit: return "Intentions"
        case .reflectionPrompt: return "Reflect prompt"
        case .reflectionEdit: return "Reflect edit"
        case .reflectionSaved: return "Reflect saved"
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

private enum JournalDayTokens {
    static let primaryText = Color(red: 0.18, green: 0.09, blue: 0.03) // "2F1607"
    static let reminderText = Color(red: 0.35, green: 0.20, blue: 0.05) // "5A320E"
    
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
            .frame(width: 800, height: 600)
    }
}
