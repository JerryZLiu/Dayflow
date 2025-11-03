//
//  ScreenRecorder.swift
//  Dayflow
//

import Foundation
@preconcurrency import ScreenCaptureKit
@preconcurrency import AVFoundation
import Combine
import IOKit.pwr_mgt
import AppKit
import CoreGraphics
import CoreText
import Sentry

private enum C {
    static let targetHeight = 1080               // Target ~1080p resolution
    static let chunk  : TimeInterval = 15        // seconds per file
    static let fps    : Int32        = 1         // keep @ 1 fps - NOTE: This is intentionally low!
}

private enum SCStreamErrorCode: Int {
    case noDisplayOrWindow = -3807          // Transient error, display disconnected
    case userStoppedViaSystemUI = -3808     // User clicked "Stop Sharing" in system UI
    case displayNotReady = -3815            // Failed to find displays/windows after wake/unlock
    case userDeclined = -3817               // Alternative code for user stop
    case connectionInvalid = -3805          // Stream connection became invalid
    case attemptToStopStreamState = -3802   // Stream already stopping
    case stoppedBySystem = -3821            // System stopped stream (usually disk space)
    
    var isUserInitiated: Bool {
        switch self {
        case .userStoppedViaSystemUI, .userDeclined:
            return true
        default:
            return false
        }
    }
    
    var shouldAutoRestart: Bool {
        switch self {
        case .noDisplayOrWindow, .displayNotReady, .stoppedBySystem:
            return true  // Transient errors, should retry
        case .userStoppedViaSystemUI, .userDeclined, .connectionInvalid, .attemptToStopStreamState:
            return false // User action or unrecoverable error
        }
    }
}

#if DEBUG
@inline(__always) func dbg(_ msg: @autoclosure () -> String) { print("[Recorder] \(msg())") }
#else
@inline(__always) func dbg(_: @autoclosure () -> String) {}
#endif

/// Explicit state machine for the recorder lifecycle
private enum RecorderState: Equatable {
    case idle           // Not recording, no active resources
    case starting       // Initiating stream creation (async operation in progress)
    case recording      // Active stream + writer
    case finishing      // Cleaning up current segment
    case paused         // System event pause (sleep/lock), will auto-resume

    var description: String {
        switch self {
        case .idle: return "idle"
        case .starting: return "starting"
        case .recording: return "recording"
        case .finishing: return "finishing"
        case .paused: return "paused"
        }
    }

    var canStart: Bool {
        switch self {
        case .idle, .paused: return true
        case .starting, .recording, .finishing: return false
        }
    }

    var canStop: Bool {
        switch self {
        case .starting, .recording, .finishing: return true
        case .idle, .paused: return false
        }
    }
}

final class ScreenRecorder: NSObject, SCStreamOutput {

    @MainActor
    init(autoStart: Bool = true) {
        super.init()
        dbg("init – autoStart = \(autoStart)")

        wantsRecording = AppState.shared.isRecording

        // Observe the app-wide recording flag on the main actor,
        // then hop our work back onto the recorder queue.
        sub = AppState.shared.$isRecording
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] rec in
                self?.q.async { [weak self] in
                    guard let self else { return }
                    self.wantsRecording = rec

                    // Clear paused state when user disables recording
                    // This prevents auto-resume after sleep/wake if user turned it off
                    if !rec && self.state == .paused {
                        self.transition(to: .idle, context: "user disabled recording")
                    }

                    Task { @MainActor [weak self] in
                        if rec {
                            await self?.start()
                        } else {
                            await self?.stop()
                        }
                    }
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

        // Honor the current flag once (after subscriptions exist).
        if autoStart, AppState.shared.isRecording { start() }

        registerForSleepAndLock()
    }

        deinit { sub?.cancel(); activeDisplaySub?.cancel(); dbg("deinit") }

    private let q = DispatchQueue(label: "com.dayflow.recorder", qos: .userInitiated)
    private var stream : SCStream?
    private var writer : AVAssetWriter?
    private var input  : AVAssetWriterInput?
    private var firstPTS : CMTime?
    private var timer  : DispatchSourceTimer?
    private var fileURL: URL?
    private var sub    : AnyCancellable?
    private var activeDisplaySub: AnyCancellable?
    private var frames : Int = 0
    private var state: RecorderState = .idle  // Single source of truth for recorder state
    private var wantsRecording = false        // mirrors AppState flag on recorder queue
    private var recordingWidth: Int = 1280   // Store recording dimensions
    private var recordingHeight: Int = 800
    @MainActor private var tracker: ActiveDisplayTracker!
    private var currentDisplayID: CGDirectDisplayID?
    private var requestedDisplayID: CGDirectDisplayID?

