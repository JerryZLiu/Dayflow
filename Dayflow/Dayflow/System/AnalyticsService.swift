//
//  AnalyticsService.swift
//  Dayflow
//
//  Local no-op. Dayflow does not start PostHog or send usage events.
//  Capture helpers stay so existing call sites compile, and they never leave the Mac.
//

import Foundation

struct TelemetrySanitizedStdout: Equatable {
  let originalLength: Int
  let nonJSONLength: Int
  let removedJSON: Bool
  let detail: String?
}

/// Sanitized failure details help us debug provider and validation regressions. Before sending
/// them through opt-in analytics, make every reasonable attempt to remove PII and content-bearing
/// sections; raw errors stay local because this best-effort sanitizer cannot cover every shape.
enum TelemetryErrorSanitizer {
  private static let maximumLength = 500
  private static let privateSectionMarkers = [
    "\n\n📥 INPUT CARDS:",
    "\n📥 INPUT CARDS:",
    "\n\n📤 OUTPUT CARDS:",
    "\n📤 OUTPUT CARDS:",
    "\n\n📄 RAW OUTPUT:",
    "\n📄 RAW OUTPUT:",
    "\n\nRAW OUTPUT:",
    "\nRAW OUTPUT:",
  ]

  static func sanitize(_ rawValue: String?) -> String? {
    guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return nil }

    for marker in privateSectionMarkers {
      if let range = value.range(of: marker) {
        value = String(value[..<range.lowerBound])
      }
    }

    value = normalizeKnownValidationMessage(value)

