import Foundation

/// Limits automatic generation to three attempts per target day, including across app launches.
/// The scheduler reserves attempts only while it owns its single in-flight check.
struct DailyRecapAttemptBudget {
  static let maxAttempts = 3
  private static let storageKey = "dailyRecapAutomaticAttempts_v1"
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func reserveAttempt(forDay day: String) -> Int? {
    let saved = defaults.dictionary(forKey: Self.storageKey)
    let count = saved?["day"] as? String == day ? (saved?["count"] as? Int ?? 0) : 0
    guard count < Self.maxAttempts else { return nil }

    let attempt = count + 1
    defaults.set(["day": day, "count": attempt], forKey: Self.storageKey)
    return attempt
  }
}
