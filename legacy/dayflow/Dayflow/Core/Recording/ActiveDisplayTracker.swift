//
//  ActiveDisplayTracker.swift
//  Dayflow
//
//  Tracks the CGDirectDisplayID under the mouse with debounce to avoid
//  flapping when the cursor grazes multi-monitor borders.
//

import AppKit
import Combine
import Foundation

@MainActor
final class ActiveDisplayTracker: ObservableObject {
  @Published private(set) var activeDisplayID: CGDirectDisplayID?

  private var timerSource: DispatchSourceTimer?
  private var screensObserver: Any?

  // Debounce state (accessed only from stateQueue - manually synchronized)
  private let stateQueue = DispatchQueue(label: "com.dayflow.ActiveDisplayTracker.state")
  nonisolated(unsafe) private var candidateID: CGDirectDisplayID?
  nonisolated(unsafe) private var candidateSince: Date?

  // Tunables
  private let pollHz: Double
  private let debounceSeconds: TimeInterval
  private let hysteresisInset: CGFloat

  /// - pollHz: How often to check mouse position. Default 0.1 = once per 10 seconds.
  ///   Lower values save significant battery (6Hz was 21,600 wakeups/hour).
  init(pollHz: Double = 0.1, debounceMs: Double = 400, hysteresisInset: CGFloat = 10) {
    self.pollHz = max(0.01, pollHz)  // Allow very slow polling for battery savings
    self.debounceSeconds = max(0.0, debounceMs / 1000.0)
    self.hysteresisInset = hysteresisInset

    // Observe screen parameter changes to refresh immediately
    screensObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: NSApplication.shared,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.handleDisplayChange()
      }
    }

    start()
  }

  deinit {
    timerSource?.cancel()
    timerSource = nil
    if let obs = screensObserver { NotificationCenter.default.removeObserver(obs) }
  }

  private func handleDisplayChange() {
    stateQueue.async {
      self.candidateID = nil
      self.candidateSince = nil
    }
    // Trigger an immediate poll
    stateQueue.async {
      self.pollDisplayOnBackground()
    }
  }

  private func start() {
    stop()

    let interval = 1.0 / pollHz
    let source = DispatchSource.makeTimerSource(queue: stateQueue)
    // Leeway allows macOS to coalesce timer fires for better energy efficiency
    let leeway = DispatchTimeInterval.milliseconds(Int(interval * 100))  // 10% tolerance
    source.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
    source.setEventHandler { [weak self] in
      self?.pollDisplayOnBackground()
    }
    source.resume()
    timerSource = source
  }

  private func stop() {
    timerSource?.cancel()
    timerSource = nil
  }

  /// Called on stateQueue (background) - does the heavy lifting off the main thread
  nonisolated private func pollDisplayOnBackground() {
    // Get mouse location - this can occasionally block, so we do it off main
    let loc = NSEvent.mouseLocation
    let inset = hysteresisInset

    // Get screens snapshot
    let screens = NSScreen.screens

    // Find screen under cursor with hysteresis
    guard
      let screen = screens.first(where: { $0.frame.insetBy(dx: inset, dy: inset).contains(loc) })
        ?? screens.first(where: { $0.frame.contains(loc) })
    else { return }

    let newID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
      .uint32Value
    guard let id = newID else { return }

    let now = Date()

    // Debounce logic
    if candidateID != id {
      candidateID = id
      candidateSince = now
      return
    }

    // Candidate is stable long enough - update the published property on main actor
    if let since = candidateSince, now.timeIntervalSince(since) >= debounceSeconds {
      let stableID = id
      Task { @MainActor [weak self] in
        guard let self = self else { return }
        if self.activeDisplayID != stableID {
          self.activeDisplayID = stableID
        }
      }
    }
  }
}
