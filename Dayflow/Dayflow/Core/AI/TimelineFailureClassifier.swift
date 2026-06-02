//
//  TimelineFailureClassifier.swift
//  Dayflow
//
//  Classifies timeline-generation failures into user-facing categories and
//  maps each actionable category to toast copy plus a settings destination.
//  Pattern tables are derived from 30 days of analysis_batch_failed events.
//

import Foundation

enum TimelineFailureKind: String {
  // Actionable: the user has to do something before timelines resume.
  case dayflowProRequired = "dayflow_pro_required"
  case providerLoginExpired = "provider_login_expired"
  case cliNotInstalled = "cli_not_installed"
  case cliOutdated = "cli_outdated"
  case localEngineOffline = "local_engine_offline"
  case localModelMissing = "local_model_missing"
  case apiKeyProblem = "api_key_problem"
  case usageLimitHit = "usage_limit_hit"
  case outOfCredits = "out_of_credits"
  case geoBlocked = "geo_blocked"
  case accountBlocked = "account_blocked"
  case modelMisconfigured = "model_misconfigured"
  case notConfigured = "not_configured"

  // Non-actionable: retrying usually resolves these without the user.
  case transient = "transient"
  case modelFlaky = "model_flaky"
  case unknown = "unknown"
}

enum TimelineFailureToastDestination: String {
  case providers
  case account
}

struct TimelineFailureToastContent {
  let title: String
  let body: String
  let destination: TimelineFailureToastDestination
}

struct TimelineFailureClassification {
  let kind: TimelineFailureKind

  /// Provider named by the error text itself, when it identifies one.
  /// More reliable than the configured provider: after a backup fallback,
  /// the failing provider isn't the primary one.
  let providerName: String?

  /// Toast copy for this failure, or nil when the failure isn't worth
  /// interrupting the user for (transient/flaky/unknown).
  func toastContent(fallbackProviderLabel: String?) -> TimelineFailureToastContent? {
    let provider =
      providerName ?? displayName(forProviderLabel: fallbackProviderLabel)
      ?? "your AI provider"

    switch kind {
    case .dayflowProRequired:
      return TimelineFailureToastContent(
        title: "Dayflow Pro required",
        body:
          "Timeline generation is paused for this account. Subscribe, or refer a friend and earn a free month of Pro. Your recordings are safe — use Retry on the failed cards once you're back.",
        destination: .account
      )

    case .providerLoginExpired:
      let body: String
      if let command = reauthCommand(for: provider) {
        body =
          "Run '\(command)' in Terminal to sign in again, or reconnect from provider settings. Your recordings are safe in the meantime."
      } else {
        body =
          "Sign in to \(provider) again from provider settings. Your recordings are safe in the meantime."
      }
      return TimelineFailureToastContent(
        title: "Your \(provider) login expired",
        body: body,
        destination: .providers
      )

    case .cliNotInstalled:
      let body: String
      if let command = reauthCommand(for: provider) {
        body =
          "Dayflow talks to \(provider) through its CLI but couldn't find it. Reinstall it and run '\(command)' in Terminal, or switch providers in settings."
      } else {
        body =
          "Dayflow couldn't find the command-line tool for \(provider). Reinstall it, or switch providers in settings."
      }
      return TimelineFailureToastContent(
        title: "\(provider)'s command-line tool is missing",
        body: body,
        destination: .providers
      )

    case .cliOutdated:
      return TimelineFailureToastContent(
        title: "Your codex CLI is out of date",
        body:
          "This model needs a newer version. Run 'npm install -g @openai/codex@latest' (or 'brew upgrade codex') in Terminal to update it.",
        destination: .providers
      )

    case .localEngineOffline:
      return TimelineFailureToastContent(
        title: "Can't reach Ollama / LM Studio",
        body:
          "Make sure it's running — Dayflow resumes with the next batch. Prefer zero setup? Gemini is free in provider settings.",
        destination: .providers
      )

    case .localModelMissing:
      return TimelineFailureToastContent(
        title: "Your local model isn't loaded",
        body:
          "Open Ollama or LM Studio and check that your model is downloaded and loaded, or pick a different one in provider settings.",
        destination: .providers
      )

    case .apiKeyProblem:
      return TimelineFailureToastContent(
        title: "Your \(provider) API key isn't working",
        body:
          "It looks missing, expired, or suspended. Add a fresh key in provider settings — Gemini keys are free at aistudio.google.com.",
        destination: .providers
      )

    case .usageLimitHit:
      return TimelineFailureToastContent(
        title: "You've hit \(provider)'s usage limit",
        body:
          "New activity will process once the limit resets — use Retry on any failed cards to fill the gap. Adding a backup provider in settings avoids this.",
        destination: .providers
      )

    case .outOfCredits:
      return TimelineFailureToastContent(
        title: "\(provider) is out of credits",
        body:
          "Top up billing with your provider, or switch to a free option like Gemini in provider settings.",
        destination: .providers
      )

    case .geoBlocked:
      return TimelineFailureToastContent(
        title: "\(provider) isn't available in your region",
        body:
          "This provider blocks API use where you are. Switching to a different provider in settings fixes it.",
        destination: .providers
      )

    case .accountBlocked:
      return TimelineFailureToastContent(
        title: "Your \(provider) project is blocked",
        body:
          "Access was denied for this account — creating a fresh API key usually fixes it. Update it in provider settings.",
        destination: .providers
      )

    case .modelMisconfigured:
      return TimelineFailureToastContent(
        title: "Your selected model isn't available",
        body:
          "The model Dayflow tried to use isn't available on \(provider). Check the model selection in provider settings, or switch providers.",
        destination: .providers
      )

    case .notConfigured:
      return TimelineFailureToastContent(
        title: "No AI provider connected",
        body:
          "Recordings are saved, but nothing gets summarized until you connect one. Gemini is free and takes about two minutes.",
        destination: .providers
      )

    case .transient, .modelFlaky, .unknown:
      return nil
    }
  }

