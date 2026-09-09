//
//  ScreenRecorder.swift
//  Dayflow
//
//  Rewritten to use SCScreenshotManager for periodic screenshots
//  instead of continuous video capture. This eliminates the screen
//  recording indicator while maintaining the same data flow.
//

import AppKit
import Combine
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit
import Sentry

// MARK: - Configuration
// Capture interval and resolution live in `ScreenshotConfig` (RecordingPreferences.swift).

private enum InputIdleSnapshot {
  // Bridge kCGAnyInputEventType into Swift without relying on a generated symbol name.
  static let anyInputEventType = CGEventType(rawValue: UInt32.max)!

  static func currentIdleSeconds() -> Int? {
    // Prefer the HID state table so the signal reflects hardware-originated user input.
    let idleSeconds = CGEventSource.secondsSinceLastEventType(
      .hidSystemState,
      eventType: anyInputEventType
    )
    guard idleSeconds.isFinite, idleSeconds >= 0 else { return nil }
    return Int(idleSeconds.rounded(.down))
  }
}

// MARK: - Debug Logging

private let recorderDebugLogging = false
@inline(__always) func dbg(_ msg: @autoclosure () -> String) {
  guard recorderDebugLogging else { return }
  print("[Recorder] \(msg())")
}

// MARK: - State Machine

/// Explicit state machine for the recorder lifecycle
private enum RecorderState: Equatable {
  case idle  // Not capturing
  case starting  // Initiating capture setup
  case capturing  // Active screenshot timer running
  case paused  // System event pause (sleep/lock), will auto-resume

  var description: String {
    switch self {
    case .idle: return "idle"
    case .starting: return "starting"
    case .capturing: return "capturing"
    case .paused: return "paused"
    }
  }

  var canStart: Bool {
    switch self {
    case .idle, .paused: return true
    case .starting, .capturing: return false
    }
  }
}

// MARK: - Errors

private enum ScreenRecorderError: Error {
  case noDisplay
  case screenshotFailed
  case imageConversionFailed
}

// MARK: - ScreenRecorder

final class ScreenRecorder: NSObject, @unchecked Sendable {

  // MARK: - Initialization

  @MainActor
  init(autoStart: Bool = true) {
    super.init()
    dbg("init – autoStart = \(autoStart)")

    wantsRecording = AppState.shared.isRecording

    // Observe the app-wide recording flag
    sub = AppState.shared.$isRecording
      .dropFirst()
      .removeDuplicates()
      .sink { [weak self] rec in
        self?.q.async { [weak self] in
          guard let self else { return }
          self.wantsRecording = rec

          // Clear paused state when user disables recording
          if !rec && self.state == .paused {
            self.transition(to: .idle, context: "user disabled recording")
          }

          rec ? self.start() : self.stop()
        }
      }

    // Active display tracking
    tracker = ActiveDisplayTracker()
    activeDisplaySub = tracker.$activeDisplayID
      .removeDuplicates()
      .sink { [weak self] newID in
        guard let self, let newID else { return }
        self.q.async { [weak self] in self?.handleActiveDisplayChange(newID) }
      }

    // Honor the current flag once (after subscriptions exist)
    if autoStart, AppState.shared.isRecording { start() }

    registerForSleepAndLock()
    registerForCaptureSettingChanges()
    FrameStore.shared.reconcileAfterLaunch()
  }

  deinit {
    sub?.cancel()
    activeDisplaySub?.cancel()
    dbg("deinit")
  }

  // MARK: - Properties

  private let q = DispatchQueue(label: "com.dayflow.recorder", qos: .userInitiated)
  private var captureTimer: DispatchSourceTimer?
  private var sub: AnyCancellable?
  private var activeDisplaySub: AnyCancellable?
  private var state: RecorderState = .idle
  private var wantsRecording = false
  private var tracker: ActiveDisplayTracker!
  private var currentDisplayID: CGDirectDisplayID?
  private var requestedDisplayID: CGDirectDisplayID?

  // ScreenCaptureKit objects (refreshed on each capture cycle).
  // Written on `q` (stop/permission loss) and from async setup/refresh tasks,
  // read from capture tasks on the cooperative pool. Guard them with a lock so a
  // reader never retains a reference that another thread is releasing.
  private let displayLock = NSLock()
  private var _cachedContent: SCShareableContent?
  private var _cachedDisplay: SCDisplay?

