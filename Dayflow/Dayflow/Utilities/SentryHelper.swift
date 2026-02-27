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
    /// Managed through `setEnabled(_:)` / `startIfConfigured()`.
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

    /// Enables or disables Sentry based on the shared telemetry preference.
    static func setEnabled(_ enabled: Bool) {
        if enabled {
            startIfConfigured()
            return
        }

        // Flip local gate first so helper calls become no-ops immediately.
        isEnabled = false
        SentrySDK.close()
    }

    /// Starts Sentry using app bundle configuration when a DSN is available.
    static func startIfConfigured() {
        guard !isEnabled else { return }

        let info = Bundle.main.infoDictionary
        let sentryDSN = info?["SentryDSN"] as? String ?? ""
        guard !sentryDSN.isEmpty else {
            isEnabled = false
            return
        }
        let sentryEnv = info?["SentryEnvironment"] as? String ?? "production"

        SentrySDK.start { options in
            options.dsn = sentryDSN
            options.environment = sentryEnv
            #if DEBUG
            options.debug = true
            options.tracesSampleRate = 1.0
            #else
            options.tracesSampleRate = 0.1
            #endif
            options.attachStacktrace = true
            options.enableAppHangTracking = true
            options.appHangTimeoutInterval = 5.0
            options.maxBreadcrumbs = 200
            options.enableAutoSessionTracking = true
        }
        isEnabled = true
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

    /// Safely starts a performance transaction, only if Sentry is initialized.
    static func startTransaction(name: String, operation: String) -> Span? {
        guard isEnabled else { return nil }
        return SentrySDK.startTransaction(name: name, operation: operation)
    }
}
