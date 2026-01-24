//
//  AnalyticsService.swift
//  Dayflow
//
//  Centralized analytics wrapper for PostHog. Provides
//  - identity management (anonymous UUID stored in Keychain)
//  - opt-in gate (default ON)
//  - super properties and person properties
//  - sampling and throttling helpers
//  - safe, PII-free capture helpers and bucketing utils
//

import Foundation
import AppKit
import PostHog

final class AnalyticsService {
    static let shared = AnalyticsService()

    private init() {}

    private let optInKey = "analyticsOptIn"
    private let distinctIdKeychainKey = "analyticsDistinctId"
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
        // Disable autocapture for privacy
        config.captureApplicationLifecycleEvents = false
        PostHogSDK.shared.setup(config)

        // Identity - run on background thread to avoid blocking app launch
        // PostHog's identify() triggers synchronous disk I/O and XPC calls
        Task.detached(priority: .utility) { [self] in
            let id = self.ensureDistinctId()
            PostHogSDK.shared.identify(id)
        }

        // Super properties at launch
        registerInitialSuperProperties()

        // Person properties via $set / $set_once
        let set: [String: Any] = [
            "analytics_opt_in": isOptedIn
        ]
        var payload: [String: Any] = ["$set": sanitize(set)]
        if !UserDefaults.standard.bool(forKey: "installTsSent") {
            payload["$set_once"] = ["install_ts": iso8601Now()]
            UserDefaults.standard.set(true, forKey: "installTsSent")
        }
        PostHogSDK.shared.capture("person_props_updated", properties: payload)
    }

    @discardableResult
    private func ensureDistinctId() -> String {
        if let existing = KeychainManager.shared.retrieve(for: distinctIdKeychainKey), !existing.isEmpty {
            return existing
        }
        let newId = UUID().uuidString
        _ = KeychainManager.shared.store(newId, for: distinctIdKeychainKey)
        return newId
    }

    func setOptIn(_ enabled: Bool) {
        if isOptedIn != enabled {
            let payload: [String: Any] = ["$set": sanitize(["analytics_opt_in": enabled])]
            Task.detached(priority: .utility) {
                PostHogSDK.shared.capture("person_props_updated", properties: payload)
                PostHogSDK.shared.capture("analytics_opt_in_changed", properties: ["enabled": enabled])
            }
        }
        isOptedIn = enabled
    }

    func capture(_ name: String, _ props: [String: Any] = [:]) {
        guard isOptedIn else { return }
        let sanitized = sanitize(props)
        Task.detached(priority: .utility) {
            PostHogSDK.shared.capture(name, properties: sanitized)
        }
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

    /// Track LLM validation failures (time coverage, duration, parse errors)
    func captureValidationFailure(
        provider: String,
        operation: String,
        validationType: String,
        attempt: Int,
        model: String?,
        batchId: Int64?,
        errorDetail: String?
    ) {
        var props: [String: Any] = [
            "provider": provider,
            "operation": operation,
            "validation_type": validationType,
            "attempt": attempt
        ]
        if let model = model { props["model"] = model }
        if let batchId = batchId { props["batch_id"] = batchId }
        if let errorDetail = errorDetail {
            // Truncate long error details to avoid bloating events
            props["error_detail"] = String(errorDetail.prefix(500))
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
        let blocked = Set(["api_key", "token", "authorization", "file_path", "url", "window_title", "clipboard", "screen_content"]) 
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
