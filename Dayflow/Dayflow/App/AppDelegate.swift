//
//  AppDelegate.swift
//  FocusLock
//

import AppKit
import ServiceManagement
import ScreenCaptureKit
import PostHog
import Sentry
import Combine
import UserNotifications

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    // Controls whether the app is allowed to terminate.
    // Default is false so Cmd+Q/Dock/App menu quit will be cancelled
    // and the app will continue running in the background.
    static var allowTermination: Bool = false
    private var statusBar: StatusBarController!
    private var recorder : ScreenRecorder!
    private var analyticsSub: AnyCancellable?
    private var powerObserver: NSObjectProtocol?
    private var deepLinkRouter: AppDeepLinkRouter?
    private var pendingDeepLinkURLs: [URL] = []
    private var pendingRecordingAnalyticsReason: String?

    // FocusLock autostart properties
    private var launchAgentManager: LaunchAgentManager?
    private var backgroundMonitor: BackgroundMonitor?
    private var focusLockSettings: FocusLockSettingsManager?
    private var isAutostartMode: Bool = false
    private var lastPermissionCheck: Date? // For debouncing permission checks

    override init() {
        UserDefaultsMigrator.migrateIfNeeded()

        // Check for autostart mode
        let arguments = CommandLine.arguments
        isAutostartMode = arguments.contains("--autostart")

        super.init()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // Block termination by default; only specific flows enable it.
        AppDelegate.allowTermination = false

        // Configure crash reporting (Sentry) - only if user has opted in
        let info = Bundle.main.infoDictionary
        let SENTRY_DSN = info?["SentryDSN"] as? String ?? ""
        let SENTRY_ENV = info?["SentryEnvironment"] as? String ?? "production"

        // Check analytics opt-in (unified consent for both crash reporting and analytics)
        if !SENTRY_DSN.isEmpty && AnalyticsService.shared.isOptedIn {
            SentrySDK.start { options in
                options.dsn = SENTRY_DSN
                options.environment = SENTRY_ENV
                // Enable debug logging in development (disable for production)
                #if DEBUG
                options.debug = true
                options.tracesSampleRate = 1.0  // 100% in debug for testing
                #else
                options.tracesSampleRate = 0.1  // 10% in prod to reduce noise
                #endif
                // Attach stack traces to all messages (helpful for debugging)
                options.attachStacktrace = true
                // Enable app hang detection with a 5-second threshold to reduce noise
                options.enableAppHangTracking = true
                options.appHangTimeoutInterval = 5.0
                // Increase breadcrumb limit for better debugging context
                options.maxBreadcrumbs = 200  // Default is 100
                // Enable automatic session tracking
                options.enableAutoSessionTracking = true
            }
            // Enable safe wrapper now that Sentry is initialized
            SentryHelper.isEnabled = true
            print("✅ Crash Reporting: Sentry initialized with user consent.")
        } else if !SENTRY_DSN.isEmpty {
            print("🔒 Crash Reporting: User has not opted in. Sentry will not be initialized.")
        }

        // Configure analytics (privacy-first: default opt-in OFF)
        let POSTHOG_API_KEY = info?["PHPostHogApiKey"] as? String ?? ""
        let POSTHOG_HOST = info?["PHPostHogHost"] as? String ?? "https://us.i.posthog.com"
        if !POSTHOG_API_KEY.isEmpty {
            AnalyticsService.shared.start(apiKey: POSTHOG_API_KEY, host: POSTHOG_HOST)
        }

        // App opened (cold start)
        AnalyticsService.shared.capture("app_opened", ["cold_start": true])

        // App updated check
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let lastBuild = UserDefaults.standard.string(forKey: "lastRunBuild")
        if let last = lastBuild, last != build {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            AnalyticsService.shared.capture("app_updated", ["from_version": last, "to_version": "\(version) (\(build))"])        
        }
        UserDefaults.standard.set(build, forKey: "lastRunBuild")
        
        statusBar = StatusBarController()   // safe: AppKit is ready, main thread
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
            // Add debouncing to prevent race conditions from rapid permission checks
            let permissionCheckDebounceInterval: TimeInterval = 2.0 // 2 second debounce
            
            Task { [weak self] in
                guard let self else { return }
                
                // Debounce permission checks
                let now = Date()
                if let lastCheck = self.lastPermissionCheck, now.timeIntervalSince(lastCheck) < permissionCheckDebounceInterval {
                    // Too soon after last check - skip
                    print("Permission check debounced (last check was \(now.timeIntervalSince(lastCheck))s ago)")
                    self.flushPendingDeepLinks()
                    return
                }
                self.lastPermissionCheck = now
                
                do {
                    // Check if we have permission by trying to access content
                    _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    // Permission granted - restore saved preference or default to ON
                    await MainActor.run {
                        let savedPref = AppState.shared.getSavedPreference()
                        AppState.shared.isRecording = savedPref ?? true
                    }
                    let finalState = await MainActor.run { AppState.shared.isRecording }
                    AnalyticsService.shared.capture("recording_toggled", ["enabled": finalState, "reason": "auto"])
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
        
        // Register login item helper (Ventura+). Non-fatal if user disabled it.
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.loginItem(identifier: "teleportlabs.com.FocusLock.LoginItem").register()
            } catch {
                print("Login item register failed: \(error)")
            }
        }
        
        // Start the Gemini analysis background job
        setupGeminiAnalysis()

        // Start inactivity monitoring for idle reset
        InactivityMonitor.shared.start()

        // Initialize FocusLock components
        setupFocusLock()
        
        // Pre-initialize database singletons to prevent lazy init during UI rendering
        // This prevents synchronous database operations on the main thread causing SIGABRT crashes
        Task {
            await HybridMemoryStore.shared.ensureInitialized()
            print("✅ AppDelegate: HybridMemoryStore pre-initialized")

            await SuggestedTodosEngine.shared.ensureInitialized()
            print("✅ AppDelegate: SuggestedTodosEngine pre-initialized")

            // TodoExtractionEngine uses sync loading, ensure it's initialized early
            TodoExtractionEngine.shared.ensureInitialized()
            print("✅ AppDelegate: TodoExtractionEngine pre-initialized")

            print("✅ AppDelegate: All database singletons pre-initialized successfully")
        }

        // Observe recording state
        analyticsSub = AppState.shared.$isRecording
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                let reason = self.pendingRecordingAnalyticsReason ?? "user"
                self.pendingRecordingAnalyticsReason = nil
                AnalyticsService.shared.capture("recording_toggled", ["enabled": enabled, "reason": reason])
                AnalyticsService.shared.setPersonProperties(["recording_enabled": enabled])
            }

        powerObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AppDelegate.allowTermination = true
            }
        }

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
    
    // Start Gemini analysis as a background task
    private func setupGeminiAnalysis() {
        // Perform after a short delay to ensure other initialization completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            AnalysisManager.shared.startAnalysisJob()
            print("AppDelegate: Gemini analysis job started")
            AnalyticsService.shared.capture("analysis_job_started", [
                "provider": {
                    if let data = UserDefaults.standard.data(forKey: "llmProviderType"),
                       let providerType = try? JSONDecoder().decode(LLMProviderType.self, from: data) {
                        switch providerType {
                        case .geminiDirect: return "gemini"
                        case .dayflowBackend: return "dayflow"
                        case .ollamaLocal: return "ollama"
                        case .chatGPTClaude: return "chat_cli"
                        }
                    }
                    return "unknown"
                }()
            ])
        }
    }

    // MARK: - FocusLock Setup

    private func setupFocusLock() {
        // Initialize FocusLock components
        launchAgentManager = LaunchAgentManager.shared
        backgroundMonitor = BackgroundMonitor.shared
        focusLockSettings = FocusLockSettingsManager.shared

        // Load settings and validate
        focusLockSettings?.loadSettings()
        let validationIssues = focusLockSettings?.validateSettings() ?? []
        if !validationIssues.isEmpty {
            print("AppDelegate: FocusLock settings validation issues: \(validationIssues)")
        }

        // Refresh autostart status from system
        focusLockSettings?.refreshAutostartStatus()
        
        // Pre-initialize critical singletons to prevent lazy init during UI rendering
        // This prevents priority inversion and memory corruption crashes
        print("AppDelegate: FocusLock components initialized")
        Task { @MainActor in
            // Initialize ProactiveCoachEngine and load its data asynchronously
            let proactiveEngine = ProactiveCoachEngine.shared
            await proactiveEngine.loadDataAsync()
            
            // Initialize FocusSessionManager (which references ProactiveCoachEngine)
            _ = FocusSessionManager.shared
            
            // Initialize TodoExtractionEngine
            _ = TodoExtractionEngine.shared
            
            print("AppDelegate: Proactive engine and session manager ready")
        }

        // Handle autostart mode
        if isAutostartMode {
            print("AppDelegate: FocusLock started in autostart mode")
            handleAutostartLaunch()
        } else {
            print("AppDelegate: FocusLock started in normal mode")
            // For normal launches, ensure LaunchAgent status is checked
            launchAgentManager?.checkAgentStatus()
        }

        // Start background monitoring if enabled
        if focusLockSettings?.enableBackgroundMonitoring == true {
            if SessionManager.shared.currentState != .idle {
                backgroundMonitor?.startMonitoring()
            }
        }

        print("AppDelegate: FocusLock components initialized")
        print("AppDelegate: Autostart status: \(focusLockSettings?.autostartStatusDescription ?? "Unknown")")
    }

    private func handleAutostartLaunch() {
        // In autostart mode, we want to minimize UI and start background services
        let isBackgroundMode = CommandLine.arguments.contains("--background")

        if isBackgroundMode {
            print("AppDelegate: FocusLock running in background mode")
            // Start background monitoring without showing main UI
            if focusLockSettings?.enableBackgroundMonitoring == true {
                backgroundMonitor?.startMonitoring()
            }

            // Show notification if enabled
            if focusLockSettings?.enableNotifications == true {
                let center = UNUserNotificationCenter.current()
                let content = UNMutableNotificationContent()
                content.title = "FocusLock Active"
                content.body = "FocusLock is running in the background"
                content.sound = nil // Quiet notification
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                center.add(request) { error in
                    if let error = error {
                        print("Failed to deliver notification: \(error.localizedDescription)")
                    }
                }
            }
        } else {
            print("AppDelegate: FocusLock autostart with UI")
            // Autostart with UI - proceed with normal launch but maybe minimize
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                // Optional: minimize window after launch
                if let window = NSApp.windows.first {
                    window.miniaturize(nil)
                }
            }
        }

        // Ensure LaunchAgent is properly installed and status is current
        launchAgentManager?.checkAgentStatus()
        focusLockSettings?.refreshAutostartStatus()
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
        // Cleanup FocusLock components
        backgroundMonitor?.stopMonitoring()
        launchAgentManager = nil
        backgroundMonitor = nil
        focusLockSettings = nil

        if let observer = powerObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            powerObserver = nil
        }
        // If onboarding not completed, mark abandoned with last step
        let didOnboard = UserDefaults.standard.bool(forKey: "didOnboard")
        if !didOnboard {
            let stepIdx = OnboardingStepMigration.migrateIfNeeded()
            let stepName: String = {
                switch stepIdx {
                case 0: return "welcome"
                case 1: return "how_it_works"
                case 2: return "llm_selection"
                case 3: return "llm_setup"
                case 4: return "categories"
                case 5: return "screen_recording"
                case 6: return "completion"
                default: return "unknown"
                }
            }()
            AnalyticsService.shared.capture("onboarding_abandoned", ["last_step": stepName])
        }
        AnalyticsService.shared.capture("app_terminated")
    }

    private func flushPendingDeepLinks() {
        guard let router = deepLinkRouter, !pendingDeepLinkURLs.isEmpty else { return }
        let urls = pendingDeepLinkURLs
        pendingDeepLinkURLs.removeAll()
        for url in urls {
            _ = router.handle(url)
        }
    }
}

extension AppDelegate: AppDeepLinkRouterDelegate {
    func prepareForRecordingToggle(reason: String) {
        pendingRecordingAnalyticsReason = reason
    }
}
