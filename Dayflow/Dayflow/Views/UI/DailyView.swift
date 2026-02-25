import SwiftUI
import Foundation
import AppKit
import CryptoKit

private let dailyTodayDisplayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "'Today,' MMMM d"
    return formatter
}()

private let dailyOtherDayDisplayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, MMMM d"
    return formatter
}()

private enum DailyGridConfig {
    static let visibleStartMinute: Double = 9 * 60
    static let visibleEndMinute: Double = 21 * 60
    static let slotDurationMinutes: Double = 15
    static let fallbackCategoryNames = ["Research", "Design", "Alignment", "Testing", "General"]
    static let fallbackColorHexes = ["5E90D9", "A166DB", "4BBFB7", "F38565", "8B8480"]
}

private enum DailyStandupCopyState: Equatable {
    case idle
    case copied
}

struct DailyView: View {
    @AppStorage("isDailyUnlocked") private var isUnlocked: Bool = false
    @Binding var selectedDate: Date
    @EnvironmentObject private var categoryStore: CategoryStore
    @Environment(\.openURL) private var openURL

    @State private var accessCode: String = ""
    @State private var attempts: Int = 0
    @State private var workflowRows: [DailyWorkflowGridRow] = []
    @State private var workflowTotals: [DailyWorkflowTotalItem] = []
    @State private var workflowStats: [DailyWorkflowStatChip] = DailyWorkflowStatChip.placeholder
    @State private var workflowWindow: DailyWorkflowTimelineWindow = .placeholder
    @State private var workflowLoadTask: Task<Void, Never>? = nil
    @State private var standupDraft: DailyStandupDraft = .default
    @State private var loadedStandupDraftDay: String? = nil
    @State private var standupDraftSaveTask: Task<Void, Never>? = nil
    @State private var standupCopyState: DailyStandupCopyState = .idle
    @State private var standupCopyResetTask: Task<Void, Never>? = nil

    private let requiredCodeHash = "6979ce2825cb3f440f987bbc487d62087c333abb99b56062c561ca557392d960"
    private let betaNoticeCopy = "Daily is a new way to visualize your day and turn it into a standup update fast."
    private let onboardingNoticeCopy = "Currently doing custom onboarding while we refine the workflow. If you’re interested, book some time and I’ll walk you through it."
    private let onboardingBookingURL = "https://cal.com/jerry-liu/15min"

    var body: some View {
        ZStack {
            if isUnlocked {
                unlockedContent
                    .transition(.opacity)
            } else {
                lockScreen
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var lockScreen: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 4) {
                Text("Dayflow Daily")
                    .font(.custom("InstrumentSerif-Italic", size: 38))
                    .foregroundColor(Color(red: 0.35, green: 0.22, blue: 0.12))

                Text("BETA")
                    .font(.custom("Nunito-Bold", size: 11))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(red: 0.98, green: 0.55, blue: 0.20))
                    )
                    .rotationEffect(.degrees(-12))
                    .offset(x: -4, y: -4)
            }

            Text(betaNoticeCopy)
                .font(.custom("Nunito-Regular", size: 15))
                .foregroundColor(Color(red: 0.35, green: 0.22, blue: 0.12).opacity(0.8))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .padding(.horizontal, 24)

            accessCodeCard
                .modifier(Shake(animatableData: CGFloat(attempts)))
                .padding(.top, 6)

            VStack(spacing: 8) {
                Text(onboardingNoticeCopy)
                    .font(.custom("Nunito-Regular", size: 13))
                    .foregroundColor(Color(red: 0.35, green: 0.22, blue: 0.12).opacity(0.75))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                    .padding(.horizontal, 24)

                DayflowSurfaceButton(
                    action: openManualOnboardingBooking,
                    content: {
                        HStack(spacing: 8) {
                            Image(systemName: "calendar")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Book a Time")
                                .font(.custom("Nunito", size: 14))
                                .fontWeight(.semibold)
                        }
                    },
                    background: Color(red: 0.25, green: 0.17, blue: 0),
                    foreground: .white,
                    borderColor: .clear,
                    cornerRadius: 8,
                    horizontalPadding: 16,
                    verticalPadding: 10,
                    showOverlayStroke: true
                )
                .pointingHandCursor()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(
            GeometryReader { geo in
                Image("JournalPreview")
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .allowsHitTesting(false)
            }
        )
    }

    private var accessCodeCard: some View {
        ZStack(alignment: .bottom) {
            Image("JournalLock")
                .resizable()
                .aspectRatio(contentMode: .fit)

            VStack(spacing: 16) {
                Text("Enter access code")
                    .font(.custom("Nunito-SemiBold", size: 20))
                    .foregroundColor(Color(red: 0.85, green: 0.45, blue: 0.25))

                TextField("", text: $accessCode)
                    .textFieldStyle(.plain)
                    .font(.custom("Nunito-Medium", size: 15))
                    .foregroundColor(Color(red: 0.25, green: 0.15, blue: 0.10))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white)
                    )
                    .padding(.horizontal, 80)
                    .submitLabel(.go)
                    .onSubmit { validateCode() }

                Button(action: validateCode) {
                    Text("Get early access")
                        .font(.custom("Nunito-SemiBold", size: 15))
                        .foregroundColor(Color(red: 0.35, green: 0.22, blue: 0.12))
                        .padding(.horizontal, 28)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 1.0, green: 0.92, blue: 0.82),
                                            Color(red: 1.0, green: 0.85, blue: 0.70)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(Color(red: 0.90, green: 0.75, blue: 0.55), lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
            .padding(.bottom, 28)
        }
        .frame(width: 380)
        .shadow(color: Color.black.opacity(0.08), radius: 16, x: 0, y: 6)
    }

    private var unlockedContent: some View {
        GeometryReader { geometry in
            let baselineWidth: CGFloat = 950
            let rawContentWidth = max(320, geometry.size.width)
            let scale = min(max(rawContentWidth / baselineWidth, 0.82), 1.18)
            let horizontalInset = 16 * scale
            let topInset = max(22, 20 * scale)
            let bottomInset = 16 * scale
            let sectionSpacing = 20 * scale
            let contentWidth = max(320, geometry.size.width - (horizontalInset * 2))
            let useSingleColumn = contentWidth < (840 * scale)
            let isViewingToday = isTodaySelection(selectedDate)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: sectionSpacing) {
                    topControls(scale: scale)
                    workflowSection(scale: scale, isViewingToday: isViewingToday)
                    actionRow(useSingleColumn: useSingleColumn, scale: scale)
                    highlightsAndTasksSection(
                        useSingleColumn: useSingleColumn,
                        contentWidth: contentWidth,
                        scale: scale,
                        showData: !isViewingToday
                    )
                }
                .frame(width: contentWidth, alignment: .leading)
                .padding(.horizontal, horizontalInset)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .onAppear {
            refreshWorkflowData()
        }
        .onDisappear {
            workflowLoadTask?.cancel()
            workflowLoadTask = nil
            standupDraftSaveTask?.cancel()
            standupDraftSaveTask = nil
            standupCopyResetTask?.cancel()
            standupCopyResetTask = nil
        }
        .onChange(of: selectedDate) { _, _ in
            refreshWorkflowData()
        }
        .onChange(of: standupDraft) { _, _ in
            scheduleStandupDraftSave()
        }
        .onReceive(NotificationCenter.default.publisher(for: .timelineDataUpdated)) { notification in
            guard let dayString = notification.userInfo?["dayString"] as? String else {
                return
            }
            if dayString == workflowDayString(for: selectedDate) {
                refreshWorkflowData()
            }
        }
    }

