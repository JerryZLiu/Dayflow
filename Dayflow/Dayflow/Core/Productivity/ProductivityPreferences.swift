//
//  ProductivityPreferences.swift
//  Dayflow
//
//  UserDefaults-backed settings for the focus Mini Timer.
//

import Foundation

enum ProductivityPreferences {
  private static let defaults = UserDefaults.standard

  // MARK: - Keys
  private static let miniTimerEnabledKey = "miniTimerEnabled"
  private static let miniTimerOriginXKey = "miniTimerOriginX"
  private static let miniTimerOriginYKey = "miniTimerOriginY"

  // MARK: - Mini Timer

  /// Whether the floating focus timer is shown. Default off so the app stays
  /// unobtrusive until the user opts in from the menu bar or Settings.
  static var miniTimerEnabled: Bool {
    get { defaults.bool(forKey: miniTimerEnabledKey) }
    set { defaults.set(newValue, forKey: miniTimerEnabledKey) }
  }

  /// Saved bottom-left origin of the timer panel, or nil if never moved.
  static var miniTimerOrigin: CGPoint? {
    get {
      guard
        defaults.object(forKey: miniTimerOriginXKey) != nil,
        defaults.object(forKey: miniTimerOriginYKey) != nil
      else { return nil }
      return CGPoint(
        x: defaults.double(forKey: miniTimerOriginXKey),
        y: defaults.double(forKey: miniTimerOriginYKey)
      )
    }
    set {
      if let point = newValue {
        defaults.set(point.x, forKey: miniTimerOriginXKey)
        defaults.set(point.y, forKey: miniTimerOriginYKey)
      } else {
        defaults.removeObject(forKey: miniTimerOriginXKey)
        defaults.removeObject(forKey: miniTimerOriginYKey)
      }
    }
  }
}
