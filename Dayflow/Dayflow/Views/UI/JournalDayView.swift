import SwiftUI
import Combine

// MARK: - Motion Modifiers & Transitions

struct BookFlipModifier: ViewModifier {
    let angle: Double
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(
                .degrees(angle),
                axis: (x: 0, y: 1, z: 0),
                anchor: anchor,
                anchorZ: 0,
                perspective: 0.5
            )
            .opacity(abs(angle) > 89 ? 0 : 1)
            .overlay(
                Color.black
                    .opacity(calculateShadowOpacity(angle: angle))
                    .allowsHitTesting(false)
            )
    }
    
    private func calculateShadowOpacity(angle: Double) -> Double {
        let progress = abs(angle) / 90.0
        return progress * 0.15
    }
}

extension AnyTransition {
    static var bookFlipNext: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: BookFlipModifier(angle: 90, anchor: .leading),
                identity: BookFlipModifier(angle: 0, anchor: .leading)
            ),
            removal: .modifier(
                active: BookFlipModifier(angle: -90, anchor: .trailing),
                identity: BookFlipModifier(angle: 0, anchor: .trailing)
            )
        )
    }

    static var bookFlipPrev: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: BookFlipModifier(angle: -90, anchor: .trailing),
                identity: BookFlipModifier(angle: 0, anchor: .trailing)
            ),
            removal: .modifier(
                active: BookFlipModifier(angle: 90, anchor: .leading),
                identity: BookFlipModifier(angle: 0, anchor: .leading)
            )
        )
    }
}

struct WetInkText: View {
    let text: String
    var font: Font = .custom("Nunito-Regular", size: 15)
    var color: Color = Color(red: 0.18, green: 0.11, blue: 0.06)
    var lineHeight: CGFloat = 5
    
    @State private var displayedText: String = ""
    @State private var isComplete: Bool = false
    
    var body: some View {
        Text(displayedText)
            .font(font)
            .foregroundStyle(color.opacity(isComplete ? 1.0 : 0.8))
            .lineSpacing(lineHeight)
            .blur(radius: isComplete ? 0 : 0.2)
            .animation(.easeOut(duration: 0.5), value: isComplete)
            .onAppear {
                typewriterEffect()
            }
            .onChange(of: text) { _ in
                typewriterEffect()
            }
    }
    
    private func typewriterEffect() {
        displayedText = ""
        isComplete = false
        
        let chars = Array(text)
        var currentIndex = 0
        
        func nextChar() {
            guard currentIndex < chars.count else {
                isComplete = true
                return
            }
            
            displayedText.append(chars[currentIndex])
            currentIndex += 1
            
            let char = chars[currentIndex - 1]
            var delay: Double = Double.random(in: 0.01...0.03)
            
            if char == "." || char == "," || char == "\n" {
                delay += 0.15
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                nextChar()
            }
        }
        
        nextChar()
    }
}

struct JournalPillButtonStyle: ButtonStyle {
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
                ZStack {
                    Color(red: 1, green: 0.96, blue: 0.92)
                        .opacity(configuration.isPressed ? 0.9 : 0.6)
                    
                    if configuration.isPressed {
                        Color.white.opacity(0.2)
                    }
                }
            )
            .cornerRadius(100)
            .overlay(
                RoundedRectangle(cornerRadius: 100)
                    .inset(by: 0.5)
                    .stroke(Color(red: 0.95, green: 0.86, blue: 0.84), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}


// MARK: - Main View

struct JournalDayView: View {
    var onSetReminders: (() -> Void)?

    @StateObject private var manager = JournalDayManager()
    @State private var selectedPeriod: JournalDayViewPeriod = .day
    
    @Namespace private var layoutNamespace
    @State private var transitionDirection: AnyTransition = .identity
    @State private var pageId = UUID()
    
    @AppStorage("showJournalDebugPanel") private var showDebugPanel = false

    init(onSetReminders: (() -> Void)? = nil) {
        self.onSetReminders = onSetReminders
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 10) {
                toolbar

                Text(manager.headline)
                    .font(.custom("InstrumentSerif-Regular", size: 36))
                    .foregroundStyle(JournalDayTokens.primaryText)
                    .transaction { transaction in
                        transaction.animation = nil
                    }

                contentForFlowState
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .id(pageId)
                    .transition(transitionDirection)

                Spacer(minLength: 0)
            }
            .padding(.top, 10)
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if showDebugPanel {
                DebugPanelView(manager: manager)
            }
        }
        .onAppear {
            manager.loadCurrentDay()
        }
    }
}

