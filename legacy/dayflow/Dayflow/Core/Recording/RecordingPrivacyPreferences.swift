import AppKit
import Foundation
@preconcurrency import ScreenCaptureKit

struct RecordingPrivacyApplication: Identifiable, Equatable, Sendable {
  let name: String
  let bundleIdentifier: String
  let appURL: URL?

  var id: String { bundleIdentifier }

  init(name: String, bundleIdentifier: String, appURL: URL? = nil) {
    self.name = name
    self.bundleIdentifier = bundleIdentifier
    self.appURL = appURL
  }
}

enum RecordingPrivacyPreferences {
  private static let blockedApplicationIdentifiersKey =
    "recordingPrivacyBlockedApplicationIdentifiers"
  private static let didSeedDefaultSecretAppsKey = "recordingPrivacyDidSeedDefaultSecretApps"

  private static let defaultSecretAppNames: Set<String> = [
    "1password",
    "authy",
    "bitwarden",
    "dashlane",
    "enpass",
    "keeper",
    "keepassxc",
    "keychain access",
    "lastpass",
    "ledger live",
    "nordpass",
    "passwords",
    "proton pass",
    "secrets",
    "trezor suite",
    "yubico authenticator",
  ]

  private static let defaultSecretBundleHints = [
    "1password",
    "authy",
    "bitwarden",
    "dashlane",
    "enpass",
    "keeper",
    "keepass",
    "keychainaccess",
    "lastpass",
    "ledger",
    "nordpass",
    "passwords",
    "protonpass",
    "secrets",
    "trezor",
    "yubico",
  ]

  static func blockedApplicationIdentifiers(defaults: UserDefaults = .standard) -> [String] {
    let stored = defaults.stringArray(forKey: blockedApplicationIdentifiersKey) ?? []
    return normalizedIdentifiers(from: stored)
  }

  static func blockedApplicationsText(defaults: UserDefaults = .standard) -> String {
    blockedApplicationIdentifiers(defaults: defaults).joined(separator: "\n")
  }

  static func saveBlockedApplicationsText(
    _ text: String,
    defaults: UserDefaults = .standard
  ) {
    saveBlockedApplicationIdentifiers(identifiers(from: text), defaults: defaults)
  }

  static func saveBlockedApplicationIdentifiers(
    _ identifiers: [String],
    defaults: UserDefaults = .standard
  ) {
    defaults.set(normalizedIdentifiers(from: identifiers), forKey: blockedApplicationIdentifiersKey)
  }

  static func seedDefaultSecretApplicationsIfNeeded(
    from applications: [RecordingPrivacyApplication],
    defaults: UserDefaults = .standard
  ) {
    guard !defaults.bool(forKey: didSeedDefaultSecretAppsKey) else { return }

    let defaultIdentifiers = defaultSecretApplicationIdentifiers(in: applications)
    if !defaultIdentifiers.isEmpty {
      saveBlockedApplicationIdentifiers(
        blockedApplicationIdentifiers(defaults: defaults) + defaultIdentifiers,
        defaults: defaults
      )
    }
    defaults.set(true, forKey: didSeedDefaultSecretAppsKey)
  }

  static func identifiers(from text: String) -> [String] {
    normalizedIdentifiers(from: text.components(separatedBy: .newlines))
  }

  static func isApplicationBlocked(
    bundleIdentifier: String?,
    applicationName: String?,
    defaults: UserDefaults = .standard
  ) -> Bool {
    let blocked = Set(blockedApplicationIdentifiers(defaults: defaults))
    guard !blocked.isEmpty else { return false }

    let candidates = [
      normalizedIdentifier(bundleIdentifier),
      normalizedIdentifier(applicationName),
    ].compactMap { $0 }

    return candidates.contains { blocked.contains($0) }
  }

  @MainActor
  static func frontmostBlockedApplication(
    defaults: UserDefaults = .standard
  ) -> RecordingPrivacyApplication? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    guard
      isApplicationBlocked(
        bundleIdentifier: app.bundleIdentifier,
        applicationName: app.localizedName,
        defaults: defaults
      )
    else {
      return nil
    }