    private func validateCode() {
        let inputLowercased = accessCode.lowercased()
        let inputData = Data(inputLowercased.utf8)
        let inputHash = SHA256.hash(data: inputData)
        let inputHashString = inputHash.compactMap { String(format: "%02x", $0) }.joined()

        if inputHashString == requiredCodeHash {
            AnalyticsService.shared.capture("daily_unlocked")
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                isUnlocked = true
            }
        } else {
            withAnimation(.default) {
                attempts += 1
                accessCode = ""
            }
        }
    }

    private func openManualOnboardingBooking() {
        guard let url = URL(string: onboardingBookingURL) else { return }
        AnalyticsService.shared.capture("daily_manual_onboarding_booking_opened", [
            "source": "daily_lock_screen",
            "url": onboardingBookingURL
        ])
        openURL(url)
    }

    private func topControls(scale: CGFloat) -> some View {
        VStack(spacing: 10 * scale) {
            HStack(spacing: 10 * scale) {
                DailyCircleNavButton(iconName: "chevron.left", isDisabled: false, scale: scale) {
                    shiftDate(by: -1)
                }

                Text(dailyDateTitle(for: selectedDate))
                    .font(.custom("InstrumentSerif-Regular", size: 26 * scale))
                    .foregroundStyle(Color(hex: "1E1B18"))

                let canMoveForward = canNavigateForward(from: selectedDate)
                DailyCircleNavButton(iconName: "chevron.right", isDisabled: !canMoveForward, scale: scale) {
                    guard canMoveForward else { return }
                    shiftDate(by: 1)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func isTodaySelection(_ date: Date) -> Bool {
        let displayDate = timelineDisplayDate(from: date)
        let timelineToday = timelineDisplayDate(from: Date())
        return Calendar.current.isDate(displayDate, inSameDayAs: timelineToday)
    }

    private func workflowSection(scale: CGFloat, isViewingToday: Bool) -> some View {
        let headingText = isViewingToday
            ? "Come back tomorrow to see this filled out."
            : "Your workflow yesterday"

        return VStack(alignment: .leading, spacing: 8 * scale) {
            HStack {
                Text(headingText)
                    .font(.custom("InstrumentSerif-Regular", size: 24 * scale))
                    .foregroundStyle(Color(hex: "B46531"))

                Spacer()

                Button(action: {}) {
                    HStack(spacing: 4 * scale) {
                        Image(systemName: "pencil")
                            .font(.system(size: 9 * scale, weight: .medium))
                        Text("Edit categories")
                            .font(.custom("Nunito-Regular", size: 10 * scale))
                    }
                    .padding(.horizontal, 10 * scale)
                    .padding(.vertical, 5 * scale)
                    .foregroundStyle(Color(hex: "D17C45"))
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color(hex: "FFF2E6"))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color(hex: "E6C6A8"), lineWidth: max(0.6, 0.8 * scale))
                    )
                }
                .buttonStyle(.plain)
                .pointingHandCursorOnHover(reassertOnPressEnd: true)
            }

            VStack(spacing: 0) {
                DailyWorkflowGrid(rows: workflowRows, timelineWindow: workflowWindow, scale: scale)

                Divider()
                    .overlay(Color(hex: "E5DFD9"))

                workflowTotalsView(scale: scale, isViewingToday: isViewingToday)
                    .padding(.horizontal, 16 * scale)
                    .padding(.top, 14 * scale)
                    .padding(.bottom, 12 * scale)
            }
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.78))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color(hex: "E8E1DA"), lineWidth: max(0.7, 1 * scale))
            )
        }
    }

    private func workflowTotalsView(scale: CGFloat, isViewingToday: Bool) -> some View {
        Group {
            if isViewingToday {
                Text("Yesterday's total")
                    .font(.custom("InstrumentSerif-Regular", size: 14 * scale))
                    .foregroundStyle(Color(hex: "777777"))
            } else if workflowTotals.isEmpty {
                Text("Yesterday's total  No captured activity during 9am-9pm")
                    .font(.custom("Nunito-Regular", size: 12 * scale))
                    .foregroundStyle(Color(hex: "7F7062"))
            } else {
                HStack(spacing: 8 * scale) {
                    Text("Yesterday's total")
                        .font(.custom("InstrumentSerif-Regular", size: 14 * scale))
                        .foregroundStyle(Color(hex: "777777"))

                    ForEach(workflowTotals) { total in
                        HStack(spacing: 2 * scale) {
                            Text(total.name)
                                .font(.custom("Nunito-Regular", size: 12 * scale))
                                .foregroundStyle(Color(hex: "1F1B18"))
                            Text(formatDuration(minutes: total.minutes))
                                .font(.custom("Nunito-SemiBold", size: 12 * scale))
                                .foregroundStyle(Color(hex: total.colorHex))
                        }
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
    }

    @ViewBuilder
    private func actionRow(useSingleColumn: Bool, scale: CGFloat) -> some View {
        if useSingleColumn {
            VStack(alignment: .leading, spacing: 10 * scale) {
                DailyModeToggle(activeMode: .highlights, scale: scale)
                standupCopyButton(scale: scale)
            }
        } else {
            HStack {
                DailyModeToggle(activeMode: .highlights, scale: scale)
                Spacer()
                standupCopyButton(scale: scale)
            }
        }
    }

    private func standupCopyButton(scale: CGFloat) -> some View {
        let transition = AnyTransition.opacity.combined(with: .scale(scale: 0.5))

        return Button(action: copyStandupUpdateToClipboard) {
            HStack(spacing: 6 * scale) {
                ZStack {
                    if standupCopyState == .copied {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12 * scale, weight: .semibold))
                            .transition(transition)
                    } else {
                        Image("Copy")
                            .resizable()
                            .interpolation(.high)
                            .renderingMode(.template)
                            .scaledToFit()
                            .frame(width: 16 * scale, height: 16 * scale)
                            .transition(transition)
                    }
                }
                .frame(width: 16 * scale, height: 16 * scale)

                ZStack(alignment: .leading) {
                    Text("Copy standup update")
                        .font(.custom("Nunito-Medium", size: 14 * scale))
                        .lineLimit(1)
                        .opacity(standupCopyState == .copied ? 0 : 1)

                    Text("Copied")
                        .font(.custom("Nunito-Medium", size: 14 * scale))
                        .lineLimit(1)
                        .opacity(standupCopyState == .copied ? 1 : 0)
                }
                .frame(minWidth: 136 * scale, alignment: .leading)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12 * scale)
            .padding(.vertical, 10 * scale)
            .background(
                LinearGradient(
                    colors: [
                        Color(hex: "FF986F"),
                        Color(hex: "BDAAFF")
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color(hex: "F2D7C3"), lineWidth: max(1.2, 1.5 * scale))
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(DailyCopyPressButtonStyle())
        .animation(.easeInOut(duration: 0.22), value: standupCopyState)
        .pointingHandCursorOnHover(reassertOnPressEnd: true)
        .accessibilityLabel(Text(standupCopyState == .copied ? "Copied standup update" : "Copy standup update"))
    }

    @ViewBuilder
    private func highlightsAndTasksSection(useSingleColumn: Bool, contentWidth: CGFloat, scale: CGFloat, showData: Bool) -> some View {
        if useSingleColumn {
            VStack(alignment: .leading, spacing: 12 * scale) {
                DailyBulletCard(
                    style: .highlights,
                    seamMode: .standalone,
                    title: $standupDraft.highlightsTitle,
                    items: $standupDraft.highlights,
                    showItems: showData,
                    addTaskLabel: $standupDraft.addTaskLabel,
                    blockersTitle: $standupDraft.blockersTitle,
                    blockersBody: $standupDraft.blockersBody,
                    scale: scale
                )
                DailyBulletCard(
                    style: .tasks,
                    seamMode: .standalone,
                    title: $standupDraft.tasksTitle,
                    items: $standupDraft.tasks,
                    showItems: showData,
                    addTaskLabel: $standupDraft.addTaskLabel,
                    blockersTitle: $standupDraft.blockersTitle,
                    blockersBody: $standupDraft.blockersBody,
                    scale: scale
                )
            }
        } else {
            // Figma overlaps borders by ~1px to avoid a visible gutter.
            let cardSpacing = -1 * scale
            let cardWidth = (contentWidth - cardSpacing) / 2
            HStack(alignment: .top, spacing: cardSpacing) {
                DailyBulletCard(
                    style: .highlights,
                    seamMode: .joinedLeading,
                    title: $standupDraft.highlightsTitle,
                    items: $standupDraft.highlights,
                    showItems: showData,
                    addTaskLabel: $standupDraft.addTaskLabel,
                    blockersTitle: $standupDraft.blockersTitle,
                    blockersBody: $standupDraft.blockersBody,
                    scale: scale
                )
                    .frame(width: cardWidth)

                DailyBulletCard(
                    style: .tasks,
                    seamMode: .joinedTrailing,
                    title: $standupDraft.tasksTitle,
                    items: $standupDraft.tasks,
                    showItems: showData,
                    addTaskLabel: $standupDraft.addTaskLabel,
                    blockersTitle: $standupDraft.blockersTitle,
                    blockersBody: $standupDraft.blockersBody,
                    scale: scale
                )
                    .frame(width: cardWidth)
            }
        }
    }

    private func refreshWorkflowData() {
        workflowLoadTask?.cancel()
        workflowLoadTask = nil

        let dayString = workflowDayString(for: selectedDate)
        refreshStandupDraftIfNeeded(for: dayString)

        if isTodaySelection(selectedDate) {
            workflowRows = []
            workflowTotals = []
            workflowStats = DailyWorkflowStatChip.placeholder
            workflowWindow = .placeholder
            return
        }

        let categorySnapshot = categoryStore.categories

        workflowLoadTask = Task.detached(priority: .userInitiated) {
            let cards = StorageManager.shared.fetchTimelineCards(forDay: dayString)
            let computed = computeDailyWorkflow(cards: cards, categories: categorySnapshot)

            guard !Task.isCancelled else { return }

            await MainActor.run {
                workflowRows = computed.rows
                workflowTotals = computed.totals
                workflowStats = computed.stats
                workflowWindow = computed.window
            }
        }
    }

    private func copyStandupUpdateToClipboard() {
        let clipboardText = standupClipboardText()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(clipboardText, forType: .string)

        standupCopyResetTask?.cancel()

        withAnimation(.easeInOut(duration: 0.22)) {
            standupCopyState = .copied
        }

        AnalyticsService.shared.capture("daily_standup_copied", [
            "timeline_day": workflowDayString(for: selectedDate),
            "highlights_count": standupDraft.highlights.count,
            "tasks_count": standupDraft.tasks.count
        ])

        standupCopyResetTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.22)) {
                    standupCopyState = .idle
                }
                standupCopyResetTask = nil
            }
        }
    }

    private func standupClipboardText() -> String {
        var lines: [String] = []
        lines.append("Standup update (\(dailyDateTitle(for: selectedDate)))")
        lines.append("")
        lines.append(standupDraft.highlightsTitle)
        standupDraft.highlights.forEach { item in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty || !body.isEmpty else { return }
            if !title.isEmpty && !body.isEmpty {
                lines.append("- \(title) — \(body)")
            } else if !title.isEmpty {
                lines.append("- \(title)")
            } else {
                lines.append("- \(body)")
            }
        }
        lines.append("")
        lines.append(standupDraft.tasksTitle)
        standupDraft.tasks.forEach { item in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty || !body.isEmpty else { return }
            if !title.isEmpty && !body.isEmpty {
                lines.append("- \(title) — \(body)")
            } else if !title.isEmpty {
                lines.append("- \(title)")
            } else {
                lines.append("- \(body)")
            }
        }
        lines.append("")
        lines.append(standupDraft.blockersTitle)
        lines.append("- \(standupDraft.blockersBody)")
        return lines.joined(separator: "\n")
    }

    private func refreshStandupDraftIfNeeded(for dayString: String) {
        guard loadedStandupDraftDay != dayString else { return }
        loadedStandupDraftDay = dayString

        guard let entry = StorageManager.shared.fetchDailyStandup(forDay: dayString),
              let data = entry.payloadJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(DailyStandupDraft.self, from: data) else {
            standupDraft = .default
            return
        }

        var normalized = decoded
        if normalized.addTaskLabel == "Add task" {
            normalized.addTaskLabel = ""
        }
        standupDraft = normalized
    }

    private func scheduleStandupDraftSave() {
        guard let dayString = loadedStandupDraftDay else { return }
        let draftToSave = standupDraft

        standupDraftSaveTask?.cancel()
        standupDraftSaveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }

            guard let data = try? JSONEncoder().encode(draftToSave),
                  let json = String(data: data, encoding: .utf8) else {
                return
            }

            StorageManager.shared.saveDailyStandup(forDay: dayString, payloadJSON: json)
        }
    }

    private func workflowDayString(for date: Date) -> String {
        let anchorDate = timelineDisplayDate(from: date)
        return anchorDate.getDayInfoFor4AMBoundary().dayString
    }

    private func shiftDate(by days: Int) {
        let shifted = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) ?? selectedDate
        selectedDate = normalizedTimelineDate(shifted)
    }

    private func dailyDateTitle(for date: Date) -> String {
        let displayDate = timelineDisplayDate(from: date)
        let timelineToday = timelineDisplayDate(from: Date())
        if Calendar.current.isDate(displayDate, inSameDayAs: timelineToday) {
            return dailyTodayDisplayFormatter.string(from: displayDate)
        }
        return dailyOtherDayDisplayFormatter.string(from: displayDate)
    }

    private func formatDuration(minutes: Double) -> String {
        let rounded = max(0, Int(minutes.rounded()))
        let hours = rounded / 60
        let mins = rounded % 60

        if hours > 0 && mins > 0 { return "\(hours)h \(mins)m" }
        if hours > 0 { return "\(hours)h" }
        return "\(mins)m"
    }
}

