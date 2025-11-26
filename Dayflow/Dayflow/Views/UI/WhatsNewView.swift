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
    private static let versionOverride: String? = "1.3.1"

    /// Update this content before shipping each release. Return nil to disable the modal entirely.
    static var configuredRelease: ReleaseNote? {
        ReleaseNote(
            version: targetVersion,
            title: "ChatGPT & Claude integration, timeline export, and smoother animations.",
            highlights: [
                "ChatGPT & Claude integration (beta): New inference provider that hooks up through their CLI tools. Find it in Settings → Providers.",
                "Timeline export: Export a day's cards directly from the timeline, or export any time range through Settings. Useful for passing into AI for custom analysis.",
                "Smoother animations on the timeline.",
                "Local model users: If you're still on Qwen2.5VL, upgrade to Qwen3VL from Settings → Providers for greatly improved quality.",
                "Journal (early preview): We're slowly rolling out as we work out the bugs. Keep an eye out!"
            ],
            imageName: nil
        )
    }

    /// Returns the configured release when it matches the app version and hasn't been shown yet.
    static func pendingReleaseForCurrentBuild() -> ReleaseNote? {
        guard let release = configuredRelease else { return nil }
        guard release.version == currentAppVersion else { return nil }
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
}

// MARK: - What's New View

struct WhatsNewView: View {
    let releaseNote: ReleaseNote
    let onDismiss: () -> Void

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
        }
    }

    private func dismiss() {
        AnalyticsService.shared.capture("whats_new_dismissed", [
            "version": releaseNote.version
        ])

        onDismiss()
    }
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
