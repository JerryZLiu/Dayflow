import Foundation

/// User-tunable capture settings. Read by the recorder, the frame store, and settings.
enum ScreenshotConfig {
  static let intervalKey = "screenshotIntervalSeconds"
  static let captureHeightKey = "captureHeightPixels"

  /// Posted on the main queue whenever a capture preference changes.
  static let didChange = Notification.Name("ScreenshotConfigDidChange")

  static let intervalOptions: [TimeInterval] = [1, 5, 10, 20, 30, 60]
  static let heightOptions: [Int] = [720, 1080]

  static let defaultInterval: TimeInterval = 10
  static let defaultHeight = 1080

  /// Seconds between captures.
  static var interval: TimeInterval {
    get {
      let stored = UserDefaults.standard.double(forKey: intervalKey)
      return stored > 0 ? stored : defaultInterval
    }
    set {
      UserDefaults.standard.set(newValue, forKey: intervalKey)
      postChange()
    }
  }

  /// Height in pixels each frame is scaled to before encoding.
  static var captureHeight: Int {
    get {
      let stored = UserDefaults.standard.integer(forKey: captureHeightKey)
      return heightOptions.contains(stored) ? stored : defaultHeight
    }
    set {
      UserDefaults.standard.set(newValue, forKey: captureHeightKey)
      postChange()
    }
  }

  /// Rough disk cost per recorded hour, from measured HEVC output at a 10 s interval.
  static func estimatedBytesPerHour(height: Int, interval: TimeInterval) -> Int64 {
    let bytesAtTenSeconds: Double = height <= 720 ? 5_000_000 : 10_300_000
    let framesRatio = defaultInterval / max(1, interval)
    return Int64(bytesAtTenSeconds * framesRatio)
  }

  static func label(forInterval interval: TimeInterval) -> String {
    let seconds = Int(interval)
    if seconds >= 60 { return String(localized: "Every \(seconds / 60) min") }
    return String(localized: "Every \(seconds) sec")
  }

  static func label(forHeight height: Int) -> String {
    "\(height)p"
  }

  private static func postChange() {
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: didChange, object: nil)
    }
  }
}

/// Settings for the accessibility recorder (clicks, typing and screen text,
/// written next to the recordings). Off for users until it's been checked for
/// CPU use and file size; on in debug builds.
enum AccessibilityCaptureConfig {
  /// Overrides the default when set:
  /// `defaults write teleportlabs.com.Dayflow accessibilityCaptureEnabled -bool YES`
  static let enabledKey = "accessibilityCaptureEnabled"

  /// Logs are deleted once the screenshots from the same time are gone, and
  /// never kept longer than this.
  static let maxRetention: TimeInterval = 7 * 24 * 60 * 60

  static var isEnabled: Bool {
    if let stored = UserDefaults.standard.object(forKey: enabledKey) as? Bool {
      return stored
    }
    #if DEBUG
      return true
    #else
      return false
    #endif
  }
}
