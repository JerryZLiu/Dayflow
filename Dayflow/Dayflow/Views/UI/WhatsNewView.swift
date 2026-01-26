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
    private static let versionOverride: String? = "1.6.0"

    /// Update this content before shipping each release. Return nil to disable the modal entirely.
    static var configuredRelease: ReleaseNote? {
        ReleaseNote(
            version: targetVersion,
            title: "Dashboard Beta + Quality improvements",
            highlights: [
                "Better card quality for Gemini, Claude, and ChatGPT users. Please reach out with any feedback!",
                "Dashboard (beta): a new place to ask questions about your Dayflow data and generate charts/graphs of your time - limited to ChatGPT and Claude for now.",
                "Gemini rate limits: automatic Gemma backup so you stay unblocked."
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

    @AppStorage("whatsNewSurveyFriendVersion") private var submittedFriendVersion: String = ""
    @State private var disappointmentSelection: DisappointmentOption? = nil
    @State private var friendDescription: String = ""

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
            if disappointmentSelection == nil {
                disappointmentSelection = storedDisappointmentSelection
            }
        }
    }

    private func dismiss() {
        AnalyticsService.shared.capture("whats_new_dismissed", [
            "version": releaseNote.version
        ])

        onDismiss()
    }

    private var surveySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("If Dayflow has been helpful, could you answer two quick questions?")
                .font(.custom("Nunito", size: 13))
                .foregroundColor(.black.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            disappointmentQuestion
            friendDescriptionQuestion
        }
        .padding(.top, 10)
    }

    private var disappointmentQuestion: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How would you feel if you could no longer use Dayflow?")
                .font(.custom("Nunito", size: 15))
                .fontWeight(.semibold)
                .foregroundColor(.black.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                ForEach(DisappointmentOption.allCases, id: \.self) { option in
                    Button(action: { selectDisappointment(option) }) {
                        HStack(spacing: 10) {
                            Image(systemName: disappointmentSelection == option ? "largecircle.fill.circle" : "circle")
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
                                .fill(disappointmentSelection == option ? Color(red: 1.0, green: 0.95, blue: 0.9) : Color.white)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color(red: 0.25, green: 0.17, blue: 0).opacity(disappointmentSelection == option ? 0.22 : 0.1), lineWidth: 1)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }

            if disappointmentSelection != nil {
                Label("Thanks for sharing!", systemImage: "checkmark.circle.fill")
                    .font(.custom("Nunito", size: 14))
                    .foregroundColor(Color(red: 0.25, green: 0.17, blue: 0))
            }
        }
    }

    private var friendDescriptionQuestion: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How would you describe Dayflow to a friend?")
                .font(.custom("Nunito", size: 15))
                .fontWeight(.semibold)
                .foregroundColor(.black.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            TextField("Type your response here", text: $friendDescription)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .font(.custom("Nunito", size: 13))
                .padding(.horizontal, 4)

            HStack {
                Spacer()
                DayflowSurfaceButton(
                    action: submitFriendDescription,
                    content: {
                        Text("Submit")
                            .font(.custom("Nunito", size: 15))
                            .fontWeight(.semibold)
                    },
                    background: canSubmitFriendDescription ? Color(red: 0.25, green: 0.17, blue: 0) : Color.black.opacity(0.08),
                    foreground: .white.opacity(canSubmitFriendDescription ? 1 : 0.7),
                    borderColor: .clear,
                    cornerRadius: 8,
                    horizontalPadding: 34,
                    verticalPadding: 12,
                    minWidth: 160,
                    showOverlayStroke: true
                )
                .disabled(!canSubmitFriendDescription)
                .opacity(canSubmitFriendDescription ? 1 : 0.8)
            }

            if hasSubmittedFriend {
                Label("Thanks for sharing!", systemImage: "checkmark.circle.fill")
                    .font(.custom("Nunito", size: 14))
                    .foregroundColor(Color(red: 0.25, green: 0.17, blue: 0))
            }
        }
    }

    private var hasSubmittedFriend: Bool {
        submittedFriendVersion == releaseNote.version
    }

    private var canSubmitFriendDescription: Bool {
        !hasSubmittedFriend && !friendDescriptionTrimmed.isEmpty
    }

    private var friendDescriptionTrimmed: String {
        friendDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func selectDisappointment(_ option: DisappointmentOption) {
        let previousSelection = storedDisappointmentSelection
        disappointmentSelection = option
        UserDefaults.standard.set(option.rawValue, forKey: disappointmentStorageKey)
        guard previousSelection != option else { return }

        AnalyticsService.shared.capture("whats_new_survey_disappointment_selected", [
            "version": releaseNote.version,
            "option": option.analyticsValue
        ])
    }

    private func submitFriendDescription() {
        let trimmed = friendDescriptionTrimmed
        guard !trimmed.isEmpty, !hasSubmittedFriend else { return }
        let response = String(trimmed.prefix(280))

        AnalyticsService.shared.capture("whats_new_survey_friend_desc_submitted", [
            "version": releaseNote.version,
            "response": response
        ])

        submittedFriendVersion = releaseNote.version
    }

    private var disappointmentStorageKey: String {
        "whatsNewSurveyDisappointmentSelection_\(releaseNote.version)"
    }

    private var storedDisappointmentSelection: DisappointmentOption? {
        guard let storedValue = UserDefaults.standard.string(forKey: disappointmentStorageKey) else { return nil }
        return DisappointmentOption(rawValue: storedValue)
    }
}

private enum DisappointmentOption: String, CaseIterable {
    case veryDisappointed = "very_disappointed"
    case somewhatDisappointed = "somewhat_disappointed"
    case notDisappointed = "not_disappointed"

    var title: String {
        switch self {
        case .veryDisappointed: return "Very disappointed"
        case .somewhatDisappointed: return "Somewhat disappointed"
        case .notDisappointed: return "Not disappointed"
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