// MARK: - Content Switcher

extension JournalDayView {
    @ViewBuilder
    var contentForFlowState: some View {
        switch manager.flowState {
        case .intro:
            IntroView(ctaTitle: manager.ctaTitle, isEnabled: manager.isToday) {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                    manager.startEditingIntentions()
                }
            }
        case .summary:
            SummaryView(copy: manager.recentSummary?.summary ?? "") {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                    manager.startEditingIntentions()
                }
            }
        case .intentionsEdit:
            IntentionsEditForm(
                intentions: $manager.formIntentions,
                notes: $manager.formNotes,
                goals: $manager.formGoals,
                onBack: { manager.cancelEditingIntentions() },
                onSave: {
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) {
                        manager.saveIntentions()
                    }
                },
                namespace: layoutNamespace
            )
            .zIndex(10)
            
        case .reflectionPrompt:
            JournalBoardLayout(
                intentions: manager.intentionsList,
                notes: manager.formNotes,
                goals: manager.goalsList,
                onTapLeft: manager.isToday ? {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                        manager.startEditingIntentions()
                    }
                } : nil,
                isUnfolding: true,
                namespace: layoutNamespace
            ) {
                ReflectionPromptCard(isEnabled: manager.isToday) {
                    withAnimation { manager.startReflecting() }
                }
            }
            .zIndex(1)
            
        case .reflectionEdit:
            JournalBoardLayout(
                intentions: manager.intentionsList,
                notes: manager.formNotes,
                goals: manager.goalsList,
                onTapLeft: nil
            ) {
                ReflectionEditorCard(
                    text: $manager.formReflections,
                    onSave: { manager.saveReflections() },
                    onSkip: { manager.skipReflections() }
                )
            }
        case .reflectionSaved:
            JournalBoardLayout(
                intentions: manager.intentionsList,
                notes: manager.formNotes,
                goals: manager.goalsList,
                onTapLeft: manager.isToday ? { manager.startEditingIntentions() } : nil
            ) {
                ReflectionSavedCard(
                    reflections: manager.formReflections,
                    canSummarize: manager.canSummarize,
                    isLoading: manager.isLoading,
                    errorMessage: manager.errorMessage,
                    onSummarize: {
                        Task { await manager.generateSummary() }
                    },
                    onDismissError: { manager.errorMessage = nil }
                )
            }
        case .boardComplete:
            JournalBoardLayout(
                intentions: manager.intentionsList,
                notes: manager.formNotes,
                goals: manager.goalsList,
                onTapLeft: manager.isToday ? { manager.startEditingIntentions() } : nil
            ) {
                SummaryCard(
                    summary: manager.formSummary.isEmpty ? nil : manager.formSummary,
                    reflections: manager.formReflections.isEmpty ? nil : manager.formReflections,
                    onRegenerate: {
                        Task { await manager.generateSummary() }
                    }
                )
            }
        }
    }

    private var toolbar: some View {
        ZStack {
            HStack(spacing: 10) {
                JournalDayCircleButton(direction: .left) {
                    transitionDirection = .bookFlipPrev
                    withAnimation(.easeInOut(duration: 0.6)) {
                        manager.navigateToPreviousDay()
                        pageId = UUID()
                    }
                }

                JournalDaySegmentedControl(selection: $selectedPeriod)
                    .fixedSize()

                JournalDayCircleButton(direction: .right, isDisabled: !manager.canNavigateForward) {
                    transitionDirection = .bookFlipNext
                    withAnimation(.easeInOut(duration: 0.6)) {
                        manager.navigateToNextDay()
                        pageId = UUID()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            HStack {
                Spacer()
                Button(action: {
                    AnalyticsService.shared.capture("journal_reminders_opened")
                    onSetReminders?()
                }) {
                    HStack(alignment: .center, spacing: 4) {
                        Image("JournalReminderIcon")
                            .resizable()
                            .renderingMode(.template)
                            .foregroundStyle(JournalDayTokens.reminderText)
                            .frame(width: 16, height: 16)

                        Text("Set reminders")
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

// MARK: - Debug Panel
private struct DebugPanelView: View {
    @ObservedObject var manager: JournalDayManager
    @AppStorage("isJournalUnlocked") private var isJournalUnlocked: Bool = false
    @AppStorage("hasCompletedJournalOnboarding") private var hasCompletedOnboarding: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Debug")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
            Button("🔒 Lock") { isJournalUnlocked = false }.font(.system(size: 9))
            Button("🔄 Reset") { hasCompletedOnboarding = false; isJournalUnlocked = false }.font(.system(size: 9))
            Divider().background(Color.white.opacity(0.3))
            Button("→ Intro") { manager.flowState = .intro }.font(.system(size: 9))
            Button("→ Summary") { manager.flowState = .summary }.font(.system(size: 9))
            Button("→ Intents") { manager.flowState = .intentionsEdit }.font(.system(size: 9))
            Button("→ Prompt") { manager.flowState = .reflectionPrompt }.font(.system(size: 9))
        }
        .frame(maxWidth: 100)
        .padding(6)
        .background(Color.black.opacity(0.75))
        .cornerRadius(6)
        .padding(8)
    }
}

// MARK: - Reusable Modern Text Editor

private struct JournalTextEditor: View {
    @Binding var text: String
    var placeholder: String
    var minLines: Int = 3
    var autoFocus: Bool = false

    private let font = NSFont(name: "Nunito-Regular", size: 15) ?? .systemFont(ofSize: 15)
    private let verticalInset: CGFloat = 4
    @State private var height: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.custom("Nunito-Regular", size: 15))
                    .foregroundStyle(JournalDayTokens.bodyText.opacity(0.45))
                    .padding(.top, verticalInset)
                    .padding(.leading, 4)
                    .allowsHitTesting(false)
            }

            MacTextView(
                text: $text,
                height: $height,
                minLines: minLines,
                font: font,
                autoFocus: autoFocus
            )
            .frame(height: max(height, calculateMinHeight()))
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 2)
    }
    
    private func calculateMinHeight() -> CGFloat {
        guard let layoutManager = NSLayoutManager() as? NSLayoutManager else {
            return CGFloat(minLines * 22)
        }
        let lineHeight = layoutManager.defaultLineHeight(for: font)
        return (lineHeight * CGFloat(minLines)) + (verticalInset * 2)
    }
}

// MARK: - AppKit Wrappers

private struct MacTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var minLines: Int
    var font: NSFont
    var autoFocus: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> JournalClickableTextView {
        let textView = JournalClickableTextView()
        textView.delegate = context.coordinator
        textView.font = font
        textView.textColor = NSColor(red: 0.18, green: 0.11, blue: 0.06, alpha: 1.0)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 4)

        if let container = textView.textContainer {
            container.lineFragmentPadding = 4
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
        }

        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(red: 1.0, green: 0.93, blue: 0.82, alpha: 1.0),
            .foregroundColor: NSColor(red: 0.18, green: 0.11, blue: 0.06, alpha: 1.0)
        ]

        if autoFocus {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                textView.window?.makeFirstResponder(textView)
            }
        }
        return textView
    }
    
    func updateNSView(_ nsView: JournalClickableTextView, context: Context) {
        if nsView.string != text {
            let selectedRange = nsView.selectedRange()
            nsView.string = text
            let newLength = (text as NSString).length
            let location = min(selectedRange.location, newLength)
            let length = min(selectedRange.length, newLength - location)
            if location >= 0 {
                nsView.setSelectedRange(NSRange(location: location, length: length))
            }
        }
        if let container = nsView.textContainer, container.containerSize.width != nsView.bounds.width {
            container.containerSize = NSSize(width: nsView.bounds.width, height: .greatestFiniteMagnitude)
        }
        context.coordinator.recalculateHeight(view: nsView)
    }
    
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacTextView
        init(parent: MacTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            recalculateHeight(view: textView)
        }
        func recalculateHeight(view: NSTextView) {
            guard let layoutManager = view.layoutManager, let textContainer = view.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let newHeight = usedRect.height + view.textContainerInset.height * 2
            if abs(parent.height - newHeight) > 0.5 {
                DispatchQueue.main.async { self.parent.height = newHeight }
            }
        }
    }
}

