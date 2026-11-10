//
//  TimelineFailureClassifier.swift
//  Dayflow
//
//  Classifies timeline-generation failures into user-facing categories.
//  It is the only place failure copy lives: the plain-language sentence on
//  the failed timeline card, and the bottom-right card for problems the user
//  has to fix themselves. Pattern tables are derived from analysis_batch_failed
//  events and the raw CLI output logged with llm_api_call.
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

  // Non-actionable: Dayflow retries these on its own.
  case transient = "transient"
  case modelFlaky = "model_flaky"
  case unknown = "unknown"

  /// True when the provider's account or setup is the problem, so any other request to the same
  /// provider fails the same way, whichever model or step it's for.
  var failsEveryRequestToProvider: Bool {
    switch self {
    case .dayflowProRequired, .providerLoginExpired, .cliNotInstalled, .cliOutdated,
      .localEngineOffline, .apiKeyProblem, .usageLimitHit, .outOfCredits, .geoBlocked,
      .accountBlocked, .notConfigured:
      return true
    // A missing or unsupported model can work with the other step's model.
    case .modelMisconfigured, .localModelMissing, .transient, .modelFlaky, .unknown:
      return false
    }
  }
}

enum TimelineFailureToastDestination: String {
  case providers
  case account
}

struct TimelineFailureToastContent {
  /// The provider the card is about ("Claude", "ChatGPT", "Gemini", "Dayflow"...),
  /// used to pick the logo.
  var providerName = ""
  let title: String
  let body: String
  /// Plain-language steps to fix the problem. When `command` is set, it is
  /// shown under the first step with a Copy button. Empty means the card
  /// shows a settings button instead.
  let steps: [String]
  let command: String?
  let destination: TimelineFailureToastDestination
}

struct TimelineFailureClassification {
  let kind: TimelineFailureKind

  /// Provider named by the error text itself, when it identifies one.
  /// More reliable than the configured provider: after a backup fallback,
  /// the failing provider isn't the primary one.
  let providerName: String?

  /// One or two plain sentences for the failed timeline card. Written for
  /// someone who doesn't know what an API or JSON is.
  func cardMessage(fallbackProviderLabel: String?) -> String {
    let provider = resolvedProvider(fallbackProviderLabel)
    let catchUp = "Dayflow will catch up automatically once that's done."

    switch kind {
    case .dayflowProRequired:
      return
        "Your Dayflow Pro plan has ended. Renew it or switch to another provider in Settings. \(catchUp)"

    case .providerLoginExpired:
      if let fix = signInFix(for: provider) {
        return "\(provider) is signed out. \(fix.cardSentence) \(catchUp)"
      }
      return "\(provider) is signed out. Sign in again from Settings, under Providers. \(catchUp)"

    case .cliNotInstalled:
      return
        "Dayflow couldn't find \(provider)'s command-line tool on this Mac. Reinstall it, or switch providers in Settings. \(catchUp)"

    case .cliOutdated:
      return
        "Your Codex command-line tool is too old for the model Dayflow uses. Run `\(Self.codexUpdateCommand)` in Terminal to update it. \(catchUp)"

    case .localEngineOffline:
      return "Dayflow couldn't reach Ollama or LM Studio on this Mac. Open it. \(catchUp)"

    case .localModelMissing:
      return
        "Your local model isn't loaded. Open Ollama or LM Studio and load the model you picked in Dayflow. \(catchUp)"

    case .apiKeyProblem:
      return
        "Your \(provider) API key isn't working. Add a new key in Settings, under Providers. \(catchUp)"

    case .usageLimitHit:
      return
        "You've used up your \(provider) plan's usage for now. Dayflow will catch up automatically once your limit resets."

    case .outOfCredits:
      return
        "Your \(provider) account is out of credits. Top it up, or switch providers in Settings. \(catchUp)"

    case .geoBlocked:
      return
        "\(provider) isn't available in your region. Switch to another provider in Settings. \(catchUp)"

    case .accountBlocked:
      return
        "\(provider) blocked access for this account. A new API key or a different provider in Settings usually fixes it. \(catchUp)"

    case .modelMisconfigured:
      return
        "The AI model Dayflow tried to use isn't available on your \(provider) account. Pick a different one in Settings, under Providers. \(catchUp)"

    case .notConfigured:
      return "No AI provider is connected yet. Connect one in Settings, under Providers. \(catchUp)"

    case .transient:
      return
        "Dayflow couldn't reach \(provider) because the connection dropped or its servers were busy. Dayflow will try again automatically."

    case .modelFlaky:
      return
        "The AI's reply came back jumbled, so Dayflow couldn't turn it into cards. This usually sorts itself out, and Dayflow will try again automatically."

    case .unknown:
      return
        "Something went wrong while turning this time into cards. Dayflow will try again automatically."
    }
  }

