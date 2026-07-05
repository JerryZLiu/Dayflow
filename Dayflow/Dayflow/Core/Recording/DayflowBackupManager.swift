import Foundation
import GRDB

struct DayflowBackupSummary: Sendable {
  let packageURL: URL
  let createdAt: Date
  let sizeBytes: Int64
  let includesRecordings: Bool
  let includesTimelapses: Bool
  let includesPreferences: Bool
}

enum DayflowBackupManager {
  static let backupFileExtension = "dayflowbackup"

  private static let formatVersion = 1
  private static let manifestFilename = "manifest.json"
  private static let preferencesFilename = "preferences.json"
  private static let dataDirectoryName = "data"
  private static let databaseFilename = "chunks.sqlite"
  private static let recordingsDirectoryName = "recordings"
  private static let timelapsesDirectoryName = "timelapses"
  private static let backupsDirectoryName = "backups"
  private static let pendingRestoreName = "Dayflow.pending-restore.dayflowbackup"
  private static let restoreBackupsDirectoryName = "Dayflow.restore-backups"

  static func defaultBackupFilename(now: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HH-mm"
    return "Dayflow backup \(formatter.string(from: now)).\(backupFileExtension)"
  }

  static func dayflowBaseDirectory(fileManager: FileManager = .default) -> URL {
    fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Dayflow", isDirectory: true)
  }

  static func exportBackup(to requestedURL: URL) throws -> DayflowBackupSummary {
    let fileManager = FileManager.default
    let packageURL = normalizedPackageURL(requestedURL)
    try validateExportDestination(packageURL, fileManager: fileManager)

    let dataURL = packageURL.appendingPathComponent(dataDirectoryName, isDirectory: true)
    let databaseURL = dataURL.appendingPathComponent(databaseFilename)
    let recordingsSourceURL = StorageManager.shared.recordingsRoot
    let timelapsesSourceURL = TimelapseStorageManager.shared.rootURL
    let recordingsDestinationURL = dataURL.appendingPathComponent(
      recordingsDirectoryName,
      isDirectory: true
    )
    let timelapsesDestinationURL = dataURL.appendingPathComponent(
      timelapsesDirectoryName,
      isDirectory: true
    )
    let preferencesURL = packageURL.appendingPathComponent(preferencesFilename)

    if fileManager.fileExists(atPath: packageURL.path) {
      try fileManager.removeItem(at: packageURL)
    }

    do {
      try fileManager.createDirectory(at: dataURL, withIntermediateDirectories: true)

      do {
        let destinationDatabase = try DatabaseQueue(path: databaseURL.path)
        try StorageManager.shared.db.backup(to: destinationDatabase)
      }

      let includesRecordings = fileManager.fileExists(atPath: recordingsSourceURL.path)
      if includesRecordings {
        try fileManager.copyItem(at: recordingsSourceURL, to: recordingsDestinationURL)
      }

      let includesTimelapses = fileManager.fileExists(atPath: timelapsesSourceURL.path)
      if includesTimelapses {
        try fileManager.copyItem(at: timelapsesSourceURL, to: timelapsesDestinationURL)
      }

      let preferences = DayflowPreferencesBackup.capture()
      try preferences.write(to: preferencesURL)

      let createdAt = Date()
      let manifest = DayflowBackupManifest(
        formatVersion: formatVersion,
        createdAt: createdAt,
        appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
        buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
        includesRecordings: includesRecordings,
        includesTimelapses: includesTimelapses,
        includesPreferences: true
      )
      try manifest.write(to: packageURL.appendingPathComponent(manifestFilename))

      return DayflowBackupSummary(
        packageURL: packageURL,
        createdAt: createdAt,
        sizeBytes: (try? fileManager.allocatedSizeOfDirectory(at: packageURL)) ?? 0,
        includesRecordings: includesRecordings,
        includesTimelapses: includesTimelapses,
        includesPreferences: true
      )
    } catch {
      try? fileManager.removeItem(at: packageURL)
      throw error
    }
  }

  static func stageRestorePackage(from packageURL: URL) throws -> DayflowBackupSummary {
    let fileManager = FileManager.default
    let manifest = try readManifest(from: packageURL)
    try validateBackupPackage(at: packageURL, manifest: manifest)

    let pendingURL = pendingRestoreURL(fileManager: fileManager)
    if fileManager.fileExists(atPath: pendingURL.path) {
      try fileManager.removeItem(at: pendingURL)
    }

    try fileManager.copyItem(at: packageURL, to: pendingURL)

    return DayflowBackupSummary(
      packageURL: pendingURL,
      createdAt: manifest.createdAt,
      sizeBytes: (try? fileManager.allocatedSizeOfDirectory(at: pendingURL)) ?? 0,
      includesRecordings: manifest.includesRecordings,
      includesTimelapses: manifest.includesTimelapses,
      includesPreferences: manifest.includesPreferences
    )
  }

