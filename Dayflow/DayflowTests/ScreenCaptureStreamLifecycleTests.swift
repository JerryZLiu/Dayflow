import Foundation
import XCTest
@testable import Dayflow

final class ScreenCaptureStreamLifecycleTests: XCTestCase {
  func testActiveStreamRejectsManualResume() {
    XCTAssertFalse(
      ScreenCaptureManualResumePolicy.shouldResume(
        wantsRecording: true,
        hasActiveSession: true
      )
    )
  }

  func testIdleSampleRepeatsLastFrameWhenDue() {
    var cadence = ScreenCaptureFrameCadence<Data>(interval: 10)

    let first = cadence.frameToSave(Data([1]), at: Date(timeIntervalSince1970: 0))
    let idle = cadence.frameToSave(nil, at: Date(timeIntervalSince1970: 10))

    XCTAssertEqual(first, Data([1]))
    XCTAssertEqual(idle, Data([1]))
  }

  func testOneStreamSavesSeveralScheduledFrames() async throws {
    let builder = ScreenCaptureStreamBuilderSpy()
    let savedFrames = SavedFramesSpy()
    let lifecycle = ScreenCaptureStreamLifecycle(
      interval: 10,
      builder: builder.makeSessionHandler,
      saveFrame: savedFrames.saveHandler
    )
    let filter = ScreenCaptureFilterDescriptor(
      displayID: 1, width: 1920, height: 1080, excludedApplicationIDs: [])

    try await lifecycle.start(filter: filter, setup: lifecycle.beginSetup())
    builder.session?.emit(Data([1]), at: Date(timeIntervalSince1970: 0))
    builder.session?.emit(Data([2]), at: Date(timeIntervalSince1970: 10))
    builder.session?.emit(Data([3]), at: Date(timeIntervalSince1970: 20))
    await lifecycle.waitForPendingFrames()

    XCTAssertEqual(builder.makeCount, 1)
    XCTAssertEqual(savedFrames.frames, [Data([1]), Data([2]), Data([3])])
    XCTAssertEqual(builder.settings, .init(frameInterval: 10, queueDepth: 3))
  }

  func testDisplayChangeUpdatesFilterWithoutReplacingStream() async throws {
    let builder = ScreenCaptureStreamBuilderSpy()
    let lifecycle = ScreenCaptureStreamLifecycle(
      interval: 10,
      builder: builder.makeSessionHandler,
      saveFrame: { _, _ in }
    )
    let first = ScreenCaptureFilterDescriptor(
      displayID: 1, width: 1920, height: 1080, excludedApplicationIDs: [])
    let second = ScreenCaptureFilterDescriptor(
      displayID: 2, width: 2560, height: 1440, excludedApplicationIDs: ["secret"])

    try await lifecycle.start(filter: first, setup: lifecycle.beginSetup())
    try await lifecycle.updateFilter(second)

    XCTAssertEqual(builder.makeCount, 1)
    XCTAssertEqual(builder.session?.updatedFilters, [second])
  }

  func testFilterUpdateDropsOldFramesAndClearsCadence() async throws {
    let updateGate = ScreenCaptureFilterUpdateGate()
    let builder = ScreenCaptureStreamBuilderSpy()
    builder.updateGate = updateGate
    let savedFrames = SavedFramesSpy()
    let lifecycle = ScreenCaptureStreamLifecycle(
      interval: 10,
      builder: builder.makeSessionHandler,
      saveFrame: savedFrames.saveHandler
    )
    let first = ScreenCaptureFilterDescriptor(
      displayID: 1, width: 1920, height: 1080, excludedApplicationIDs: [])
    let filtered = ScreenCaptureFilterDescriptor(
      displayID: 1, width: 1920, height: 1080, excludedApplicationIDs: ["private"])

    try await lifecycle.start(filter: first, setup: lifecycle.beginSetup())
    builder.session?.emit(Data([1]), at: Date(timeIntervalSince1970: 0))
    let updateTask = Task { try await lifecycle.updateFilter(filtered) }
    while !(await updateGate.hasBegun()) {
      await Task.yield()
    }
    builder.session?.emit(Data([2]), at: Date(timeIntervalSince1970: 10))
    await updateGate.release()
    try await updateTask.value
    builder.session?.emit(nil, at: Date(timeIntervalSince1970: 20))
    builder.session?.emit(Data([3]), at: Date(timeIntervalSince1970: 30))

    XCTAssertEqual(savedFrames.frames, [Data([1]), Data([3])])
  }