  private func reauthCommand(for provider: String) -> String? {
    switch provider {
    case "ChatGPT": return "codex auth"
    case "Claude": return "claude login"
    case "AWS": return "aws sso login"
    default: return nil
    }
  }

  /// Provider labels arrive as lowercase analytics names ("gemini",
  /// "chatgpt", "local"); map them to names fit for user-facing copy.
  private func displayName(forProviderLabel label: String?) -> String? {
    switch label?.lowercased() {
    case "gemini": return "Gemini"
    case "chatgpt": return "ChatGPT"
    case "claude": return "Claude"
    case "local", "ollama": return "Ollama/LM Studio"
    case "dayflow": return "Dayflow"
    default: return label
    }
  }
}

enum TimelineFailureClassifier {
  static func classify(_ error: Error) -> TimelineFailureClassification {
    let lower = error.localizedDescription.lowercased()
    return TimelineFailureClassification(
      kind: kind(for: lower),
      providerName: providerName(in: lower)
    )
  }

  private static func kind(for lower: String) -> TimelineFailureKind {
    let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)

    // Raw model output sometimes ends up as the error message (truncated
    // JSON, stray brackets, empty strings) — all symptoms of a flaky reply.
    if trimmed.isEmpty || trimmed.hasPrefix("[") || trimmed.hasPrefix("{")
      || trimmed.hasPrefix("]") || trimmed.hasPrefix("`")
    {
      return .modelFlaky
    }

    for rule in rules where rule.patterns.contains(where: lower.contains) {
      return rule.kind
    }
    return .unknown
  }

  /// Ordered: first matching rule wins, so specific/actionable rules must
  /// stay above the broad transient and model-flaky catch-alls.
  private static let rules: [(kind: TimelineFailureKind, patterns: [String])] = [
    (.dayflowProRequired, ["dayflow pro is required"]),
    (
      .providerLoginExpired,
      [
        "could not be refreshed", "log out and sign in", "please run /login",
        "sso session", "aws sso login",
      ]
    ),
    (.cliNotInstalled, ["cli not found", "enoent"]),
    (.cliOutdated, ["requires a newer version of codex"]),
    (.localEngineOffline, ["ollama/lmstudio is running"]),
    (
      .localModelMissing,
      [
        "ollama api request failed with status 404", "no models loaded",
        "context size has been exceeded",
      ]
    ),
    (
      .usageLimitHit,
      ["hit your usage limit", "hit your limit", "accountquotaexceeded", "usage quota"]
    ),
    (
      .outOfCredits,
      [
        "prepayment credits", "insufficient balance", "spending cap", "dunning",
        "payment required", "out of credits",
      ]
    ),
    (
      .apiKeyProblem,
      [
        "api key not found", "api key expired", "has been suspended",
        "api key not valid", "invalid api key",
      ]
    ),
    (.geoBlocked, ["location is not supported"]),
    (.accountBlocked, ["denied access"]),
    (.notConfigured, ["no llm provider configured"]),
    (.modelMisconfigured, ["is not found for api version", "not_found_error"]),
    (
      .transient,
      [
        "timed out", "reconnecting", "network connection", "internet connection",
        "tls error", "ssl error", "could not connect", "unable to connect",
        "connection refused", "econnreset", "socket", "hostname", "502",
        "upstream", "service unavailable", "internal error", "high demand",
        "at capacity", "quota exceeded", "too many requests", "overloaded",
        "message too long", "cancelled",
      ]
    ),
    (
      .modelFlaky,
      [
        "failed to decode", "be read because", "failed to parse", "empty title",
        "last segment", "segment end time", "segment out of bounds",
        "missing coverage", "gap detected", "reading additional input",
        "failed to load",
      ]
    ),
  ]

  private static func providerName(in lower: String) -> String? {
    if lower.contains("codex") || lower.contains("chatgpt")
      || lower.contains("could not be refreshed")
    {
      return "ChatGPT"
    }
    // Claude via Bedrock: the expired session is AWS's, and the fix is
    // 'aws sso login' — not 'claude login'. Must be checked before Claude.
    if lower.contains("aws sso") || lower.contains("sso session") {
      return "AWS"
    }
    if lower.contains("claude") || lower.contains("please run /login") {
      return "Claude"
    }
    if lower.contains("ollama") || lower.contains("lmstudio") || lower.contains("lm studio") {
      return "Ollama/LM Studio"
    }
    if lower.contains("gemini") || lower.contains("ai studio") || lower.contains("ai.studio")
      || lower.contains("generativelanguage") || lower.contains("api key")
      || lower.contains("lightning dunning")
    {
      return "Gemini"
    }
    return nil
  }
}
