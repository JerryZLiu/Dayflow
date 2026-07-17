import Foundation
import GRDB

extension StorageManager {
  func upsertCaptureDevice(_ device: CaptureDevice) {
    try? timedWrite("upsertCaptureDevice") { db in
      try db.execute(
        sql: """
              INSERT INTO capture_devices(
                id, platform, display_name, model, os_version,
                paired_at, last_seen_at, is_revoked
              ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
              ON CONFLICT(id) DO UPDATE SET
                platform = excluded.platform,
                display_name = excluded.display_name,
                model = excluded.model,
                os_version = excluded.os_version,
                paired_at = COALESCE(excluded.paired_at, capture_devices.paired_at),
                last_seen_at = excluded.last_seen_at,
                is_revoked = excluded.is_revoked
          """,
        arguments: [
          device.id,
          device.platform.rawValue,
          device.displayName,
          device.model,
          device.osVersion,
          device.pairedAt.map { Int($0.timeIntervalSince1970) },
          device.lastSeenAt.map { Int($0.timeIntervalSince1970) },
          device.isRevoked ? 1 : 0,
        ]
      )
    }
  }

  func fetchCaptureDevices(includeRevoked: Bool = false) -> [CaptureDevice] {
    (try? timedRead("fetchCaptureDevices") { db in
      let revokedClause = includeRevoked ? "" : "WHERE is_revoked = 0"
      return try Row.fetchAll(
        db,
        sql: """
              SELECT * FROM capture_devices
              \(revokedClause)
              ORDER BY platform ASC, display_name COLLATE NOCASE ASC
          """
      ).compactMap { row in
        let platformRaw: String = row["platform"]
        guard let platform = CapturePlatform(rawValue: platformRaw) else { return nil }
        let pairedAt: Int? = row["paired_at"]
        let lastSeenAt: Int? = row["last_seen_at"]
        return CaptureDevice(
          id: row["id"],
          platform: platform,
          displayName: row["display_name"],
          model: row["model"],
          osVersion: row["os_version"],
          pairedAt: pairedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
          lastSeenAt: lastSeenAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
          isRevoked: (row["is_revoked"] as? Int ?? 0) != 0
        )
      }
    }) ?? []
  }

  func revokeCaptureDevice(id: String) {
    guard id != LocalCaptureDevice.id else { return }
    try? timedWrite("revokeCaptureDevice") { db in
      try db.execute(
        sql: "UPDATE capture_devices SET is_revoked = 1 WHERE id = ?",
        arguments: [id]
      )
    }
  }
}