private class JournalClickableTextView: NSTextView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hitView = super.hitTest(point)
        if hitView != nil { return hitView }
        if self.bounds.contains(point) { return self }
        return nil
    }
}

// MARK: - Intentions Edit Form

private struct IntentionsEditForm: View {
    @Binding var intentions: String
    @Binding var notes: String
    @Binding var goals: String
    var onBack: () -> Void
    var onSave: () -> Void
    var namespace: Namespace.ID

    private let titleLeading: CGFloat = 5

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(JournalDayTokens.bodyText.opacity(0.5))
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.6))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 12)

            editCard
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .matchedGeometryEffect(id: "card_bg", in: namespace)

            HStack(spacing: 12) {
                Button("Save", action: onSave)
                    .buttonStyle(JournalPillButtonStyle(horizontalPadding: 22, verticalPadding: 9))
            }
            .frame(height: 46)
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
        .transition(.opacity.animation(.easeInOut(duration: 0.2)))
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

    private static let intentionsPlaceholders = [
        "What does a good day look like?",
        "If today goes well, what will you have done?"
    ]

    @State private var intentionsPlaceholder: String = intentionsPlaceholders.randomElement()!

    private var sectionIntentions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Today's intentions")
                .font(.custom("InstrumentSerif-Regular", size: 22))
                .foregroundStyle(JournalDayTokens.sectionHeader)
                .padding(.leading, titleLeading)

            JournalTextEditor(
                text: $intentions,
                placeholder: intentionsPlaceholder,
                minLines: 3,
                autoFocus: true
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
                text: $notes,
                placeholder: "What mindset do you want to carry today?",
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
                text: $goals,
                placeholder: "What are you working towards?",
                minLines: 3
            )
        }
    }
}