private struct DailyCircleNavButton: View {
    let iconName: String
    let isDisabled: Bool
    let scale: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color(hex: "F4EFEA"))
                Circle()
                    .stroke(Color(hex: "E2DDD8"), lineWidth: max(0.7, 1 * scale))

                Image(systemName: iconName)
                    .font(.system(size: 13 * scale, weight: .medium))
                    .foregroundStyle(Color(hex: "C9C2BC").opacity(isDisabled ? 0.5 : 1.0))
            }
            .frame(width: 30 * scale, height: 30 * scale)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .pointingHandCursorOnHover(enabled: !isDisabled, reassertOnPressEnd: true)
    }
}

private struct DailyCopyPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct DailyWorkflowGrid: View {
    let rows: [DailyWorkflowGridRow]
    let timelineWindow: DailyWorkflowTimelineWindow
    let scale: CGFloat

    private var renderRows: [DailyWorkflowGridRow] {
        if rows.isEmpty {
            return DailyWorkflowGridRow.placeholderRows(slotCount: timelineWindow.slotCount)
        }
        return rows
    }

    var body: some View {
        GeometryReader { geo in
            let hourTicks = timelineWindow.hourTickHours
            let slotCount = max(1, renderRows.map { $0.slotOccupancies.count }.max() ?? timelineWindow.slotCount)
            let widthScale = max(0.7, min(1.35, geo.size.width / 1016))
            let layoutScale = max(0.7, min(1.35, widthScale))

            let leftInset: CGFloat = 36 * layoutScale
            let categoryLabelWidth = labelColumnWidth(for: renderRows, layoutScale: layoutScale)
            let labelToGridSpacing: CGFloat = 13 * layoutScale
            let rightInset: CGFloat = 52 * layoutScale
            let topInset: CGFloat = 25 * layoutScale
            let axisTopSpacing: CGFloat = 10 * layoutScale
            let axisLabelSpacing: CGFloat = 5 * layoutScale

            let gridViewportWidth = max(80, geo.size.width - leftInset - categoryLabelWidth - labelToGridSpacing - rightInset)
            let baselineCellSize: CGFloat = 18 * layoutScale
            let baselineGap: CGFloat = 2 * layoutScale
            let cellSize = baselineCellSize
            let columnSpacing = baselineGap
            let rowSpacing = baselineGap
            let cellCornerRadius = max(1.2, 2.5 * layoutScale)
            let categoryLabelFontSize: CGFloat = 12 * layoutScale
            let axisLabelFontSize: CGFloat = 10 * layoutScale
            let totalGap = columnSpacing * CGFloat(slotCount - 1)
            let gridWidth = (cellSize * CGFloat(slotCount)) + totalGap
            let axisWidth = gridWidth

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: labelToGridSpacing) {
                    VStack(alignment: .trailing, spacing: rowSpacing) {
                        ForEach(renderRows) { row in
                            Text(row.name)
                                .font(.custom("Nunito-Regular", size: categoryLabelFontSize))
                                .foregroundStyle(Color.black.opacity(0.9))
                                .frame(width: categoryLabelWidth, height: cellSize, alignment: .trailing)
                        }
                    }
                    .padding(.top, topInset)

                    ScrollView(.horizontal, showsIndicators: gridWidth > gridViewportWidth) {
                        VStack(alignment: .leading, spacing: 0) {
                            VStack(alignment: .leading, spacing: rowSpacing) {
                                ForEach(renderRows) { row in
                                    HStack(spacing: columnSpacing) {
                                        ForEach(0..<slotCount, id: \.self) { index in
                                            Rectangle()
                                                .foregroundStyle(.clear)
                                                .background(fillColor(for: row, slotIndex: index))
                                                .cornerRadius(cellCornerRadius)
                                                .frame(width: cellSize, height: cellSize)
                                        }
                                    }
                                    .frame(width: gridWidth, alignment: .leading)
                                }
                            }
                            .padding(.top, topInset)

                            VStack(alignment: .leading, spacing: axisLabelSpacing) {
                                Rectangle()
                                    .fill(Color(hex: "E0D9D5"))
                                    .frame(width: axisWidth, height: max(0.7, 0.9 * layoutScale))

                                if hourTicks.count > 1 {
                                    let intervalCount = hourTicks.count - 1
                                    let intervalWidth = axisWidth / CGFloat(intervalCount)
                                    let labelWidth = max(22 * layoutScale, min(34 * layoutScale, intervalWidth * 1.4))

                                    ZStack(alignment: .leading) {
                                        ForEach(Array(hourTicks.enumerated()), id: \.offset) { index, hour in
                                            let tickX = CGFloat(index) * intervalWidth
                                            Text(formatAxisHourLabel(fromAbsoluteHour: hour))
                                                .font(.custom("Nunito-Regular", size: axisLabelFontSize))
                                                .kerning(-0.08 * layoutScale)
                                                .foregroundStyle(Color.black.opacity(0.78))
                                                .frame(
                                                    width: labelWidth,
                                                    alignment: axisLabelAlignment(
                                                        tickIndex: index,
                                                        tickCount: hourTicks.count
                                                    )
                                                )
                                                .offset(
                                                    x: axisLabelOffset(
                                                        tickIndex: index,
                                                        tickCount: hourTicks.count,
                                                        tickX: tickX,
                                                        axisWidth: axisWidth,
                                                        labelWidth: labelWidth
                                                    )
                                                )
                                        }
                                    }
                                    .frame(width: axisWidth, alignment: .leading)
                                } else if let onlyTick = hourTicks.first {
                                    Text(formatAxisHourLabel(fromAbsoluteHour: onlyTick))
                                        .font(.custom("Nunito-Regular", size: axisLabelFontSize))
                                        .kerning(-0.08 * layoutScale)
                                        .foregroundStyle(Color.black.opacity(0.78))
                                        .frame(width: axisWidth, alignment: .leading)
                                }
                            }
                            .padding(.top, axisTopSpacing)
                        }
                        .frame(width: gridWidth, alignment: .leading)
                    }
                    .frame(width: gridViewportWidth, alignment: .leading)
                }
            }
            .padding(.leading, leftInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 146 * scale)
    }

    private func fillColor(for row: DailyWorkflowGridRow, slotIndex: Int) -> Color {
        guard slotIndex < row.slotOccupancies.count else {
            return Color(red: 0.95, green: 0.93, blue: 0.92)
        }
        let occupancy = min(max(row.slotOccupancies[slotIndex], 0), 1)
        guard occupancy > 0 else { return Color(red: 0.95, green: 0.93, blue: 0.92) }

        // Partial occupancy stays dimmer; full occupancy reaches full intensity.
        let alpha = 0.3 + (occupancy * 0.7)
        return Color(hex: row.colorHex).opacity(alpha)
    }

    private func axisLabelAlignment(tickIndex: Int, tickCount: Int) -> Alignment {
        if tickIndex == tickCount - 1 { return .trailing }
        return .leading
    }

    private func axisLabelOffset(
        tickIndex: Int,
        tickCount: Int,
        tickX: CGFloat,
        axisWidth: CGFloat,
        labelWidth: CGFloat
    ) -> CGFloat {
        if tickIndex == tickCount - 1 { return max(0, axisWidth - labelWidth) }
        return min(max(0, tickX), max(0, axisWidth - labelWidth))
    }

    private func labelColumnWidth(for rows: [DailyWorkflowGridRow], layoutScale: CGFloat) -> CGFloat {
        let fontSize = 12 * layoutScale
        let font = NSFont(name: "Nunito-Regular", size: fontSize) ?? NSFont.systemFont(ofSize: fontSize, weight: .regular)
        let measuredMax = rows.reduce(CGFloat.zero) { currentMax, row in
            let width = (row.name as NSString).size(withAttributes: [.font: font]).width
            return max(currentMax, width)
        }

        // Keep the label column as tight as possible while avoiding text clipping.
        return ceil(measuredMax + 1)
    }
}

