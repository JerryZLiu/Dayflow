//
//  ActiveDisplayTracker.swift
//  Dayflow
//
//  Tracks the CGDirectDisplayID under the mouse with debounce to avoid
//  flapping when the cursor grazes multi-monitor borders.
//

import Foundation
import AppKit
import Combine

@MainActor
final class ActiveDisplayTracker: ObservableObject {
    @Published private(set) var activeDisplayID: CGDirectDisplayID?

    private var timer: Timer?
    private var candidateID: CGDirectDisplayID?
    private var candidateSince: Date?
    private var screensObserver: Any?

    // Tunables
    private let pollHz: Double
    private let debounceSeconds: TimeInterval
    private let hysteresisInset: CGFloat

    init(pollHz: Double = 6.0, debounceMs: Double = 400, hysteresisInset: CGFloat = 10) {
        self.pollHz = max(1.0, pollHz)
        self.debounceSeconds = max(0.0, debounceMs / 1000.0)
        self.hysteresisInset = hysteresisInset

        // Observe screen parameter changes to refresh immediately
        screensObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: NSApplication.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.resetCandidateDueToDisplayChange()
                await self?.tick()
            }
        }

        start()
    }

    deinit {
        // Avoid calling main-actor methods from deinit
        timer?.invalidate()
        timer = nil
        if let obs = screensObserver { NotificationCenter.default.removeObserver(obs) }
    }

    private func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / pollHz, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.tick()
            }
        }
        RunLoop.current.add(timer!, forMode: .common)
    }

    private func stop() { timer?.invalidate(); timer = nil }

    @MainActor
    private func resetCandidateDueToDisplayChange() {
        candidateID = nil
        candidateSince = nil
    }

    @MainActor
    private func tick() {
        let loc = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: hysteresisInset, dy: hysteresisInset).contains(loc) })
                ?? NSScreen.screens.first(where: { $0.frame.contains(loc) })
        else { return }

        let newID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let id = newID else { return }

        let now = Date()
        if candidateID != id {
            candidateID = id
            candidateSince = now
            return
        }

        // Candidate is stable long enough
        if activeDisplayID != id, let since = candidateSince, now.timeIntervalSince(since) >= debounceSeconds {
            activeDisplayID = id
        }
    }
}
