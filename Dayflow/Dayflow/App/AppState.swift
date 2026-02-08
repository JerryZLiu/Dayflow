import SwiftUI
import Combine

@MainActor // <--- Add this
protocol AppStateManaging: ObservableObject {
    // This requirement must now be fulfilled on the main actor
    var isRecording: Bool { get }
    var objectWillChange: ObservableObjectPublisher { get }
}

@MainActor
final class AppState: ObservableObject, AppStateManaging { // <-- Add AppStateManaging here
    static let shared = AppState()

    private let recordingKey = "isRecording"
    private var shouldPersist = false

    @Published var isRecording: Bool {
        didSet {
            // Only persist after onboarding is complete
            if shouldPersist {
                UserDefaults.standard.set(isRecording, forKey: recordingKey)
            }
        }
    }

    @Published var productivityScore: Int = 0
    @Published var hasProductivityData: Bool = false

    private init() {
        // Always start with false - AppDelegate will set the correct value
        // didSet doesn't fire during initialization, so this won't save
        self.isRecording = false
    }

    /// Enable persistence after onboarding is complete
    func enablePersistence() {
        shouldPersist = true
    }

    /// Get the saved recording preference, if any
    func getSavedPreference() -> Bool? {
        if UserDefaults.standard.object(forKey: recordingKey) != nil {
            return UserDefaults.standard.bool(forKey: recordingKey)
        }
        return nil
    }
}