private struct DailyStatChip: View {
    let title: String
    let value: String
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.custom("Nunito-Regular", size: 10 * scale))
                .foregroundStyle(Color(hex: "5D5651"))
            Text(value)
                .font(.custom("Nunito-SemiBold", size: 10 * scale))
                .foregroundStyle(Color(hex: "D77A43"))
        }
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, 6 * scale)
        .background(
            Capsule(style: .continuous)
                .fill(Color(hex: "F7F3F0"))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color(hex: "DDD6CF"), lineWidth: max(0.6, 0.8 * scale))
        )
    }
}

private struct DailyModeToggle: View {
    enum ActiveMode {
        case highlights
        case details
    }

    let activeMode: ActiveMode
    let scale: CGFloat

    private var cornerRadius: CGFloat { 8 * scale }
    private var borderWidth: CGFloat { max(0.7, 1 * scale) }
    private var borderColor: Color { Color(hex: "C7C2C0") }

    var body: some View {
        HStack(spacing: 0) {
            segment(
                text: "Highlights",
                isActive: activeMode == .highlights,
                isLeading: true
            )
            segment(
                text: "Details",
                isActive: activeMode == .details,
                isLeading: false
            )
        }
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(borderColor, lineWidth: borderWidth)
        )
    }

    @ViewBuilder
    private func segment(text: String, isActive: Bool, isLeading: Bool) -> some View {
        let fill = isActive ? Color(hex: "FFA767") : Color(hex: "FFFAF7").opacity(0.6)

        Text(text)
            .font(.custom("Nunito-Regular", size: 14 * scale))
            .lineLimit(1)
            .foregroundStyle(isActive ? Color.white : Color(hex: "837870"))
            .padding(.horizontal, 12 * scale)
            .padding(.vertical, 8 * scale)
            .frame(minHeight: 33 * scale)
            .background(
                UnevenRoundedRectangle(
                    cornerRadii: .init(
                        topLeading: isLeading ? cornerRadius : 0,
                        bottomLeading: isLeading ? cornerRadius : 0,
                        bottomTrailing: isLeading ? 0 : cornerRadius,
                        topTrailing: isLeading ? 0 : cornerRadius
                    ),
                    style: .continuous
                )
                .fill(fill)
            )
            .overlay(alignment: .trailing) {
                if isLeading {
                    Rectangle()
                        .fill(borderColor)
                        .frame(width: borderWidth)
                }
            }
    }
}

