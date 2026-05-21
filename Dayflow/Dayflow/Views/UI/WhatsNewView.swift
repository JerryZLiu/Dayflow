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

enum WhatsNewTaskOption: String, CaseIterable, Identifiable {
  case manualPlan = "manual_plan"
  case importedTasks = "imported_tasks"
  case progressReview = "progress_review"
  case tomorrowPriorities = "tomorrow_priorities"
  case timeTrackingOnly = "time_tracking_only"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .manualPlan:
      return "Let me write down what I want to get done, then auto-detect progress from my day"
    case .importedTasks:
      return "Pull tasks from tools I already use, like Linear, Notion, Todoist, or my calendar"
    case .progressReview:
      return "Show me which planned tasks I actually made progress on"
    case .tomorrowPriorities:
      return "Carry unfinished work into tomorrow's priorities"
    case .timeTrackingOnly:
      return "Nothing; I want Dayflow to track my time, not manage my tasks"
    }
  }
}

// MARK: - What's New Configuration

enum WhatsNewConfiguration {
  private static let seenKey = "lastSeenWhatsNewVersion"

  /// Override with the specific release number you want to show.
  private static let versionOverride: String? = "1.12.0"

  /// Update this content before shipping each release. Return nil to disable the modal entirely.
  static var configuredRelease: ReleaseNote? {
    ReleaseNote(
      version: targetVersion,
      title: "Set goals for your day",
      highlights: [
        "Dayflow is evolving from helping you understand your time to helping you improve how you spend it.",
        "We're starting with daily focus targets: choose what counts as focus, set a distraction limit, and track your progress as the day unfolds.",
        "Dayflow also has a cleaner visual system, with more readable text and a calmer, more consistent feel throughout the app.",
        "Daily goal reminders can be turned off anytime in Settings.",
      ],
      previewIntro: nil,
      previewImageNames: [],
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
  @AppStorage("whatsNewTaskOptionsSubmittedVersion") private var submittedTaskOptionsVersion:
    String = ""
  @State private var selectedTaskOptionIDs: Set<String> = []
  @State private var releaseSurveyResponseID = ""
  @State private var isSubmittingTaskOptions = false
  @State private var surveyErrorText: String?
  @State private var didHydrateSurveyState = false

  private let bottomAnchorID = "whats_new_bottom_anchor"
  private let releaseSurveyKey = "task_planning"

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
                .font(.custom("Figtree", size: 15))
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
            .font(.custom("Figtree", size: 14))
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
        "What should Dayflow do with your tasks?"
      )
      .font(.custom("Figtree", size: 15))
      .fontWeight(.semibold)
      .foregroundColor(.black.opacity(0.85))
      .fixedSize(horizontal: false, vertical: true)

      Text(
        "We're thinking about ways to connect what you intend to do with what Dayflow can see you actually worked on."
      )
      .font(.custom("Figtree", size: 13))
      .foregroundColor(.black.opacity(0.62))
      .fixedSize(horizontal: false, vertical: true)

      VStack(spacing: 10) {
        ForEach(WhatsNewTaskOption.allCases) { option in
          taskOptionRow(option)
        }
      }

      if let surveyErrorText {
        Text(surveyErrorText)
          .font(.custom("Figtree", size: 13))
          .foregroundColor(Color.red.opacity(0.75))
          .fixedSize(horizontal: false, vertical: true)
      }

      if isSubmittingTaskOptions {
        Label("Saving...", systemImage: "arrow.triangle.2.circlepath")
          .font(.custom("Figtree", size: 14))
          .foregroundColor(Color(red: 0.25, green: 0.17, blue: 0).opacity(0.72))
      } else if hasSubmittedTaskOptions {
        Label("Saved.", systemImage: "checkmark.circle.fill")
          .font(.custom("Figtree", size: 14))
          .foregroundColor(Color(red: 0.25, green: 0.17, blue: 0))
      }
    }
    .padding(.top, 10)
    .environment(\.colorScheme, .light)
    .preferredColorScheme(.light)
  }

  private func taskOptionRow(_ option: WhatsNewTaskOption) -> some View {
    let isSelected = selectedTaskOptionIDs.contains(option.rawValue)

    return Button(action: {
      toggleTaskOption(option)
    }) {
      HStack(spacing: 12) {
        ZStack {
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .stroke(
              isSelected ? Color(red: 0.25, green: 0.17, blue: 0) : Color.black.opacity(0.16),
              lineWidth: 1.5
            )
            .frame(width: 18, height: 18)

          if isSelected {
            Image(systemName: "checkmark")
              .font(.system(size: 11, weight: .bold))
              .foregroundColor(Color(red: 0.25, green: 0.17, blue: 0))
          }
        }

        Text(option.title)
          .font(.custom("Figtree", size: 14))
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
  }

  private func ctaSection(_ cta: ReleaseNoteCTA) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(cta.title)
        .font(.custom("Figtree", size: 16))
        .fontWeight(.bold)
        .foregroundColor(.black.opacity(0.86))

      Text(cta.description)
        .font(.custom("Figtree", size: 14))
        .foregroundColor(.black.opacity(0.75))
        .fixedSize(horizontal: false, vertical: true)

      DayflowSurfaceButton(
        action: { openCTA(cta) },
        content: {
          HStack(spacing: 8) {
            Image(systemName: "calendar")
              .font(.system(size: 12, weight: .semibold))
            Text(cta.buttonTitle)
              .font(.custom("Figtree", size: 14))
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

  private var hasSubmittedTaskOptions: Bool {
    submittedTaskOptionsVersion == releaseNote.version
  }

  private var selectedTaskOptionsPayload: String {
    WhatsNewTaskOption.allCases
      .map(\.rawValue)
      .filter { selectedTaskOptionIDs.contains($0) }
      .joined(separator: ",")
  }

  private func toggleTaskOption(_ option: WhatsNewTaskOption) {
    let previousSelection = selectedTaskOptionIDs

    if selectedTaskOptionIDs.contains(option.rawValue) {
      selectedTaskOptionIDs.remove(option.rawValue)
    } else if option == .timeTrackingOnly {
      selectedTaskOptionIDs = [option.rawValue]
    } else {
      selectedTaskOptionIDs.insert(option.rawValue)
      selectedTaskOptionIDs.remove(WhatsNewTaskOption.timeTrackingOnly.rawValue)
    }

    persistSelectedTaskOptions()
    surveyErrorText = nil

    let selectedOptions = selectedTaskOptionsPayload
    guard !selectedOptions.isEmpty else {
      submittedTaskOptionsVersion = ""
      return
    }

    Task {
      if await submitReleaseSurvey(selectedOptions: selectedOptions) {
        submittedTaskOptionsVersion = releaseNote.version
      } else {
        selectedTaskOptionIDs = previousSelection
        persistSelectedTaskOptions()
      }
    }
  }

  private func persistSelectedTaskOptions() {
    let selectedOptions = WhatsNewTaskOption.allCases
      .map(\.rawValue)
      .filter { selectedTaskOptionIDs.contains($0) }
    UserDefaults.standard.set(selectedOptions, forKey: selectedTaskOptionsStorageKey)
  }

  private func hydrateSurveyStateIfNeeded() {
    let storedOptions =
      UserDefaults.standard.stringArray(forKey: selectedTaskOptionsStorageKey) ?? []
    selectedTaskOptionIDs = Set(storedOptions)
    releaseSurveyResponseID = loadReleaseSurveyResponseID()
  }

  private var selectedTaskOptionsStorageKey: String {
    "whatsNewTaskOptions_\(releaseSurveyKey)_\(releaseNote.version)"
  }

  private var releaseSurveyResponseIDStorageKey: String {
    "whatsNewReleaseSurveyResponseID_\(releaseSurveyKey)_\(releaseNote.version)"
  }

  private func loadReleaseSurveyResponseID() -> String {
    let defaults = UserDefaults.standard
    if let existing = defaults.string(forKey: releaseSurveyResponseIDStorageKey),
      !existing.isEmpty
    {
      return existing
    }

    let generated = UUID().uuidString.lowercased()
    defaults.set(generated, forKey: releaseSurveyResponseIDStorageKey)
    return generated
  }

  private func submitReleaseSurvey(selectedOptions: String) async -> Bool {
    isSubmittingTaskOptions = true

    defer {
      isSubmittingTaskOptions = false
    }

    do {
      let responseID =
        releaseSurveyResponseID.isEmpty
        ? loadReleaseSurveyResponseID() : releaseSurveyResponseID
      releaseSurveyResponseID = responseID
      try await ReleaseSurveyClient.submit(
        ReleaseSurveyPayload(
          responseID: responseID,
          surveyKey: releaseSurveyKey,
          version: releaseNote.version,
          proInterest: selectedOptions,
          proPrice: nil,
          appVersion: appVersion,
          analyticsOptIn: AnalyticsService.shared.isOptedIn,
          providerLabel: currentProviderLabel
        )
      )
      surveyErrorText = nil
      return true
    } catch {
      surveyErrorText = "Could not submit. Please try again."
      return false
    }
  }

  private var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? releaseNote.version
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

private struct ReleaseSurveyPayload: Encodable {
  let responseID: String
  let surveyKey: String
  let version: String
  let proInterest: String?
  let proPrice: String?
  let appVersion: String
  let analyticsOptIn: Bool
  let providerLabel: String

  enum CodingKeys: String, CodingKey {
    case responseID = "response_id"
    case surveyKey = "survey_key"
    case version
    case proInterest = "pro_interest"
    case proPrice = "pro_price"
    case appVersion = "app_version"
    case analyticsOptIn = "analytics_opt_in"
    case providerLabel = "provider_label"
  }
}

private enum ReleaseSurveyClient {
  private static let infoPlistEndpointKey = "DayflowBackendURL"
  private static let debugEndpointOverrideKey = "dayflowBackendURLOverride"

  static func submit(_ payload: ReleaseSurveyPayload) async throws {
    guard let url = releaseSurveyURL() else {
      throw URLError(.badURL)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(payload)

    let (_, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    else {
      throw URLError(.badServerResponse)
    }
  }

  private static func releaseSurveyURL() -> URL? {
    guard let endpoint = resolvedEndpoint() else { return nil }
    return URL(string: "\(endpoint)/v1/release-survey")
  }

  private static func resolvedEndpoint() -> String? {
    #if DEBUG
      if let override = UserDefaults.standard.string(forKey: debugEndpointOverrideKey)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !override.isEmpty
      {
        return override.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      }
    #endif

    if let infoEndpoint = Bundle.main.infoDictionary?[infoPlistEndpointKey] as? String {
      let trimmed = infoEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      }
    }

    #if DEBUG
      return "https://web-production-f3361.up.railway.app"
    #else
      return nil
    #endif
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
    textView.font = NSFont(name: "Figtree", size: fontSize) ?? .systemFont(ofSize: fontSize)
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
