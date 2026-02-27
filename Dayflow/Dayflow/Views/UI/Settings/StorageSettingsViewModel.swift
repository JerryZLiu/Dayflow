import AppKit
import Combine
import Foundation
import ScreenCaptureKit

@MainActor
final class StorageSettingsViewModel: ObservableObject {
    @Published var isRefreshingStorage = false
    @Published var storagePermissionGranted: Bool?
    @Published var lastStorageCheck: Date?
    @Published var recordingsUsageBytes: Int64 = 0
    @Published var timelapseUsageBytes: Int64 = 0
    @Published var recordingsLimitBytes: Int64
    @Published var timelapsesLimitBytes: Int64
    @Published var recordingsLimitIndex: Int
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
        let timelapseLimit = StoragePreferences.timelapsesLimitBytes

        recordingsLimitBytes = recordingsLimit
        timelapsesLimitBytes = timelapseLimit
        recordingsLimitIndex = Self.indexForLimit(recordingsLimit)
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
            let permission: Bool
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                permission = true
            } catch {
                permission = false
            }
            let recordingsURL = StorageManager.shared.recordingsRoot

            let recordingsSize = StorageSettingsViewModel.directorySize(at: recordingsURL)
            let timelapseSize = TimelapseStorageManager.shared.currentUsageBytes()

            await MainActor.run {
                guard let self else { return }
                self.storagePermissionGranted = permission
                self.recordingsUsageBytes = recordingsSize
                self.timelapseUsageBytes = timelapseSize
                self.lastStorageCheck = Date()
                self.isRefreshingStorage = false

                let recordingsLimit = StoragePreferences.recordingsLimitBytes
                let timelapseLimit = StoragePreferences.timelapsesLimitBytes
                self.recordingsLimitBytes = recordingsLimit
                self.timelapsesLimitBytes = timelapseLimit
                self.recordingsLimitIndex = Self.indexForLimit(recordingsLimit)
                self.timelapsesLimitIndex = Self.indexForLimit(timelapseLimit)
            }
        }
    }

    func storageFooterText() -> String {
        let recordingsText = recordingsLimitBytes == Int64.max ? "Unlimited" : usageFormatter.string(fromByteCount: recordingsLimitBytes)
        let timelapsesText = timelapsesLimitBytes == Int64.max ? "Unlimited" : usageFormatter.string(fromByteCount: timelapsesLimitBytes)
        return "Recording cap: \(recordingsText) • Timelapse cap: \(timelapsesText). Lowering a cap immediately deletes the oldest files for that type. Timeline card text stays preserved. Please avoid deleting files manually so you do not remove Dayflow's database."
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
        case .recordings:
            StorageManager.shared.updateStorageLimit(bytes: newBytes)
            recordingsLimitBytes = newBytes
            recordingsLimitIndex = index
        case .timelapses:
            TimelapseStorageManager.shared.updateLimit(bytes: newBytes)
            timelapsesLimitBytes = newBytes
            timelapsesLimitIndex = index
        }

        pendingLimit = nil
        showLimitConfirmation = false

        AnalyticsService.shared.capture("storage_limit_changed", [
            "category": category.analyticsKey,
            "previous_limit_bytes": previousBytes,
            "new_limit_bytes": newBytes
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
        case .recordings: return recordingsLimitBytes
        case .timelapses: return timelapsesLimitBytes
        }
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

    nonisolated private static func directorySize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileAllocatedSizeKey, .totalFileAllocatedSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            do {
                let values = try fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
                total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            } catch {
                continue
            }
        }
        return total
    }

    static let storageOptions: [StorageLimitOption] = [
        StorageLimitOption(id: 0, label: "1 GB", bytes: 1_000_000_000),
        StorageLimitOption(id: 1, label: "2 GB", bytes: 2_000_000_000),
        StorageLimitOption(id: 2, label: "3 GB", bytes: 3_000_000_000),
        StorageLimitOption(id: 3, label: "5 GB", bytes: 5_000_000_000),
        StorageLimitOption(id: 4, label: "10 GB", bytes: 10_000_000_000),
        StorageLimitOption(id: 5, label: "20 GB", bytes: 20_000_000_000),
        StorageLimitOption(id: 6, label: "Unlimited", bytes: nil)
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
    case recordings
    case timelapses

    var analyticsKey: String {
        switch self {
        case .recordings: return "recordings"
        case .timelapses: return "timelapses"
        }
    }

    var displayName: String {
        switch self {
        case .recordings: return "Recordings"
        case .timelapses: return "Timelapses"
        }
    }
}

struct PendingLimit {
    let category: StorageCategory
    let index: Int
}
