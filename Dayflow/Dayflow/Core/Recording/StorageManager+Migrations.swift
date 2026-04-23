import Foundation
import GRDB

extension StorageManager {
  func migrateLegacyChunkPathsIfNeeded() {
    guard let bundleID = Bundle.main.bundleIdentifier else { return }
    guard
      let appSupport = fileMgr.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else { return }

    let legacyBase = fileMgr.homeDirectoryForCurrentUser
      .appendingPathComponent(
        "Library/Containers/\(bundleID)/Data/Library/Application Support/Dayflow", isDirectory: true
      )
    let newBase = appSupport.appendingPathComponent("Dayflow", isDirectory: true)

    guard legacyBase.path != newBase.path else { return }

    func normalizedPrefix(_ path: String) -> String {
      path.hasSuffix("/") ? path : path + "/"
    }

    let legacyRecordings = normalizedPrefix(
      legacyBase.appendingPathComponent("recordings", isDirectory: true).path)
    let newRecordings = normalizedPrefix(root.path)

    let legacyTimelapses = normalizedPrefix(
      legacyBase.appendingPathComponent("timelapses", isDirectory: true).path)
    let newTimelapses = normalizedPrefix(
      newBase.appendingPathComponent("timelapses", isDirectory: true).path)

    let replacements:
      [(label: String, table: String, column: String, legacyPrefix: String, newPrefix: String)] = [
        ("chunk file paths", "chunks", "file_url", legacyRecordings, newRecordings),
        (
          "timelapse video paths", "timeline_cards", "video_summary_url", legacyTimelapses,
          newTimelapses
        ),
      ]

    do {
      try timedWrite("migrateLegacyFileURLs") { db in
        for replacement in replacements {
          guard replacement.legacyPrefix != replacement.newPrefix else { continue }

          let pattern = replacement.legacyPrefix + "%"
          let count =
            try Int.fetchOne(
              db,
              sql: "SELECT COUNT(*) FROM \(replacement.table) WHERE \(replacement.column) LIKE ?",
              arguments: [pattern]
            ) ?? 0

          guard count > 0 else { continue }

          try db.execute(
            sql: """
                  UPDATE \(replacement.table)
                  SET \(replacement.column) = REPLACE(\(replacement.column), ?, ?)
                  WHERE \(replacement.column) LIKE ?
              """,
            arguments: [replacement.legacyPrefix, replacement.newPrefix, pattern]
          )

          let updated = db.changesCount
          print(
            "ℹ️ StorageManager: migrated \(updated) \(replacement.label) to \(replacement.newPrefix)"
          )
        }
      }
    } catch {
      print("⚠️ StorageManager: failed to migrate legacy file URLs: \(error)")
    }
  }

  static func migrateDatabaseLocationIfNeeded(
    fileManager: FileManager,
    legacyRecordingsDir: URL,
    newDatabaseURL: URL
  ) {
    let destinationDir = newDatabaseURL.deletingLastPathComponent()
    let filenames = ["chunks.sqlite", "chunks.sqlite-wal", "chunks.sqlite-shm"]

    guard
      filenames.contains(where: {
        fileManager.fileExists(atPath: legacyRecordingsDir.appendingPathComponent($0).path)
      })
    else {
      return
    }

    if !fileManager.fileExists(atPath: destinationDir.path) {
      try? fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
    }

    for name in filenames {
      let legacyURL = legacyRecordingsDir.appendingPathComponent(name)
      guard fileManager.fileExists(atPath: legacyURL.path) else { continue }

      let destinationURL = destinationDir.appendingPathComponent(name)
      do {
        if fileManager.fileExists(atPath: destinationURL.path) {
          try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: legacyURL, to: destinationURL)
        print("ℹ️ StorageManager: migrated \(name) to \(destinationURL.path)")
      } catch {
        print("⚠️ StorageManager: failed to migrate \(name): \(error)")
      }
    }
  }
}
