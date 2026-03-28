// Analytics disabled build: no-op implementation
import Foundation
import AppKit

final class AnalyticsService {
    static let shared = AnalyticsService()
    private init() {}

    var isOptedIn: Bool {
        get { false }
        set { /* ignore */ }
    }

    func start(apiKey: String, host: String) {
        // no-op
    }

    func setOptIn(_ enabled: Bool) { /* no-op */ }
    func capture(_ name: String, _ props: [String: Any] = [:]) { /* no-op */ }
    func screen(_ name: String, _ props: [String: Any] = [:]) { /* no-op */ }
    func identify(_ distinctId: String, properties: [String: Any] = [:]) { /* no-op */ }
    func alias(_ aliasId: String) { /* no-op */ }
    func registerSuperProperties(_ props: [String: Any]) { /* no-op */ }
    func setPersonProperties(_ props: [String: Any]) { /* no-op */ }
    func throttled(_ key: String, minInterval: TimeInterval, action: () -> Void) { action() }
    func withSampling(probability: Double, action: () -> Void) { action() }
    func secondsBucket(_ seconds: Double) -> String { "" }
    func pctBucket(_ value: Double) -> String { "" }
    func captureValidationFailure(provider: String, operation: String, validationType: String, attempt: Int, model: String?, batchId: Int64?, errorDetail: String?) { /* no-op */ }
    func dayString(_ date: Date) -> String { "" }
}
