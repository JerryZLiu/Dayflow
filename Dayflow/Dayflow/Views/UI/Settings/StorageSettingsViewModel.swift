import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor
final class StorageSettingsViewModel: ObservableObject {
  @Published var isRefreshingStorage = false
  @Published var storagePermissionGranted: Bool?
  @Published var lastStorageCheck: Date?
  @Published var macRecordingsUsageBytes: Int64 = 0
  @Published var androidRecordingsUsageBytes: Int64 = 0
  @Published var timelapseUsageBytes: Int64 = 0
  @Published var macRecordingsLimitBytes: Int64
  @Published var androidRecordingsLimitBytes: Int64
  @Published var timelapsesLimitBytes: Int64
  @Published var macRecordingsLimitIndex: Int
  @Published var androidRecordingsLimitIndex: Int
  @Published var timelapsesLimitIndex: Int
  @Published var showLimitConfirmation = false
  @Published var pendingLimit: PendingLimit?

  let usageFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useMB, .useGB]
    formatter.countStyle = .file
    return formatter
  }()

  init() {
    let recordingsLimit = StoragePreferences.recordingsLimitBytes
    let androidRecordingsLimit = StoragePreferences.androidRecordingsLimitBytes
    let timelapseLimit = StoragePreferences.timelapsesLimitBytes

    macRecordingsLimitBytes = recordingsLimit
    androidRecordingsLimitBytes = androidRecordingsLimit
    timelapsesLimitBytes = timelapseLimit
    macRecordingsLimitIndex = Self.indexForLimit(recordingsLimit)
    androidRecordingsLimitIndex = Self.indexForLimit(androidRecordingsLimit)
    timelapsesLimitIndex = Self.indexForLimit(timelapseLimit)
  }

  func refreshStorageIfNeeded(isStorageTab: Bool) {
    if storagePermissionGranted == nil && isStorageTab {
      refreshStorageMetrics()
    }
  }

  func runStorageStatusCheck() {
    guard !isRefreshingStorage else { return }
    isRefreshingStorage = true

    let group = DispatchGroup()
    group.enter()
    StorageManager.shared.purgeNow {
      group.leave()
    }
    group.enter()
    TimelapseStorageManager.shared.purgeNow {
      group.leave()
    }
    group.notify(queue: .main) { [weak self] in
      self?.refreshStorageMetrics(force: true)
    }
  }

  func refreshStorageMetrics(force: Bool = false) {
    if !force {
      guard !isRefreshingStorage else { return }
    }
    if !isRefreshingStorage {
      isRefreshingStorage = true
    }

    Task.detached(priority: .utility) { [weak self] in
      let permission = CGPreflightScreenCaptureAccess()
      let macRecordingsSize = StorageManager.shared.recordingUsageBytes(for: .macOS)
      let androidRecordingsSize = StorageManager.shared.recordingUsageBytes(for: .android)
      let timelapseSize = TimelapseStorageManager.shared.currentUsageBytes()

      await MainActor.run {
        guard let self else { return }
        self.storagePermissionGranted = permission
        self.macRecordingsUsageBytes = macRecordingsSize
        self.androidRecordingsUsageBytes = androidRecordingsSize
        self.timelapseUsageBytes = timelapseSize
        self.lastStorageCheck = Date()
        self.isRefreshingStorage = false

        let recordingsLimit = StoragePreferences.recordingsLimitBytes
        let androidRecordingsLimit = StoragePreferences.androidRecordingsLimitBytes
        let timelapseLimit = StoragePreferences.timelapsesLimitBytes
        self.macRecordingsLimitBytes = recordingsLimit
        self.androidRecordingsLimitBytes = androidRecordingsLimit
        self.timelapsesLimitBytes = timelapseLimit
        self.macRecordingsLimitIndex = Self.indexForLimit(recordingsLimit)
        self.androidRecordingsLimitIndex = Self.indexForLimit(androidRecordingsLimit)
        self.timelapsesLimitIndex = Self.indexForLimit(timelapseLimit)
      }
    }
  }

  func storageFooterText() -> String {
    let macText = limitDescription(macRecordingsLimitBytes)
    let androidText = limitDescription(androidRecordingsLimitBytes)
    let timelapsesText =
      timelapsesLimitBytes == Int64.max
      ? "Unlimited" : usageFormatter.string(fromByteCount: timelapsesLimitBytes)
    return
      "Mac cap: \(macText) • Android cap: \(androidText) • Timelapse cap: \(timelapsesText). Lowering a cap immediately deletes the oldest files for that type. Timeline card text stays preserved. Please avoid deleting files manually so you do not remove Dayflow's database."
  }

  func handleLimitSelection(for category: StorageCategory, index: Int) {
    guard Self.storageOptions.indices.contains(index) else { return }
    let newBytes = Self.storageOptions[index].resolvedBytes
    let currentBytes = limitBytes(for: category)
    guard newBytes != currentBytes else { return }

    if newBytes < currentBytes {
      pendingLimit = PendingLimit(category: category, index: index)
      showLimitConfirmation = true
    } else {
      applyLimit(for: category, index: index)
    }
  }

  func applyLimit(for category: StorageCategory, index: Int) {
    guard Self.storageOptions.indices.contains(index) else { return }
    let option = Self.storageOptions[index]
    let newBytes = option.resolvedBytes
    let previousBytes = limitBytes(for: category)

    switch category {
    case .macRecordings:
      StorageManager.shared.updateStorageLimit(bytes: newBytes, platform: .macOS)
      macRecordingsLimitBytes = newBytes
      macRecordingsLimitIndex = index
    case .androidRecordings:
      StorageManager.shared.updateStorageLimit(bytes: newBytes, platform: .android)
      androidRecordingsLimitBytes = newBytes
      androidRecordingsLimitIndex = index
    case .timelapses:
      TimelapseStorageManager.shared.updateLimit(bytes: newBytes)
      timelapsesLimitBytes = newBytes
      timelapsesLimitIndex = index
    }

    pendingLimit = nil
    showLimitConfirmation = false

    AnalyticsService.shared.capture(
      "storage_limit_changed",
      [
        "category": category.analyticsKey,
        "previous_limit_bytes": previousBytes,
        "new_limit_bytes": newBytes,
      ])

    refreshStorageMetrics()
  }

  func openRecordingsFolder() {
    let url = StorageManager.shared.recordingsRoot
    ensureDirectoryExists(url)
    NSWorkspace.shared.open(url)
  }

  func openTimelapseFolder() {
    let url = TimelapseStorageManager.shared.rootURL
    ensureDirectoryExists(url)
    NSWorkspace.shared.open(url)
  }

  private func ensureDirectoryExists(_ url: URL) {
    do {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
      print("⚠️ Failed to ensure directory exists at \(url.path): \(error)")
    }
  }

  private func limitBytes(for category: StorageCategory) -> Int64 {
    switch category {
    case .macRecordings: return macRecordingsLimitBytes
    case .androidRecordings: return androidRecordingsLimitBytes
    case .timelapses: return timelapsesLimitBytes
    }
  }

  private func limitDescription(_ bytes: Int64) -> String {
    bytes == Int64.max ? "Unlimited" : usageFormatter.string(fromByteCount: bytes)
  }

  private static func indexForLimit(_ bytes: Int64) -> Int {
    if bytes >= Int64.max {
      return storageOptions.count - 1
    }
    if let exact = storageOptions.firstIndex(where: { $0.resolvedBytes == bytes }) {
      return exact
    }
    for option in storageOptions where option.bytes != nil {
      if bytes <= option.resolvedBytes {
        return option.id
      }
    }
    return storageOptions.count - 1
  }

  static let storageOptions: [StorageLimitOption] = [
    StorageLimitOption(id: 0, label: "1 GB", bytes: 1_000_000_000),
    StorageLimitOption(id: 1, label: "2 GB", bytes: 2_000_000_000),
    StorageLimitOption(id: 2, label: "3 GB", bytes: 3_000_000_000),
    StorageLimitOption(id: 3, label: "5 GB", bytes: 5_000_000_000),
    StorageLimitOption(id: 4, label: "10 GB", bytes: 10_000_000_000),
    StorageLimitOption(id: 5, label: "20 GB", bytes: 20_000_000_000),
    StorageLimitOption(id: 6, label: "Unlimited", bytes: nil),
  ]
}

struct StorageLimitOption: Identifiable {
  let id: Int
  let label: String
  let bytes: Int64?

  var resolvedBytes: Int64 { bytes ?? Int64.max }
  var shortLabel: String {
    if bytes == nil { return "∞" }
    return label.replacingOccurrences(of: " GB", with: "")
  }
}

enum StorageCategory {
  case macRecordings
  case androidRecordings
  case timelapses

  var analyticsKey: String {
    switch self {
    case .macRecordings: return "mac_recordings"
    case .androidRecordings: return "android_recordings"
    case .timelapses: return "timelapses"
    }
  }

  var displayName: String {
    switch self {
    case .macRecordings: return "Mac recordings"
    case .androidRecordings: return "Android recordings"
    case .timelapses: return "Timelapses"
    }
  }
}

struct PendingLimit {
  let category: StorageCategory
  let index: Int
}
