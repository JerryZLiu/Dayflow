import Foundation

struct ScreenCaptureFilterDescriptor: Equatable, Sendable {
  let displayID: UInt32
  let width: Int
  let height: Int
  let excludedApplicationIDs: [String]
}

struct ScreenCaptureStreamSettings: Equatable, Sendable {
  let frameInterval: TimeInterval
  let queueDepth: Int
}

protocol ScreenCaptureStreamSession: AnyObject, Sendable {
  func start() async throws
  func updateFilter(_ filter: ScreenCaptureFilterDescriptor) async throws
  func stop() async
}

struct ScreenCaptureSetupToken: Equatable, Sendable {
  fileprivate let generation: UInt64
}

enum ScreenCaptureManualResumePolicy {
  static func shouldResume(
    wantsRecording: Bool,
    hasActiveSession: Bool
  ) -> Bool {
    wantsRecording && !hasActiveSession
  }
}

struct ScreenCaptureFrameCadence<Frame: Sendable>: Sendable {
  private let interval: TimeInterval
  private var lastFrame: Frame?
  private var nextDueDate: Date?

  init(interval: TimeInterval) {
    self.interval = interval
  }

  mutating func frameToSave(_ frame: Frame?, at capturedAt: Date) -> Frame? {
    if let frame {
      lastFrame = frame
    }
    guard let lastFrame else { return nil }
    if let nextDueDate, capturedAt < nextDueDate {
      return nil
    }
    nextDueDate = capturedAt.addingTimeInterval(interval)
    return lastFrame
  }

  mutating func reset() {
    lastFrame = nil
    nextDueDate = nil
  }
}

final class ScreenCaptureStreamLifecycle<Frame: Sendable>: @unchecked Sendable {
  typealias Builder = @Sendable (
    ScreenCaptureFilterDescriptor,
    ScreenCaptureStreamSettings,
    @escaping @Sendable (Frame?, Date) -> Void,
    @escaping @Sendable (NSError) -> Void
  ) throws -> ScreenCaptureStreamSession
  typealias SaveFrame = @Sendable (Frame, Date) -> Void

  private let lock = NSLock()
  private let settings: ScreenCaptureStreamSettings
  private let builder: Builder
  private let saveFrame: SaveFrame
  private let handleError: @Sendable (NSError) -> Void
  private var session: ScreenCaptureStreamSession?
  private var cadence: ScreenCaptureFrameCadence<Frame>
  private var generation: UInt64 = 0
  private var pendingStop: Task<Void, Never>?
  private var filterUpdateRevision: UInt64 = 0
  private var blockedFilterUpdateRevision: UInt64?

  init(
    interval: TimeInterval,
    builder: @escaping Builder,
    saveFrame: @escaping SaveFrame,
    handleError: @escaping @Sendable (NSError) -> Void = { _ in }
  ) {
    settings = ScreenCaptureStreamSettings(frameInterval: interval, queueDepth: 3)
    cadence = ScreenCaptureFrameCadence(interval: interval)
    self.builder = builder
    self.saveFrame = saveFrame
    self.handleError = handleError
  }

  var hasActiveSession: Bool {
    lock.withLock { session != nil }
  }

  func beginSetup() -> ScreenCaptureSetupToken {
    lock.withLock {
      generation &+= 1
      return ScreenCaptureSetupToken(generation: generation)
    }
  }

  func isCurrentSetup(_ setup: ScreenCaptureSetupToken) -> Bool {
    lock.withLock { setup.generation == generation }
  }

