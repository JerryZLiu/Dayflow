//
//  WhatsNewView.swift
//  Dayflow
//
//  Displays release highlights after app updates
//

import AppKit
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
  let version: String  // e.g. "2.0.1"
  let title: String  // e.g. "Timeline Improvements"
  let highlights: [String]  // Array of bullet points
  let previewIntro: String?
  let previewImageNames: [String]
  let cta: ReleaseNoteCTA?

  // Helper to compare semantic versions
  var semanticVersion: [Int] {
    version.split(separator: ".").compactMap { Int($0) }
  }
}

enum WhatsNewDesignSurveyOption: String, CaseIterable, Identifiable {
  case bestDesigned = "Best-designed app I use"
  case oneOfTheBest = "One of the best"
  case goodNeedsPolish = "Good, but still needs polish"
  case roughOrBuggy = "Too rough or buggy today"

  var id: String { rawValue }
}

// MARK: - What's New Configuration

enum WhatsNewConfiguration {
  private static let seenKey = "lastSeenWhatsNewVersion"

  /// Override with the specific release number you want to show.
  private static let versionOverride: String? = "1.10.0"

  /// Update this content before shipping each release. Return nil to disable the modal entirely.
  static var configuredRelease: ReleaseNote? {
    ReleaseNote(
      version: targetVersion,
      title: "A new Week view for your timeline",
      highlights: [
        "We've started rolling out a new Week view for your main timeline.",
        "You can now step back and scan your week at a glance. We're still refining the Week view, so if you notice bugs or rough edges, please reach out. We'd love your feedback.",
        "Codex-powered flows in Dayflow now use newer GPT-5.4 models.",
      ],
      previewIntro:
        "A few previews from the new Week view are below.",
      previewImageNames: ["WeeklyCalendarPreview", "WeeklyPreview"],
      cta: nil
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
    return true  // equal
  }
}

// MARK: - What's New View

struct WhatsNewView: View {
  let releaseNote: ReleaseNote
  let onDismiss: () -> Void

  @Environment(\.openURL) private var openURL
  @AppStorage("whatsNewDesignRatingSubmittedVersion") private var submittedDesignRatingVersion:
    String = ""
  @AppStorage("whatsNewReferenceAppsSubmittedVersion") private var submittedReferenceAppsVersion:
    String = ""
  @State private var selectedDesignSurveyOptionID = ""
  @State private var referenceAppsResponse = ""
  @State private var didHydrateSurveyState = false

  private let bottomAnchorID = "whats_new_bottom_anchor"

  var body: some View {
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

        surveySection

        if let previewIntro = releaseNote.previewIntro,
          previewIntro.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        {
          Text(previewIntro)
            .font(.custom("Nunito", size: 14))
            .foregroundColor(.black.opacity(0.72))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
        }

        if !releaseNote.previewImageNames.isEmpty {
          VStack(spacing: 16) {
            ForEach(releaseNote.previewImageNames, id: \.self) { imageName in
              Image(imageName)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .background(
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.985, green: 0.985, blue: 0.985))
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )
            }
          }
          // Let previews use more horizontal space than text for better readability.
          .padding(.top, 6)
          .padding(.horizontal, -36)
        }

        if let cta = releaseNote.cta {
          ctaSection(cta)
        }

