import Foundation

/// Defaults for idle-throttled screenshot capture (issue #286).
///
/// The throttled interval must stay at or under IdleBatchClassifier's
/// maxAllowedUncoveredGapSeconds (30s), not just under AnalysisManager's
/// looser batch maxGap (2 min). idleSecondsAtCapture measures time since
/// the *last input event*, not time since the last screenshot — so a brief
/// activity blip mid-idle-stretch resets that clock to near-zero for the
/// next screenshot, leaving up to (throttledIntervalSeconds - 1) seconds of
/// the *previous* inter-screenshot gap uncovered. At 30s that worst case is
/// exactly 29s, just inside the 30s limit; anything higher can silently
/// exceed it and kick the whole batch out of idle classification, forcing
/// full LLM processing — the opposite of what this throttle is for. See
/// IdleCaptureIntervalTests.testWorstCaseBlipDuringIdleStaysWithinClassifierGapLimit.
enum IdleCaptureDefaults {
  /// Match `IdleBatchRules.qualifyingIdleSecondsAtCapture` so we throttle once
  /// screenshots would count as "qualified idle", keeping the 10s ramp window
  /// small enough for the 90% qualified-idle ratio.
  static let idleThresholdSeconds: TimeInterval = 60
  /// Largest interval that keeps worst-case blip gaps under 30s *and* leaves
  /// enough qualified samples in a 15-minute batch alongside the 10s ramp.
  static let throttledIntervalSeconds: TimeInterval = 16
}

/// User preference for idle-throttled capture. Only an on/off toggle is
/// exposed — the threshold/interval values above are tuned constants, not
/// something a typical user needs to hand-configure (matching IdleBatchRules'
/// hardcoded-constants convention elsewhere in this pipeline).
enum IdleCapturePreferences {
  static let enabledKey = "idleCaptureThrottleEnabled"

  static var enabled: Bool {
    get {
      UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
    set {
      UserDefaults.standard.set(newValue, forKey: enabledKey)
    }
  }
}

/// Pure decision logic for how often to capture a screenshot given how long
/// the user has been idle. Kept free of ScreenRecorder's actors/queues so it
/// can be unit-tested directly.
enum IdleCaptureInterval {
  /// Effective capture interval for the recorder, honoring the user toggle.
  static func effectiveInterval(
    baseInterval: TimeInterval = ScreenshotConfig.interval,
    idleSeconds: Int?,
    throttleEnabled: Bool = IdleCapturePreferences.enabled
  ) -> TimeInterval {
    guard throttleEnabled else { return baseInterval }
    return interval(
      baseInterval: baseInterval,
      idleThrottledInterval: IdleCaptureDefaults.throttledIntervalSeconds,
      idleSeconds: idleSeconds,
      idleThresholdSeconds: IdleCaptureDefaults.idleThresholdSeconds
    )
  }

  static func interval(
    baseInterval: TimeInterval,
    idleThrottledInterval: TimeInterval,
    idleSeconds: Int?,
    idleThresholdSeconds: TimeInterval
  ) -> TimeInterval {
    guard let idleSeconds, TimeInterval(idleSeconds) >= idleThresholdSeconds else {
      return baseInterval
    }
    return idleThrottledInterval
  }
}