// MARK: - Layout & Utility Components

private struct JournalBoardLayout<RightContent: View>: View {
    var intentions: [String]
    var notes: String
    var goals: [String]
    var onTapLeft: (() -> Void)?
    
    var isUnfolding: Bool
    var namespace: Namespace.ID?
    @State private var rotationAngle: Double
    @State private var opacity: Double
    
    var rightContent: RightContent

    init(
        intentions: [String],
        notes: String,
        goals: [String],
        onTapLeft: (() -> Void)? = nil,
        isUnfolding: Bool = false,
        namespace: Namespace.ID? = nil,
        @ViewBuilder rightContent: () -> RightContent
    ) {
        self.intentions = intentions
        self.notes = notes
        self.goals = goals
        self.onTapLeft = onTapLeft
        self.isUnfolding = isUnfolding
        self.namespace = namespace
        self.rightContent = rightContent()
        
        _rotationAngle = State(initialValue: isUnfolding ? -90 : 0)
        _opacity = State(initialValue: isUnfolding ? 0 : 1)
    }

    var body: some View {
        HStack(spacing: 0) {
            JournalLeftCardView(intentions: intentions, notes: notes, goals: goals, onTap: onTapLeft, namespace: namespace)
                .zIndex(1)
            
            JournalRightCard { rightContent }
                .opacity(opacity)
                .rotation3DEffect(
                    .degrees(rotationAngle),
                    axis: (x: 0, y: 1, z: 0),
                    anchor: .leading,
                    anchorZ: 0,
                    perspective: 0.5
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            if isUnfolding {
                withAnimation(.spring(response: 0.7, dampingFraction: 0.7).delay(0.6)) {
                    rotationAngle = 0
                    opacity = 1
                }
            }
        }
    }
}

struct PaperHoverEffect: ViewModifier {
    @State private var isHovered = false
    var isEnabled: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered && isEnabled ? 1.01 : 1.0)
            .shadow(
                color: Color.black.opacity(isHovered && isEnabled ? 0.12 : 0.0),
                radius: isHovered && isEnabled ? 12 : 0,
                x: 0,
                y: isHovered && isEnabled ? 4 : 0
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

private struct JournalLeftCardView: View {
    var intentions: [String]
    var notes: String
    var goals: [String]
    var onTap: (() -> Void)?
    var namespace: Namespace.ID?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                section("Today's intentions") {
                    JournalDayBulletList(items: intentions)
                }
                section("Notes for the day") {
                    Text(notes.isEmpty ? "—" : notes)
                        .font(.custom("Nunito-Regular", size: 15))
                        .foregroundStyle(notes.isEmpty ? JournalDayTokens.bodyText.opacity(0.4) : JournalDayTokens.bodyText)
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
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .applyIf(namespace != nil) { view in
             view.matchedGeometryEffect(id: "card_bg", in: namespace!)
        }
        .modifier(PaperHoverEffect(isEnabled: onTap != nil))
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
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

extension View {
    @ViewBuilder func applyIf<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

private struct JournalRightCard<Content: View>: View {
    var content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) { content }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.92))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.1), radius: 6, x: 0, y: 0)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.8), lineWidth: 1)
        )
    }
}