  func testStoppingRecordingStopsAndReleasesStream() async throws {
    let builder = ScreenCaptureStreamBuilderSpy()
    let lifecycle = ScreenCaptureStreamLifecycle(
      interval: 10,
      builder: builder.makeSessionHandler,
      saveFrame: { _, _ in }
    )
    try await lifecycle.start(
      filter: ScreenCaptureFilterDescriptor(
        displayID: 1, width: 1920, height: 1080, excludedApplicationIDs: []),
      setup: lifecycle.beginSetup()
    )
    let weakSession = WeakReference(builder.session)

    await lifecycle.stop()
    builder.releaseSession()

    let hasActiveSession = lifecycle.hasActiveSession
    XCTAssertNil(weakSession.value)
    XCTAssertFalse(hasActiveSession)
  }

  func testStopInvalidatesSetupBeforeSessionConstruction() async throws {
    let builder = ScreenCaptureStreamBuilderSpy()
    let lifecycle = ScreenCaptureStreamLifecycle(
      interval: 10,
      builder: builder.makeSessionHandler,
      saveFrame: { _, _ in }
    )
    let setup = lifecycle.beginSetup()

    await lifecycle.stop()

    do {
      try await lifecycle.start(
        filter: ScreenCaptureFilterDescriptor(
          displayID: 1, width: 1920, height: 1080, excludedApplicationIDs: []),
        setup: setup
      )
      XCTFail("A stopped setup must not create a stream")
    } catch is CancellationError {
      // Expected: stop invalidates work that started earlier.
    }

    XCTAssertEqual(builder.makeCount, 0)
    XCTAssertFalse(lifecycle.hasActiveSession)
  }

  func testStopDuringStartStopsStaleSessionAndDropsFrames() async throws {
    let gate = ScreenCaptureStartGate()
    let builder = ScreenCaptureStreamBuilderSpy()
    builder.startGate = gate
    let savedFrames = SavedFramesSpy()
    let lifecycle = ScreenCaptureStreamLifecycle(
      interval: 10,
      builder: builder.makeSessionHandler,
      saveFrame: savedFrames.saveHandler
    )
    let setup = lifecycle.beginSetup()
    let startTask = Task {
      try await lifecycle.start(
        filter: ScreenCaptureFilterDescriptor(
          displayID: 1, width: 1920, height: 1080, excludedApplicationIDs: []),
        setup: setup
      )
    }
    while !(await gate.hasBegun()) {
      await Task.yield()
    }

    await lifecycle.stop()
    await gate.release()

    do {
      try await startTask.value
      XCTFail("A stream that finishes after stop must be cancelled")
    } catch is CancellationError {
      // Expected: the late start cannot reactivate capture.
    }
    builder.session?.emit(Data([1]), at: Date())

    XCTAssertEqual(builder.session?.stopCount, 2)
    XCTAssertEqual(savedFrames.frames, [])
    XCTAssertFalse(lifecycle.hasActiveSession)
  }

  func testReplacementWaitsForPreviousStopCompletion() async throws {
    let stopGate = ScreenCaptureStopGate()
    let builder = ScreenCaptureStreamBuilderSpy()
    builder.stopGate = stopGate
    let lifecycle = ScreenCaptureStreamLifecycle(
      interval: 10,
      builder: builder.makeSessionHandler,
      saveFrame: { _, _ in }
    )
    let filter = ScreenCaptureFilterDescriptor(
      displayID: 1, width: 1920, height: 1080, excludedApplicationIDs: [])

    try await lifecycle.start(filter: filter, setup: lifecycle.beginSetup())
    let stopTask = lifecycle.requestStop()
    while !(await stopGate.hasBegun()) {
      await Task.yield()
    }
    let replacementSetup = lifecycle.beginSetup()
    let replacementTask = Task {
      try await lifecycle.start(filter: filter, setup: replacementSetup)
    }
    for _ in 0..<20 {
      await Task.yield()
    }

    XCTAssertEqual(builder.makeCount, 1)
    await stopGate.release()
    await stopTask.value
    try await replacementTask.value
    XCTAssertEqual(builder.makeCount, 2)
  }

  func testRecoveryCancelsBackoff() {
    var retry = ScreenCaptureRetryState()
    XCTAssertEqual(retry.beginRetry(), 15)

    retry.markRecovered()

    XCTAssertFalse(retry.isRetryRunning)
    XCTAssertEqual(retry.beginRetry(), 15)
  }

  func testOnlyOneRetryCanRun() {
    var retry = ScreenCaptureRetryState()

    XCTAssertEqual(retry.beginRetry(), 15)
    XCTAssertNil(retry.beginRetry())
    retry.finishRetry(recovered: false)
    XCTAssertEqual(retry.beginRetry(), 60)
  }

