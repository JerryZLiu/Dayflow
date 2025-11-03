//
//  AnalyticsService.swift
//  Dayflow
//
//  Centralized analytics wrapper (currently stubbed out).
//  Provides no-op methods to preserve analytics hooks for future use.
//  - identity management (anonymous UUID stored in Keychain)
//  - opt-in gate (default OFF)
//  - super properties and person properties
//  - sampling and throttling helpers
//  - safe, PII-free capture helpers and bucketing utils
//

import Foundation
import AppKit

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
                // Default OFF - analytics currently disabled
                return false
            }
            return UserDefaults.standard.bool(forKey: optInKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: optInKey)
        }
    }

    func start(apiKey: String, host: String) {
        // No-op stub: Analytics disabled
        // Keep method signature for compatibility
        _ = ensureDistinctId()  // Still maintain identity for future use
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
        // No-op stub: Analytics disabled
        isOptedIn = enabled
    }

    func capture(_ name: String, _ props: [String: Any] = [:]) {
        // No-op stub: Analytics disabled
    }

    func screen(_ name: String, _ props: [String: Any] = [:]) {
        // No-op stub: Analytics disabled
    }

    func identify(_ distinctId: String, properties: [String: Any] = [:]) {
        // No-op stub: Analytics disabled
    }

    func alias(_ aliasId: String) {
        // No-op stub: Analytics disabled
    }

    func registerSuperProperties(_ props: [String: Any]) {
        // No-op stub: Analytics disabled
    }

    func setPersonProperties(_ props: [String: Any]) {
        // No-op stub: Analytics disabled
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

    func dayString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
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