// MARK: - Reflection Prompt & Edit Components

private struct ReflectionPromptCard: View {
    var isEnabled: Bool = true
    var onReflect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Today's reflections")
                .font(.custom("InstrumentSerif-Regular", size: 22))
                .foregroundStyle(JournalDayTokens.sectionHeader.opacity(0.4))

            Text("Return near the end of your day to reflect on your intentions. Let Dayflow generate a narrative summary based on the activities on your Timeline.")
                .font(.custom("Nunito-Regular", size: 15))
                .foregroundStyle(JournalDayTokens.bodyText.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if isEnabled {
                HStack {
                    Spacer()
                    Button("Reflect on your day", action: onReflect)
                        .buttonStyle(JournalPillButtonStyle(horizontalPadding: 20, verticalPadding: 10))
                }
            }
        }
    }
}

private struct ReflectionEditorCard: View {
    @Binding var text: String
    var onSave: () -> Void
    var onSkip: () -> Void
    private var isSaveDisabled: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

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
                    .animation(.easeInOut(duration: 0.2), value: isSaveDisabled)

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
    var canSummarize: Bool = true
    var isLoading: Bool = false
    var errorMessage: String? = nil
    var onSummarize: () -> Void
    var onDismissError: (() -> Void)? = nil
    private var hasReflections: Bool { !reflections.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

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
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text("Generating summary...").font(.custom("Nunito-Regular", size: 14)).foregroundStyle(JournalDayTokens.bodyText.opacity(0.7))
                    }
                } else if let error = errorMessage {
                    VStack(alignment: .trailing, spacing: 8) {
                        Text(error).font(.custom("Nunito-Regular", size: 13)).foregroundStyle(Color.red.opacity(0.8)).multilineTextAlignment(.trailing)
                        HStack(spacing: 12) {
                            Button("Dismiss") { onDismissError?() }
                                .buttonStyle(.plain).font(.custom("Nunito-Regular", size: 13)).foregroundStyle(JournalDayTokens.bodyText.opacity(0.6))
                            Button("Try again", action: onSummarize)
                                .buttonStyle(JournalPillButtonStyle(horizontalPadding: 18, verticalPadding: 8))
                        }
                    }
                } else if canSummarize {
                    Button("Summarize with Dayflow", action: onSummarize)
                        .buttonStyle(JournalPillButtonStyle(horizontalPadding: 24, verticalPadding: 11))
                } else {
                    Text("Need at least 1 hour of timeline activity to summarize")
                        .font(.custom("Nunito-Regular", size: 13))
                        .foregroundStyle(JournalDayTokens.bodyText.opacity(0.5))
                }
            }
        }
    }
}

private struct SummaryCard: View {
    var summary: String?
    var reflections: String?
    var onRegenerate: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Dayflow summary")
                    .font(.custom("InstrumentSerif-Regular", size: 22))
                    .foregroundStyle(JournalDayTokens.sectionHeader)

