import Foundation

/// Counts only foreground time with a loaded dashboard, never download or scan time.
@MainActor
final class AgentPlaybackUsage {
  enum EndReason: String {
    case tabClosed = "tab_closed"
    case background
    case unavailable
    case appExit = "app_exit"
  }

  private let now: () -> TimeInterval
  private let enabled: () -> Bool
  private let capture: (String, [String: Any]) -> Void
  private var selected = false
  private var foreground = false
  private var ready = false
  private var startedAt: TimeInterval?

  init(
    now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    enabled: @escaping () -> Bool = { AnalyticsService.shared.isOptedIn },
    capture: @escaping (String, [String: Any]) -> Void = { AnalyticsService.shared.capture($0, $1) }
  ) {
    self.now = now
    self.enabled = enabled
    self.capture = capture
  }

  func appear(foreground: Bool) {
    guard !selected else { return }
    selected = true
    self.foreground = foreground
    if enabled() { capture("agentplayback_opened", ["already_loaded": ready]) }
    beginIfNeeded()
  }

  func disappear() {
    end(.tabClosed)
    selected = false
  }

  func setForeground(_ value: Bool) {
    if !value { end(.background) }
    foreground = value
    beginIfNeeded()
  }

  func setReady(_ value: Bool) {
    if !value { end(.unavailable) }
    ready = value
    beginIfNeeded()
  }

  func consentChanged() {
    // Discard the old interval so opting back in cannot upload opted-out activity.
    startedAt = nil
    beginIfNeeded()
  }

  func terminate() { end(.appExit) }

  private func beginIfNeeded() {
    if selected && foreground && ready && enabled() && startedAt == nil { startedAt = now() }
  }

  private func end(_ reason: EndReason) {
    guard let start = startedAt else { return }
    startedAt = nil
    guard enabled() else { return }
    capture(
      "agentplayback_session_ended",
      [
        "duration_seconds": (max(0, now() - start) * 10).rounded() / 10,
        "reason": reason.rawValue,
      ])
  }
}