  @discardableResult
  static func applyPendingRestoreIfNeeded(fileManager: FileManager = .default) -> Bool {
    let pendingURL = pendingRestoreURL(fileManager: fileManager)
    guard fileManager.fileExists(atPath: pendingURL.path) else { return false }

    do {
      try restoreBackupPackage(at: pendingURL, fileManager: fileManager)
      try? fileManager.removeItem(at: pendingURL)
      print("[DayflowBackupManager] Pending restore applied")
      return true
    } catch {
      print("[DayflowBackupManager] Pending restore failed: \(error)")
      quarantineFailedPendingRestore(at: pendingURL, fileManager: fileManager)
      return false
    }
  }

  private static func restoreBackupPackage(at packageURL: URL, fileManager: FileManager) throws {
    let manifest = try readManifest(from: packageURL)
    try validateBackupPackage(at: packageURL, manifest: manifest)

    let baseURL = dayflowBaseDirectory(fileManager: fileManager)
    let supportURL = baseURL.deletingLastPathComponent()
    let restoreBackupsURL = supportURL.appendingPathComponent(
      restoreBackupsDirectoryName,
      isDirectory: true
    )
    try fileManager.createDirectory(at: restoreBackupsURL, withIntermediateDirectories: true)

    let safetyBackupURL = restoreBackupsURL.appendingPathComponent(
      "Dayflow-before-restore-\(timestampString())",
      isDirectory: true
    )

    let hadExistingData = fileManager.fileExists(atPath: baseURL.path)
    if hadExistingData {
      try fileManager.moveItem(at: baseURL, to: safetyBackupURL)
    }

    do {
      try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
      try restoreDatabase(from: packageURL, to: baseURL, fileManager: fileManager)
      try restoreOptionalDirectory(
        named: recordingsDirectoryName,
        from: packageURL,
        to: baseURL,
        fileManager: fileManager
      )
      try restoreOptionalDirectory(
        named: timelapsesDirectoryName,
        from: packageURL,
        to: baseURL,
        fileManager: fileManager
      )
      try fileManager.createDirectory(
        at: baseURL.appendingPathComponent(backupsDirectoryName, isDirectory: true),
        withIntermediateDirectories: true
      )
      try restorePreferencesIfPresent(from: packageURL)
    } catch {
      try? fileManager.removeItem(at: baseURL)
      if hadExistingData, fileManager.fileExists(atPath: safetyBackupURL.path) {
        try? fileManager.moveItem(at: safetyBackupURL, to: baseURL)
      }
      throw error
    }
  }

  private static func restoreDatabase(
    from packageURL: URL,
    to baseURL: URL,
    fileManager: FileManager
  ) throws {
    let source = packageURL
      .appendingPathComponent(dataDirectoryName, isDirectory: true)
      .appendingPathComponent(databaseFilename)
    let destination = baseURL.appendingPathComponent(databaseFilename)
    try fileManager.copyItem(at: source, to: destination)
  }

  private static func restoreOptionalDirectory(
    named name: String,
    from packageURL: URL,
    to baseURL: URL,
    fileManager: FileManager
  ) throws {
    let source = packageURL
      .appendingPathComponent(dataDirectoryName, isDirectory: true)
      .appendingPathComponent(name, isDirectory: true)
    let destination = baseURL.appendingPathComponent(name, isDirectory: true)

    if fileManager.fileExists(atPath: source.path) {
      try fileManager.copyItem(at: source, to: destination)
    } else {
      try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    }
  }

  private static func restorePreferencesIfPresent(from packageURL: URL) throws {
    let preferencesURL = packageURL.appendingPathComponent(preferencesFilename)
    guard FileManager.default.fileExists(atPath: preferencesURL.path) else { return }
    let preferences = try DayflowPreferencesBackup(contentsOf: preferencesURL)
    preferences.apply()
    UserDefaultsMigrator.migrateIfNeeded()
  }

