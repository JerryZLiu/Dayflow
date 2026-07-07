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
import ImageIO
@preconcurrency import ScreenCaptureKit
import Sentry

// MARK: - Configuration

/// Global screenshot configuration accessible throughout the app
enum ScreenshotConfig {
  /// Screenshot interval in seconds. Can be changed via UserDefaults.
  /// Used by: ScreenRecorder (capture), VideoProcessingService (compression), LLM providers (timestamp expansion)
  static var interval: TimeInterval {
    let stored = UserDefaults.standard.double(forKey: "screenshotIntervalSeconds")
    return stored > 0 ? stored : 10.0  // Default: 10 seconds
  }
}

private enum Config {
  static let targetHeight: CGFloat = 1080  // Scale screenshots to ~1080p
  static let jpegQuality: CGFloat = 0.85  // Balance quality vs file size

  /// Screenshot interval - references the global config
  static var screenshotInterval: TimeInterval {
    ScreenshotConfig.interval
  }

  /// Effective capture interval given current idle state. Throttles (rather
  /// than pauses) capture during long idle periods, per issue #286 — a hard
  /// pause would starve IdleBatchClassifier of the screenshots it needs to
  /// produce an "Idle" timeline card, turning idle periods into silent gaps.
  static func effectiveScreenshotInterval(idleSeconds: Int?) -> TimeInterval {
    guard IdleCapturePreferences.enabled else { return screenshotInterval }
    return IdleCaptureInterval.interval(
      baseInterval: screenshotInterval,
      idleThrottledInterval: IdleCaptureDefaults.throttledIntervalSeconds,
      idleSeconds: idleSeconds,
      idleThresholdSeconds: IdleCaptureDefaults.idleThresholdSeconds
    )
  }
}

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
  }

  deinit {
    sub?.cancel()
    activeDisplaySub?.cancel()
    dbg("deinit")
  }

  // MARK: - Properties

  private let q = DispatchQueue(label: "com.dayflow.recorder", qos: .userInitiated)
  private var captureTimer: DispatchSourceTimer?
  private var currentCaptureInterval: TimeInterval?
  private var sub: AnyCancellable?
  private var activeDisplaySub: AnyCancellable?
  private var state: RecorderState = .idle
  private var wantsRecording = false
  private var tracker: ActiveDisplayTracker!
  private var currentDisplayID: CGDirectDisplayID?
  private var requestedDisplayID: CGDirectDisplayID?

  // ScreenCaptureKit objects (refreshed on each capture cycle)
  private var cachedContent: SCShareableContent?
  private var cachedDisplay: SCDisplay?

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

      // 2. Choose display: prefer requested → active → first
      let displaysByID: [CGDirectDisplayID: SCDisplay] = Dictionary(
        uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) }
      )
      let trackerID: CGDirectDisplayID? = await MainActor.run { [weak tracker] in
        tracker?.activeDisplayID
      }
      let preferredID = requestedDisplayID ?? trackerID

      let display: SCDisplay
      if let pid = preferredID, let scd = displaysByID[pid] {
        display = scd
      } else if let first = content.displays.first {
        display = first
      } else {
        throw ScreenRecorderError.noDisplay
      }

      cachedDisplay = display
      currentDisplayID = display.displayID
      requestedDisplayID = nil

      dbg("Setup complete - display \(display.displayID) (\(display.width)x\(display.height))")

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

  private func startCaptureTimer(interval: TimeInterval? = nil) {
    stopCaptureTimer()

    let resolvedInterval =
      interval ?? Config.effectiveScreenshotInterval(idleSeconds: InputIdleSnapshot.currentIdleSeconds())
    currentCaptureInterval = resolvedInterval

    let timer = DispatchSource.makeTimerSource(queue: q)
    timer.schedule(deadline: .now() + resolvedInterval, repeating: resolvedInterval)
    timer.setEventHandler { [weak self] in
      Task { await self?.captureScreenshot() }
    }
    timer.resume()
    captureTimer = timer

    dbg("Capture timer started (interval: \(resolvedInterval)s)")
  }

  private func stopCaptureTimer() {
    captureTimer?.cancel()
    captureTimer = nil
    currentCaptureInterval = nil
  }

  /// Re-checks the idle-throttled target interval and restarts the capture
  /// timer if it has changed since it was last scheduled. Called on every
  /// capture tick rather than driven by a separate poller, since a fixed
  /// DispatchSourceTimer can't self-adjust its own repeat interval. The tick
  /// that crosses the idle threshold still fires at the old cadence — the
  /// new interval only takes effect starting from the next scheduled tick —
  /// so there's a bounded, self-correcting one-tick lag in either direction.
  /// Acceptable for a battery/disk optimization; not a correctness concern.
  private func rescheduleCaptureTimerIfIntervalChanged() {
    let idleSeconds = InputIdleSnapshot.currentIdleSeconds()
    let targetInterval = Config.effectiveScreenshotInterval(idleSeconds: idleSeconds)
    guard targetInterval != currentCaptureInterval else { return }

    dbg(
      "Capture interval changing: \(String(describing: currentCaptureInterval))s → \(targetInterval)s (idle: \(String(describing: idleSeconds))s)"
    )
    startCaptureTimer(interval: targetInterval)
  }

  // MARK: - Screenshot Capture

  private func captureScreenshot() async {
    guard state == .capturing else {
      dbg("captureScreenshot skipped - state: \(state.description)")
      return
    }

    rescheduleCaptureTimerIfIntervalChanged()

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
          let jpegData = await MainActor.run(body: {
            RecordingPrivacyPlaceholder.jpegData(
              size: CGSize(width: captureSize.width, height: captureSize.height),
              quality: Config.jpegQuality,
              applicationName: blockedApplication.name
            )
          })
        else {
          throw ScreenRecorderError.imageConversionFailed
        }
        _ = try saveScreenshotData(
          jpegData,
          capturedAt: captureTime,
          idleSecondsAtCapture: idleSecondsAtCapture
        )
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

      // 4. Convert to JPEG
      guard let jpegData = jpegData(from: image, quality: Config.jpegQuality) else {
        throw ScreenRecorderError.imageConversionFailed
      }

      // 5. Save to disk and register in the database
      let fileURL = try saveScreenshotData(
        jpegData,
        capturedAt: captureTime,
        idleSecondsAtCapture: idleSecondsAtCapture
      )

      dbg("📸 Screenshot saved: \(fileURL.lastPathComponent) (\(jpegData.count / 1024)KB)")

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

  private func scaledCaptureSize(for display: SCDisplay) -> (width: Int, height: Int) {
    let aspectRatio = Double(display.width) / Double(display.height)
    var targetWidth = Int(Double(Config.targetHeight) * aspectRatio)
    if targetWidth % 2 != 0 { targetWidth += 1 }
    var targetHeight = Int(Config.targetHeight)
    if targetHeight % 2 != 0 { targetHeight += 1 }
    return (targetWidth, targetHeight)
  }

  private func saveScreenshotData(
    _ jpegData: Data,
    capturedAt: Date,
    idleSecondsAtCapture: Int?
  ) throws -> URL {
    let fileURL = StorageManager.shared.nextScreenshotURL()
    try jpegData.write(to: fileURL)

    _ = StorageManager.shared.saveScreenshot(
      url: fileURL,
      capturedAt: capturedAt,
      idleSecondsAtCapture: idleSecondsAtCapture
    )
    return fileURL
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

      // Prefer requested display (from active display tracking) over current
      let targetID = requestedDisplayID ?? currentDisplayID

      if let id = targetID,
        let display = content.displays.first(where: { $0.displayID == id })
      {
        cachedDisplay = display
        currentDisplayID = id
        if requestedDisplayID == id { requestedDisplayID = nil }
        dbg("Switched to display \(id)")
      } else if let first = content.displays.first {
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

  // MARK: - Image Conversion

  private func jpegData(from cgImage: CGImage, quality: CGFloat) -> Data? {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data as CFMutableData, "public.jpeg" as CFString, 1, nil)
    else {
      return nil
    }
    CGImageDestinationAddImage(
      destination, cgImage,
      [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }

  // MARK: - Display Change Handling

  private func handleActiveDisplayChange(_ newID: CGDirectDisplayID) {
    requestedDisplayID = newID

    guard wantsRecording else {
      dbg("Active display changed – recording disabled, deferring switch")
      return
    }

    guard currentDisplayID != nil, state == .capturing else {
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