private struct DailyBulletCard: View {
    enum SeamMode {
        case standalone
        case joinedLeading
        case joinedTrailing
    }

    enum Style {
        case highlights
        case tasks
    }

    let style: Style
    let seamMode: SeamMode
    @Binding var title: String
    @Binding var items: [DailyBulletItem]
    let showItems: Bool
    @Binding var addTaskLabel: String
    @Binding var blockersTitle: String
    @Binding var blockersBody: String
    let scale: CGFloat
    @State private var draggedItemID: UUID? = nil

    private var cardShape: UnevenRoundedRectangle {
        let cornerRadius = 12 * scale
        let cornerRadii: RectangleCornerRadii

        switch seamMode {
        case .standalone:
            cornerRadii = .init(
                topLeading: cornerRadius,
                bottomLeading: cornerRadius,
                bottomTrailing: cornerRadius,
                topTrailing: cornerRadius
            )
        case .joinedLeading:
            cornerRadii = .init(
                topLeading: cornerRadius,
                bottomLeading: cornerRadius,
                bottomTrailing: 0,
                topTrailing: 0
            )
        case .joinedTrailing:
            cornerRadii = .init(
                topLeading: 0,
                bottomLeading: 0,
                bottomTrailing: cornerRadius,
                topTrailing: cornerRadius
            )
        }

        return UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18 * scale) {
                TextField("Section title", text: $title)
                    .font(.custom("InstrumentSerif-Regular", size: 24 * scale))
                    .foregroundStyle(Color(hex: "B46531"))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if showItems {
                    VStack(alignment: .leading, spacing: 14 * scale) {
                        ForEach($items) { $item in
                            let itemID = item.id
                            HStack(alignment: .top, spacing: 6 * scale) {
                                DailyDragHandleIcon(scale: scale)
                                    .padding(.top, 5 * scale)
                                    .onDrag {
                                        draggedItemID = itemID
                                        return NSItemProvider(object: itemID.uuidString as NSString)
                                    }
                                    .pointingHandCursorOnHover(reassertOnPressEnd: true)

                                HStack(alignment: .firstTextBaseline, spacing: 4 * scale) {
                                    TextField("Item title", text: $item.title)
                                        .font(.custom("Nunito-Bold", size: 14 * scale))
                                        .foregroundStyle(Color.black)
                                        .textFieldStyle(.plain)
                                        .lineLimit(1)

                                    Text("—")
                                        .font(.custom("Nunito-Regular", size: 14 * scale))
                                        .foregroundStyle(Color.black)

                                    TextField("Details", text: $item.body, axis: .vertical)
                                        .font(.custom("Nunito-Regular", size: 14 * scale))
                                        .foregroundStyle(Color.black)
                                        .textFieldStyle(.plain)
                                        .lineLimit(1...6)
                                }
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .onDrop(
                                of: ["public.text"],
                                delegate: DailyItemDropDelegate(
                                    targetItemID: itemID,
                                    items: $items,
                                    draggedItemID: $draggedItemID
                                )
                            )
                        }
                    }
                    .onDrop(
                        of: ["public.text"],
                        delegate: DailyItemDropToEndDelegate(
                            items: $items,
                            draggedItemID: $draggedItemID
                        )
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.leading, 26 * scale)
            .padding(.trailing, 26 * scale)
            .padding(.top, 26 * scale)

            Spacer(minLength: 0)

            DailyAddTaskRow(scale: scale, text: $addTaskLabel) { submitted in
                let normalizedTitle = submitted.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedTitle.isEmpty else { return }
                items.append(DailyBulletItem(title: normalizedTitle, body: ""))
            }
                .padding(.leading, style == .highlights ? 16 * scale : 26 * scale)
                .padding(.bottom, style == .tasks ? 24 * scale : 20 * scale)

            if style == .tasks {
                DailyBlockersSection(
                    scale: scale,
                    title: $blockersTitle,
                    prompt: $blockersBody
                )
            }
        }
        .frame(maxWidth: .infinity, minHeight: max(180, 394 * scale), alignment: .topLeading)
        .background(
            cardShape
                .fill(
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color.white.opacity(0.6), location: 0.011932),
                            .init(color: Color.white, location: 0.5104),
                            .init(color: Color.white.opacity(0.6), location: 0.98092)
                        ]),
                        startPoint: UnitPoint(x: 1, y: 0.45),
                        endPoint: UnitPoint(x: 0, y: 0.55)
                    )
                )
        )
        .clipShape(cardShape)
        .overlay(
            cardShape
                .stroke(Color(hex: "EBE6E3"), lineWidth: max(0.7, 1 * scale))
        )
        .shadow(color: Color.black.opacity(0.1), radius: 12 * scale, x: 0, y: 0)
    }
}