  private static func validateBackupPackage(
    at packageURL: URL,
    manifest: DayflowBackupManifest
  ) throws {
    guard manifest.formatVersion <= formatVersion else {
      throw BackupError.unsupportedVersion(manifest.formatVersion)
    }

    let databaseURL = packageURL
      .appendingPathComponent(dataDirectoryName, isDirectory: true)
      .appendingPathComponent(databaseFilename)
    guard FileManager.default.fileExists(atPath: databaseURL.path) else {
      throw BackupError.missingDatabase
    }
  }

  private static func readManifest(from packageURL: URL) throws -> DayflowBackupManifest {
    let manifestURL = packageURL.appendingPathComponent(manifestFilename)
    guard FileManager.default.fileExists(atPath: manifestURL.path) else {
      throw BackupError.missingManifest
    }
    return try DayflowBackupManifest(contentsOf: manifestURL)
  }

  private static func normalizedPackageURL(_ url: URL) -> URL {
    url.pathExtension == backupFileExtension
      ? url : url.appendingPathExtension(backupFileExtension)
  }

  private static func validateExportDestination(
    _ packageURL: URL,
    fileManager: FileManager
  ) throws {
    let packagePath = packageURL.standardizedFileURL.path
    let basePath = dayflowBaseDirectory(fileManager: fileManager).standardizedFileURL.path
    if packagePath == basePath || packagePath.hasPrefix(basePath + "/") {
      throw BackupError.destinationInsideDataDirectory
    }
  }

  private static func pendingRestoreURL(fileManager: FileManager) -> URL {
    dayflowBaseDirectory(fileManager: fileManager)
      .deletingLastPathComponent()
      .appendingPathComponent(pendingRestoreName, isDirectory: true)
  }

  private static func quarantineFailedPendingRestore(at pendingURL: URL, fileManager: FileManager) {
    let failedURL = pendingURL
      .deletingLastPathComponent()
      .appendingPathComponent("Dayflow.failed-restore-\(timestampString()).dayflowbackup")
    try? fileManager.removeItem(at: failedURL)
    try? fileManager.moveItem(at: pendingURL, to: failedURL)
  }

  private static func timestampString(date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    return formatter.string(from: date)
  }
}

private struct DayflowBackupManifest: Codable {
  let formatVersion: Int
  let createdAt: Date
  let appVersion: String?
  let buildNumber: String?
  let includesRecordings: Bool
  let includesTimelapses: Bool
  let includesPreferences: Bool

  init(
    formatVersion: Int,
    createdAt: Date,
    appVersion: String?,
    buildNumber: String?,
    includesRecordings: Bool,
    includesTimelapses: Bool,
    includesPreferences: Bool
  ) {
    self.formatVersion = formatVersion
    self.createdAt = createdAt
    self.appVersion = appVersion
    self.buildNumber = buildNumber
    self.includesRecordings = includesRecordings
    self.includesTimelapses = includesTimelapses
    self.includesPreferences = includesPreferences
  }

  init(contentsOf url: URL) throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self = try decoder.decode(Self.self, from: Data(contentsOf: url))
  }

  func write(to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(self).write(to: url, options: .atomic)
  }
}

private struct DayflowPreferencesBackup: Codable {
  let values: [String: PreferenceValue]

  static func capture(defaults: UserDefaults = .standard) -> Self {
    var values: [String: PreferenceValue] = [:]
    for key in safePreferenceKeys {
      guard let value = PreferenceValue(defaultsObject: defaults.object(forKey: key)) else {
        continue
      }
      values[key] = value
    }
    return Self(values: values)
  }

  init(values: [String: PreferenceValue]) {
    self.values = values
  }

  init(contentsOf url: URL) throws {
    self = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
  }

  func write(to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(self).write(to: url, options: .atomic)
  }

  func apply(defaults: UserDefaults = .standard) {
    for (key, value) in values {
      value.apply(to: defaults, key: key)
    }
  }

  private static let safePreferenceKeys: Set<String> = [
    DayGoalPreferences.showDailyGoalPopupsKey,
    TimelapsePreferences.saveAllTimelapsesToDiskKey,
    "colorCategories",
    "dashboardChatMemoryBlob",
    "dashboardChatMemoryUpdatedAt",
    "didOnboard",
    "hasUsedApp",
    "hasCompletedJournalOnboarding",
    "idleResetMinutes",
    "idleResetSecondsOverride",
    "isDailyUnlocked",
    "isJournalUnlocked",
    "isRecording",
    "lastSeenWhatsNewVersion",
    "llmOutputLanguageOverride",
    "onboardingAppliedCategoryPreset",
    "onboardingCategoriesCustomized",
    "onboardingHasPaidAI",
    "onboardingSelectedRole",
    "onboardingStarted",
    "onboardingStep",
    "recordingPrivacyBlockedApplicationIdentifiers",
    "recordingPrivacyDidSeedDefaultSecretApps",
    "screenshotIntervalSeconds",
    "showDockIcon",
    "showTimelineAppIcons",
    "storageLimitRecordingsBytes",
    "storageLimitTimelapsesBytes",
    "weeklyAccessManuallyLocked",
  ]
}