  /// Copy for the bottom-right card, or nil when the failure isn't worth
  /// interrupting the user for (Dayflow retries those on its own).
  func toastContent(fallbackProviderLabel: String?) -> TimelineFailureToastContent? {
    let provider = resolvedProvider(fallbackProviderLabel)
    var content = baseToastContent(provider: provider)
    content?.providerName = kind == .dayflowProRequired ? "Dayflow" : provider
    return content
  }

  private func baseToastContent(provider: String) -> TimelineFailureToastContent? {
    switch kind {
    case .dayflowProRequired:
      return TimelineFailureToastContent(
        title: "Your Dayflow Pro plan ended",
        body: "Renew to keep your timeline going, or switch to a free provider like Gemini.",
        steps: [],
        command: nil,
        destination: .account
      )

    case .providerLoginExpired:
      guard let fix = signInFix(for: provider) else {
        return TimelineFailureToastContent(
          title: "\(provider) is signed out",
          body:
            "Sign in again from provider settings so Dayflow can turn your activity into cards.",
          steps: [],
          command: nil,
          destination: .providers
        )
      }
      return TimelineFailureToastContent(
        title: "\(provider) is signed out",
        body:
          "Your \(provider) login expired, so recent activity hasn't been turned into cards yet.",
        steps: fix.steps,
        command: fix.command,
        destination: .providers
      )

    case .cliNotInstalled:
      guard let installCommand = installCommand(for: provider) else {
        return TimelineFailureToastContent(
          title: "Dayflow can't find \(provider)",
          body:
            "Dayflow couldn't find \(provider)'s command-line tool on this Mac. Reinstall it, or switch providers.",
          steps: [],
          command: nil,
          destination: .providers
        )
      }
      return TimelineFailureToastContent(
        title: "Dayflow can't find \(provider)",
        body: "Dayflow uses \(provider)'s command-line tool, but couldn't find it on this Mac.",
        steps: ["Open Terminal and run"],
        command: installCommand,
        destination: .providers
      )

    case .cliOutdated:
      return TimelineFailureToastContent(
        title: "Codex needs an update",
        body: "Your Codex command-line tool is too old for the model Dayflow uses.",
        steps: ["Open Terminal and run"],
        command: Self.codexUpdateCommand,
        destination: .providers
      )

    case .localEngineOffline:
      return TimelineFailureToastContent(
        title: "Ollama or LM Studio isn't running",
        body: "Dayflow can't reach your local model.",
        steps: ["Open Ollama or LM Studio"],
        command: nil,
        destination: .providers
      )

    case .localModelMissing:
      return TimelineFailureToastContent(
        title: "Your local model isn't loaded",
        body: "Dayflow reached Ollama or LM Studio, but the model it uses isn't available.",
        steps: ["Open Ollama or LM Studio", "Download or load the model you picked in Dayflow"],
        command: nil,
        destination: .providers
      )

    case .apiKeyProblem:
      return TimelineFailureToastContent(
        title: "Your \(provider) API key isn't working",
        body: "It may be missing, expired, or suspended. Add a new key in provider settings.",
        steps: [],
        command: nil,
        destination: .providers
      )

    case .usageLimitHit:
      return TimelineFailureToastContent(
        title: "You've hit \(provider)'s usage limit",
        body:
          "Dayflow will catch up on its own when your limit resets. To keep going now, add a backup provider.",
        steps: [],
        command: nil,
        destination: .providers
      )

    case .outOfCredits:
      return TimelineFailureToastContent(
        title: "\(provider) is out of credits",
        body: "Top up your account, or switch to a free provider like Gemini.",
        steps: [],
        command: nil,
        destination: .providers
      )

    case .geoBlocked:
      return TimelineFailureToastContent(
        title: "\(provider) isn't available in your region",
        body: "Switching to a different provider fixes this.",
        steps: [],
        command: nil,
        destination: .providers
      )

    case .accountBlocked:
      return TimelineFailureToastContent(
        title: "\(provider) blocked this account",
        body: "Creating a new API key or switching providers usually fixes this.",
        steps: [],
        command: nil,
        destination: .providers
      )

    case .modelMisconfigured:
      return TimelineFailureToastContent(
        title: "Your selected model isn't available",
        body:
          "The model Dayflow tried to use isn't available on your \(provider) account. Pick a different one.",
        steps: [],
        command: nil,
        destination: .providers
      )

    case .notConfigured:
      return TimelineFailureToastContent(
        title: "No AI provider connected",
        body:
          "Your recordings are saved, but nothing gets turned into cards until you connect one. Gemini is free and takes about two minutes.",
        steps: [],
        command: nil,
        destination: .providers
      )

    case .transient, .modelFlaky, .unknown:
      return nil
    }
  }

  // MARK: - Helpers

  private static let codexUpdateCommand = "npm install -g @openai/codex@latest"

  private struct SignInFix {
    let steps: [String]
    let command: String
    let cardSentence: String
  }