  private var cachedContent: SCShareableContent? {
    get { displayLock.withLock { _cachedContent } }
    set { displayLock.withLock { _cachedContent = newValue } }
  }

  private var cachedDisplay: SCDisplay? {
    get { displayLock.withLock { _cachedDisplay } }
    set { displayLock.withLock { _cachedDisplay = newValue } }
  }

  // MARK: - State Transitions

  private func transition(to newState: RecorderState, context: String? = nil) {
    let oldState = state
    state = newState

    let message =
      context.map { "\(oldState.description) → \(newState.description) (\($0))" }
      ?? "\(oldState.description) → \(newState.description)"
    dbg("State: \(message)")

    let breadcrumb = Breadcrumb(level: .info, category: "recorder_state")
    breadcrumb.message = message
    breadcrumb.data = [
      "old_state": oldState.description,
      "new_state": newState.description,
    ]
    if let ctx = context {
      breadcrumb.data?["context"] = ctx
    }
    SentryHelper.addBreadcrumb(breadcrumb)
  }

  // MARK: - Start/Stop

  func start() {
    q.async { [weak self] in
      guard let self else { return }
      guard self.wantsRecording else {
        dbg("start – suppressed (recording disabled)")
        return
      }
      guard self.state.canStart else {
        dbg("start – invalid state: \(self.state.description)")
        return
      }

      self.transition(to: .starting, context: "user/system start")
      Task { await self.setupCapture() }
    }
  }

  func stop() {
    q.async { [weak self] in
      guard let self else { return }
      self.stopCaptureTimer()
      self.cachedContent = nil
      self.cachedDisplay = nil
      self.currentDisplayID = nil
      FrameStore.shared.finishCurrentSegment()

      if self.state != .paused {
        self.transition(to: .idle, context: "stopped")
      }
      dbg("capture stopped")
    }
  }

  // MARK: - Capture Setup

