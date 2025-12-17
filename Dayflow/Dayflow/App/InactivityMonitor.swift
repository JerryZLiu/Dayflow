import AppKit
import Combine

@MainActor
final class InactivityMonitor: ObservableObject {
    static let shared = InactivityMonitor()

    // Published so views can react when an idle reset is pending
    @Published var pendingReset: Bool = false

    // Config
    private let secondsOverrideKey = "idleResetSecondsOverride"
    private let legacyMinutesKey = "idleResetMinutes"
    private let defaultThresholdSeconds: TimeInterval = 15 * 60

    var thresholdSeconds: TimeInterval {
        let override = UserDefaults.standard.double(forKey: secondsOverrideKey)
        if override > 0 { return override }

        let legacyMinutes = UserDefaults.standard.integer(forKey: legacyMinutesKey)
        if legacyMinutes > 0 {
            return TimeInterval(legacyMinutes * 60)
        }

        return defaultThresholdSeconds
    }

    // State
    private var lastInteractionAt: Date = Date()
    private var lastBecameInactiveAt: Date? = nil
    private var firedForCurrentIdle: Bool = false
    private var checkTimer: Timer?
    private var eventMonitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    private init() {}

    func start() {
        setupEventMonitors()
        setupAppLifecycleObservers()

        // Only check while active; we'll also check immediately on activation.
        if NSApp.isActive {
            startTimer()
        }
    }

    func stop() {
        stopTimer()
        removeEventMonitors()
        removeObservers()
    }

    func markHandledIfPending() {
        if pendingReset {
            pendingReset = false
        }
    }

    private func setupEventMonitors() {
        removeEventMonitors()

        let masks: [NSEvent.EventTypeMask] = [
            .keyDown,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .scrollWheel
        ]

        for mask in masks {
            let token = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                guard let self = self else { return event }
                self.handleInteraction()
                return event
            }
            if let token = token {
                eventMonitors.append(token)
            }
        }
    }

    private func removeEventMonitors() {
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors.removeAll()
    }

    private func setupAppLifecycleObservers() {
        removeObservers()

        let center = NotificationCenter.default

        let didResign = center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.lastBecameInactiveAt = Date()
            self.stopTimer()
        }
        observers.append(didResign)

        let didBecome = center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.handleBecameActive()
        }
        observers.append(didBecome)
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func handleInteraction() {
        lastInteractionAt = Date()
        lastBecameInactiveAt = nil
        firedForCurrentIdle = false
    }

    private func startTimer() {
        stopTimer()
        let interval = max(5.0, min(60.0, thresholdSeconds / 2))
        checkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkIdle()
            }
        }
    }

    private func stopTimer() {
        checkTimer?.invalidate()
        checkTimer = nil
    }

    private func checkIdle() {
        guard !pendingReset, !firedForCurrentIdle else { return }

        let threshold = thresholdSeconds
        let now = Date()
        let reference = lastBecameInactiveAt ?? lastInteractionAt
        guard now.timeIntervalSince(reference) >= threshold else { return }

        pendingReset = true
        firedForCurrentIdle = true
    }

    private func handleBecameActive() {
        // If we were inactive, decide based on how long the app was in the background.
        if let inactiveAt = lastBecameInactiveAt {
            let elapsed = Date().timeIntervalSince(inactiveAt)
            if !pendingReset, !firedForCurrentIdle, elapsed >= thresholdSeconds {
                pendingReset = true
                firedForCurrentIdle = true
            }
        } else {
            checkIdle()
        }

        // Clear background marker now that we're active again.
        lastBecameInactiveAt = nil
        startTimer()
    }
}