private struct DailyDragHandleIcon: View {
    let scale: CGFloat

    var body: some View {
        VStack(spacing: 2 * scale) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 2 * scale) {
                    Circle()
                        .fill(Color(hex: "999999"))
                        .frame(width: 2.5 * scale, height: 2.5 * scale)
                    Circle()
                        .fill(Color(hex: "999999"))
                        .frame(width: 2.5 * scale, height: 2.5 * scale)
                }
            }
        }
        .frame(width: 16 * scale, height: 16 * scale, alignment: .topLeading)
    }
}

private struct DailyAddTaskRow: View {
    let scale: CGFloat
    @Binding var text: String
    var onCommit: (String) -> Void

    var body: some View {
        HStack(spacing: 6 * scale) {
            Button(action: commit) {
                Image(systemName: "plus")
                    .font(.system(size: 24 * scale, weight: .regular))
                    .foregroundStyle(Color(hex: "999999"))
                    .frame(width: 24 * scale, height: 24 * scale)
            }
            .buttonStyle(.plain)
            .pointingHandCursorOnHover(reassertOnPressEnd: true)

            TextField("Add task", text: $text)
                .font(.custom("Nunito-Regular", size: 12 * scale))
                .foregroundStyle(Color(hex: "999999"))
                .textFieldStyle(.plain)
                .onSubmit(commit)
                .onAppear {
                    if text == "Add task" {
                        text = ""
                    }
                }
        }
    }

    private func commit() {
        let submitted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submitted.isEmpty else { return }
        onCommit(submitted)
        text = ""
    }
}

private struct DailyBlockersSection: View {
    let scale: CGFloat
    @Binding var title: String
    @Binding var prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            TextField("Blockers", text: $title)
                .font(.custom("Nunito-Medium", size: 14 * scale))
                .foregroundStyle(Color(hex: "BD9479"))
                .textFieldStyle(.plain)

            HStack(alignment: .top, spacing: 6 * scale) {
                DailyDragHandleIcon(scale: scale)
                    .padding(.top, 1 * scale)

                TextField("Fill in any blockers you may have", text: $prompt, axis: .vertical)
                    .font(.custom("Nunito-Regular", size: 14 * scale))
                    .foregroundStyle(Color(hex: "929292"))
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, 26 * scale)
        .padding(.trailing, 26 * scale)
        .padding(.top, 14 * scale)
        .frame(maxWidth: .infinity, minHeight: 94 * scale, alignment: .topLeading)
        .background(Color(hex: "F7F6F5"))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(hex: "EBE6E3"))
                .frame(height: max(0.7, 1 * scale))
        }
    }
}

private struct DailyItemDropDelegate: DropDelegate {
    let targetItemID: UUID
    @Binding var items: [DailyBulletItem]
    @Binding var draggedItemID: UUID?

    func dropEntered(info: DropInfo) {
        guard let draggedID = draggedItemID,
              draggedID != targetItemID,
              let fromIndex = items.firstIndex(where: { $0.id == draggedID }),
              let toIndex = items.firstIndex(where: { $0.id == targetItemID }) else {
            return
        }

        withAnimation(.easeInOut(duration: 0.14)) {
            items.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedItemID = nil
        return true
    }
}

private struct DailyItemDropToEndDelegate: DropDelegate {
    @Binding var items: [DailyBulletItem]
    @Binding var draggedItemID: UUID?

    func dropEntered(info: DropInfo) {
        guard let draggedID = draggedItemID,
              let fromIndex = items.firstIndex(where: { $0.id == draggedID }) else {
            return
        }

        let endIndex = items.count
        guard fromIndex != endIndex - 1 else { return }

        withAnimation(.easeInOut(duration: 0.14)) {
            items.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: endIndex)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedItemID = nil
        return true
    }
}

private struct DailyBulletItem: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var title: String
    var body: String
}

private struct DailyWorkflowGridRow: Identifiable, Sendable {
    let id: String
    let name: String
    let colorHex: String
    let slotOccupancies: [Double]

    static func placeholderRows(slotCount: Int) -> [DailyWorkflowGridRow] {
        DailyGridConfig.fallbackCategoryNames.enumerated().map { index, name in
            DailyWorkflowGridRow(
                id: "placeholder-\(index)",
                name: name,
                colorHex: DailyGridConfig.fallbackColorHexes[index % DailyGridConfig.fallbackColorHexes.count],
                slotOccupancies: Array(repeating: 0, count: max(1, slotCount))
            )
        }
    }
}

private struct DailyWorkflowTotalItem: Identifiable, Sendable {
    let id: String
    let name: String
    let minutes: Double
    let colorHex: String
}