  private func setupCapture(attempt: Int = 1, maxAttempts: Int = 4) async {
    guard ScreenRecordingPermissionNotice.isGranted else {
      handleMissingScreenRecordingPermission(reason: "setupCapture")
      return
    }

    do {
      // 1. Get shareable content (requires screen recording permission)
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)
      cachedContent = content

      // 2. Choose display: prefer requested → active. Defer if preferred is missing from the snapshot.
      let displaysByID: [CGDirectDisplayID: SCDisplay] = Dictionary(
        uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) }
      )
      let trackerID: CGDirectDisplayID? = await MainActor.run { [weak tracker] in
        tracker?.activeDisplayID
      }
      let preferredID = requestedDisplayID ?? trackerID

      let display: SCDisplay?
      if let pid = preferredID {
        display = displaysByID[pid]
        if display == nil {
          requestedDisplayID = pid
          dbg(
            "setupCapture: preferred display \(pid) not in snapshot (count=\(content.displays.count)); deferring"
          )
        } else {
          requestedDisplayID = nil
        }
      } else if let first = content.displays.first {
        display = first
        requestedDisplayID = nil
      } else {
        throw ScreenRecorderError.noDisplay
      }

      cachedDisplay = display
      currentDisplayID = display?.displayID

      if let d = display {
        dbg("Setup complete - display \(d.displayID) (\(d.width)x\(d.height))")
      } else {
        dbg("Setup complete - awaiting display availability")
      }

      // 3. Start capture timer
      q.async { [weak self] in
        guard let self else { return }
        guard self.state == .starting else {
          dbg("setupCapture completed but state changed to \(self.state.description), ignoring")
          return
        }
        self.startCaptureTimer()
        self.transition(to: .capturing, context: "capture started")

        // Take first screenshot immediately
        Task { await self.captureScreenshot() }
      }

      Task { @MainActor in
        AnalyticsService.shared.withSampling(probability: 0.01) {
          AnalyticsService.shared.capture("recording_started", ["mode": "screenshot"])
        }
      }

    } catch {
      dbg("setupCapture failed [attempt \(attempt)] – \(error.localizedDescription)")

      if !ScreenRecordingPermissionNotice.isGranted {
        handleMissingScreenRecordingPermission(reason: "setupCapture_failed_permission")
        return
      }

      q.async { [weak self] in
        self?.transition(to: .idle, context: "setupCapture failed")
      }

      let nsError = error as NSError
      let isNoDisplay = (error as? ScreenRecorderError) == .noDisplay

      if isNoDisplay && attempt < maxAttempts {
        let delay = Double(attempt)
        dbg("retrying in \(delay)s")
        q.asyncAfter(deadline: .now() + delay) { [weak self] in self?.start() }
      } else {
        Task { @MainActor in
          AnalyticsService.shared.capture(
            "recording_startup_failed",
            [
              "attempt": attempt,
              "error_domain": nsError.domain,
              "error_code": nsError.code,
            ])
        }
      }
    }
  }

  // MARK: - Capture Timer

  private func startCaptureTimer() {
    stopCaptureTimer()

    let interval = ScreenshotConfig.interval
    let timer = DispatchSource.makeTimerSource(queue: q)
    timer.schedule(deadline: .now() + interval, repeating: interval)
    timer.setEventHandler { [weak self] in
      Task { await self?.captureScreenshot() }
    }
    timer.resume()
    captureTimer = timer

    dbg("Capture timer started (interval: \(interval)s)")
  }

  private func stopCaptureTimer() {
    captureTimer?.cancel()
    captureTimer = nil
  }

  // MARK: - Screenshot Capture

  private func captureScreenshot() async {
    guard state == .capturing else {
      dbg("captureScreenshot skipped - state: \(state.description)")
      return
    }
    guard let display = cachedDisplay else {
      dbg("captureScreenshot skipped - no display")
      return
    }
    guard ScreenRecordingPermissionNotice.isGranted else {
      handleMissingScreenRecordingPermission(reason: "captureScreenshot")
      return
    }

    let captureTime = Date()
    let idleSecondsAtCapture = InputIdleSnapshot.currentIdleSeconds()

    do {
      let captureSize = scaledCaptureSize(for: display)
      if let blockedApplication = await MainActor.run(body: {
        RecordingPrivacyPreferences.frontmostBlockedApplication()
      }) {
        guard
          let placeholder = await MainActor.run(body: {
            RecordingPrivacyPlaceholder.image(
              width: captureSize.width,
              height: captureSize.height,
              applicationName: blockedApplication.name
            )
          })
        else {
          throw ScreenRecorderError.imageConversionFailed
        }
        try appendFrame(
          placeholder, capturedAt: captureTime, idleSecondsAtCapture: idleSecondsAtCapture)
        dbg("🔒 Screenshot redacted for blocked foreground application")
        return
      }

      // 1. Create content filter for the display
      let excludedApplications =
        cachedContent.map {
          RecordingPrivacyPreferences.blockedScreenCaptureApplications(in: $0)
        } ?? []
      let filter =
        excludedApplications.isEmpty
        ? SCContentFilter(display: display, excludingWindows: [])
        : SCContentFilter(
          display: display,
          excludingApplications: excludedApplications,
          exceptingWindows: []
        )

      // 2. Configure screenshot
      let config = SCStreamConfiguration()

      config.width = captureSize.width
      config.height = captureSize.height
      config.scalesToFit = true
      config.showsCursor = true

      // 3. Capture screenshot
      let image = try await SCScreenshotManager.captureImage(
        contentFilter: filter,
        configuration: config
      )

      // 4. Encode into the current HEVC segment and register in the database
      try appendFrame(image, capturedAt: captureTime, idleSecondsAtCapture: idleSecondsAtCapture)
      dbg("📸 Frame appended (\(image.width)x\(image.height))")

    } catch {
      dbg("❌ Screenshot capture failed: \(error.localizedDescription)")

      if !ScreenRecordingPermissionNotice.isGranted {
        handleMissingScreenRecordingPermission(reason: "captureScreenshot_failed_permission")
        return
      }

      // If display became unavailable, try to refresh
      if (error as NSError).domain == SCStreamErrorDomain {
        dbg("SCStream error - will refresh display on next capture")
        Task { await refreshDisplay() }
      }
    }
  }

  /// Re-checks state right before writing so a capture that was in flight during
  /// `stop()` does not reopen a segment that would then sit open through sleep.
  private func appendFrame(_ image: CGImage, capturedAt: Date, idleSecondsAtCapture: Int?) throws {
    guard state == .capturing else {
      dbg("frame dropped - recorder stopped mid-capture")
      return
    }
    let screenshotId = FrameStore.shared.append(
      image, capturedAt: capturedAt, idleSecondsAtCapture: idleSecondsAtCapture)
    guard screenshotId != nil else {
      throw ScreenRecorderError.imageConversionFailed
    }
  }

  private func scaledCaptureSize(for display: SCDisplay) -> (width: Int, height: Int) {
    let targetHeight = Double(ScreenshotConfig.captureHeight)
    let aspectRatio = Double(display.width) / Double(display.height)
    var width = Int(targetHeight * aspectRatio)
    if width % 2 != 0 { width += 1 }
    var height = Int(targetHeight)
    if height % 2 != 0 { height += 1 }
    return (width, height)
  }

  private func refreshDisplay() async {
    guard ScreenRecordingPermissionNotice.isGranted else {
      handleMissingScreenRecordingPermission(reason: "refreshDisplay")
      return
    }

    do {
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)
      cachedContent = content

      // Prefer requested display over current; hold if missing from snapshot.
      let targetID = requestedDisplayID ?? currentDisplayID

      if let id = targetID {
        if let display = content.displays.first(where: { $0.displayID == id }) {
          cachedDisplay = display
          currentDisplayID = id
          if requestedDisplayID == id { requestedDisplayID = nil }
          dbg("Switched to display \(id)")
        } else {
          dbg(
            "refreshDisplay: target \(id) not in snapshot (count=\(content.displays.count)); keeping current"
          )
        }
      } else if let first = content.displays.first, cachedDisplay == nil {
        cachedDisplay = first
        currentDisplayID = first.displayID
      }
    } catch {
      if !ScreenRecordingPermissionNotice.isGranted {
        handleMissingScreenRecordingPermission(reason: "refreshDisplay_failed_permission")
        return
      }

      dbg("Failed to refresh display: \(error)")
    }
  }

  private func handleMissingScreenRecordingPermission(reason: String) {
    q.async { [weak self] in
      guard let self else { return }
      self.stopCaptureTimer()
      self.cachedContent = nil
      self.cachedDisplay = nil
      self.currentDisplayID = nil
      if self.state != .idle {
        self.transition(to: .idle, context: "missing screen recording permission")
      }
      self.wantsRecording = false
    }

    Task { @MainActor in
      if AppState.shared.isRecording {
        AppState.shared.setRecording(
          false,
          analyticsReason: "permission_missing",
          persistPreference: false
        )
      }
      ScreenRecordingPermissionNotice.post(reason: reason)
    }
  }

  // MARK: - Capture Setting Changes

  private func registerForCaptureSettingChanges() {
    // Interval changes restart the timer; resolution changes take effect on the
    // next capture because FrameStore rotates segments when frame size changes.
    NotificationCenter.default.addObserver(
      forName: ScreenshotConfig.didChange,
      object: nil, queue: nil
    ) { [weak self] _ in
      self?.q.async { [weak self] in
        guard let self, self.state == .capturing else { return }
        dbg("capture settings changed – restarting timer")
        self.startCaptureTimer()
      }
    }

    // Finalize the open segment so a clean quit never loses the last few minutes.
    NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification,
      object: nil, queue: nil
    ) { _ in
      FrameStore.shared.finishCurrentSegment()
    }
  }

  // MARK: - Display Change Handling

  private func handleActiveDisplayChange(_ newID: CGDirectDisplayID) {
    requestedDisplayID = newID

    guard wantsRecording else {
      dbg("Active display changed – recording disabled, deferring switch")
      return
    }

    guard state == .capturing else {
      dbg("Active display changed while not capturing – will switch on next start")
      return
    }
    guard newID != currentDisplayID else { return }

    dbg("Active display changed → switching: \(String(describing: currentDisplayID)) → \(newID)")

    // Refresh display for next screenshot
    Task { await refreshDisplay() }
  }

  // MARK: - System Events (Sleep/Lock)

  private func registerForSleepAndLock() {
    let nc = NSWorkspace.shared.notificationCenter
    let dnc = DistributedNotificationCenter.default()

    // Screen configuration changed — recover any deferred display selection.
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil, queue: nil
    ) { [weak self] _ in
      self?.q.async { [weak self] in
        guard let self, self.state == .capturing else { return }
        dbg("didChangeScreenParameters – refreshing display selection")
        Task { await self.refreshDisplay() }
      }
    }

    // System will sleep
    nc.addObserver(
      forName: NSWorkspace.willSleepNotification,
      object: nil, queue: nil
    ) { [weak self] _ in
      guard let self else { return }
      dbg("willSleep – pausing")

      self.q.async { [weak self] in
        guard let self else { return }
        Task { @MainActor in
          if AppState.shared.isRecording {
            self.q.async { [weak self] in
              self?.transition(to: .paused, context: "system sleep")
            }
          }
        }
      }
      self.stop()
      Task { @MainActor in
        AnalyticsService.shared.withSampling(probability: 0.01) {
          AnalyticsService.shared.capture("recording_stopped", ["stop_reason": "system_sleep"])
        }
      }
    }

    // System did wake
    nc.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil, queue: nil
    ) { [weak self] _ in
      guard let self else { return }
      dbg("didWake – checking flag")

      self.q.async { [weak self] in
        guard let self else { return }
        guard self.state == .paused else { return }
        self.resumeRecording(after: 5, context: "didWake")
      }
    }

    // Screen locked
    dnc.addObserver(
      forName: .init("com.apple.screenIsLocked"),
      object: nil, queue: nil
    ) { [weak self] _ in
      guard let self else { return }
      dbg("screen locked – pausing")

      self.q.async { [weak self] in
        guard let self else { return }
        Task { @MainActor in
          if AppState.shared.isRecording {
            self.q.async { [weak self] in
              self?.transition(to: .paused, context: "screen locked")
            }
          }
        }
      }
      self.stop()
      Task { @MainActor in
        AnalyticsService.shared.withSampling(probability: 0.01) {
          AnalyticsService.shared.capture("recording_stopped", ["stop_reason": "lock"])
        }
      }
    }

    // Screen unlocked
    dnc.addObserver(
      forName: .init("com.apple.screenIsUnlocked"),
      object: nil, queue: nil
    ) { [weak self] _ in
      guard let self else { return }
      dbg("screen unlocked – checking flag")

      self.q.async { [weak self] in
        guard let self else { return }
        guard self.state == .paused else { return }
        self.resumeRecording(after: 0.5, context: "screen unlock")
      }
    }

    // Screensaver started
    dnc.addObserver(
      forName: .init("com.apple.screensaver.didstart"),
      object: nil, queue: nil
    ) { [weak self] _ in
      guard let self else { return }
      dbg("screensaver started – pausing")

      self.q.async { [weak self] in
        guard let self else { return }
        Task { @MainActor in
          if AppState.shared.isRecording {
            self.q.async { [weak self] in
              self?.transition(to: .paused, context: "screensaver started")
            }
          }
        }
      }
      self.stop()
      Task { @MainActor in
        AnalyticsService.shared.withSampling(probability: 0.01) {
          AnalyticsService.shared.capture("recording_stopped", ["stop_reason": "screensaver"])
        }
      }
    }

    // Screensaver stopped
    dnc.addObserver(
      forName: .init("com.apple.screensaver.didstop"),
      object: nil, queue: nil
    ) { [weak self] _ in
      guard let self else { return }
      dbg("screensaver stopped – checking flag")

      self.q.async { [weak self] in
        guard let self else { return }
        guard self.state == .paused else { return }
        self.resumeRecording(after: 0.5, context: "screensaver stop")
      }
    }
  }

  private func resumeRecording(after delay: TimeInterval, context: String) {
    q.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        guard AppState.shared.isRecording else {
          dbg("\(context) – skip auto-resume (recording disabled)")
          return
        }
        self.start()
      }
    }
  }
}