        Color.clear
          .frame(height: 1)
          .id(bottomAnchorID)
      }
      .padding(.horizontal, 44)
      .padding(.vertical, 36)
    }
    .frame(maxHeight: 760)
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
    AnalyticsService.shared.capture(
      "whats_new_dismissed",
      [
        "version": releaseNote.version,
        "provider_label": currentProviderLabel,
      ])

    onDismiss()
  }

  private var surveySection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(
        "We want Dayflow to become one of the best-designed apps in the world. Where do you think it stands today?"
      )
      .font(.custom("Nunito", size: 15))
      .fontWeight(.semibold)
      .foregroundColor(.black.opacity(0.85))
      .fixedSize(horizontal: false, vertical: true)

      Text(
        "Choose the option that feels closest, then tell us which apps feel exceptionally well designed to you."
      )
      .font(.custom("Nunito", size: 13))
      .foregroundColor(.black.opacity(0.62))
      .fixedSize(horizontal: false, vertical: true)

      VStack(spacing: 10) {
        ForEach(WhatsNewDesignSurveyOption.allCases) { option in
          designSurveyOptionRow(option)
        }
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Which apps feel exceptionally well designed to you?")
          .font(.custom("Nunito", size: 14))
          .fontWeight(.semibold)
          .foregroundColor(.black.opacity(0.82))

        Text(
          hasSubmittedDesignRating
            ? "Optional. This helps us understand the bar you're comparing Dayflow against."
            : "Optional. Pick a rating first, then share the apps you're comparing Dayflow against."
        )
        .font(.custom("Nunito", size: 13))
        .foregroundColor(.black.opacity(0.58))
        .fixedSize(horizontal: false, vertical: true)

        ZStack {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white)

          WhatsNewSurveyTextEditor(
            text: $referenceAppsResponse,
            placeholder: "Examples: Linear, Raycast, Apple Notes, Arc...",
            isEditable: !hasSubmittedReferenceApps
          )
          .frame(height: 86)
          .onChange(of: referenceAppsResponse) {
            persistReferenceAppsResponse()
          }
          .environment(\.colorScheme, .light)
          .preferredColorScheme(.light)
        }
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.black.opacity(0.1), lineWidth: 1)
        )
        .opacity(hasSubmittedReferenceApps ? 0.72 : 1)
      }

      HStack {
        Spacer()
        DayflowSurfaceButton(
          action: submitReferenceApps,
          content: {
            Text("Send apps")
              .font(.custom("Nunito", size: 15))
              .fontWeight(.semibold)
          },
          background: canSubmitReferenceApps
            ? Color(red: 0.25, green: 0.17, blue: 0) : Color.black.opacity(0.08),
          foreground: .white.opacity(canSubmitReferenceApps ? 1 : 0.7),
          borderColor: .clear,
          cornerRadius: 8,
          horizontalPadding: 34,
          verticalPadding: 12,
          minWidth: 160,
          showOverlayStroke: true
        )
        .disabled(!canSubmitReferenceApps)
        .opacity(canSubmitReferenceApps ? 1 : 0.8)
      }

      if hasSubmittedDesignRating {
        Label("Thanks for rating Dayflow.", systemImage: "checkmark.circle.fill")
          .font(.custom("Nunito", size: 14))
          .foregroundColor(Color(red: 0.25, green: 0.17, blue: 0))
      }

      if hasSubmittedReferenceApps {
        Label("Thanks for sharing!", systemImage: "checkmark.circle.fill")
          .font(.custom("Nunito", size: 14))
          .foregroundColor(Color(red: 0.25, green: 0.17, blue: 0))
      }
    }
    .padding(.top, 10)
    .environment(\.colorScheme, .light)
    .preferredColorScheme(.light)
  }

  private func designSurveyOptionRow(_ option: WhatsNewDesignSurveyOption) -> some View {
    let isSelected = selectedDesignSurveyOption == option

    return Button(action: {
      selectDesignSurveyOption(option)
    }) {
      HStack(spacing: 12) {
        ZStack {
          Circle()
            .stroke(
              isSelected ? Color(red: 0.25, green: 0.17, blue: 0) : Color.black.opacity(0.16),
              lineWidth: 1.5
            )
            .frame(width: 18, height: 18)

          if isSelected {
            Circle()
              .fill(Color(red: 0.25, green: 0.17, blue: 0))
              .frame(width: 8, height: 8)
          }
        }

        Text(option.rawValue)
          .font(.custom("Nunito", size: 14))
          .foregroundColor(.black.opacity(0.82))
          .fixedSize(horizontal: false, vertical: true)

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(
            isSelected
              ? Color(red: 0.25, green: 0.17, blue: 0).opacity(0.06)
              : Color.white
          )
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(
            isSelected
              ? Color(red: 0.25, green: 0.17, blue: 0).opacity(0.28)
              : Color.black.opacity(0.1),
            lineWidth: 1
          )
      )
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
    .disabled(hasSubmittedDesignRating)
    .opacity(hasSubmittedDesignRating ? 0.75 : 1)
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
    AnalyticsService.shared.capture(
      "whats_new_cta_opened",
      [
        "version": releaseNote.version,
        "cta_title": cta.title,
        "cta_url": cta.url,
        "provider_label": currentProviderLabel,
      ])
    openURL(url)
  }

  private var hasSubmittedDesignRating: Bool {
    submittedDesignRatingVersion == releaseNote.version
  }

  private var hasSubmittedReferenceApps: Bool {
    submittedReferenceAppsVersion == releaseNote.version
  }

  private var selectedDesignSurveyOption: WhatsNewDesignSurveyOption? {
    WhatsNewDesignSurveyOption(rawValue: selectedDesignSurveyOptionID)
  }

  private var referenceAppsResponseTrimmed: String {
    referenceAppsResponse.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canSubmitReferenceApps: Bool {
    hasSubmittedDesignRating && !hasSubmittedReferenceApps && !referenceAppsResponseTrimmed.isEmpty
  }

  private func selectDesignSurveyOption(_ option: WhatsNewDesignSurveyOption) {
    guard !hasSubmittedDesignRating else { return }
    selectedDesignSurveyOptionID = option.rawValue
    persistSelectedDesignSurveyOption()
    AnalyticsService.shared.capture(
      "whats_new_design_rating_submitted",
      [
        "version": releaseNote.version,
        "design_rating": option.rawValue,
        "provider_label": currentProviderLabel,
      ]
    )

    submittedDesignRatingVersion = releaseNote.version
  }

  private func submitReferenceApps() {
    guard hasSubmittedDesignRating else { return }
    guard !hasSubmittedReferenceApps else { return }

    let referenceApps = String(referenceAppsResponseTrimmed.prefix(1000))
    guard !referenceApps.isEmpty else { return }

    var props: [String: Any] = [
      "version": releaseNote.version,
      "reference_apps": referenceApps,
      "provider_label": currentProviderLabel,
    ]
    if let selectedOption = selectedDesignSurveyOption {
      props["design_rating"] = selectedOption.rawValue
    }

    AnalyticsService.shared.capture(
      "whats_new_design_reference_apps_submitted",
      props
    )

    submittedReferenceAppsVersion = releaseNote.version
    referenceAppsResponse = referenceApps
    persistReferenceAppsResponse()
  }

  private func persistSelectedDesignSurveyOption() {
    UserDefaults.standard.set(
      selectedDesignSurveyOptionID,
      forKey: selectedDesignSurveyOptionStorageKey
    )
  }

  private func persistReferenceAppsResponse() {
    UserDefaults.standard.set(referenceAppsResponse, forKey: referenceAppsResponseStorageKey)
  }

  private func hydrateSurveyStateIfNeeded() {
    selectedDesignSurveyOptionID =
      UserDefaults.standard.string(forKey: selectedDesignSurveyOptionStorageKey) ?? ""
    referenceAppsResponse =
      UserDefaults.standard.string(forKey: referenceAppsResponseStorageKey) ?? ""
  }

  private var selectedDesignSurveyOptionStorageKey: String {
    "whatsNewDesignSurveyOption_\(releaseNote.version)"
  }

  private var referenceAppsResponseStorageKey: String {
    "whatsNewReferenceAppsResponse_\(releaseNote.version)"
  }

  private var currentProviderLabel: String {
    let providerID = LLMProviderID.from(currentProviderType)
    return providerID.providerLabel(
      chatTool: providerID == .chatGPTClaude ? preferredChatCLITool : nil)
  }

  private var currentProviderType: LLMProviderType {
    LLMProviderType.load()
  }

  private var preferredChatCLITool: ChatCLITool {
    let preferredTool = UserDefaults.standard.string(forKey: "chatCLIPreferredTool") ?? "codex"
    return preferredTool == "claude" ? .claude : .codex
  }
}

private struct WhatsNewSurveyTextEditor: NSViewRepresentable {
  @Binding var text: String
  let placeholder: String
  var isEditable: Bool = true

  private let fontSize: CGFloat = 14
  private let textInsets = NSSize(width: 14, height: 12)

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.focusRingType = .none
    scrollView.appearance = NSAppearance(named: .aqua)

    let textView = PlaceholderTextView()
    textView.delegate = context.coordinator
    textView.placeholder = placeholder
    textView.font = NSFont(name: "Nunito", size: fontSize) ?? .systemFont(ofSize: fontSize)
    textView.textColor = NSColor.black.withAlphaComponent(0.82)
    textView.insertionPointColor = .systemBlue
    textView.drawsBackground = false
    textView.backgroundColor = .clear
    textView.focusRingType = .none
    textView.appearance = NSAppearance(named: .aqua)
    textView.isRichText = false
    textView.importsGraphics = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = true
    textView.isEditable = isEditable
    textView.isSelectable = true
    textView.autoresizingMask = [.width]
    textView.textContainerInset = textInsets
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
      width: 0,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.string = text

    scrollView.documentView = textView
    return scrollView
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    nsView.appearance = NSAppearance(named: .aqua)

    guard let textView = nsView.documentView as? PlaceholderTextView else { return }

    if textView.string != text {
      textView.string = text
    }

    textView.placeholder = placeholder
    textView.isEditable = isEditable
    textView.isSelectable = true
    textView.appearance = NSAppearance(named: .aqua)
    textView.needsDisplay = true
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    @Binding private var text: String

    init(text: Binding<String>) {
      _text = text
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      text = textView.string
      textView.needsDisplay = true
    }
  }
}

private final class PlaceholderTextView: NSTextView {
  var placeholder = "" {
    didSet { needsDisplay = true }
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    guard string.isEmpty, let font else { return }

    let placeholderRect = NSRect(
      x: textContainerInset.width,
      y: textContainerInset.height,
      width: bounds.width - (textContainerInset.width * 2),
      height: (font.ascender - font.descender + font.leading) * 2
    )

    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: NSColor.black.withAlphaComponent(0.35),
    ]

    (placeholder as NSString).draw(
      with: placeholderRect,
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: attributes
    )
  }

  override func didChangeText() {
    super.didChangeText()
    needsDisplay = true
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