    /// Transitions to a new state and logs it for debugging
    private func transition(to newState: RecorderState, context: String? = nil) {
        let oldState = state
        state = newState

        let message = context.map { "\(oldState.description) → \(newState.description) (\($0))" }
                      ?? "\(oldState.description) → \(newState.description)"
        dbg("State: \(message)")

        // Breadcrumbs are only sent if an error/crash occurs - zero cost otherwise
        let breadcrumb = Breadcrumb(level: .info, category: "recorder_state")
        breadcrumb.message = message
        breadcrumb.data = [
            "old_state": oldState.description,
            "new_state": newState.description
        ]
        if let ctx = context {
            breadcrumb.data?["context"] = ctx
        }
        SentryHelper.addBreadcrumb(breadcrumb)
    }

    @MainActor
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
            Task { await self.makeStream() }
        }
    }

    @MainActor
    func stop() {
        q.async { [weak self] in
            guard let self else { return }

            self.finishSegment(restart: false)
            self.stopStream()               // (stopStream transitions to idle)
        }
    }

    @MainActor
    private func shouldRetry(_ err: NSError?) -> Bool {
        guard let scErr = err, scErr.domain == SCStreamErrorDomain else { return false }

        if let errorCode = SCStreamErrorCode(rawValue: Int(scErr.code)) {
            dbg("SCStream error code: \(scErr.code) (\(errorCode)) - shouldAutoRestart: \(errorCode.shouldAutoRestart)")
            return errorCode.shouldAutoRestart
        }

        dbg("Unknown SCStream error code: \(scErr.code) - not retrying")
        return false
    }

    @MainActor
    private func shouldRetry(_ err: Error) -> Bool {
        let nsError = err as NSError
        return shouldRetry(nsError as NSError?)
    }
    
    @MainActor
    private func isUserInitiatedStop(_ err: NSError?) -> Bool {
        guard let scErr = err, scErr.domain == SCStreamErrorDomain else { return false }

        if let errorCode = SCStreamErrorCode(rawValue: Int(scErr.code)) {
            return errorCode.isUserInitiated
        }

        let userInfo = scErr.userInfo
        if let reason = userInfo[NSLocalizedFailureReasonErrorKey] as? String {
            let userStopIndicators = ["user stopped", "stopped by user", "user cancelled", "stop sharing"]
            let lowercasedReason = reason.lowercased()
            if userStopIndicators.contains(where: { lowercasedReason.contains($0) }) {
                dbg("Detected user stop from error reason: \(reason)")
                return true
            }
        }
        
        return false
    }

    @MainActor
    private func isUserInitiatedStop(_ err: Error) -> Bool {
        let nsError = err as NSError
        return isUserInitiatedStop(nsError as NSError?)
    }

    private func makeStream(attempt: Int = 1, maxAttempts: Int = 4) async {
        do {
            // 1. find a display
            let content = try await SCShareableContent
                .excludingDesktopWindows(false, onScreenWindowsOnly: true)

            // choose the display: prefer requested → active → first
            let displaysByID: [CGDirectDisplayID: SCDisplay] = Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) })
            // Read tracker's active display on the main actor to respect isolation
            let trackerID: CGDirectDisplayID? = await MainActor.run { [tracker] in tracker.activeDisplayID }
            let preferredID = requestedDisplayID ?? trackerID
            let display: SCDisplay
            if let pid = preferredID, let scd = displaysByID[pid] {
                display = scd
            } else if let first = content.displays.first {
                display = first
            } else {
                throw RecorderError.noDisplay
            }
            currentDisplayID = display.displayID
            requestedDisplayID = nil

            // 2. filter
            let filter = SCContentFilter(display: display,
                                         excludingApplications: [],
                                         exceptingWindows: [])

            // 3. configuration
            let cfg                 = SCStreamConfiguration()
            
            // Calculate dimensions to maintain aspect ratio at ~1080p
            let displayWidth = display.width
            let displayHeight = display.height
            let aspectRatio = Double(displayWidth) / Double(displayHeight)
            
            // Scale to target height while maintaining aspect ratio
            let targetHeight = C.targetHeight
            var targetWidth = Int(Double(targetHeight) * aspectRatio)
            // Ensure even dimensions for encoder safety
            if targetWidth % 2 != 0 { targetWidth += 1 }
            var evenTargetHeight = targetHeight
            if evenTargetHeight % 2 != 0 { evenTargetHeight += 1 }
            
            cfg.width               = targetWidth
            cfg.height              = evenTargetHeight
            cfg.capturesAudio       = false
            cfg.pixelFormat         = kCVPixelFormatType_32BGRA
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: C.fps)
            
            // Store dimensions for later use
            recordingWidth = targetWidth
            recordingHeight = evenTargetHeight
            
            dbg("Recording at \(targetWidth)×\(targetHeight) (display: \(displayWidth)×\(displayHeight), ratio: \(String(format: "%.2f", aspectRatio)):1)")

            // 4. kick-off
            try await startStream(filter: filter, config: cfg)

            // Successfully started - transition to recording
            q.async { [weak self] in
                guard let self else { return }
                // Only transition if we're still in starting state (user didn't stop during startup)
                guard self.state == .starting else {
                    dbg("makeStream completed but state changed to \(self.state.description), ignoring")
                    return
                }
                self.transition(to: .recording, context: "stream started")
            }
        }
        catch {
            dbg("makeStream failed [attempt \(attempt)] – \(error.localizedDescription)")

            q.async { [weak self] in
                self?.transition(to: .idle, context: "makeStream failed")
            }

            // Extract error details for analytics
            let nsError = error as NSError
            let errorDomain = nsError.domain
            let errorCode = nsError.code
            let isNoDisplay = (error as? RecorderError) == .noDisplay

            // Check if this is a user-initiated stop
            if isUserInitiatedStop(error) {
                dbg("User stopped recording during startup - updating app state")

                Task { @MainActor in
                    AnalyticsService.shared.capture("recording_startup_failed", [
                        "attempt": attempt,
                        "max_attempts": maxAttempts,
                        "error_domain": errorDomain,
                        "error_code": errorCode,
                        "error_type": "user_initiated",
                        "outcome": "user_cancelled"
                    ])
                    self.forceStopFlag()
                }
                return
            }

            // Treat `noDisplay` like other transient issues
            let retryable = shouldRetry(error) || isNoDisplay

            if retryable, attempt < maxAttempts {
                let delay = Double(attempt)        // 1 s, 2 s, 3 s …
                dbg("retrying in \(delay)s")

                Task { @MainActor in
                    AnalyticsService.shared.capture("recording_startup_failed", [
                        "attempt": attempt,
                        "max_attempts": maxAttempts,
                        "error_domain": errorDomain,
                        "error_code": errorCode,
                        "error_type": isNoDisplay ? "no_display" : "retryable",
                        "outcome": "will_retry",
                        "retry_delay_seconds": delay
                    ])
                }

                q.asyncAfter(deadline: .now() + delay) { [weak self] in self?.start() }
            } else {
                // Final failure - either non-retryable or exceeded max attempts
                let failureReason = !retryable ? "non_retryable" : "max_attempts_exceeded"

                Task { @MainActor in
                    AnalyticsService.shared.capture("recording_startup_failed", [
                        "attempt": attempt,
                        "max_attempts": maxAttempts,
                        "error_domain": errorDomain,
                        "error_code": errorCode,
                        "error_type": isNoDisplay ? "no_display" : (retryable ? "retryable" : "non_retryable"),
                        "outcome": "gave_up",
                        "failure_reason": failureReason
                    ])
                    self.forceStopFlag()
                }
            }
        }
    }

    @MainActor
    private func forceStopFlag() {
        AppState.shared.isRecording = false
    }

    @MainActor
    private func startStream(filter: SCContentFilter, config: SCStreamConfiguration) async throws {
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
        try await s.startCapture()
        stream = s
        dbg("stream started")
        AnalyticsService.shared.withSampling(probability: 0.01) {
            AnalyticsService.shared.capture("recording_started")
        }
    }

    private func stopStream() {
        if let s = stream { s.stopCapture()
            do {
              try s.removeStreamOutput(self, type: .screen)
            } catch {
              dbg("removeStreamOutput failed – \(error)")
            }

        }

        stream = nil
        currentDisplayID = nil             // clear stale ID so idle guards hold
        reset()

        // Only transition to .idle if not paused - preserve .paused state for auto-resume
        if state != .paused {
            transition(to: .idle, context: "stream stopped")
        }
        dbg("stream stopped")
    }

    private func handleActiveDisplayChange(_ newID: CGDirectDisplayID) {
        requestedDisplayID = newID         // retain latest display for next explicit start

        // If the user disabled recording, just remember the ID and stay idle.
        guard wantsRecording else {
            dbg("Active display changed – recording disabled, deferring switch")
            return
        }

        // Only flip streams when one is currently running and we're in recording state.
        guard currentDisplayID != nil, state == .recording else {
            dbg("Active display changed while not recording – will switch on next start")
            return
        }
        guard newID != currentDisplayID else { return }

        dbg("Active display changed → switching stream: \(String(describing: currentDisplayID)) → \(newID)")

        // Finish the current segment and restart on the new display.
        finishSegment(restart: false)
        stopStream()
        Task { @MainActor [weak self] in
            await self?.start()
        }
    }

    private func beginSegment() {
        guard writer == nil else { return }
        let url = StorageManager.shared.nextFileURL(); fileURL = url; frames = 0

        // Add breadcrumb for recording segment start
        let beginBreadcrumb = Breadcrumb(level: .info, category: "recording")
        beginBreadcrumb.message = "Beginning new segment"
        beginBreadcrumb.data = [
            "file": url.lastPathComponent,
            "resolution": "\(recordingWidth)x\(recordingHeight)"
        ]
        SentryHelper.addBreadcrumb(beginBreadcrumb)

        StorageManager.shared.registerChunk(url: url)
        do {
            let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
            
            // Increase bitrate for higher resolution (roughly 2.5 Mbps for 1080p at 1fps)
            let bitrate = 2500000 // 2.5 Mbps
            
            let inp = AVAssetWriterInput(mediaType: .video,
                                         outputSettings: [
                                             AVVideoCodecKey  : AVVideoCodecType.h264,
                                             AVVideoWidthKey  : recordingWidth,
                                             AVVideoHeightKey : recordingHeight,
                                             AVVideoCompressionPropertiesKey: [
                                                 AVVideoAverageBitRateKey: bitrate,
                                                 AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
                                                 AVVideoMaxKeyFrameIntervalKey: 30
                                             ]
                                         ])
            inp.expectsMediaDataInRealTime = true
            guard w.canAdd(inp) else { throw RecorderError.badInput }
            w.add(inp)

            // ARCHITECTURAL FIX: Start writing immediately after adding input
            // This prevents the race condition where multiple frames try to call startWriting()
            // The writer is now guaranteed to be in .writing state before any frames arrive
            guard w.startWriting() else {
                let error = w.error ?? RecorderError.badInput
                dbg("❌ AVAssetWriter.startWriting() failed in beginSegment: \(error)")

                // Add Sentry breadcrumb for initialization failures
                let writerFailBreadcrumb = Breadcrumb(level: .error, category: "recording")
                writerFailBreadcrumb.message = "AVAssetWriter startWriting failed during initialization"
                writerFailBreadcrumb.data = [
                    "writer_status": String(describing: w.status.rawValue),
                    "error": w.error?.localizedDescription ?? "nil",
                    "file": url.lastPathComponent
                ]
                SentryHelper.addBreadcrumb(writerFailBreadcrumb)

                throw error
            }

            writer = w; input = inp

            // Sampled chunk_created event (main actor)
            Task { @MainActor in
                AnalyticsService.shared.withSampling(probability: 0.01) {
                    let gb = Double(self.recordingWidth * self.recordingHeight) / (1920.0 * 1080.0)
                    let resBucket: String = gb >= 1.0 ? "~1080p+" : "<1080p"
                    AnalyticsService.shared.capture("chunk_created", [
                        "duration_bucket": AnalyticsService.shared.secondsBucket(C.chunk),
                        "resolution_bucket": resBucket
                    ])
                }
            }

            // auto-finish after C.chunk seconds
            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now() + C.chunk)
            t.setEventHandler { [weak self] in self?.finishSegment() }
            t.resume(); timer = t

            // Transition to recording now that segment is fully initialized
            transition(to: .recording, context: "segment started")
        } catch {
            dbg("writer creation failed – \(error.localizedDescription)")
            StorageManager.shared.markChunkFailed(url: url); reset()
        }
    }

    private func finishSegment(restart: Bool = true) {
        // Guard against concurrent calls
        guard state != .finishing else { return }

        // Only transition to finishing if we're actually recording
        if state == .recording {
            transition(to: .finishing, context: "finishing segment (restart: \(restart))")
        }

        // Add breadcrumb for finishing segment
        let finishBreadcrumb = Breadcrumb(level: .info, category: "recording")
        finishBreadcrumb.message = "Finishing segment (restart: \(restart))"
        finishBreadcrumb.data = [
            "frames": frames,
            "file": fileURL?.lastPathComponent ?? "nil"
        ]
        SentryHelper.addBreadcrumb(finishBreadcrumb)

        // 1. stop the timer that would have closed the file
        timer?.cancel()
        timer = nil

        // 2. make sure we even have something to finish
        guard let w = writer, let inp = input, let url = fileURL else {
            return reset()
        }

        // ── EARLY EXIT ────────────────────────────────────────────────────
        guard frames > 0 else {
            w.cancelWriting()
            StorageManager.shared.markChunkFailed(url: url)
            reset()
            transition(to: .idle, context: "finishSegment - no frames")
            return
        }
        // ─────────────────────────────────────────────────────────────────

        guard w.status == .writing else {
            w.cancelWriting()
            StorageManager.shared.markChunkFailed(url: url)
            reset()
            transition(to: .idle, context: "finishSegment - writer not writing")
            return
        }

        // 4. normal shutdown path
        inp.markAsFinished()
        w.finishWriting { [weak self] in
            // CRITICAL FIX: finishWriting completion runs on AVFoundation's internal queue
            // We MUST dispatch all state mutations back to the recorder queue for thread safety
            guard let self = self else { return }

            // Dispatch ALL state mutations to recorder queue
            self.q.async { [weak self] in
                guard let self = self else { return }

                // Mark chunk completion status
                if w.status == .completed {
                    StorageManager.shared.markChunkCompleted(url: url)
                } else {
                    StorageManager.shared.markChunkFailed(url: url)
                }

                // Reset recorder state (NOW SAFE - on recorder queue)
                self.reset()

                guard restart else { return }

                // Hop back to the main actor to read the flag safely.
                Task { @MainActor in
                    guard AppState.shared.isRecording else { return }
                    self.q.async { [weak self] in
                        guard let self else { return }
                        // Double-check wantsRecording on recorder queue to catch stop() during finishWriting
                        guard self.wantsRecording else { return }
                        self.beginSegment()
                    }
                }
            }
        }
    }

    private func reset() {
        timer = nil; writer = nil; input = nil; firstPTS = nil; fileURL = nil; frames = 0
    }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard CMSampleBufferDataIsReady(sb) else { return }
        guard isComplete(sb) else { return }
        if let pb = CMSampleBufferGetImageBuffer(sb) {
            // TEMPORARILY DISABLED to test if this causes corruption
            // overlayClock(on: pb)          // ← inject the clock into this frame
        }
        if writer == nil { beginSegment() }
        guard let w = writer, let inp = input else { return }

        if firstPTS == nil {
            firstPTS = sb.presentationTimeStamp

            // Start the session timeline with the first frame's timestamp
            // Note: startWriting() was already called in beginSegment() - no race condition!
            w.startSession(atSourceTime: firstPTS!)
        }

        if inp.isReadyForMoreMediaData, w.status == .writing {
            if inp.append(sb) { 
                frames += 1
            } else { 
                finishSegment() 
            }
        }
    }

    private func registerForSleepAndLock() {
        let nc = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()

        // -------- system will sleep ----------
        nc.addObserver(forName: NSWorkspace.willSleepNotification,
                       object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            dbg("willSleep – pausing")

            self.q.async { [weak self] in
                guard let self else { return }
                // Remember that we want to resume after wake if we're currently recording
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

        // -------- system did wake ------------
        nc.addObserver(forName: NSWorkspace.didWakeNotification,
                       object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            dbg("didWake – checking flag")

            self.q.async { [weak self] in
                guard let self else { return }
                guard self.state == .paused else { return }

                // give ScreenCaptureKit a moment to re-enumerate displays
                self.resumeRecording(after: 5, context: "didWake")
            }
        }

        // -------- screen locked ------------
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"),
                        object: nil, queue: nil) { [weak self] _ in
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

        // -------- screen unlocked ----------
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"),
                        object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            dbg("screen unlocked – checking flag")

            self.q.async { [weak self] in
                guard let self else { return }
                guard self.state == .paused else { return }

                self.resumeRecording(after: 0.5, context: "screen unlock")
            }
        }

        // -------- screensaver started ------
        dnc.addObserver(forName: .init("com.apple.screensaver.didstart"),
                        object: nil, queue: nil) { [weak self] _ in
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

        // -------- screensaver stopped ------
        dnc.addObserver(forName: .init("com.apple.screensaver.didstop"),
                        object: nil, queue: nil) { [weak self] _ in
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
            Task { @MainActor [weak self] in
                guard AppState.shared.isRecording else {
                    dbg("\(context) – skip auto-resume (recording disabled)")
                    return
                }
                await self?.start()
            }
        }
    }

    private enum RecorderError: Error { case badInput, noDisplay }

    /// Accept only fully-assembled frames (complete & not dropped).
    private func isComplete(_ sb: CMSampleBuffer) -> Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo : Any]],
              let raw = arr.first?[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    
    private func overlayClock(on pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, [])  // Lock for read/write access
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }

        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)

        guard let ctx = CGContext(data: base,
                                  width: w,
                                  height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: bpr,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return }

        // ---- draw black box ----
        let padding: CGFloat = 12
        let fontSize: CGFloat = 36

        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        let text = fmt.string(from: Date())

        let attrs: [NSAttributedString.Key: Any] = [
            .font: CTFontCreateWithName("Menlo" as CFString, fontSize, nil),
            .foregroundColor: CGColor(red: 1, green: 0, blue: 0, alpha: 1) // red
        ]
        let line   = CTLineCreateWithAttributedString(NSAttributedString(string: text,
                                                                         attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)

        let boxW = bounds.width  + padding * 2
        let boxH = bounds.height + padding * 2
        let originX = CGFloat(w) - boxW
        let originY = CGFloat(h) - boxH

        ctx.setFillColor(CGColor(gray: 0, alpha: 1))           // black
        ctx.fill(CGRect(x: originX, y: originY,
                        width: boxW,  height: boxH))

        ctx.textPosition = CGPoint(x: originX + padding,
                                   y: originY + padding - bounds.minY)
        CTLineDraw(line, ctx)
    }
}

