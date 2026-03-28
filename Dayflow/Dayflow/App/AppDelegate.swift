//
//  AppDelegate.swift
//  Dayflow
//

import AppKit
import ServiceManagement
import ScreenCaptureKit
import Combine

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    // Controls whether the app is allowed to terminate.
    // Default is false so Cmd+Q/Dock/App menu quit will be cancelled
    // and the app will continue running in the background.
    static var allowTermination: Bool = false

    // Flag set when app is opened via notification tap - skips video intro
    static var pendingNavigationToChat: Bool = false
    private var statusBar: StatusBarController!
    private var recorder : ScreenRecorder!
    private var analyticsSub: AnyCancellable?
    private var powerObserver: NSObjectProtocol?
    private var deepLinkRouter: AppDeepLinkRouter?
    private var pendingDeepLinkURLs: [URL] = []
    private var pendingRecordingAnalyticsReason: String?
    private var heartbeatTimer: Timer?
    private var appLaunchDate: Date?
    private var foregroundStartTime: Date?

    override init() {
        UserDefaultsMigrator.migrateIfNeeded()
        super.init()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // Block termination by default; only specific flows enable it.
        AppDelegate.allowTermination = false

        // App opened (cold start)
        // Removed AnalyticsService.shared.capture("app_opened", ["cold_start": true])

        // Start heartbeat for DAU tracking
        appLaunchDate = Date()
        startHeartbeat()

        // App updated check
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let lastBuild = UserDefaults.standard.string(forKey: "lastRunBuild")
        if let last = lastBuild, last != build {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            // Removed AnalyticsService.shared.capture("app_updated", ["from_version": last, "to_version": "\(version) (\(build))"])        
        }
        UserDefaults.standard.set(build, forKey: "lastRunBuild")
        statusBar = StatusBarController()
        LaunchAtLoginManager.shared.bootstrapDefaultPreference()
        deepLinkRouter = AppDeepLinkRouter(delegate: self)

        // Check if we've passed the screen recording permission step
        let onboardingStep = OnboardingStepMigration.migrateIfNeeded()
        let didOnboard = UserDefaults.standard.bool(forKey: "didOnboard")

        // Seed recording flag low, then create recorder so the first
        // transition to true will reliably start capture.
        AppState.shared.isRecording = false
        recorder = ScreenRecorder(autoStart: true)

        // Only attempt to start recording if we're past the screen step or fully onboarded
        // Steps: 0=welcome, 1=howItWorks, 2=llmSelection, 3=llmSetup, 4=categories, 5=screen, 6=completion
        if didOnboard || onboardingStep > 5 {
            // Onboarding complete - enable persistence and restore user preference
            AppState.shared.enablePersistence()

            // Try to start recording, but handle permission failures gracefully
            Task { [weak self] in
                guard let self else { return }
                do {
                    // Check if we have permission by trying to access content
                    _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    // Permission granted - restore saved preference or default to ON
                    await MainActor.run {
                        let savedPref = AppState.shared.getSavedPreference()
                        AppState.shared.isRecording = savedPref ?? true
                    }
                    // Removed AnalyticsService.shared.capture("recording_toggled", ["enabled": finalState, "reason": "auto"])
                } catch {
                    // No permission or error - don't start recording
                    // User will need to grant permission in onboarding
                    await MainActor.run {
                        AppState.shared.isRecording = false
                    }
                    print("Screen recording permission not granted, skipping auto-start")
                }
                self.flushPendingDeepLinks()
            }
        } else {
            // Still in early onboarding, don't enable persistence yet
            // Keep recording off and don't persist this state
            AppState.shared.isRecording = false
            flushPendingDeepLinks()
        }
        
        // Start the Gemini analysis background job
        setupGeminiAnalysis()

        // Start inactivity monitoring for idle reset
        InactivityMonitor.shared.start()

        // Start notification service for journal reminders
        NotificationService.shared.start()

        // Observe recording state
        analyticsSub = AppState.shared.$isRecording
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                let reason = self.pendingRecordingAnalyticsReason ?? "user"
                guard reason != "auto" else { return }
                self.pendingRecordingAnalyticsReason = nil
                // Removed:
                // AnalyticsService.shared.capture("recording_toggled", ["enabled": enabled, "reason": reason])
                // AnalyticsService.shared.setPersonProperties(["recording_enabled": enabled])
            }

        powerObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AppDelegate.allowTermination = true
            }
        }

        // Track foreground sessions for engagement analytics
        setupForegroundTracking()
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.allowTermination {
            return .terminateNow
        }
        // Soft-quit: hide windows and remove Dock icon, but keep status item + background tasks
        NSApp.hide(nil)
        NSApp.setActivationPolicy(.accessory)
        return .terminateCancel
    }
    
    // MARK: - Foreground Tracking

    private func setupForegroundTracking() {
        // Initialize with current state (app is active at launch)
        foregroundStartTime = Date()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.foregroundStartTime = Date()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let startTime = self.foregroundStartTime else { return }
                let duration = Date().timeIntervalSince(startTime)
                self.foregroundStartTime = nil

                // Removed AnalyticsService.shared.capture("app_foreground_session", ...)
            }
        }
    }

    // Start Gemini analysis as a background task
    private func setupGeminiAnalysis() {
        // Perform after a short delay to ensure other initialization completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            AnalysisManager.shared.startAnalysisJob()
            print("AppDelegate: Gemini analysis job started")
            // Removed AnalyticsService.shared.capture("analysis_job_started", [...])
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if deepLinkRouter == nil {
            pendingDeepLinkURLs.append(contentsOf: urls)
            return
        }

        for url in urls {
            _ = deepLinkRouter?.handle(url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Checkpoint WAL to persist any pending database changes before quit
        // Using .truncate to also reset the WAL file for a clean state
        StorageManager.shared.checkpoint(mode: .truncate)

        heartbeatTimer?.invalidate()
        heartbeatTimer = nil

        if let observer = powerObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            powerObserver = nil
        }
        // Removed onboarding_abandoned analytics block
        // Removed AnalyticsService.shared.capture("app_terminated")
    }

    private func flushPendingDeepLinks() {
        guard let router = deepLinkRouter, !pendingDeepLinkURLs.isEmpty else { return }
        let urls = pendingDeepLinkURLs
        pendingDeepLinkURLs.removeAll()
        for url in urls {
            _ = router.handle(url)
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        // Removed initial call to sendHeartbeat()
        // Removed scheduled repeating timer for heartbeat sending
    }

    // Removed sendHeartbeat() method

}

extension AppDelegate: AppDeepLinkRouterDelegate {
    func prepareForRecordingToggle(reason: String) {
        pendingRecordingAnalyticsReason = reason
    }
}
