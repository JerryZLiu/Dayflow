import Foundation

enum TimelapsePreferences {
  static let saveAllTimelapsesToDiskKey = "saveAllTimelapsesToDisk"

  static var saveAllTimelapsesToDisk: Bool {
    get {
      UserDefaults.standard.object(forKey: saveAllTimelapsesToDiskKey) as? Bool ?? false
    }
    set {
      UserDefaults.standard.set(newValue, forKey: saveAllTimelapsesToDiskKey)
    }
  }
}