                if let summary {
                    WetInkText(text: summary, font: .custom("Nunito-Regular", size: 17))
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

            if let onRegenerate {
                Button(action: onRegenerate) {
                    Text("Regenerate summary")
                        .font(.custom("Nunito-Regular", size: 13))
                        .foregroundStyle(JournalDayTokens.sectionHeader)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Intro & Summary Views (Simple)

private struct IntroView: View {
    var ctaTitle: String
    var isEnabled: Bool = true
    var onTapCTA: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Set daily intentions and track your progress")
                .font(.custom("InstrumentSerif-Regular", size: 34))
                .foregroundStyle(JournalDayTokens.sectionHeader)
                .multilineTextAlignment(.center)
            Text("Dayflow helps you track your daily and longer term pursuits, gives you the space to reflect, and generates a summary of each day.")
                .font(.custom("Nunito-Regular", size: 16))
                .foregroundStyle(JournalDayTokens.bodyText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 540)

            if isEnabled {
                Button(action: onTapCTA) {
                    Text(ctaTitle).font(.custom("Nunito-SemiBold", size: 17))
                }
                .buttonStyle(JournalPillButtonStyle(horizontalPadding: 28, verticalPadding: 10))
                .padding(.top, 16)
            } else {
                Text("No journal entry for this day")
                    .font(.custom("Nunito-Regular", size: 14))
                    .foregroundStyle(JournalDayTokens.bodyText.opacity(0.5))
                    .padding(.top, 16)
            }
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

            ScrollView(.vertical, showsIndicators: false) {
                WetInkText(text: copy, font: .custom("Nunito-Regular", size: 17))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 640, alignment: .leading)
            }
            .frame(maxHeight: 300)

            Button(action: onTapCTA) {
                Text("Set today's intentions")
                    .font(.custom("Nunito-SemiBold", size: 17))
            }
            .buttonStyle(JournalPillButtonStyle(horizontalPadding: 28, verticalPadding: 10))
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Utilities & Tokens

private struct JournalDayBulletList: View {
    let items: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(JournalDayTokens.bullet).frame(width: 6, height: 6).padding(.top, 6)
                    Text(item).font(.custom("Nunito-Regular", size: 15)).foregroundStyle(JournalDayTokens.bodyText).fixedSize(horizontal: false, vertical: true)
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
                Circle().fill(JournalDayTokens.navCircleFill)
                Circle().stroke(JournalDayTokens.navCircleStroke, lineWidth: 1)
                Image("JournalArrow")
                    .renderingMode(.template).resizable().aspectRatio(contentMode: .fit)
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
                        .padding(.horizontal, 14).padding(.vertical, 4)
                        .frame(width: 64, alignment: .center)
                        .background(selection == option ? JournalDayTokens.segmentActiveFill : JournalDayTokens.segmentInactiveFill)
                        .cornerRadius(200)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            Capsule().fill(JournalDayTokens.segmentContainerFill).overlay(Capsule().inset(by: 0.5).stroke(Color.white.opacity(0.6), lineWidth: 1))
        )
        .shadow(color: Color.black.opacity(0.10), radius: 2, x: 0, y: 1)
    }
}

enum JournalFlowState: CaseIterable {
    case intro, summary, intentionsEdit, reflectionPrompt, reflectionEdit, reflectionSaved, boardComplete
    var label: String { "" }
}

enum JournalDayViewPeriod: String, CaseIterable, Identifiable {
    case day = "Day", week = "Week"
    var id: String { rawValue }
}

private enum JournalDayTokens {
    static let primaryText = Color(red: 0.18, green: 0.09, blue: 0.03)
    static let reminderText = Color(red: 0.35, green: 0.20, blue: 0.05)
    static let bodyText = Color(red: 0.18, green: 0.11, blue: 0.06)
    static let bullet = Color(red: 0.96, green: 0.57, blue: 0.24)
    static let sectionHeader = Color(red: 0.85, green: 0.44, blue: 0.04)
    static let divider = Color(red: 0.90, green: 0.85, blue: 0.80)
    static let navCircleFill = Color(red: 0.996, green: 0.976, blue: 0.953)
    static let navCircleStroke = Color.white
    static let navCircleShadow = Color.black.opacity(0.04)
    static let navArrow = Color(red: 1.0, green: 0.74, blue: 0.35)
    static let segmentActiveFill = Color(red: 1, green: 0.72, blue: 0.35)
    static let segmentInactiveFill = Color(red: 0.95, green: 0.94, blue: 0.93)
    static let segmentInactiveText = Color(red: 0.80, green: 0.78, blue: 0.77)
    static let segmentContainerFill = Color(red: 1.0, green: 0.976, blue: 0.953)
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
