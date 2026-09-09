import Foundation

enum StoragePreferences {
  private static let defaults = UserDefaults.standard

  private static let recordingsKey = "storageLimitRecordingsBytes"
  private static let timelapsesKey = "storageLimitTimelapsesBytes"

  private static let defaultRecordings: Int64 = 10_000_000_000  // 10 GB
  private static let defaultTimelapses: Int64 = 10_000_000_000  // 10 GB

  static var recordingsLimitBytes: Int64 {
    get {
      let stored = defaults.object(forKey: recordingsKey) as? NSNumber
      return stored?.int64Value ?? defaultRecordings
    }
    set {
      defaults.set(NSNumber(value: newValue), forKey: recordingsKey)
    }
  }

  static var timelapsesLimitBytes: Int64 {
    get {
      let stored = defaults.object(forKey: timelapsesKey) as? NSNumber
      return stored?.int64Value ?? defaultTimelapses
    }
    set {
      defaults.set(NSNumber(value: newValue), forKey: timelapsesKey)
    }
  }
}