  func start(
    filter: ScreenCaptureFilterDescriptor,
    setup: ScreenCaptureSetupToken
  ) async throws {
    let stopToFinish = lock.withLock { pendingStop }
    await stopToFinish?.value
    guard isCurrentSetup(setup) else { throw CancellationError() }

    let created = try builder(
      filter,
      settings,
      { [weak self] frame, capturedAt in
        self?.receiveFrame(frame, capturedAt: capturedAt, setup: setup)
      },
      { [weak self] error in
        self?.handleError(error)
      }
    )
    let accepted = lock.withLock { () -> Bool in
      guard setup.generation == generation, session == nil else { return false }
      session = created
      cadence.reset()
      blockedFilterUpdateRevision = nil
      return true
    }
    guard accepted else {
      await created.stop()
      throw CancellationError()
    }

    do {
      try await created.start()
    } catch {
      lock.withLock {
        if isSameSession(session, created) {
          session = nil
          cadence.reset()
          blockedFilterUpdateRevision = nil
        }
      }
      throw error
    }

    let remainsCurrent = lock.withLock {
      setup.generation == generation && isSameSession(session, created)
    }
    guard remainsCurrent else {
      await created.stop()
      throw CancellationError()
    }
  }

  func updateFilter(_ filter: ScreenCaptureFilterDescriptor) async throws {
    let update = lock.withLock { () -> (ScreenCaptureStreamSession, UInt64)? in
      guard let session else { return nil }
      filterUpdateRevision &+= 1
      blockedFilterUpdateRevision = filterUpdateRevision
      cadence.reset()
      return (session, filterUpdateRevision)
    }
    guard let (current, revision) = update else { return }

    try await current.updateFilter(filter)

    lock.withLock {
      guard isSameSession(session, current), blockedFilterUpdateRevision == revision else {
        return
      }
      cadence.reset()
      blockedFilterUpdateRevision = nil
    }
  }

  func requestStop() -> Task<Void, Never> {
    lock.withLock {
      generation &+= 1
      let current = session
      session = nil
      cadence.reset()
      blockedFilterUpdateRevision = nil
      let previousStop = pendingStop
      let stopTask = Task {
        await previousStop?.value
        await current?.stop()
      }
      pendingStop = stopTask
      return stopTask
    }
  }

  func stop() async {
    await requestStop().value
  }

  func waitForPendingFrames() async {}

  private func receiveFrame(
    _ frame: Frame?,
    capturedAt: Date,
    setup: ScreenCaptureSetupToken
  ) {
    let frameToSave = lock.withLock { () -> Frame? in
      guard
        setup.generation == generation,
        session != nil,
        blockedFilterUpdateRevision == nil
      else { return nil }
      return cadence.frameToSave(frame, at: capturedAt)
    }
    if let frameToSave {
      saveFrame(frameToSave, capturedAt)
    }
  }

  private func isSameSession(
    _ lhs: ScreenCaptureStreamSession?,
    _ rhs: ScreenCaptureStreamSession
  ) -> Bool {
    guard let lhs else { return false }
    return (lhs as AnyObject) === (rhs as AnyObject)
  }
}

struct ScreenCaptureRetryState: Equatable, Sendable {
  private static let delays: [TimeInterval] = [15, 60, 300]

  private var attempt = 0
  private(set) var isRetryRunning = false

  mutating func beginRetry() -> TimeInterval? {
    guard !isRetryRunning else { return nil }
    isRetryRunning = true
    return Self.delays[min(attempt, Self.delays.count - 1)]
  }

  mutating func beginManualRetry() -> TimeInterval? {
    guard !isRetryRunning else { return nil }
    isRetryRunning = true
    return 0
  }

  mutating func finishRetry(recovered: Bool) {
    isRetryRunning = false
    if recovered {
      attempt = 0
    } else {
      attempt = min(attempt + 1, Self.delays.count - 1)
    }
  }

  mutating func markRecovered() {
    attempt = 0
    isRetryRunning = false
  }
}

struct ScreenCaptureRecordingIntent: Equatable, Sendable {
  let isEnabled: Bool
  var authorizationState: ScreenCaptureAuthorizationState = .unknown

  func paused(for state: ScreenCaptureAuthorizationState) -> Self {
    var copy = self
    copy.authorizationState = state
    return copy
  }
}