    let replacements: [(pattern: String, replacement: String)] = [
      (#"\x1B\[[0-?]*[ -/]*[@-~]"#, ""),
      (#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "<redacted-email>"),
      (
        #"(?i)\b(api[_-]?key|access[_-]?token|token|authorization)\s*[:=]\s*[^\s,;]+"#,
        "$1=<redacted>"
      ),
      (#"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer <redacted>"),
      (#"\b(?:sk|phc|dfs)[-_A-Za-z0-9:.]{8,}\b"#, "<redacted-token>"),
      (#"https?://[^\s]+"#, "<redacted-url>"),
      (#"/(?:Users|private|var|tmp|Volumes)/[^\s,;]+"#, "<redacted-path>"),
      (#"'[^\n]{1,512}'"#, "'<redacted>'"),
      (#"\"[^\"\n]{1,512}\""#, "\"<redacted>\""),
    ]
    for replacement in replacements {
      value = value.replacingOccurrences(
        of: replacement.pattern,
        with: replacement.replacement,
        options: .regularExpression
      )
    }

    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return String(trimmed.prefix(maximumLength))
  }

  /// Failure output sometimes contains useful CLI diagnostics around model-generated payloads.
  /// Remove every braced/bracketed block and fenced JSON before applying the same best-effort PII
  /// redaction used for errors. Successful output is never sent to analytics.
  static func sanitizeFailureStdout(_ rawValue: String?) -> TelemetrySanitizedStdout? {
    guard let rawValue else { return nil }

    let withoutFencedJSON = rawValue.replacingOccurrences(
      of: #"(?is)```[ \t]*json[^\n]*\n.*?```"#,
      with: "",
      options: .regularExpression
    )
    var removedJSON = withoutFencedJSON != rawValue
    let bytes = Array(withoutFencedJSON.utf8)
    var kept: [UInt8] = []
    var index = 0

    while index < bytes.count {
      let byte = bytes[index]
      guard byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") else {
        kept.append(byte)
        index += 1
        continue
      }

      guard let end = balancedJSONEnd(in: bytes, startingAt: index) else {
        // Generated JSON can be truncated. Drop the rest of that line rather than risk sending a
        // partial card, transcript, or other content-bearing payload.
        removedJSON = true
        index = bytes[index...].firstIndex(of: UInt8(ascii: "\n")) ?? bytes.count
        continue
      }

      removedJSON = true
      index = end + 1
    }

    let nonJSON = String(decoding: kept, as: UTF8.self)
      .replacingOccurrences(
        of: #"(?s)```[^\n]*\n\s*```"#,
        with: "",
        options: .regularExpression
      )
      .replacingOccurrences(
        of: #"(?m)[ \t]{2,}"#,
        with: " ",
        options: .regularExpression
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)

    return TelemetrySanitizedStdout(
      originalLength: rawValue.count,
      nonJSONLength: nonJSON.count,
      removedJSON: removedJSON,
      detail: sanitize(nonJSON)
    )
  }

  static func failureOutputProperties(_ rawValue: String?, prefix: String) -> [String: Any] {
    guard let sanitized = sanitizeFailureStdout(rawValue) else { return [:] }

    var properties: [String: Any] = [
      "\(prefix)_was_present": sanitized.originalLength > 0,
      "\(prefix)_length": sanitized.originalLength,
      "\(prefix)_json_removed": sanitized.removedJSON,
      "\(prefix)_non_json_length": sanitized.nonJSONLength,
    ]
    if let detail = sanitized.detail {
      properties["\(prefix)_non_json_detail"] = detail
      properties["\(prefix)_non_json_sanitized"] = true
    }
    return properties
  }

  private static func balancedJSONEnd(in bytes: [UInt8], startingAt start: Int) -> Int? {
    var expectedClosers: [UInt8] = []
    var isInsideString = false
    var isEscaped = false

    for index in start..<bytes.count {
      let byte = bytes[index]
      if isInsideString {
        if isEscaped {
          isEscaped = false
        } else if byte == UInt8(ascii: "\\") {
          isEscaped = true
        } else if byte == UInt8(ascii: "\"") {
          isInsideString = false
        }
        continue
      }

      if byte == UInt8(ascii: "\"") {
        isInsideString = true
      } else if byte == UInt8(ascii: "{") {
        expectedClosers.append(UInt8(ascii: "}"))
      } else if byte == UInt8(ascii: "[") {
        expectedClosers.append(UInt8(ascii: "]"))
      } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
        guard expectedClosers.last == byte else { return nil }
        expectedClosers.removeLast()
        if expectedClosers.isEmpty { return index }
      }
    }

    return nil
  }

  private static func normalizeKnownValidationMessage(_ value: String) -> String {
    let safePrefixes: [(prefix: String, replacement: String)] = [
      (
        "Segment end time must be after start time:",
        "Segment end time must be after start time."
      ),
      (
        "Segment start time must be >= 00:00:00",
        "Segment starts before 00:00:00."
      ),
      (
        "Segment out of bounds:",
        "Segment is outside the recording duration."
      ),
    ]
    if let match = safePrefixes.first(where: { value.hasPrefix($0.prefix) }) {
      return match.replacement
    }

    return value.replacingOccurrences(
      of: #"(?s)^Card ([0-9]+) .* is only ([0-9]+(?:\.[0-9]+)? minutes long)$"#,
      with: "Card $1 is only $2",
      options: .regularExpression
    )
  }
}

final class AnalyticsService {
  static let shared = AnalyticsService()

  private init() {}

  /// Telemetry is removed. This stays false so callers that gate on consent do no extra work.
  var isOptedIn: Bool {
    get { false }
    set { _ = newValue }
  }

  func start(apiKey: String, host: String) {}

  /// There is no analytics identity, and this value is never sent to a backend.
  func backendAuthToken() -> String { "" }

  func postHogDistinctIdForAppcast() -> String? { nil }

  func currentDistinctId() -> String? { nil }

  func setOptIn(_ enabled: Bool) {
    _ = enabled
    NotificationCenter.default.post(
      name: .analyticsPreferenceChanged,
      object: nil,
      userInfo: ["enabled": false]
    )
  }

  func capture(_ name: String, _ props: [String: Any] = [:]) {}

  func flush() {}

  func featureFlagVariant(_ key: String) -> String? { nil }

  func screen(_ name: String, _ props: [String: Any] = [:]) {}

  func identify(_ distinctId: String, properties: [String: Any] = [:]) {}

  func alias(_ aliasId: String) {}

  func registerSuperProperties(_ props: [String: Any]) {}

  func setPersonProperties(_ props: [String: Any]) {}

  func throttled(_ key: String, minInterval: TimeInterval, action: () -> Void) {
    _ = (key, minInterval)
    action()
  }

  func withSampling(probability: Double, action: () -> Void) {
    _ = probability
    action()
  }

  func secondsBucket(_ seconds: Double) -> String {
    switch seconds {
    case ..<15: return "0-15s"
    case ..<60: return "15-60s"
    case ..<300: return "1-5m"
    case ..<1200: return "5-20m"
    default: return ">20m"
    }
  }

  func pctBucket(_ value: Double) -> String {
    let pct = max(0.0, min(1.0, value))
    switch pct {
    case ..<0.25: return "0-25%"
    case ..<0.5: return "25-50%"
    case ..<0.75: return "50-75%"
    default: return "75-100%"
    }
  }

  func cpuPercentBucket(_ value: Double) -> String {
    let pct = value.isFinite ? max(0.0, value) : 0.0
    switch pct {
    case ..<5: return "0-5%"
    case ..<20: return "5-20%"
    case ..<50: return "20-50%"
    case ..<100: return "50-100%"
    case ..<150: return "100-150%"
    case ..<200: return "150-200%"
    default: return ">200%"
    }
  }

  func captureValidationFailure(
    provider: String,
    providerID: LLMProviderID,
    operation: String,
    validationType: String,
    attempt: Int,
    model: String?,
    batchId: Int64?,
    errorDetail: String?
  ) {
    _ = (provider, providerID, operation, validationType, attempt, model, batchId, errorDetail)
  }

  private static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  func dayString(_ date: Date) -> String {
    Self.dayFormatter.string(from: date)
  }
}
