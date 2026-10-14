import Foundation

/// Reports which Codex and Claude CLI versions are installed, as PostHog super
/// properties (so every event carries them) and person properties (so the
/// version distribution across users is chartable).
@MainActor
enum CLIVersionTelemetry {
  private static let staleAfter: TimeInterval = 24 * 60 * 60
  private static var lastRefresh: Date?

  /// Dayflow runs for weeks at a time and the CLIs update underneath it, so
  /// the heartbeat calls this to re-probe about once a day.
  static func refreshIfStale() {
    if let lastRefresh, Date().timeIntervalSince(lastRefresh) < staleAfter { return }
    refresh()
  }

  static func refresh() {
    return
    guard AnalyticsService.shared.isOptedIn else { return }
    lastRefresh = Date()

    // Probing spawns login shells, which can take seconds with a heavy shell config.
    Task.detached(priority: .utility) {
      let properties = probe()
      await MainActor.run {
        AnalyticsService.shared.registerSuperProperties(properties)
        AnalyticsService.shared.setPersonProperties(properties)
      }
    }
  }

  private nonisolated static func probe() -> [String: String] {
    // Drop the cached resolution so an updated binary reports its new version.
    CodexExecutableResolver.shared.invalidate()
    let codex = CodexExecutableResolver.shared.resolve()
    let claude = LoginShellRunner.version(of: "claude")

    return [
      "codex_cli_version": codex?.version ?? "not_installed",
      "codex_cli_source": codex?.source.rawValue ?? "not_installed",
      "claude_cli_version": claude.map(numericVersion) ?? "not_installed",
    ]
  }

  /// "2.1.4 (Claude Code)" -> "2.1.4". Keeps stray shell output out of analytics.
  nonisolated static func numericVersion(_ versionSummary: String) -> String {
    guard
      let range = versionSummary.range(of: #"\d+(?:\.\d+){1,3}"#, options: .regularExpression)
    else { return "unknown" }
    return String(versionSummary[range])
  }
}