private struct PreferenceValue: Codable {
  let type: String
  let stringValue: String?
  let boolValue: Bool?
  let intValue: Int?
  let doubleValue: Double?
  let stringArrayValue: [String]?
  let dataBase64Value: String?
  let dateValue: Date?

  init?(defaultsObject object: Any?) {
    guard let object else { return nil }

    switch object {
    case let value as String:
      type = "string"
      stringValue = value
      boolValue = nil
      intValue = nil
      doubleValue = nil
      stringArrayValue = nil
      dataBase64Value = nil
      dateValue = nil
    case let value as Bool:
      type = "bool"
      stringValue = nil
      boolValue = value
      intValue = nil
      doubleValue = nil
      stringArrayValue = nil
      dataBase64Value = nil
      dateValue = nil
    case let value as Int:
      type = "int"
      stringValue = nil
      boolValue = nil
      intValue = value
      doubleValue = nil
      stringArrayValue = nil
      dataBase64Value = nil
      dateValue = nil
    case let value as Double:
      type = "double"
      stringValue = nil
      boolValue = nil
      intValue = nil
      doubleValue = value
      stringArrayValue = nil
      dataBase64Value = nil
      dateValue = nil
    case let value as [String]:
      type = "stringArray"
      stringValue = nil
      boolValue = nil
      intValue = nil
      doubleValue = nil
      stringArrayValue = value
      dataBase64Value = nil
      dateValue = nil
    case let value as Data:
      type = "data"
      stringValue = nil
      boolValue = nil
      intValue = nil
      doubleValue = nil
      stringArrayValue = nil
      dataBase64Value = value.base64EncodedString()
      dateValue = nil
    case let value as Date:
      type = "date"
      stringValue = nil
      boolValue = nil
      intValue = nil
      doubleValue = nil
      stringArrayValue = nil
      dataBase64Value = nil
      dateValue = value
    case let value as NSNumber:
      let numberType = String(cString: value.objCType)
      if numberType == "c" {
        type = "bool"
        stringValue = nil
        boolValue = value.boolValue
        intValue = nil
        doubleValue = nil
        stringArrayValue = nil
        dataBase64Value = nil
        dateValue = nil
      } else if numberType == "f" || numberType == "d" {
        type = "double"
        stringValue = nil
        boolValue = nil
        intValue = nil
        doubleValue = value.doubleValue
        stringArrayValue = nil
        dataBase64Value = nil
        dateValue = nil
      } else {
        type = "int"
        stringValue = nil
        boolValue = nil
        intValue = value.intValue
        doubleValue = nil
        stringArrayValue = nil
        dataBase64Value = nil
        dateValue = nil
      }
    default:
      return nil
    }
  }

  func apply(to defaults: UserDefaults, key: String) {
    switch type {
    case "string":
      defaults.set(stringValue, forKey: key)
    case "bool":
      defaults.set(boolValue ?? false, forKey: key)
    case "int":
      defaults.set(intValue ?? 0, forKey: key)
    case "double":
      defaults.set(doubleValue ?? 0, forKey: key)
    case "stringArray":
      defaults.set(stringArrayValue ?? [], forKey: key)
    case "data":
      if let dataBase64Value, let data = Data(base64Encoded: dataBase64Value) {
        defaults.set(data, forKey: key)
      }
    case "date":
      defaults.set(dateValue, forKey: key)
    default:
      break
    }
  }
}

private enum BackupError: LocalizedError {
  case destinationInsideDataDirectory
  case missingManifest
  case missingDatabase
  case unsupportedVersion(Int)

  var errorDescription: String? {
    switch self {
    case .destinationInsideDataDirectory:
      return "Choose a backup location outside Dayflow's Application Support data folder."
    case .missingManifest:
      return "This does not look like a Dayflow backup. The manifest is missing."
    case .missingDatabase:
      return "This Dayflow backup is missing its timeline database."
    case .unsupportedVersion(let version):
      return "This backup was created by a newer Dayflow backup format (\(version))."
    }
  }
}
