// Updater disabled build: no-op manager
import Foundation
import OSLog
import Combine

@MainActor
final class UpdaterManager: NSObject, ObservableObject {
    static let shared = UpdaterManager()

    @Published var isChecking = false
    @Published var statusText: String = ""
    @Published var updateAvailable = false
    @Published var latestVersionString: String? = nil

    private let logger = Logger(subsystem: "com.dayflow.app", category: "sparkle")

    private override init() {
        super.init()
        print("[Updater] Sparkle disabled; updates are not checked.")
    }

    func checkForUpdates(showUI: Bool = false) {
        isChecking = true
        statusText = "Updates disabled"
        logger.debug("Updates disabled; ignoring checkForUpdates")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.isChecking = false
        }
    }
}
