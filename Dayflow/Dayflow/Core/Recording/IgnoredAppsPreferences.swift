import AppKit
import Foundation

struct IgnoredApp: Codable, Identifiable, Hashable {
  let bundleId: String
  let name: String
  var id: String { bundleId }
}

enum IgnoredAppsPreferences {
  static let storageKey = "ignoredAppsList"
  static let didChangeNotification = Notification.Name("IgnoredAppsPreferencesDidChange")

  static var apps: [IgnoredApp] {
    get {
      guard let data = UserDefaults.standard.data(forKey: storageKey),
        let decoded = try? JSONDecoder().decode([IgnoredApp].self, from: data)
      else { return [] }
      return decoded
    }
    set {
      let deduped = dedupe(newValue).sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
      if let data = try? JSONEncoder().encode(deduped) {
        UserDefaults.standard.set(data, forKey: storageKey)
      } else {
        UserDefaults.standard.removeObject(forKey: storageKey)
      }
      NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
  }

  static var bundleIdSet: Set<String> {
    Set(apps.map { $0.bundleId })
  }

  static func contains(bundleId: String) -> Bool {
    bundleIdSet.contains(bundleId)
  }

  static func add(_ app: IgnoredApp) {
    var current = apps
    if current.contains(where: { $0.bundleId == app.bundleId }) { return }
    current.append(app)
    apps = current
  }

  static func remove(bundleId: String) {
    apps = apps.filter { $0.bundleId != bundleId }
  }

  private static func dedupe(_ list: [IgnoredApp]) -> [IgnoredApp] {
    var seen = Set<String>()
    var result: [IgnoredApp] = []
    for item in list where !seen.contains(item.bundleId) {
      seen.insert(item.bundleId)
      result.append(item)
    }
    return result
  }
}
