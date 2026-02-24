//
//  SentryHelper.swift
//  Dayflow
//
//  Safe wrapper for Sentry SDK calls.
//  Prevents errors when Sentry is not initialized (e.g., DSN not configured).
//

import Foundation
import Sentry

/// Thread-safe wrapper for Sentry SDK calls that gracefully handles uninitialized state.
final class SentryHelper {
  /// Tracks whether Sentry SDK has been successfully initialized.
  /// Set to true in AppDelegate after SentrySDK.start() completes.
  private static let _isEnabled = NSLock()
  private static var _value = false

  static var isEnabled: Bool {
    get {
      _isEnabled.lock()
      defer { _isEnabled.unlock() }
      return _value
    }
    set {
      _isEnabled.lock()
      _value = newValue
      _isEnabled.unlock()
    }
  }

  /// Safely adds a breadcrumb to Sentry, only if the SDK is initialized.
  /// - Parameter breadcrumb: The breadcrumb to add
  static func addBreadcrumb(_ breadcrumb: Breadcrumb) {
    guard isEnabled else { return }
    SentrySDK.addBreadcrumb(breadcrumb)
  }

  /// Safely configures Sentry scope, only if the SDK is initialized.
  /// - Parameter configure: The scope configuration closure
  static func configureScope(_ configure: @escaping (Scope) -> Void) {
    guard isEnabled else { return }
    SentrySDK.configureScope(configure)
  }
}