private struct DailyWorkflowComputationResult: Sendable {
    let rows: [DailyWorkflowGridRow]
    let totals: [DailyWorkflowTotalItem]
    let stats: [DailyWorkflowStatChip]
    let window: DailyWorkflowTimelineWindow
}

private struct DailyWorkflowSegment: Sendable {
    let categoryKey: String
    let displayName: String
    let colorHex: String
    let startMinute: Double
    let endMinute: Double
    let hasDistraction: Bool
}

private struct DailyWorkflowStatChip: Identifiable, Sendable {
    let id: String
    let title: String
    let value: String

    static let placeholder: [DailyWorkflowStatChip] = [
        DailyWorkflowStatChip(id: "context-switched", title: "Context switched", value: "0 times"),
        DailyWorkflowStatChip(id: "interrupted", title: "Interrupted", value: "0 times"),
        DailyWorkflowStatChip(id: "focused-for", title: "Focused for", value: "0m"),
        DailyWorkflowStatChip(id: "distracted-for", title: "Distracted for", value: "0m"),
        DailyWorkflowStatChip(id: "transitioning-time", title: "Transitioning time", value: "0m")
    ]
}

private struct DailyWorkflowTimelineWindow: Sendable {
    let startMinute: Double
    let endMinute: Double

    static let placeholder = DailyWorkflowTimelineWindow(
        startMinute: DailyGridConfig.visibleStartMinute,
        endMinute: DailyGridConfig.visibleEndMinute
    )

    var hourTickHours: [Int] {
        guard endMinute > startMinute else { return [9, 17] }

        let startHour = Int(floor(startMinute / 60))
        let endHour = Int(ceil(endMinute / 60))
        let adjustedEndHour = max(startHour + 1, endHour)
        return Array(startHour...adjustedEndHour)
    }

    var slotCount: Int {
        guard endMinute > startMinute else {
            let fallbackDuration = DailyGridConfig.visibleEndMinute - DailyGridConfig.visibleStartMinute
            return max(1, Int((fallbackDuration / DailyGridConfig.slotDurationMinutes).rounded()))
        }

        let durationMinutes = endMinute - startMinute
        return max(1, Int((durationMinutes / DailyGridConfig.slotDurationMinutes).rounded()))
    }

    var hourLabels: [String] {
        hourTickHours.map(formatAxisHourLabel(fromAbsoluteHour:))
    }
}

private func computeDailyWorkflow(cards: [TimelineCard], categories: [TimelineCategory]) -> DailyWorkflowComputationResult {
    let orderedCategories = categories.sorted { $0.order < $1.order }

    let colorMap: [String: String] = Dictionary(uniqueKeysWithValues: orderedCategories.map {
        (normalizedCategoryKey($0.name), normalizedHex($0.colorHex))
    })

    let nameMap: [String: String] = Dictionary(uniqueKeysWithValues: orderedCategories.map {
        (normalizedCategoryKey($0.name), $0.name.trimmingCharacters(in: .whitespacesAndNewlines))
    })

    struct RawDailyWorkflowSegment {
        let categoryKey: String
        let displayName: String
        let colorHex: String
        let startMinute: Double
        let endMinute: Double
        let hasDistraction: Bool
    }

    var rawSegments: [RawDailyWorkflowSegment] = []
    rawSegments.reserveCapacity(cards.count)

    for card in cards {
        guard var startMinute = parseCardMinute(card.startTimestamp),
              var endMinute = parseCardMinute(card.endTimestamp) else {
            continue
        }

        if startMinute < 240 { startMinute += 1440 }
        if endMinute < 240 { endMinute += 1440 }
        if endMinute <= startMinute { endMinute += 1440 }

        let trimmed = card.category.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmed.isEmpty ? "Uncategorized" : trimmed
        let key = normalizedCategoryKey(displayName)
        let colorHex = colorMap[key] ?? fallbackColorHex(for: key)

        rawSegments.append(
            RawDailyWorkflowSegment(
                categoryKey: key,
                displayName: displayName,
                colorHex: colorHex,
                startMinute: startMinute,
                endMinute: endMinute,
                hasDistraction: !(card.distractions?.isEmpty ?? true)
            )
        )
    }

    let workflowWindow: DailyWorkflowTimelineWindow = {
        guard !rawSegments.isEmpty else { return .placeholder }

        let firstUsedMinute = rawSegments.map(\.startMinute).min() ?? DailyGridConfig.visibleStartMinute
        let lastUsedMinute = rawSegments.map(\.endMinute).max() ?? DailyGridConfig.visibleEndMinute

        let alignedStart = floor(firstUsedMinute / 60) * 60
        let alignedDataEnd = ceil(lastUsedMinute / 60) * 60
        let minWindowDuration = DailyGridConfig.visibleEndMinute - DailyGridConfig.visibleStartMinute
        let computedEnd = max(alignedStart + minWindowDuration, alignedDataEnd)

        return DailyWorkflowTimelineWindow(startMinute: alignedStart, endMinute: computedEnd)
    }()

    let visibleStart = workflowWindow.startMinute
    let visibleEnd = workflowWindow.endMinute
    let slotCount = workflowWindow.slotCount
    let slotDuration = DailyGridConfig.slotDurationMinutes

    let segments: [DailyWorkflowSegment] = rawSegments.compactMap { raw in
        let clippedStart = max(raw.startMinute, visibleStart)
        let clippedEnd = min(raw.endMinute, visibleEnd)
        guard clippedEnd > clippedStart else { return nil }
        return DailyWorkflowSegment(
            categoryKey: raw.categoryKey,
            displayName: raw.displayName,
            colorHex: raw.colorHex,
            startMinute: clippedStart,
            endMinute: clippedEnd,
            hasDistraction: raw.hasDistraction
        )
    }

    var durationByCategory: [String: Double] = [:]
    var resolvedNameByCategory: [String: String] = [:]
    var resolvedColorByCategory: [String: String] = [:]

    for segment in segments {
        let overlap = max(0, segment.endMinute - segment.startMinute)
        guard overlap > 0 else { continue }
        durationByCategory[segment.categoryKey, default: 0] += overlap
        resolvedNameByCategory[segment.categoryKey] = segment.displayName
        resolvedColorByCategory[segment.categoryKey] = segment.colorHex
    }

    let sortedSegments = segments.sorted { lhs, rhs in
        if lhs.startMinute == rhs.startMinute {
            return lhs.endMinute < rhs.endMinute
        }
        return lhs.startMinute < rhs.startMinute
    }

    let idleCategoryKeys = Set(orderedCategories.filter(\.isIdle).map { normalizedCategoryKey($0.name) })
    var contextSwitches = 0
    var interruptions = 0
    var focusedMinutes = 0.0
    var distractedMinutes = 0.0
    var transitionMinutes = 0.0
    var previousCategory: String? = nil
    var previousEndMinute: Double? = nil

    for segment in sortedSegments {
        let duration = max(0, segment.endMinute - segment.startMinute)
        guard duration > 0 else { continue }

        if idleCategoryKeys.contains(segment.categoryKey) {
            distractedMinutes += duration
        } else {
            focusedMinutes += duration
        }

        if segment.hasDistraction {
            interruptions += 1
        }

        if let previousCategory, previousCategory != segment.categoryKey {
            contextSwitches += 1
        }
        previousCategory = segment.categoryKey

        if let priorEndMinute = previousEndMinute {
            let gap = segment.startMinute - priorEndMinute
            if gap > 0 {
                transitionMinutes += gap
            }
            previousEndMinute = max(priorEndMinute, segment.endMinute)
        } else {
            previousEndMinute = segment.endMinute
        }
    }

    var selectedKeys = durationByCategory
        .sorted { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key < rhs.key }
            return lhs.value > rhs.value
        }
        .map(\.key)

    if selectedKeys.count < 5 {
        for category in orderedCategories where !category.isIdle {
            let key = normalizedCategoryKey(category.name)
            if !selectedKeys.contains(key) {
                selectedKeys.append(key)
            }
            if selectedKeys.count >= 5 { break }
        }
    }

    if selectedKeys.count < 5 {
        for fallback in DailyGridConfig.fallbackCategoryNames {
            let key = normalizedCategoryKey(fallback)
            if !selectedKeys.contains(key) {
                selectedKeys.append(key)
            }
            if selectedKeys.count >= 5 { break }
        }
    }

    selectedKeys = Array(selectedKeys.prefix(5))

    let segmentsByCategory = Dictionary(grouping: segments, by: { $0.categoryKey })

    let rows: [DailyWorkflowGridRow] = selectedKeys.enumerated().map { index, key in
        let rowSegments = segmentsByCategory[key] ?? []
        let occupancies: [Double] = (0..<slotCount).map { slotIndex in
            let slotStart = visibleStart + (Double(slotIndex) * slotDuration)
            let slotEnd = min(visibleEnd, slotStart + slotDuration)
            let slotMinutes = max(1, slotEnd - slotStart)

            let occupied = rowSegments.reduce(0.0) { partial, segment in
                let overlap = max(0, min(segment.endMinute, slotEnd) - max(segment.startMinute, slotStart))
                return partial + overlap
            }

            return min(1, occupied / slotMinutes)
        }

        let displayName = resolvedNameByCategory[key] ?? nameMap[key] ?? DailyGridConfig.fallbackCategoryNames[index % DailyGridConfig.fallbackCategoryNames.count]
        let colorHex = resolvedColorByCategory[key] ?? colorMap[key] ?? DailyGridConfig.fallbackColorHexes[index % DailyGridConfig.fallbackColorHexes.count]

        return DailyWorkflowGridRow(
            id: key,
            name: displayName,
            colorHex: colorHex,
            slotOccupancies: occupancies
        )
    }

    let totals = selectedKeys.compactMap { key -> DailyWorkflowTotalItem? in
        guard let minutes = durationByCategory[key], minutes > 0 else { return nil }
        let name = resolvedNameByCategory[key] ?? nameMap[key] ?? "Uncategorized"
        let colorHex = resolvedColorByCategory[key] ?? colorMap[key] ?? fallbackColorHex(for: key)
        return DailyWorkflowTotalItem(id: key, name: name, minutes: minutes, colorHex: colorHex)
    }

    let stats = [
        DailyWorkflowStatChip(
            id: "context-switched",
            title: "Context switched",
            value: formatCount(contextSwitches)
        ),
        DailyWorkflowStatChip(
            id: "interrupted",
            title: "Interrupted",
            value: formatCount(interruptions)
        ),
        DailyWorkflowStatChip(
            id: "focused-for",
            title: "Focused for",
            value: formatDurationValue(focusedMinutes)
        ),
        DailyWorkflowStatChip(
            id: "distracted-for",
            title: "Distracted for",
            value: formatDurationValue(distractedMinutes)
        ),
        DailyWorkflowStatChip(
            id: "transitioning-time",
            title: "Transitioning time",
            value: formatDurationValue(transitionMinutes)
        )
    ]

    return DailyWorkflowComputationResult(rows: rows, totals: totals, stats: stats, window: workflowWindow)
}

