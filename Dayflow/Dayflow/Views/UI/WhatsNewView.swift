//
//  WhatsNewView.swift
//  Dayflow
//
//  Displays release highlights after app updates
//

import SwiftUI

// MARK: - Release Notes Data Structure

struct ReleaseNoteCTA {
    let title: String
    let description: String
    let buttonTitle: String
    let url: String
}

struct ReleaseNote: Identifiable {
    let id = UUID()
    let version: String      // e.g. "2.0.1"
    let title: String        // e.g. "Timeline Improvements"
    let highlights: [String] // Array of bullet points
    let cta: ReleaseNoteCTA?
    let imageName: String?   // Optional asset name for preview

    // Helper to compare semantic versions
    var semanticVersion: [Int] {
        version.split(separator: ".").compactMap { Int($0) }
    }
}

// MARK: - What's New Configuration

enum WhatsNewConfiguration {
    private static let seenKey = "lastSeenWhatsNewVersion"

    /// Override with the specific release number you want to show.
    private static let versionOverride: String? = "1.8.0"

    /// Update this content before shipping each release. Return nil to disable the modal entirely.
    static var configuredRelease: ReleaseNote? {
        ReleaseNote(
            version: targetVersion,
            title: "Just-in-time timelapses · Gemini back to 15-minute windows · UI polish",
            highlights: [
                "Instead of generating timelapse videos continuously, Dayflow now generates them in a just-in-time fashion for better energy efficiency.",
                "Gemini is back to 15-minute processing windows now that new mitigations are in place.",
                "A lot of small-but-helpful UI enhancements landed across timeline, chat, settings, and navigation.",
                "Fixed a bug where Dock icon preferences could reset after restart."
            ],
            cta: ReleaseNoteCTA(
                title: "Standup Pilot",
                description: "I'm piloting a workflow to make standups and weekly 1:1 prep less painful. I'm personally onboarding the first 10 users to work out the kinks, so please book a time if you're interested!",
                buttonTitle: "Book a Time",
                url: "https://cal.com/jerry-liu/15min"
            ),
            imageName: nil
        )
    }

    /// Returns the configured release when it matches the app version and hasn't been shown yet.
    static func pendingReleaseForCurrentBuild() -> ReleaseNote? {
        guard let release = configuredRelease else { return nil }
        guard isVersion(release.version, lessThanOrEqualTo: currentAppVersion) else { return nil }
        let defaults = UserDefaults.standard
        let lastSeen = defaults.string(forKey: seenKey)

        // First run: seed seen version so new installs skip the modal until next upgrade.
        if lastSeen == nil || lastSeen?.isEmpty == true {
            defaults.set(release.version, forKey: seenKey)
            return nil
        }

        return lastSeen == release.version ? nil : release
    }

    /// Returns the latest configured release, regardless of the running app version.
    static func latestRelease() -> ReleaseNote? {
        configuredRelease
    }

    static func markReleaseAsSeen(version: String) {
        UserDefaults.standard.set(version, forKey: seenKey)
    }

    private static var targetVersion: String {
        versionOverride ?? currentAppVersion
    }

    private static var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// Compare two semantic version strings. Returns true if lhs <= rhs.
    private static func isVersion(_ lhs: String, lessThanOrEqualTo rhs: String) -> Bool {
        let lhsParts = lhs.split(separator: ".").compactMap { Int($0) }
        let rhsParts = rhs.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(lhsParts.count, rhsParts.count) {
            let lhsVal = i < lhsParts.count ? lhsParts[i] : 0
            let rhsVal = i < rhsParts.count ? rhsParts[i] : 0
            if lhsVal < rhsVal { return true }
            if lhsVal > rhsVal { return false }
        }
        return true // equal
    }
}

// MARK: - What's New View

struct WhatsNewView: View {
    let releaseNote: ReleaseNote
    let onDismiss: () -> Void

