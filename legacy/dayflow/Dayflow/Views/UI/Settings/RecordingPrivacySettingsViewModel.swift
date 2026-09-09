import Foundation

@MainActor
final class RecordingPrivacySettingsViewModel: ObservableObject {
  @Published var searchText = ""
  @Published private(set) var installedApplications: [RecordingPrivacyApplication] = []
  @Published private(set) var blockedIdentifiers: [String]
  @Published private(set) var isLoadingApplications = false

  init() {
    blockedIdentifiers = RecordingPrivacyPreferences.blockedApplicationIdentifiers()
  }

  var filteredApplications: [RecordingPrivacyApplication] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return installedApplications }

    return installedApplications.filter { app in
      app.name.lowercased().contains(query)
        || app.bundleIdentifier.lowercased().contains(query)
    }
  }

  var blockedApplications: [RecordingPrivacyApplication] {
    let appsByIdentifier = Dictionary(
      uniqueKeysWithValues: installedApplications.map {
        (Self.normalizedIdentifier($0.bundleIdentifier), $0)
      }
    )

    return blockedIdentifiers.map { identifier in
      appsByIdentifier[Self.normalizedIdentifier(identifier)]
        ?? RecordingPrivacyApplication(
          name: Self.displayName(forMissingIdentifier: identifier),
          bundleIdentifier: identifier
        )
    }
  }

  func handleOnAppear() {
    loadInstalledApplicationsIfNeeded()
  }

  func loadInstalledApplicationsIfNeeded() {
    guard installedApplications.isEmpty, !isLoadingApplications else { return }
    isLoadingApplications = true

    Task {
      let applications = await Task.detached(priority: .utility) {
        RecordingPrivacyPreferences.installedApplications()
      }.value

      RecordingPrivacyPreferences.seedDefaultSecretApplicationsIfNeeded(from: applications)
      installedApplications = applications
      blockedIdentifiers = RecordingPrivacyPreferences.blockedApplicationIdentifiers()
      isLoadingApplications = false
    }
  }

  func isBlocked(_ app: RecordingPrivacyApplication) -> Bool {
    blockedIdentifierSet.contains(Self.normalizedIdentifier(app.bundleIdentifier))
  }

  func toggleBlocked(_ app: RecordingPrivacyApplication) {
    if isBlocked(app) {
      removeBlockedApplication(app)
    } else {
      addBlockedApplication(app)
    }
  }

  func addBlockedApplication(_ app: RecordingPrivacyApplication) {
    addBlockedIdentifier(app.bundleIdentifier)
  }

  func removeBlockedApplication(_ app: RecordingPrivacyApplication) {
    let identifier = Self.normalizedIdentifier(app.bundleIdentifier)
    blockedIdentifiers.removeAll { Self.normalizedIdentifier($0) == identifier }
    saveBlockedIdentifiers()
  }

  func clearBlockedApplications() {
    guard !blockedIdentifiers.isEmpty else { return }
    blockedIdentifiers = []
    saveBlockedIdentifiers()
  }

  func handleApplicationDrop(providers: [NSItemProvider]) -> Bool {
    for provider in providers where provider.canLoadObject(ofClass: NSString.self) {
      provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
        guard let identifier = object as? String else { return }
        Task { @MainActor in
          self?.addBlockedIdentifier(identifier)
        }
      }
      return true
    }

    return false
  }

  private var blockedIdentifierSet: Set<String> {
    Set(blockedIdentifiers.map(Self.normalizedIdentifier))
  }

  private func addBlockedIdentifier(_ identifier: String) {
    let normalized = Self.normalizedIdentifier(identifier)
    guard !normalized.isEmpty else { return }
    guard !blockedIdentifierSet.contains(normalized) else { return }
    blockedIdentifiers.append(normalized)
    saveBlockedIdentifiers()
  }

  private func saveBlockedIdentifiers() {
    RecordingPrivacyPreferences.saveBlockedApplicationIdentifiers(blockedIdentifiers)
    blockedIdentifiers = RecordingPrivacyPreferences.blockedApplicationIdentifiers()

    AnalyticsService.shared.capture(
      "recording_privacy_rules_saved",
      ["blocked_app_count": blockedIdentifiers.count]
    )
  }

  private static func normalizedIdentifier(_ identifier: String) -> String {
    identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private static func displayName(forMissingIdentifier identifier: String) -> String {
    identifier
      .split(separator: ".")
      .last
      .map(String.init)?
      .replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "_", with: " ")
      .capitalized
      ?? identifier
  }
}
