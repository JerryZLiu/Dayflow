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
    if seconds >= 60 { return "Every \(seconds / 60) min" }
    return "Every \(seconds) sec"
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
