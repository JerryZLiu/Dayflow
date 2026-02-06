//
//  WhatsNewView.swift
//  Dayflow
//
//  Displays release highlights after app updates
//

import SwiftUI

// MARK: - Release Notes Data Structure

struct ReleaseNote: Identifiable {
    let id = UUID()
    let version: String      // e.g. "2.0.1"
    let title: String        // e.g. "Timeline Improvements"
    let highlights: [String] // Array of bullet points
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
    private static let versionOverride: String? = "1.7.0"

    /// Update this content before shipping each release. Return nil to disable the modal entirely.
    static var configuredRelease: ReleaseNote? {
        ReleaseNote(
            version: targetVersion,
            title: "Set a backup provider · Improved quality for local LLMs · New language toggle",
            highlights: [
                "You can improve reliability of timeline generation by setting a backup provider in Settings.",
                "Set your preferred language output in Settings with the new language toggle.",
                "Local LLM quality is better: titles and grouping are more accurate with optimized prompts. Local mode now also pulls app/site icons, and you can turn icons off in Settings for additional privacy."
            ],
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

    @AppStorage("whatsNewTimelineQualitySubmittedVersion") private var submittedTimelineQualityVersion: String = ""
    @State private var timelineQualitySelection: TimelineQualityOption? = nil
    @State private var timelineQualityFeedback: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What's New in \(releaseNote.version) 🎉")
                        .font(.custom("InstrumentSerif-Regular", size: 32))
                        .foregroundColor(.black.opacity(0.9))

                    Text(releaseNote.title)
                        .font(.custom("Nunito", size: 15))
                        .fontWeight(.semibold)
                        .foregroundColor(.black.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
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

            surveySection

        }
        .padding(.horizontal, 44)
        .padding(.vertical, 36)
        .frame(width: 780)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.25), radius: 40, x: 0, y: 20)
        )
        .onAppear {
            AnalyticsService.shared.screen("whats_new")
            if timelineQualitySelection == nil {
                timelineQualitySelection = storedTimelineQualitySelection
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
            timelineQualityQuestion
            timelineQualityFeedbackQuestion
        }
        .padding(.top, 10)
    }

    private var timelineQualityQuestion: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How would you grade the quality of your timeline cards?")
                .font(.custom("Nunito", size: 15))
                .fontWeight(.semibold)
                .foregroundColor(.black.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: 12),
                    GridItem(.flexible(minimum: 0, maximum: .infinity), spacing: 12)
                ],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(TimelineQualityOption.allCases, id: \.self) { option in
                    Button(action: { selectTimelineQuality(option) }) {
                        HStack(spacing: 10) {
                            Image(systemName: timelineQualitySelection == option ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(Color(red: 0.25, green: 0.17, blue: 0))

                            Text(option.title)
                                .font(.custom("Nunito", size: 14))
                                .foregroundColor(.black.opacity(0.8))

                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(timelineQualitySelection == option ? Color(red: 1.0, green: 0.95, blue: 0.9) : Color.white)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color(red: 0.25, green: 0.17, blue: 0).opacity(timelineQualitySelection == option ? 0.22 : 0.1), lineWidth: 1)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }

            if timelineQualitySelection != nil {
                Label("Thanks for sharing!", systemImage: "checkmark.circle.fill")
                    .font(.custom("Nunito", size: 14))
                    .foregroundColor(Color(red: 0.25, green: 0.17, blue: 0))
            }
        }
    }

    private var timelineQualityFeedbackQuestion: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What do you like most, or what should we improve?")
                .font(.custom("Nunito", size: 15))
                .fontWeight(.semibold)
                .foregroundColor(.black.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            TextField("Would be really helpful if you could elaborate, especially if you think the quality isn't great - feel free to write about other stuff as well.", text: $timelineQualityFeedback)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .font(.custom("Nunito", size: 13))
                .padding(.horizontal, 4)

            HStack {
                Spacer()
                DayflowSurfaceButton(
                    action: submitTimelineQualitySurvey,
                    content: {
                        Text("Submit")
                            .font(.custom("Nunito", size: 15))
                            .fontWeight(.semibold)
                    },
                    background: canSubmitTimelineQualitySurvey ? Color(red: 0.25, green: 0.17, blue: 0) : Color.black.opacity(0.08),
                    foreground: .white.opacity(canSubmitTimelineQualitySurvey ? 1 : 0.7),
                    borderColor: .clear,
                    cornerRadius: 8,
                    horizontalPadding: 34,
                    verticalPadding: 12,
                    minWidth: 160,
                    showOverlayStroke: true
                )
                .disabled(!canSubmitTimelineQualitySurvey)
                .opacity(canSubmitTimelineQualitySurvey ? 1 : 0.8)
            }

            if hasSubmittedTimelineQualitySurvey {
                Label("Thanks for sharing!", systemImage: "checkmark.circle.fill")
                    .font(.custom("Nunito", size: 14))
                    .foregroundColor(Color(red: 0.25, green: 0.17, blue: 0))
            }
        }
    }

    private var hasSubmittedTimelineQualitySurvey: Bool {
        submittedTimelineQualityVersion == releaseNote.version
    }

    private var canSubmitTimelineQualitySurvey: Bool {
        !hasSubmittedTimelineQualitySurvey && timelineQualitySelection != nil
    }

    private var timelineQualityFeedbackTrimmed: String {
        timelineQualityFeedback.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func selectTimelineQuality(_ option: TimelineQualityOption) {
        let previousSelection = storedTimelineQualitySelection
        timelineQualitySelection = option
        UserDefaults.standard.set(option.rawValue, forKey: timelineQualityStorageKey)
        guard previousSelection != option else { return }

        AnalyticsService.shared.capture("whats_new_survey_timeline_quality_selected", [
            "version": releaseNote.version,
            "option": option.analyticsValue,
            "provider_label": currentProviderLabel
        ])
    }

    private func submitTimelineQualitySurvey() {
        guard let selection = timelineQualitySelection, !hasSubmittedTimelineQualitySurvey else { return }
        let trimmed = timelineQualityFeedbackTrimmed
        let response = String(trimmed.prefix(280))

        AnalyticsService.shared.capture("whats_new_survey_timeline_quality_submitted", [
            "version": releaseNote.version,
            "rating": selection.analyticsValue,
            "feedback": response,
            "provider_label": currentProviderLabel
        ])

        submittedTimelineQualityVersion = releaseNote.version
    }

    private var timelineQualityStorageKey: String {
        "whatsNewTimelineQualitySelection_\(releaseNote.version)"
    }

    private var storedTimelineQualitySelection: TimelineQualityOption? {
        guard let storedValue = UserDefaults.standard.string(forKey: timelineQualityStorageKey) else { return nil }
        return TimelineQualityOption(rawValue: storedValue)
    }

    private var currentProviderLabel: String {
        let providerID = LLMProviderID.from(currentProviderType)
        return providerID.providerLabel(chatTool: providerID == .chatGPTClaude ? preferredChatCLITool : nil)
    }

    private var currentProviderType: LLMProviderType {
        guard let data = UserDefaults.standard.data(forKey: "llmProviderType"),
              let providerType = try? JSONDecoder().decode(LLMProviderType.self, from: data) else {
            return .geminiDirect
        }
        return providerType
    }

    private var preferredChatCLITool: ChatCLITool {
        let preferredTool = UserDefaults.standard.string(forKey: "chatCLIPreferredTool") ?? "codex"
        return preferredTool == "claude" ? .claude : .codex
    }
}

private enum TimelineQualityOption: String, CaseIterable {
    case extraordinary = "extraordinary"
    case solid = "solid"
    case mixed = "mixed"
    case inaccurate = "inaccurate"
    case poor = "poor"

    var title: String {
        switch self {
        case .extraordinary: return "It's extraordinarily accurate, feels like magic"
        case .solid: return "It's pretty solid, very useful"
        case .mixed: return "It's usable, but still inconsistent"
        case .inaccurate: return "It's often inaccurate and needs corrections"
        case .poor: return "Poor, consistently hallucinates."
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
