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
import CoreImage
import CoreMedia
import Foundation
import OSLog
@preconcurrency import ScreenCaptureKit
import Sentry

// MARK: - Configuration
// Capture interval and resolution live in `ScreenshotConfig` (RecordingPreferences.swift).

private final class DayflowScreenCaptureStreamSession: NSObject, @unchecked Sendable,
  ScreenCaptureStreamSession, SCStreamOutput, SCStreamDelegate
{
  typealias ResolveFilter = @Sendable (ScreenCaptureFilterDescriptor) throws -> SCContentFilter

  private let outputQueue = DispatchQueue(
    label: "com.dayflow.recorder.stream-output",
    qos: .userInitiated
  )
  private let settings: ScreenCaptureStreamSettings
  private let resolveFilter: ResolveFilter
  private let onFrame: @Sendable (CGImage?, Date) -> Void
  private let onError: @Sendable (NSError) -> Void
  private let imageContext = CIContext(options: [.cacheIntermediates: false])
  private var stream: SCStream!

  init(
    descriptor: ScreenCaptureFilterDescriptor,
    filter: SCContentFilter,
    settings: ScreenCaptureStreamSettings,
    resolveFilter: @escaping ResolveFilter,
    onFrame: @escaping @Sendable (CGImage?, Date) -> Void,
    onError: @escaping @Sendable (NSError) -> Void
  ) throws {
    self.settings = settings
    self.resolveFilter = resolveFilter
    self.onFrame = onFrame
    self.onError = onError
    super.init()

    stream = SCStream(
      filter: filter,
      configuration: Self.configuration(for: descriptor, settings: settings),
      delegate: self
    )
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
  }

  func start() async throws {
    try await stream.startCapture()
  }

  func updateFilter(_ descriptor: ScreenCaptureFilterDescriptor) async throws {
    let filter = try resolveFilter(descriptor)
    try await stream.updateContentFilter(filter)
    try await stream.updateConfiguration(Self.configuration(for: descriptor, settings: settings))
    await withCheckedContinuation { continuation in
      outputQueue.async { continuation.resume() }
    }
  }

  func stop() async {
    try? await stream.stopCapture()
    try? stream.removeStreamOutput(self, type: .screen)
  }

  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of outputType: SCStreamOutputType
  ) {
    guard outputType == .screen else { return }
    guard sampleBuffer.isValid else { return }
    let capturedAt = Date()
    guard let status = frameStatus(in: sampleBuffer) else { return }
    if status == .idle {
      onFrame(nil, capturedAt)
      return
    }
    guard status == .complete || status == .started else { return }
    guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

    let image = CIImage(cvPixelBuffer: pixelBuffer)
    guard let cgImage = imageContext.createCGImage(image, from: image.extent) else { return }
    onFrame(cgImage, capturedAt)
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    onError(error as NSError)
  }

  private func frameStatus(in sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer,
        createIfNecessary: false
      ) as? [[SCStreamFrameInfo: Any]],
      let statusRawValue = attachments.first?[.status] as? Int
    else {
      return nil
    }
    return SCFrameStatus(rawValue: statusRawValue)
  }

  private static func configuration(
    for descriptor: ScreenCaptureFilterDescriptor,
    settings: ScreenCaptureStreamSettings
  ) -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    configuration.width = descriptor.width
    configuration.height = descriptor.height
    configuration.scalesToFit = true
    configuration.showsCursor = true
    configuration.capturesAudio = false
    configuration.queueDepth = settings.queueDepth
    configuration.minimumFrameInterval = CMTime(
      seconds: settings.frameInterval,
      preferredTimescale: 600
    )
    return configuration
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
private let recorderLogger = Logger(subsystem: "teleportlabs.com.Dayflow", category: "screen-capture")
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
    let didCompleteOnboarding = UserDefaults.standard.bool(forKey: "didOnboard")
    let history = ScreenCapturePermissionHistory(
      didCompleteOnboarding: didCompleteOnboarding)
    authorization = ScreenCaptureAuthorizationCoordinator(
      wasGranted: history.wasGranted,
      history: history
    )
    super.init()
    streamLifecycle = makeStreamLifecycle(interval: ScreenshotConfig.interval)
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

    privacySub = NotificationCenter.default.publisher(
      for: RecordingPrivacyPreferences.didChangeNotification
    )
    .sink { [weak self] _ in
      self?.q.async { [weak self] in
        guard let self, self.state == .capturing else { return }
        Task { await self.refreshDisplay() }
      }
    }

    manualResumeSub = NotificationCenter.default.publisher(for: .resumeScreenCaptureRequested)
      .sink { [weak self] _ in
        self?.q.async { [weak self] in
          guard let self else { return }
          guard ScreenCaptureManualResumePolicy.shouldResume(
            wantsRecording: self.wantsRecording,
            hasActiveSession: self.streamLifecycle.hasActiveSession
          ) else { return }
          self.authorizationRecoveryTask?.cancel()
          self.authorizationRecoveryTask = nil
          self.captureRestartTask?.cancel()
          self.captureRestartTask = nil
          if self.retryState.isRetryRunning {
            self.retryState.finishRetry(recovered: false)
          }
          self.scheduleCaptureRestart(manual: true)
        }
      }

    // Honor the current flag once (after subscriptions exist)
    if autoStart, AppState.shared.isRecording { start() }

    registerForSleepAndLock()
    registerForCaptureSettingChanges()
    FrameStore.shared.reconcileAfterLaunch()
  }

  private func makeStreamLifecycle(
    interval: TimeInterval
  ) -> ScreenCaptureStreamLifecycle<CGImage> {
    ScreenCaptureStreamLifecycle(
      interval: interval,
      builder: { [weak self] descriptor, settings, onFrame, onError in
        guard let self else { throw ScreenRecorderError.screenshotFailed }
        return try self.makeStreamSession(
          descriptor: descriptor,
          settings: settings,
          onFrame: onFrame,
          onError: onError
        )
      },
      saveFrame: { [weak self] image, capturedAt in
        self?.saveCapturedFrame(image, capturedAt: capturedAt)
      },
      handleError: { [weak self] error in
        self?.handleStreamFailure(error)
      }
    )
  }

  deinit {
    sub?.cancel()
    activeDisplaySub?.cancel()
    privacySub?.cancel()
    manualResumeSub?.cancel()
    authorizationRecoveryTask?.cancel()
    captureRestartTask?.cancel()
    streamFailureTask?.cancel()
    dbg("deinit")
  }

  // MARK: - Properties

  private let q = DispatchQueue(label: "com.dayflow.recorder", qos: .userInitiated)
  private var sub: AnyCancellable?
  private var activeDisplaySub: AnyCancellable?
  private var privacySub: AnyCancellable?
  private var manualResumeSub: AnyCancellable?
  private var state: RecorderState = .idle
  private var wantsRecording = false
  private var tracker: ActiveDisplayTracker!
  private var currentDisplayID: CGDirectDisplayID?
  private var requestedDisplayID: CGDirectDisplayID?
  private let authorization: ScreenCaptureAuthorizationCoordinator
  private var authorizationRecoveryTask: Task<Void, Never>?
  private var streamLifecycle: ScreenCaptureStreamLifecycle<CGImage>!
  private var captureRestartTask: Task<Void, Never>?
  private var streamFailureTask: Task<Void, Never>?
  private var retryState = ScreenCaptureRetryState()
  private var recoveryUsesBackoff = false

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
      let setup = self.streamLifecycle.beginSetup()
      Task { await self.setupCapture(setup: setup) }
    }
  }

  func stop() {
    q.async { [weak self] in
      guard let self else { return }
      self.authorizationRecoveryTask?.cancel()
      self.authorizationRecoveryTask = nil
      self.captureRestartTask?.cancel()
      self.captureRestartTask = nil
      self.streamFailureTask?.cancel()
      self.streamFailureTask = nil
      self.retryState.markRecovered()
      Task { await self.authorization.cancelConfirmation() }
      let stopTask = self.streamLifecycle.requestStop()
      Task { await stopTask.value }
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

  private func setupCapture(
    setup: ScreenCaptureSetupToken,
    attempt: Int = 1,
    maxAttempts: Int = 4
  ) async {
    guard streamLifecycle.isCurrentSetup(setup) else { return }
    guard await authorization.checkBeforeCapture() else {
      await handleScreenCaptureUnavailable(reason: "setupCapture")
      return
    }
    guard streamLifecycle.isCurrentSetup(setup) else { return }

    do {
      // 1. Get shareable content (requires screen recording permission)
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)
      guard streamLifecycle.isCurrentSetup(setup) else { return }
      cachedContent = content
      await authorization.recordCaptureSuccess()

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

      guard let display else { throw ScreenRecorderError.noDisplay }
      let descriptor = makeFilterDescriptor(display: display, content: content)
      try await streamLifecycle.start(filter: descriptor, setup: setup)

      q.async { [weak self] in
        guard let self else { return }
        guard self.state == .starting else {
          dbg("setupCapture completed but state changed to \(self.state.description), ignoring")
          return
        }
        self.retryState.markRecovered()
        self.recoveryUsesBackoff = false
        self.transition(to: .capturing, context: "stream started")
      }

      Task { @MainActor in
        AnalyticsService.shared.withSampling(probability: 0.01) {
          AnalyticsService.shared.capture("recording_started", ["mode": "stream"])
        }
      }

    } catch is CancellationError {
      dbg("setupCapture cancelled because recording stopped")
      return
    } catch {
      dbg("setupCapture failed [attempt \(attempt)] – \(error.localizedDescription)")

      let nsError = error as NSError
      let preflightGranted = await authorization.checkBeforeCapture()
      if !preflightGranted || nsError.domain == SCStreamErrorDomain {
        if preflightGranted {
          handleStreamFailure(nsError)
        } else {
          await handleScreenCaptureUnavailable(
            reason: "setupCapture_failed_permission",
            error: nsError,
            useBackoffAfterRecovery: true
          )
        }
        return
      }

      q.async { [weak self] in
        self?.transition(to: .idle, context: "setupCapture failed")
      }

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

  private func makeFilterDescriptor(
    display: SCDisplay,
    content: SCShareableContent
  ) -> ScreenCaptureFilterDescriptor {
    let size = scaledCaptureSize(for: display)
    let excludedApplicationIDs = RecordingPrivacyPreferences
      .blockedScreenCaptureApplications(in: content)
      .map(\.bundleIdentifier)
      .sorted()
    return ScreenCaptureFilterDescriptor(
      displayID: display.displayID,
      width: size.width,
      height: size.height,
      excludedApplicationIDs: excludedApplicationIDs
    )
  }

  private func makeContentFilter(
    for descriptor: ScreenCaptureFilterDescriptor
  ) throws -> SCContentFilter {
    guard let content = cachedContent else { throw ScreenRecorderError.noDisplay }
    guard let display = content.displays.first(where: { $0.displayID == descriptor.displayID }) else {
      throw ScreenRecorderError.noDisplay
    }
    let excludedIDs = Set(descriptor.excludedApplicationIDs)
    let excludedApplications = content.applications.filter {
      excludedIDs.contains($0.bundleIdentifier)
    }
    if excludedApplications.isEmpty {
      return SCContentFilter(display: display, excludingWindows: [])
    }
    return SCContentFilter(
      display: display,
      excludingApplications: excludedApplications,
      exceptingWindows: []
    )
  }

  private func makeStreamSession(
    descriptor: ScreenCaptureFilterDescriptor,
    settings: ScreenCaptureStreamSettings,
    onFrame: @escaping @Sendable (CGImage?, Date) -> Void,
    onError: @escaping @Sendable (NSError) -> Void
  ) throws -> ScreenCaptureStreamSession {
    try DayflowScreenCaptureStreamSession(
      descriptor: descriptor,
      filter: makeContentFilter(for: descriptor),
      settings: settings,
      resolveFilter: { [weak self] descriptor in
        guard let self else { throw ScreenRecorderError.noDisplay }
        return try self.makeContentFilter(for: descriptor)
      },
      onFrame: onFrame,
      onError: onError
    )
  }

  private func saveCapturedFrame(_ image: CGImage, capturedAt: Date) {
    Task { await authorization.recordCaptureSuccess() }
    q.async { [weak self] in
      guard let self, self.state == .capturing, let display = self.cachedDisplay else { return }
      let captureSize = self.scaledCaptureSize(for: display)
      let idleSeconds = InputIdleSnapshot.currentIdleSeconds()

      Task { @MainActor [weak self] in
        guard let self else { return }
        let frame = RecordingPrivacyPreferences.frontmostBlockedApplication().flatMap {
          RecordingPrivacyPlaceholder.image(
            width: captureSize.width,
            height: captureSize.height,
            applicationName: $0.name
          )
        } ?? image

        self.q.async { [weak self] in
          guard let self else { return }
          do {
            try self.appendFrame(
              frame,
              capturedAt: capturedAt,
              idleSecondsAtCapture: idleSeconds
            )
            dbg("Frame appended (\(frame.width)x\(frame.height))")
          } catch {
            let nsError = error as NSError
            recorderLogger.error(
              "Frame save failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
            )
          }
        }
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
    guard await authorization.checkBeforeCapture() else {
      await handleScreenCaptureUnavailable(reason: "refreshDisplay")
      return
    }

    do {
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)
      cachedContent = content
      await authorization.recordCaptureSuccess()

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

      if let display = cachedDisplay {
        let descriptor = makeFilterDescriptor(display: display, content: content)
        try await streamLifecycle.updateFilter(descriptor)
      }
    } catch {
      let nsError = error as NSError
      let preflightGranted = await authorization.checkBeforeCapture()
      if preflightGranted {
        handleStreamFailure(nsError)
      } else {
        await handleScreenCaptureUnavailable(
          reason: "refreshDisplay_failed_permission",
          error: nsError,
          useBackoffAfterRecovery: true
        )
      }
      return
    }
  }

  private func handleScreenCaptureUnavailable(
    reason: String,
    error: NSError? = nil,
    useBackoffAfterRecovery: Bool = false
  ) async {
    if let error {
      recorderLogger.error(
        "ScreenCaptureKit failure domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public)"
      )
      await authorization.recordCaptureFailure(error)
    }
    let authorizationState = await authorization.state

    q.async { [weak self] in
      guard let self else { return }
      self.recoveryUsesBackoff = self.recoveryUsesBackoff || useBackoffAfterRecovery
      let stopTask = self.streamLifecycle.requestStop()
      Task { await stopTask.value }
      self.cachedContent = nil
      self.cachedDisplay = nil
      self.currentDisplayID = nil
      if self.state != .paused {
        self.transition(to: .paused, context: "screen capture temporarily unavailable")
      }
      self.scheduleAuthorizationConfirmation()
    }

    ScreenRecordingPermissionNotice.postAuthorizationState(
      authorizationState,
      reason: reason
    )
  }

  private func scheduleAuthorizationConfirmation() {
    guard authorizationRecoveryTask == nil else { return }
    authorizationRecoveryTask = Task { [weak self] in
      guard let self else { return }
      await authorization.confirmWithoutPrompting()
      let authorizationState = await authorization.state
      ScreenRecordingPermissionNotice.postAuthorizationState(
        authorizationState,
        reason: "confirmation_complete"
      )

      q.async { [weak self] in
        guard let self else { return }
        self.authorizationRecoveryTask = nil
        guard self.wantsRecording else { return }
        guard authorizationState == .granted else { return }
        if self.recoveryUsesBackoff {
          self.scheduleCaptureRestart()
        } else {
          self.transition(to: .idle, context: "screen capture permission recovered")
          self.start()
        }
      }
    }
  }

  private func handleStreamFailure(_ error: NSError) {
    recorderLogger.error(
      "ScreenCaptureKit failure domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public)"
    )
    q.async { [weak self] in
      guard let self else { return }
      guard self.captureRestartTask == nil, self.streamFailureTask == nil else { return }
      self.recoveryUsesBackoff = true
      if self.state != .paused {
        self.transition(to: .paused, context: "screen stream failed")
      }
      let stopTask = self.streamLifecycle.requestStop()
      self.streamFailureTask = Task { [weak self] in
        guard let self else { return }
        await self.authorization.recordCaptureFailure(error)
        await stopTask.value
        if await self.authorization.preflightIsGranted() {
          self.q.async { [weak self] in
            guard let self else { return }
            self.streamFailureTask = nil
            self.scheduleCaptureRestart()
          }
        } else {
          self.q.async { [weak self] in self?.streamFailureTask = nil }
          await self.handleScreenCaptureUnavailable(
            reason: "stream_failed_permission",
            useBackoffAfterRecovery: true
          )
        }
      }
    }
  }

  private func scheduleCaptureRestart(manual: Bool = false) {
    guard captureRestartTask == nil else { return }
    let delay = manual ? retryState.beginManualRetry() : retryState.beginRetry()
    guard let delay else { return }

    captureRestartTask = Task { [weak self] in
      guard let self else { return }
      if delay > 0 {
        try? await Task.sleep(for: .seconds(delay))
      }
      guard !Task.isCancelled else { return }

      guard await authorization.checkBeforeCapture() else {
        q.async { [weak self] in
          guard let self else { return }
          self.captureRestartTask = nil
          self.retryState.finishRetry(recovered: false)
        }
        await handleScreenCaptureUnavailable(
          reason: "stream_retry_preflight",
          useBackoffAfterRecovery: true
        )
        return
      }

      q.async { [weak self] in
        guard let self else { return }
        self.captureRestartTask = nil
        self.retryState.finishRetry(recovered: false)
        guard self.wantsRecording else { return }
        self.transition(to: .idle, context: manual ? "manual stream retry" : "stream retry")
        self.start()
      }
    }
  }

  // MARK: - Capture Setting Changes

  private func registerForCaptureSettingChanges() {
    // Recreate the stream so interval and resolution changes both take effect.
    NotificationCenter.default.addObserver(
      forName: ScreenshotConfig.didChange,
      object: nil, queue: nil
    ) { [weak self] _ in
      self?.q.async { [weak self] in
        guard let self, self.state == .capturing else { return }
        let oldLifecycle = self.streamLifecycle
        let stopTask = oldLifecycle?.requestStop()
        Task {
          await stopTask?.value
          self.q.async { [weak self] in
            guard let self, self.wantsRecording else { return }
            FrameStore.shared.finishCurrentSegment()
            self.streamLifecycle = self.makeStreamLifecycle(interval: ScreenshotConfig.interval)
            self.transition(to: .idle, context: "capture settings changed")
            self.start()
          }
        }
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