    return RecordingPrivacyApplication(
      name: app.localizedName ?? app.bundleIdentifier ?? "Private app",
      bundleIdentifier: app.bundleIdentifier ?? app.localizedName ?? "private-app"
    )
  }

  static func blockedScreenCaptureApplications(
    in content: SCShareableContent,
    defaults: UserDefaults = .standard
  ) -> [SCRunningApplication] {
    content.applications.filter { app in
      isApplicationBlocked(
        bundleIdentifier: app.bundleIdentifier,
        applicationName: app.applicationName,
        defaults: defaults
      )
    }
  }

  @MainActor
  static func runningApplications() -> [RecordingPrivacyApplication] {
    let apps = NSWorkspace.shared.runningApplications.compactMap {
      app -> RecordingPrivacyApplication? in
      guard app.activationPolicy == .regular else { return nil }
      guard let bundleIdentifier = app.bundleIdentifier, !bundleIdentifier.isEmpty else {
        return nil
      }

      return RecordingPrivacyApplication(
        name: app.localizedName ?? bundleIdentifier,
        bundleIdentifier: bundleIdentifier
      )
    }

    var seen = Set<String>()
    return
      apps
      .filter { app in
        let key = normalizedIdentifier(app.bundleIdentifier) ?? app.bundleIdentifier
        return seen.insert(key).inserted
      }
      .sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
  }

  static func installedApplications() -> [RecordingPrivacyApplication] {
    let fileManager = FileManager.default
    let roots = applicationSearchRoots(fileManager: fileManager)
    var apps: [RecordingPrivacyApplication] = []

    for root in roots {
      guard
        let enumerator = fileManager.enumerator(
          at: root,
          includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
          options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
      else {
        continue
      }

      for case let url as URL in enumerator {
        guard url.pathExtension == "app" else { continue }
        enumerator.skipDescendants()

        guard let app = installedApplication(from: url) else { continue }
        apps.append(app)
      }
    }

    var seen = Set<String>()
    return
      apps
      .filter { app in
        let key = normalizedIdentifier(app.bundleIdentifier) ?? app.bundleIdentifier
        return seen.insert(key).inserted
      }
      .sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
  }

  static func defaultSecretApplicationIdentifiers(
    in applications: [RecordingPrivacyApplication]
  ) -> [String] {
    applications.compactMap { app in
      let name = normalizedIdentifier(app.name) ?? ""
      let compactBundle = (normalizedIdentifier(app.bundleIdentifier) ?? "")
        .replacingOccurrences(of: ".", with: "")
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: "_", with: "")

      if defaultSecretAppNames.contains(name) {
        return app.bundleIdentifier
      }
      if defaultSecretBundleHints.contains(where: { compactBundle.contains($0) }) {
        return app.bundleIdentifier
      }
      return nil
    }
  }

  private static func normalizedIdentifiers(from values: [String]) -> [String] {
    var seen = Set<String>()
    return values.compactMap { value in
      guard let normalized = normalizedIdentifier(value) else { return nil }
      return seen.insert(normalized).inserted ? normalized : nil
    }
  }

  private static func normalizedIdentifier(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else {
      return nil
    }
    return trimmed.lowercased()
  }

  private static func applicationSearchRoots(fileManager: FileManager) -> [URL] {
    let paths = [
      "/Applications",
      "/System/Applications",
      NSHomeDirectory() + "/Applications",
    ]

    var seen = Set<String>()
    return paths.compactMap { path in
      let url = URL(fileURLWithPath: path, isDirectory: true)
      guard fileManager.fileExists(atPath: url.path) else { return nil }
      let standardizedPath = url.standardizedFileURL.path
      return seen.insert(standardizedPath).inserted ? url : nil
    }
  }

  private static func installedApplication(from url: URL) -> RecordingPrivacyApplication? {
    guard let bundle = Bundle(url: url),
      let bundleIdentifier = bundle.bundleIdentifier,
      !bundleIdentifier.isEmpty
    else {
      return nil
    }

    let displayName =
      bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
      ?? bundle.localizedInfoDictionary?["CFBundleName"] as? String
      ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
      ?? bundle.infoDictionary?["CFBundleName"] as? String
      ?? url.deletingPathExtension().lastPathComponent

    return RecordingPrivacyApplication(
      name: displayName,
      bundleIdentifier: bundleIdentifier,
      appURL: url
    )
  }
}