  /// How to sign back in from Terminal, for providers that sign in through a CLI.
  private func signInFix(for provider: String) -> SignInFix? {
    switch provider {
    case "Claude":
      return SignInFix(
        steps: ["Open Terminal and run", "Type /login and sign in when your browser opens"],
        command: "claude",
        cardSentence: "Open Terminal, run `claude`, then type `/login` to sign back in."
      )
    case "ChatGPT":
      return SignInFix(
        steps: ["Open Terminal and run", "Sign in when your browser opens"],
        command: "codex login",
        cardSentence: "Run `codex login` in Terminal to sign back in."
      )
    case "AWS":
      return SignInFix(
        steps: ["Open Terminal and run", "Sign in when your browser opens"],
        command: "aws sso login",
        cardSentence: "Run `aws sso login` in Terminal to sign back in."
      )
    default:
      return nil
    }
  }

  private func installCommand(for provider: String) -> String? {
    switch provider {
    case "ChatGPT": return "npm install -g @openai/codex"
    case "Claude": return "npm install -g @anthropic-ai/claude-code"
    default: return nil
    }
  }

  private func resolvedProvider(_ fallbackProviderLabel: String?) -> String {
    providerName ?? displayName(forProviderLabel: fallbackProviderLabel) ?? "your AI provider"
  }

  /// Provider labels arrive as lowercase analytics names ("gemini",
  /// "chatgpt", "local"); map them to names fit for user-facing copy.
  private func displayName(forProviderLabel label: String?) -> String? {
    switch label?.lowercased() {
    case "gemini": return "Gemini"
    case "chatgpt", "codex": return "ChatGPT"
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

    for rule in rules where rule.patterns.contains(where: { lower.contains($0) }) {
      return rule.kind
    }
    return .unknown
  }

  /// Ordered: first matching rule wins, so specific/actionable rules must
  /// stay above the broad transient and model-flaky catch-alls.
  private static let rules: [(kind: TimelineFailureKind, patterns: [String])] = [
    // Dayflow's own checks on the model's reply. These messages can quote a
    // card title ("Card 1 'Fixing OAuth login' is only 8 minutes long"), so
    // they must match before the short patterns below read words in the title.
    (
      .modelFlaky,
      [
        "minutes long", "empty title", "last segment", "segment end time",
        "segment out of bounds", "missing coverage", "gap detected", "do not cover all",
        "invalid duration",
      ]
    ),
    (.dayflowProRequired, ["dayflow pro is required"]),
    (
      .providerLoginExpired,
      [
        "could not be refreshed", "log out and sign in", "please run /login", "run /login",
        "not logged in", "oauth", "token has been revoked", "authentication token",
        "sso session", "aws sso login",
      ]
    ),
    (.cliNotInstalled, ["cli not found", "enoent"]),
    (.cliOutdated, ["requires a newer version of codex", "newer version of codex"]),
    (
      .modelMisconfigured,
      [
        "is not supported when using codex with a chatgpt account",
        "is not found for api version", "not_found_error",
      ]
    ),
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
      [
        "hit your usage limit", "hit your limit", "usage limit", "session limit",
        "weekly limit", "spend limit", "accountquotaexceeded", "usage quota",
        // Claude names the window: "You've hit your 5-hour limit", "...weekly limit".
        "you've hit your", "you’ve hit your",
      ]
    ),
    (
      .outOfCredits,
      [
        "prepayment credits", "insufficient balance", "spending cap", "dunning",
        "payment required", "out of credits", "credit balance",
      ]
    ),
    (
      .apiKeyProblem,
      [
        "api key not found", "api key expired", "has been suspended",
        "api key not valid", "invalid api key", "service account",
      ]
    ),
    (.geoBlocked, ["location is not supported"]),
    (.accountBlocked, ["denied access", "organization has disabled", "account is on hold"]),
    (.notConfigured, ["no llm provider configured"]),
    (
      .transient,
      [
        "timed out", "reconnecting", "network connection", "internet connection",
        "tls error", "ssl error", "could not connect", "unable to connect",
        "connection refused", "econnreset", "enotfound", "socket", "hostname", "502",
        "503", "529", "upstream", "service unavailable", "internal error", "high demand",
        "at capacity", "quota exceeded", "too many requests", "overloaded",
        "stream disconnected", "message too long", "cancelled",
      ]
    ),
    (
      .modelFlaky,
      [
        "failed to decode", "be read because", "failed to parse", "reading additional input",
        "failed to load", "no stdout to parse",
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
    // 'aws sso login' — not Claude's own login. Must be checked before Claude.
    if lower.contains("aws sso") || lower.contains("sso session") {
      return "AWS"
    }
    if lower.contains("claude") || lower.contains("/login") || lower.contains("anthropic") {
      return "Claude"
    }
    if lower.contains("ollama") || lower.contains("lmstudio") || lower.contains("lm studio") {
      return "Ollama/LM Studio"
    }
    if lower.contains("gemini") || lower.contains("ai studio") || lower.contains("ai.studio")
      || lower.contains("generativelanguage")
      || lower.contains("lightning dunning")
    {
      return "Gemini"
    }
    return nil
  }
}
