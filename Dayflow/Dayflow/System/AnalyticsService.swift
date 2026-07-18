//
//  AnalyticsService.swift
//  Dayflow
//
//  Centralized analytics wrapper for PostHog. Provides
//  - identity management via PostHog distinct ID
//  - opt-in gate (default ON)
//  - super properties and person properties
//  - sampling and throttling helpers
//  - safe, PII-free capture helpers and bucketing utils
//

import AppKit
import Foundation
import PostHog

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

  private let optInKey = "analyticsOptIn"
  private let backendAuthFallbackTokenKey = "localBackendAuthFallbackToken"
  private let backendAuthOverrideTokenKey = "dayflowBackendAuthTokenOverride"
  private let throttleLock = NSLock()
  private var throttles: [String: Date] = [:]

  var isOptedIn: Bool {
    get {
      if UserDefaults.standard.object(forKey: optInKey) == nil {
        // Default ON per product decision
        return true
      }
      return UserDefaults.standard.bool(forKey: optInKey)
    }
    set {
      UserDefaults.standard.set(newValue, forKey: optInKey)
    }
  }

  func start(apiKey: String, host: String) {
    let config = PostHogConfig(apiKey: apiKey, host: host)
    let optedIn = isOptedIn
    // Disable autocapture for privacy
    config.captureApplicationLifecycleEvents = false
    // Keep SDK initialized for backend auth token usage, but hard-disable networked telemetry when opted out.
    config.optOut = !optedIn
    config.preloadFeatureFlags = optedIn
    config.remoteConfig = optedIn
    PostHogSDK.shared.setup(config)

    guard optedIn else { return }

    // Identity - run on background thread to avoid blocking app launch.
    // Use PostHog's own distinct ID as the canonical identifier source.
    Task.detached(priority: .utility) {
      let id = PostHogSDK.shared.getDistinctId().trimmingCharacters(in: .whitespacesAndNewlines)
      guard !id.isEmpty else { return }
      PostHogSDK.shared.identify(id)
    }

    // Super properties at launch
    registerInitialSuperProperties()

    // Person properties via $set / $set_once
    let set: [String: Any] = [
      "analytics_opt_in": optedIn
    ]
    var payload: [String: Any] = ["$set": sanitize(set)]
    if !UserDefaults.standard.bool(forKey: "installTsSent") {
      payload["$set_once"] = ["install_ts": iso8601Now()]
      UserDefaults.standard.set(true, forKey: "installTsSent")
    }
    PostHogSDK.shared.capture("person_props_updated", properties: payload)
  }

  /// Returns the stable PostHog distinct ID used as backend auth identity.
  /// Source of truth is PostHog SDK storage (not keychain).
  func backendAuthToken() -> String {
    let defaults = UserDefaults.standard
    #if DEBUG
      if let override = defaults.string(forKey: backendAuthOverrideTokenKey)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !override.isEmpty
      {
        // This override feeds the legacy Daily/PostHog auth path only.
        // Dayflow account session tokens are intentionally ignored here; CardGen
        // reads them through DayflowAuthManager instead.
        if override.hasPrefix("dfs:") {
          print(
            "[AnalyticsService] backendAuthToken ignored_debug_override "
              + "reason=dayflow_session_token length=\(override.count)"
          )
        } else {
          print(
            "[AnalyticsService] backendAuthToken source=debug_override_user_defaults "
              + "length=\(override.count)"
          )
          return override
        }
      }
    #endif

    let distinctId = PostHogSDK.shared.getDistinctId().trimmingCharacters(
      in: .whitespacesAndNewlines)
    if !distinctId.isEmpty {
      #if DEBUG
        print(
          "[AnalyticsService] backendAuthToken source=posthog_distinct_id "
            + "length=\(distinctId.count)"
        )
      #endif
      return distinctId
    }

    #if DEBUG
      // Local-dev fallback so backend-authenticated features still work when PostHog
      // is not configured for the current build.
      if let existing = defaults.string(forKey: backendAuthFallbackTokenKey)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !existing.isEmpty
      {
        print(
          "[AnalyticsService] backendAuthToken source=debug_fallback_existing "
            + "length=\(existing.count)"
        )
        if existing.hasPrefix("local-") {
          print(
            "[AnalyticsService] backendAuthToken warning=fallback_token_looks_local "
              + "length=\(existing.count)"
          )
        }
        return existing
      }

      let generated = "\(UUID().uuidString.lowercased())"
      defaults.set(generated, forKey: backendAuthFallbackTokenKey)
      print(
        "[AnalyticsService] backendAuthToken source=debug_fallback_generated "
          + "length=\(generated.count)"
      )
      return generated
    #else
      return ""
    #endif
  }

  func postHogDistinctIdForAppcast() -> String? {
    guard isOptedIn else { return nil }
    let distinctId = PostHogSDK.shared.getDistinctId().trimmingCharacters(
      in: .whitespacesAndNewlines)
    return distinctId.isEmpty ? nil : distinctId
  }

  func setOptIn(_ enabled: Bool) {
    let previousValue = isOptedIn
    isOptedIn = enabled

    if enabled {
      PostHogSDK.shared.optIn()
      SentryHelper.setEnabled(true)
      NotificationCenter.default.post(
        name: .analyticsPreferenceChanged,
        object: nil,
        userInfo: ["enabled": enabled]
      )

      guard previousValue != enabled else { return }

      let payload: [String: Any] = ["$set": sanitize(["analytics_opt_in": enabled])]
      Task.detached(priority: .utility) {
        PostHogSDK.shared.capture("person_props_updated", properties: payload)
        PostHogSDK.shared.capture("analytics_opt_in_changed", properties: ["enabled": enabled])
      }
      return
    }

    guard previousValue != enabled else {
      SentryHelper.setEnabled(false)
      PostHogSDK.shared.optOut()
      NotificationCenter.default.post(
        name: .analyticsPreferenceChanged,
        object: nil,
        userInfo: ["enabled": enabled]
      )
      return
    }

    // Disable Sentry immediately, then send one final explicit PostHog opt-out signal.
    SentryHelper.setEnabled(false)
    let payload: [String: Any] = ["$set": sanitize(["analytics_opt_in": enabled])]
    PostHogSDK.shared.capture("person_props_updated", properties: payload)
    PostHogSDK.shared.capture("analytics_opt_in_changed", properties: ["enabled": enabled])
    PostHogSDK.shared.flush()
    PostHogSDK.shared.optOut()
    NotificationCenter.default.post(
      name: .analyticsPreferenceChanged,
      object: nil,
      userInfo: ["enabled": enabled]
    )
  }

  func capture(_ name: String, _ props: [String: Any] = [:]) {
    guard isOptedIn else { return }
    let sanitized = sanitize(props)
    PostHogSDK.shared.capture(name, properties: sanitized)
  }

  func flush() {
    guard isOptedIn else { return }
    PostHogSDK.shared.flush()
  }

  func featureFlagVariant(_ key: String) -> String? {
    guard isOptedIn else { return nil }
    return PostHogSDK.shared.getFeatureFlag(key) as? String
  }

  func screen(_ name: String, _ props: [String: Any] = [:]) {
    // Implement as a regular capture for consistency
    capture("screen_viewed", ["screen": name].merging(props, uniquingKeysWith: { _, new in new }))
  }

  func identify(_ distinctId: String, properties: [String: Any] = [:]) {
    guard isOptedIn else { return }
    Task.detached(priority: .utility) {
      PostHogSDK.shared.identify(distinctId)
    }
    if !properties.isEmpty {
      setPersonProperties(properties)
    }
  }

  func alias(_ aliasId: String) {
    guard isOptedIn else { return }
    Task.detached(priority: .utility) {
      PostHogSDK.shared.alias(aliasId)
    }
  }

  func registerSuperProperties(_ props: [String: Any]) {
    guard isOptedIn else { return }
    let sanitized = sanitize(props)
    Task.detached(priority: .utility) {
      PostHogSDK.shared.register(sanitized)
    }
  }

  func setPersonProperties(_ props: [String: Any]) {
    guard isOptedIn else { return }
    let payload: [String: Any] = ["$set": sanitize(props)]
    Task.detached(priority: .utility) {
      PostHogSDK.shared.capture("person_props_updated", properties: payload)
    }
  }

  func throttled(_ key: String, minInterval: TimeInterval, action: () -> Void) {
    let now = Date()
    throttleLock.lock()
    defer { throttleLock.unlock() }

    if let last = throttles[key], now.timeIntervalSince(last) < minInterval { return }
    throttles[key] = now
    action()
  }

  func withSampling(probability: Double, action: () -> Void) {
    guard probability >= 1.0 || Double.random(in: 0..<1) < probability else { return }
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

  /// Track LLM validation failures (time coverage, duration, parse errors)
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
    var props: [String: Any] = [
      "provider": provider,
      "provider_id": providerID.rawValue,
      "operation": operation,
      "validation_type": validationType,
      "attempt": attempt,
    ]
    if let model = model { props["model"] = model }
    if let batchId = batchId { props["batch_id"] = batchId }
    if let errorDetail = errorDetail {
      props["has_error_detail"] = true
      props["error_detail_length"] = errorDetail.count
      if let sanitizedDetail = TelemetryErrorSanitizer.sanitize(errorDetail) {
        props["error_detail"] = sanitizedDetail
        props["error_detail_sanitized"] = true
      }
    } else {
      props["has_error_detail"] = false
    }
    capture("llm_validation_failed", props)
  }

  private static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  func dayString(_ date: Date) -> String {
    Self.dayFormatter.string(from: date)
  }

  private func registerInitialSuperProperties() {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    let os = ProcessInfo.processInfo.operatingSystemVersion
    let osVersion = "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    let device = Host.current().localizedName ?? "Mac"
    let locale = Locale.current.identifier
    let tz = TimeZone.current.identifier

    registerSuperProperties([
      "app_version": version,
      "build_number": build,
      "os_version": osVersion,
      "device_model": device,
      "locale": locale,
      "time_zone": tz,
        // dynamic values will be updated later as needed
    ])
  }

  private func sanitize(_ props: [String: Any]) -> [String: Any] {
    // Drop known sensitive keys if ever passed by mistake
    let blocked = Set([
      "api_key", "token", "authorization", "file_path", "url", "window_title", "clipboard",
      "screen_content",
    ])
    var out: [String: Any] = [:]
    for (k, v) in props {
      if blocked.contains(k) { continue }
      // Only allow primitive JSON types
      if v is String || v is Int || v is Double || v is Bool || v is NSNull {
        out[k] = v
      } else {
        // Allow string coercion for simple enums
        out[k] = String(describing: v)
      }
    }
    return out
  }

  private func iso8601Now() -> String {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fmt.string(from: Date())
  }
}
