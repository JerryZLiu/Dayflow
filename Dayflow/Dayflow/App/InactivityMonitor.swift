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
    private var lastResetAt: Date? = nil
    private var checkTimer: Timer?
    private var eventMonitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    private init() {}

    func start() {
        setupEventMonitors()
        setupAppLifecycleObservers()

        // Only check while active; we'll also check immediately before activation.
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

        let willBecome = center.addObserver(
            forName: NSApplication.willBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkIdle()
            }
        }
        observers.append(willBecome)

        let didBecome = center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.startTimer()
            }
        }
        observers.append(didBecome)

        let didResign = center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopTimer()
            }
        }
        observers.append(didResign)
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
        lastResetAt = nil
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
        guard !pendingReset else { return }

        let threshold = thresholdSeconds
        let now = Date()
        guard now.timeIntervalSince(lastInteractionAt) >= threshold else { return }

        if let lastResetAt, now.timeIntervalSince(lastResetAt) < threshold {
            return
        }

        pendingReset = true
        lastResetAt = now
    }
}
