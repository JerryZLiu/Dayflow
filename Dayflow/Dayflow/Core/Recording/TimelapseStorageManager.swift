import Foundation

final class TimelapseStorageManager {
    static let shared = TimelapseStorageManager()

    private let fileMgr = FileManager.default
    private let root: URL
    private let queue = DispatchQueue(label: "com.dayflow.timelapse.purge", qos: .utility)

    private init() {
        let appSupport = fileMgr.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let path = appSupport.appendingPathComponent("Dayflow/timelapses", isDirectory: true)
        root = path
        try? fileMgr.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var rootURL: URL { root }

    func currentUsageBytes() -> Int64 {
        (try? fileMgr.allocatedSizeOfDirectory(at: root)) ?? 0
    }

    func updateLimit(bytes: Int64) {
        let previous = StoragePreferences.timelapsesLimitBytes
        StoragePreferences.timelapsesLimitBytes = bytes
        if bytes < previous {
            purgeIfNeeded(limit: bytes)
        }
    }

    func purgeNow(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else {
                if let completion {
                    DispatchQueue.main.async { completion() }
                }
                return
            }
            self.performPurge(limitBytes: StoragePreferences.timelapsesLimitBytes)
            if let completion {
                DispatchQueue.main.async { completion() }
            }
        }
    }

    func purgeIfNeeded(limit: Int64? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let limitBytes = limit ?? StoragePreferences.timelapsesLimitBytes
            self.performPurge(limitBytes: limitBytes)
        }
    }

    private func entrySize(_ url: URL) throws -> Int64 {
        var isDir: ObjCBool = false
        if fileMgr.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return (try? fileMgr.allocatedSizeOfDirectory(at: url)) ?? 0
        }
        let attrs = try fileMgr.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func performPurge(limitBytes: Int64) {
        guard limitBytes < Int64.max else { return }

        do {
            var usage = (try? fileMgr.allocatedSizeOfDirectory(at: root)) ?? 0
            if usage <= limitBytes { return }

            let entries = try fileMgr.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            .sorted { lhs, rhs in
                let lValues = try? lhs.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                let rValues = try? rhs.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                let lDate = lValues?.creationDate ?? lValues?.contentModificationDate ?? Date.distantPast
                let rDate = rValues?.creationDate ?? rValues?.contentModificationDate ?? Date.distantPast
                return lDate < rDate
            }

            for entry in entries {
                if usage <= limitBytes { break }
                let size = (try? entrySize(entry)) ?? 0
                do {
                    try fileMgr.removeItem(at: entry)
                    usage -= size
                } catch {
                    print("⚠️ Failed to delete timelapse entry at \(entry.path): \(error)")
                }
            }
        } catch {
            print("❌ Timelapse purge error: \(error)")
        }
    }
}