private func parseCardMinute(_ value: String) -> Double? {
    guard let parsed = parseTimeHMMA(timeString: value) else { return nil }
    return Double(parsed)
}

private func normalizedCategoryKey(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
}

private func normalizedHex(_ value: String) -> String {
    value.replacingOccurrences(of: "#", with: "")
}

private func fallbackColorHex(for key: String) -> String {
    let hash = key.utf8.reduce(5381) { current, byte in
        ((current << 5) &+ current) &+ Int(byte)
    }
    let palette = DailyGridConfig.fallbackColorHexes
    let index = abs(hash) % palette.count
    return palette[index]
}

private func formatAxisHourLabel(fromAbsoluteHour hour: Int) -> String {
    let normalized = ((hour % 24) + 24) % 24
    let period = normalized >= 12 ? "pm" : "am"
    let display = normalized % 12 == 0 ? 12 : normalized % 12
    return "\(display)\(period)"
}

private func formatCount(_ count: Int) -> String {
    "\(count) \(count == 1 ? "time" : "times")"
}

private func formatDurationValue(_ minutes: Double) -> String {
    let rounded = max(0, Int(minutes.rounded()))
    let hours = rounded / 60
    let mins = rounded % 60

    if hours > 0 && mins > 0 { return "\(hours)h \(mins)m" }
    if hours > 0 { return "\(hours)h" }
    return "\(mins)m"
}

private struct DailyStandupDraft: Codable, Equatable, Sendable {
    var highlightsTitle: String
    var highlights: [DailyBulletItem]
    var tasksTitle: String
    var tasks: [DailyBulletItem]
    var addTaskLabel: String
    var blockersTitle: String
    var blockersBody: String

    static let `default` = DailyStandupDraft(
        highlightsTitle: "Yesterday's highlights",
        highlights: DailyContent.yesterdayHighlights,
        tasksTitle: "Today's tasks",
        tasks: DailyContent.todayTasks,
        addTaskLabel: "",
        blockersTitle: "Blockers",
        blockersBody: DailyContent.notGeneratedMessage
    )
}

private enum DailyContent {
    static let notGeneratedTitle = "Daily data not generated yet"
    static let notGeneratedMessage = "Daily data has not been generated yet. If this is unexpected, please report a bug."

    static let yesterdayHighlights: [DailyBulletItem] = [
        DailyBulletItem(
            title: notGeneratedTitle,
            body: notGeneratedMessage
        )
    ]

    static let todayTasks: [DailyBulletItem] = [
        DailyBulletItem(
            title: notGeneratedTitle,
            body: notGeneratedMessage
        )
    ]
}

struct DailyView_Previews: PreviewProvider {
    static var previews: some View {
        DailyView(selectedDate: .constant(Date()))
            .environmentObject(CategoryStore.shared)
            .frame(width: 1180, height: 760)
    }
}