  func testManualResumeCanRetryImmediately() {
    var retry = ScreenCaptureRetryState()
    XCTAssertEqual(retry.beginRetry(), 15)
    retry.finishRetry(recovered: false)

    XCTAssertEqual(retry.beginManualRetry(), 0)
  }

  func testPauseKeepsRecordingPreferenceEnabled() {
    let intent = ScreenCaptureRecordingIntent(isEnabled: true)

    let paused = intent.paused(for: .temporarilyUnavailable)

    XCTAssertTrue(paused.isEnabled)
    XCTAssertEqual(paused.authorizationState, .temporarilyUnavailable)
  }
}

private final class ScreenCaptureStreamBuilderSpy: @unchecked Sendable {
  private(set) var makeCount = 0
  private(set) var settings: ScreenCaptureStreamSettings?
  var session: ScreenCaptureStreamSessionSpy?
  var startGate: ScreenCaptureStartGate?
  var stopGate: ScreenCaptureStopGate?
  var updateGate: ScreenCaptureFilterUpdateGate?

  var makeSessionHandler: ScreenCaptureStreamLifecycle<Data>.Builder {
    { [weak self] filter, settings, onFrame, onError in
      guard let self else { throw CancellationError() }
      return try self.makeSession(
        filter: filter,
        settings: settings,
        onFrame: onFrame,
        onError: onError
      )
    }
  }

  func makeSession(
    filter: ScreenCaptureFilterDescriptor,
    settings: ScreenCaptureStreamSettings,
    onFrame: @escaping @Sendable (Data?, Date) -> Void,
    onError: @escaping @Sendable (NSError) -> Void
  ) throws -> ScreenCaptureStreamSession {
    _ = filter
    _ = onError
    makeCount += 1
    self.settings = settings
    let session = ScreenCaptureStreamSessionSpy(
      onFrame: onFrame,
      startGate: startGate,
      stopGate: stopGate,
      updateGate: updateGate
    )
    self.session = session
    return session
  }

  func releaseSession() {
    session = nil
  }
}

private final class WeakReference<Value: AnyObject> {
  weak var value: Value?

  init(_ value: Value?) {
    self.value = value
  }
}

private final class ScreenCaptureStreamSessionSpy: ScreenCaptureStreamSession, @unchecked Sendable {
  private let onFrame: @Sendable (Data?, Date) -> Void
  private let startGate: ScreenCaptureStartGate?
  private let stopGate: ScreenCaptureStopGate?
  private let updateGate: ScreenCaptureFilterUpdateGate?
  private let lock = NSLock()
  private var _stopCount = 0
  private(set) var updatedFilters: [ScreenCaptureFilterDescriptor] = []

  init(
    onFrame: @escaping @Sendable (Data?, Date) -> Void,
    startGate: ScreenCaptureStartGate?,
    stopGate: ScreenCaptureStopGate?,
    updateGate: ScreenCaptureFilterUpdateGate?
  ) {
    self.onFrame = onFrame
    self.startGate = startGate
    self.stopGate = stopGate
    self.updateGate = updateGate
  }

  var stopCount: Int {
    lock.withLock { _stopCount }
  }

  func start() async throws {
    await startGate?.wait()
  }

  func updateFilter(_ filter: ScreenCaptureFilterDescriptor) async throws {
    await updateGate?.wait()
    updatedFilters.append(filter)
  }

  func stop() async {
    lock.withLock { _stopCount += 1 }
    await stopGate?.wait()
  }

  func emit(_ data: Data?, at date: Date) {
    onFrame(data, date)
  }
}

private actor ScreenCaptureStartGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var didBegin = false

  func wait() async {
    didBegin = true
    await withCheckedContinuation { continuation = $0 }
  }

  func hasBegun() -> Bool {
    didBegin
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

private actor ScreenCaptureStopGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var didBegin = false

  func wait() async {
    didBegin = true
    await withCheckedContinuation { continuation = $0 }
  }

  func hasBegun() -> Bool {
    didBegin
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

private actor ScreenCaptureFilterUpdateGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var didBegin = false

  func wait() async {
    didBegin = true
    await withCheckedContinuation { continuation = $0 }
  }

  func hasBegun() -> Bool {
    didBegin
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

private final class SavedFramesSpy: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var frames: [Data] = []

  var saveHandler: ScreenCaptureStreamLifecycle<Data>.SaveFrame {
    { [weak self] data, capturedAt in
      self?.save(data, capturedAt: capturedAt)
    }
  }

  func save(_ data: Data, capturedAt: Date) {
    _ = capturedAt
    lock.lock()
    frames.append(data)
    lock.unlock()
  }
}