    @Environment(\.openURL) private var openURL
    @AppStorage("whatsNewValueSurveySubmittedVersion") private var submittedValueSurveyVersion: String = ""
    @State private var valueFrequencySelection: ValueFrequencyOption? = nil
    @State private var selectedHelpfulOptions: Set<HelpfulFeatureOption> = []
    @State private var includeHelpfulOtherOption = false
    @State private var helpfulOtherText = ""
    @State private var randomizedHelpfulOptions: [HelpfulFeatureOption] = []
    @State private var didHydrateSurveyState = false
    @State private var scrollToBottomToken = 0

    private let bottomAnchorID = "whats_new_bottom_anchor"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                    Text("What's New in \(releaseNote.version) 🎉")
                        .font(.custom("InstrumentSerif-Regular", size: 32))
                        .foregroundColor(.black.opacity(0.9))
                }

                        Spacer()

                        Button(action: dismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(8)
                                .background(Color.black.opacity(0.05))
                                .clipShape(Circle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .pointingHandCursor()
                        .accessibilityLabel("Close")
                        .keyboardShortcut(.cancelAction)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(releaseNote.highlights.enumerated()), id: \.offset) { _, highlight in
                            HStack(alignment: .top, spacing: 12) {
                                Circle()
                                    .fill(Color(red: 0.25, green: 0.17, blue: 0).opacity(0.6))
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 7)

                                Text(highlight)
                                    .font(.custom("Nunito", size: 15))
                                    .foregroundColor(.black.opacity(0.75))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    if let cta = releaseNote.cta {
                        ctaSection(cta)
                    }

                    surveySection

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchorID)
                }
                .padding(.horizontal, 44)
                .padding(.vertical, 36)
            }
            .frame(maxHeight: 760)
            .onChange(of: scrollToBottomToken) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                    }
                }
            }
        }
        .frame(width: 780)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.25), radius: 40, x: 0, y: 20)
        )
        .onAppear {
            AnalyticsService.shared.screen("whats_new")
            if didHydrateSurveyState == false {
                hydrateSurveyStateIfNeeded()
                didHydrateSurveyState = true
            }
        }
        .environment(\.colorScheme, .light)
        .preferredColorScheme(.light)
    }

    private func dismiss() {
        AnalyticsService.shared.capture("whats_new_dismissed", [
            "version": releaseNote.version,
            "provider_label": currentProviderLabel
        ])

        onDismiss()
    }

    private var surveySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            valueFrequencyQuestion
            if valueFrequencySelection != nil {
                helpfulFeaturesQuestion
            }
        }
        .padding(.top, 10)
    }

    private func ctaSection(_ cta: ReleaseNoteCTA) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(cta.title)
                .font(.custom("Nunito", size: 16))
                .fontWeight(.bold)
                .foregroundColor(.black.opacity(0.86))

            Text(cta.description)
                .font(.custom("Nunito", size: 14))
                .foregroundColor(.black.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)

            DayflowSurfaceButton(
                action: { openCTA(cta) },
                content: {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar")
                            .font(.system(size: 12, weight: .semibold))
                        Text(cta.buttonTitle)
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
        .padding(.top, 6)
    }

    private func openCTA(_ cta: ReleaseNoteCTA) {
        guard let url = URL(string: cta.url) else { return }
        AnalyticsService.shared.capture("whats_new_cta_opened", [
            "version": releaseNote.version,
            "cta_title": cta.title,
            "cta_url": cta.url,
            "provider_label": currentProviderLabel
        ])
        openURL(url)
    }

    private var valueFrequencyQuestion: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How often does Dayflow feel valuable to you?")
                .font(.custom("Nunito", size: 15))
                .fontWeight(.semibold)
                .foregroundColor(.black.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(ValueFrequencyOption.allCases, id: \.self) { option in
                    Button(action: { selectValueFrequency(option) }) {
                        HStack(spacing: 10) {
                            Image(systemName: valueFrequencySelection == option ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(Color(red: 0.25, green: 0.17, blue: 0))

                            Text(option.title)
                                .font(.custom("Nunito", size: 14))
                                .foregroundColor(.black.opacity(0.8))
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(valueFrequencySelection == option ? Color(red: 1.0, green: 0.95, blue: 0.9) : Color.white)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color(red: 0.25, green: 0.17, blue: 0).opacity(valueFrequencySelection == option ? 0.22 : 0.1), lineWidth: 1)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .pointingHandCursor()
                }
            }
        }
    }

    private var helpfulFeaturesQuestion: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Which of these would make Dayflow more helpful to you?")
                .font(.custom("Nunito", size: 15))
                .fontWeight(.semibold)
                .foregroundColor(.black.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            Text("(pick all that apply)")
                .font(.custom("Nunito", size: 12))
                .foregroundColor(.black.opacity(0.58))

            VStack(alignment: .leading, spacing: 10) {
                ForEach(randomizedHelpfulOptions, id: \.self) { option in
                    helpfulOptionRow(
                        title: option.title,
                        isSelected: selectedHelpfulOptions.contains(option),
                        action: { toggleHelpfulOption(option) }
                    )
                }

                helpfulOptionRow(
                    title: "Other",
                    isSelected: includeHelpfulOtherOption,
                    action: toggleHelpfulOtherOption
                )

                if includeHelpfulOtherOption {
                    TextField("Other: ___", text: $helpfulOtherText)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .font(.custom("Nunito", size: 13))
                        .padding(.horizontal, 4)
                        .onChange(of: helpfulOtherText) {
                            persistHelpfulOtherText()
                        }
                }
            }

            HStack {
                Spacer()
                DayflowSurfaceButton(
                    action: submitValueSurvey,
                    content: {
                        Text("Submit")
                            .font(.custom("Nunito", size: 15))
                            .fontWeight(.semibold)
                    },
                    background: canSubmitValueSurvey ? Color(red: 0.25, green: 0.17, blue: 0) : Color.black.opacity(0.08),
                    foreground: .white.opacity(canSubmitValueSurvey ? 1 : 0.7),
                    borderColor: .clear,
                    cornerRadius: 8,
                    horizontalPadding: 34,
                    verticalPadding: 12,
                    minWidth: 160,
                    showOverlayStroke: true
                )
                .disabled(!canSubmitValueSurvey)
                .opacity(canSubmitValueSurvey ? 1 : 0.8)
            }

            if hasSubmittedValueSurvey {
                Label("Thanks for sharing!", systemImage: "checkmark.circle.fill")
                    .font(.custom("Nunito", size: 14))
                    .foregroundColor(Color(red: 0.25, green: 0.17, blue: 0))
            }
        }
    }

    private func helpfulOptionRow(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundColor(Color(red: 0.25, green: 0.17, blue: 0))
                Text(title)
                    .font(.custom("Nunito", size: 14))
                    .foregroundColor(.black.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color(red: 1.0, green: 0.95, blue: 0.9) : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(red: 0.25, green: 0.17, blue: 0).opacity(isSelected ? 0.22 : 0.1), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .pointingHandCursor()
    }

    private var hasSubmittedValueSurvey: Bool {
        submittedValueSurveyVersion == releaseNote.version
    }

    private var helpfulOtherTextTrimmed: String {
        helpfulOtherText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasAnyHelpfulSelection: Bool {
        if selectedHelpfulOptions.isEmpty == false {
            return true
        }
        if includeHelpfulOtherOption && helpfulOtherTextTrimmed.isEmpty == false {
            return true
        }
        return false
    }

    private var canSubmitValueSurvey: Bool {
        !hasSubmittedValueSurvey && valueFrequencySelection != nil && hasAnyHelpfulSelection
    }

    private func selectValueFrequency(_ option: ValueFrequencyOption) {
        let previousSelection = storedValueFrequencySelection
        valueFrequencySelection = option
        UserDefaults.standard.set(option.rawValue, forKey: valueFrequencyStorageKey)
        scrollToBottomToken &+= 1

        if previousSelection != option {
            AnalyticsService.shared.capture("whats_new_survey_value_frequency_selected", [
                "version": releaseNote.version,
                "option": option.analyticsValue,
                "provider_label": currentProviderLabel
            ])
        }

        captureValueSurveyProgress(
            trigger: "value_frequency_selected",
            targetOption: option.analyticsValue,
            targetSelected: true
        )
    }

    private func toggleHelpfulOption(_ option: HelpfulFeatureOption) {
        let targetSelected: Bool
        if selectedHelpfulOptions.contains(option) {
            selectedHelpfulOptions.remove(option)
            targetSelected = false
        } else {
            selectedHelpfulOptions.insert(option)
            targetSelected = true
        }
        persistHelpfulSelections()
        captureValueSurveyProgress(
            trigger: "helpful_option_toggled",
            targetOption: option.analyticsValue,
            targetSelected: targetSelected
        )
    }

    private func toggleHelpfulOtherOption() {
        includeHelpfulOtherOption.toggle()
        UserDefaults.standard.set(includeHelpfulOtherOption, forKey: helpfulOtherEnabledStorageKey)
        persistHelpfulSelections()
        captureValueSurveyProgress(
            trigger: "helpful_other_toggled",
            targetOption: "other",
            targetSelected: includeHelpfulOtherOption
        )
    }

    private func persistHelpfulSelections() {
        UserDefaults.standard.set(selectedHelpfulOptions.map(\.rawValue).sorted(), forKey: helpfulOptionsSelectionStorageKey)
    }

    private func persistHelpfulOtherText() {
        UserDefaults.standard.set(helpfulOtherText, forKey: helpfulOtherTextStorageKey)
    }

    private func submitValueSurvey() {
        guard let selection = valueFrequencySelection, !hasSubmittedValueSurvey else { return }
        guard hasAnyHelpfulSelection else { return }

        let selectedOptionTitles = selectedHelpfulOptions.map(\.title).sorted()
        let selectedOptionValues = selectedHelpfulOptions.map(\.analyticsValue).sorted()
        let otherResponse = includeHelpfulOtherOption ? helpfulOtherText : ""

        AnalyticsService.shared.capture("whats_new_survey_submitted", [
            "version": releaseNote.version,
            "value_frequency": selection.analyticsValue,
            "value_frequency_label": selection.title,
            "helpful_options": selectedOptionValues,
            "helpful_option_labels": selectedOptionTitles,
            "helpful_options_count": selectedOptionValues.count + (includeHelpfulOtherOption ? 1 : 0),
            "helpful_other_selected": includeHelpfulOtherOption,
            "helpful_other_text": otherResponse,
            "provider_label": currentProviderLabel
        ])

        submittedValueSurveyVersion = releaseNote.version
    }

    private func captureValueSurveyProgress(
        trigger: String,
        targetOption: String? = nil,
        targetSelected: Bool? = nil
    ) {
        let selectedOptionTitles = selectedHelpfulOptions.map(\.title).sorted()
        let selectedOptionValues = selectedHelpfulOptions.map(\.analyticsValue).sorted()
        let otherResponse = includeHelpfulOtherOption ? helpfulOtherText : ""

        var properties: [String: Any] = [
            "version": releaseNote.version,
            "value_frequency": valueFrequencySelection?.analyticsValue as Any,
            "value_frequency_label": valueFrequencySelection?.title as Any,
            "helpful_options": selectedOptionValues,
            "helpful_option_labels": selectedOptionTitles,
            "helpful_options_count": selectedOptionValues.count + (includeHelpfulOtherOption ? 1 : 0),
            "helpful_other_selected": includeHelpfulOtherOption,
            "helpful_other_text": otherResponse,
            "trigger": trigger,
            "provider_label": currentProviderLabel
        ]

        if let targetOption {
            properties["target_option"] = targetOption
        }
        if let targetSelected {
            properties["target_selected"] = targetSelected
        }

        AnalyticsService.shared.capture("whats_new_survey_progress", properties)
    }

    private func hydrateSurveyStateIfNeeded() {
        valueFrequencySelection = storedValueFrequencySelection
        selectedHelpfulOptions = storedHelpfulOptionSelections
        includeHelpfulOtherOption = UserDefaults.standard.bool(forKey: helpfulOtherEnabledStorageKey)
        helpfulOtherText = UserDefaults.standard.string(forKey: helpfulOtherTextStorageKey) ?? ""
        randomizedHelpfulOptions = HelpfulFeatureOption.allCases.shuffled()
    }

    private var valueFrequencyStorageKey: String {
        "whatsNewValueFrequencySelection_\(releaseNote.version)"
    }

    private var helpfulOptionsSelectionStorageKey: String {
        "whatsNewHelpfulOptionsSelection_\(releaseNote.version)"
    }

    private var helpfulOtherEnabledStorageKey: String {
        "whatsNewHelpfulOtherEnabled_\(releaseNote.version)"
    }

    private var helpfulOtherTextStorageKey: String {
        "whatsNewHelpfulOtherText_\(releaseNote.version)"
    }

    private var storedValueFrequencySelection: ValueFrequencyOption? {
        guard let storedValue = UserDefaults.standard.string(forKey: valueFrequencyStorageKey) else { return nil }
        return ValueFrequencyOption(rawValue: storedValue)
    }

    private var storedHelpfulOptionSelections: Set<HelpfulFeatureOption> {
        guard let stored = UserDefaults.standard.stringArray(forKey: helpfulOptionsSelectionStorageKey) else { return [] }
        return Set(stored.compactMap(HelpfulFeatureOption.init(rawValue:)))
    }

    private var currentProviderLabel: String {
        let providerID = LLMProviderID.from(currentProviderType)
        return providerID.providerLabel(chatTool: providerID == .chatGPTClaude ? preferredChatCLITool : nil)
    }

    private var currentProviderType: LLMProviderType {
        LLMProviderType.load()
    }

    private var preferredChatCLITool: ChatCLITool {
        let preferredTool = UserDefaults.standard.string(forKey: "chatCLIPreferredTool") ?? "codex"
        return preferredTool == "claude" ? .claude : .codex
    }
}

private enum ValueFrequencyOption: String, CaseIterable {
    case daily = "daily"
    case sometimes = "sometimes"
    case notSureYet = "not_sure_yet"

    var title: String {
        switch self {
        case .daily: return "Daily - it's part of my routine"
        case .sometimes: return "Sometimes - a few times a week"
        case .notSureYet: return "Not sure yet - still figuring it out."
        }
    }

    var analyticsValue: String { rawValue }
}

private enum HelpfulFeatureOption: String, CaseIterable, Hashable {
    case distractionNudges = "distraction_nudges"
    case meetingSummaries = "meeting_summaries"
    case weeklyTimeBreakdown = "weekly_time_breakdown"
    case dayStartContext = "day_start_context"
    case historySearch = "history_search"
    case focusFragmentationTrends = "focus_fragmentation_trends"

    var title: String {
        switch self {
        case .distractionNudges:
            return "Nudge me when I've been distracted or switching contexts too much"
        case .meetingSummaries:
            return "Auto-generate summaries for my meetings (e.g. standups, 1:1s)"
        case .weeklyTimeBreakdown:
            return "Show me where my time went each week"
        case .dayStartContext:
            return "Remind me where I left off when I start my day"
        case .historySearch:
            return "Let me search my work history (e.g. \"what was I doing last Tuesday?\")"
        case .focusFragmentationTrends:
            return "Track my focus and fragmentation trends over weeks"
        }
    }

    var analyticsValue: String { rawValue }
}

// MARK: - Preview

struct WhatsNewView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            if let note = WhatsNewConfiguration.configuredRelease {
                WhatsNewView(
                    releaseNote: note,
                    onDismiss: { print("Dismissed") }
                )
                .frame(width: 1200, height: 800)
            } else {
                Text("Configure WhatsNewConfiguration.configuredRelease to preview.")
                    .frame(width: 780, height: 400)
            }
        }
    }
}
