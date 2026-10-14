//
//  SentryHelper.swift
//  Dayflow
//
//  Local stand-ins for the old crash reporter. Nothing is uploaded.
//

import Foundation

enum SentryLevel {
  case debug
  case info
  case warning
  case error
  case fatal
}

enum SentrySpanStatus {
  case ok
  case internalError
}

final class Breadcrumb {
  var level: SentryLevel
  var category: String
  var message: String?
  var data: [String: Any]?

  init(level: SentryLevel, category: String) {
    self.level = level
    self.category = category
  }
}

final class Scope {
  func setContext(value: [String: Any], key: String) {
    _ = (value, key)
  }
}

final class SentrySpan {
  func setData(value: Any, key: String) {
    _ = (value, key)
  }

  func finish(status: SentrySpanStatus = .ok) {
    _ = status
  }
}

enum SentrySDK {
  static func capture(message: String) {
    _ = message
  }

  static func flush(timeout: TimeInterval) {
    _ = timeout
  }
}

final class SentryHelper {
  static var isEnabled: Bool { false }

  static func setEnabled(_ enabled: Bool) {
    _ = enabled
  }

  static func startIfConfigured() {}

  static func addBreadcrumb(_ breadcrumb: Breadcrumb) {
    _ = breadcrumb
  }

  static func configureScope(_ configure: (Scope) -> Void) {
    _ = configure
  }

  static func startTransaction(name: String, operation: String) -> SentrySpan? {
    _ = (name, operation)
    return nil
  }
}