extension ScreenRecorder: SCStreamDelegate {
    nonisolated func stream(_ s: SCStream, didStopWithError error: Error?) {
        // ReplayKit occasionally hands a nil NSError pointer; accept it as optional before bridging.
        let scError = error as NSError?

        guard let scError else {
            dbg("stream stopped – nil error pointer, treating as transient")
            Task { @MainActor [weak self] in
                await self?.stop()
                if AppState.shared.isRecording {
                    await self?.start()
                }
            }
            return
        }

        dbg("stream stopped – domain: \(scError.domain), code: \(scError.code), description: \(scError.localizedDescription)")

        let userInfo = scError.userInfo
        if !userInfo.isEmpty {
            dbg("Error userInfo: \(userInfo)")
        }

        Task { @MainActor [weak self] in
            await self?.stop()

            if await self?.isUserInitiatedStop(scError) ?? false {
                dbg("User stopped recording through system UI - updating app state")
                AppState.shared.isRecording = false
                AnalyticsService.shared.capture("recording_stopped", ["stop_reason": "user"])
            } else if await self?.shouldRetry(scError) ?? false {
                dbg("Retryable error - will restart if recording flag is set")
                AnalyticsService.shared.capture("recording_error", [
                    "code": scError.code,
                    "retryable": true
                ])
                if AppState.shared.isRecording {
                    AnalyticsService.shared.capture("recording_auto_recovery", ["outcome": "restarted"])
                    await self?.start()
                }
            } else {
                dbg("Non-retryable error - stopping recording")
                AppState.shared.isRecording = false
                AnalyticsService.shared.capture("recording_error", [
                    "code": scError.code,
                    "retryable": false
                ])
                AnalyticsService.shared.capture("recording_auto_recovery", ["outcome": "gave_up"])
            }
        }
    }
}
