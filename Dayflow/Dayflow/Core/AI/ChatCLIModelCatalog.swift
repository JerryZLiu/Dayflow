//
//  ChatCLIModelCatalog.swift
//  Dayflow
//
//  Discovers the list of models a user can pick for the Chat CLI
//  providers (Claude and Codex). Mirrors the role
//  `GeminiModelPreference` plays for Gemini, but with one important
//  difference: we don't hard-code the model list. The CLI is the
//  source of truth because:
//   1. Each user has a different account and therefore access to
//      different models — we can't ship a list that's right for
//      everyone.
//   2. Model names move (Sonnet 4 → Sonnet 4.5 → Sonnet 5 …). The
//      aliases (`sonnet`, `opus`, `fable`) track the latest release
//      automatically; the catalog just records what the user can
//      actually use *right now*.
//
//  The probe is a tiny `--print` call with a one-word prompt. It
//  costs one trivial API call per alias. We run all aliases in
//  parallel and cache the result for one hour so the Settings UI
//  doesn't trigger a network roundtrip on every refresh.
//
//  When the CLI isn't installed or the probe fails, we fall back to
//  the static enum's display name. The picker always shows *something*
//  useful — even offline.

import Foundation

/// A model that the user can pick for a Chat CLI provider.
struct DiscoveredChatCLIModel: Identifiable, Hashable, Sendable, Codable {
  let id: String  // Stable identifier — the CLI alias (e.g. "sonnet")
  let displayName: String  // Resolved user-facing label (e.g. "Claude Sonnet 5")
  let fullName: String  // What the CLI reported back (e.g. "claude-sonnet-5")
}

enum ChatCLIModelCatalogError: Error {
  case cliUnavailable(String)
  case probeFailed(alias: String, underlying: String)
}

/// Result of a discovery pass. Bundles per-provider results so the
/// Settings UI can show whatever's available without re-querying.
struct ChatCLIModelCatalogResult: Sendable {
  let claude: [DiscoveredChatCLIModel]
  let codex: [DiscoveredChatCLIModel]
  let discoveredAt: Date

  static let empty = ChatCLIModelCatalogResult(
    claude: [], codex: [], discoveredAt: .distantPast)
}

enum ChatCLIModelCatalog {

  // MARK: - Alias sources of truth
  //
  // These are the *aliases* the CLI accepts as `--model` values.
  // We keep them aligned with the `ClaudeModel` / `CodexModel` enums
  // so the picker can show the resolved display name next to the
  // enum-driven hint. If a new alias lands, add it to the enum AND
  // to this list — the catalog discovery is what powers the
  // Settings UI's model list.

  static let knownClaudeAliases: [String] = [
    ClaudeModel.sonnet.rawValue,
    ClaudeModel.opus.rawValue,
    ClaudeModel.fable.rawValue,
    ClaudeModel.haiku.rawValue,
  ]

  static let knownCodexAliases: [String] = [
    CodexModel.gpt56Luna.rawValue,
    CodexModel.gpt54.rawValue,
    CodexModel.gpt54Mini.rawValue,
  ]

  // MARK: - Caching

  private static let cacheKey = "chatCLIModelCatalog.v1"
  private static let cacheLifetime: TimeInterval = 60 * 60  // 1 hour

  /// Returns the cached catalog if it's fresh, otherwise `nil` and
  /// the caller should invoke `discover(refresh: true)`.
  static func cached() -> ChatCLIModelCatalogResult? {
    guard
      let data = UserDefaults.standard.data(forKey: cacheKey),
      let result = try? JSONDecoder().decode(CachedEnvelope.self, from: data)
    else {
      return nil
    }
    let age = Date().timeIntervalSince(result.discoveredAt)
    guard age < cacheLifetime else { return nil }
    return result.toResult()
  }

  /// Stores the result on disk. Failure is non-fatal — the next
  /// discover call will just re-probe.
  static func store(_ result: ChatCLIModelCatalogResult) {
    let envelope = CachedEnvelope(
      discoveredAt: result.discoveredAt,
      claude: result.claude,
      codex: result.codex
    )
    if let data = try? JSONEncoder().encode(envelope) {
      UserDefaults.standard.set(data, forKey: cacheKey)
    }
  }

  /// Clears the cache. Wired to the Settings UI's "Refresh" button
  /// so users can force a re-probe (e.g. after upgrading their
  /// subscription tier).
  static func invalidate() {
    UserDefaults.standard.removeObject(forKey: cacheKey)
  }

  // MARK: - Discovery

  /// Probes the installed CLIs in parallel and returns whatever
  /// models are accessible. Always returns a value — if the CLI
  /// is missing or every probe fails, the result is empty (the
  /// Settings UI will then fall back to the static enum list).
  static func discover(refresh: Bool = false) async -> ChatCLIModelCatalogResult {
    if !refresh, let cached = cached() {
      return cached
    }

    async let claudeResult = probeClaude()
    async let codexResult = probeCodex()

    let result = ChatCLIModelCatalogResult(
      claude: await claudeResult,
      codex: await codexResult,
      discoveredAt: Date()
    )
    store(result)
    return result
  }

  // MARK: - Probes

  /// Probes every Claude alias. Skips aliases that fail; preserves
  /// the rest. The order in the result matches `knownClaudeAliases`
  /// so the picker shows them in a stable order.
  private static func probeClaude() async -> [DiscoveredChatCLIModel] {
    let probeResults = await withTaskGroup(
      of: (String, DiscoveredChatCLIModel?).self
    ) { group in
      for alias in knownClaudeAliases {
        group.addTask { (alias, await probeModel(cli: .claude, alias: alias)) }
      }
      var out: [(String, DiscoveredChatCLIModel?)] = []
      for await pair in group {
        out.append(pair)
      }
      return out
    }

    return probeResults
      .sorted { lhs, rhs in
        // Preserve the order in `knownClaudeAliases` so the picker
        // shows Sonnet → Opus → Fable → Haiku consistently.
        let li = knownClaudeAliases.firstIndex(of: lhs.0) ?? Int.max
        let ri = knownClaudeAliases.firstIndex(of: rhs.0) ?? Int.max
        return li < ri
      }
      .compactMap { $0.1 }
  }

  private static func probeCodex() async -> [DiscoveredChatCLIModel] {
    let probeResults = await withTaskGroup(
      of: (String, DiscoveredChatCLIModel?).self
    ) { group in
      for alias in knownCodexAliases {
        group.addTask { (alias, await probeModel(cli: .codex, alias: alias)) }
      }
      var out: [(String, DiscoveredChatCLIModel?)] = []
      for await pair in group {
        out.append(pair)
      }
      return out
    }

    return probeResults
      .sorted { lhs, rhs in
        let li = knownCodexAliases.firstIndex(of: lhs.0) ?? Int.max
        let ri = knownCodexAliases.firstIndex(of: rhs.0) ?? Int.max
        return li < ri
      }
      .compactMap { $0.1 }
  }

  /// Probes a single model. Returns `nil` on any failure (CLI
  /// missing, alias not recognized, transient error). The cache
  /// layer above swallows the nil and the Settings UI just omits
  /// the row.
  ///
  /// We deliberately bypass `ChatCLIProcessRunner` here. The runner
  /// is built for real screen-recording batches (safe mode, MCP
  /// config, session management, PTY-vs-pipe handling) and those
  /// affordances cause the probe to silently produce no stdout on
  /// some setups — which leaves the catalog empty. The probe only
  /// needs three things from the CLI: does the alias resolve, what
  /// model name did the CLI use, and does the user have access. A
  /// plain `claude -p --output-format json --model <alias> "OK"` on
  /// a vanilla `Process` pipe answers all three without any of the
  /// runner's complications.
  private static func probeModel(
    cli: ChatCLITool,
    alias: String
  ) async -> DiscoveredChatCLIModel? {
    let probeCommand: String
    let arguments: [String]
    switch cli {
    case .claude:
      // Plain `claude -p` with `--output-format json` returns a
      // single JSON object on stdout (not the JSONL stream the
      // `--verbose` flag produces). The parser handles both shapes,
      // but the plain form is simpler and matches what `claude
      // --help` documents as the standard non-interactive path.
      // The trailing `--` is important: the prompt is the next
      // argument and we don't want it to be interpreted as a flag.
      probeCommand = "/usr/bin/env"
      arguments = [
        "claude", "-p", "--output-format", "json",
        "--model", alias, "--",
        "Respond with only the word OK.",
      ]
    case .codex:
      // Codex CLI exposes the same `--json` flag on `exec` and
      // takes the model via `-m`. We invoke through `/usr/bin/env`
      // so the user's PATH (with their Codex install) is honoured
      // without us having to resolve the executable ourselves.
      probeCommand = "/usr/bin/env"
      arguments = [
        "codex", "exec", "--skip-git-repo-check", "--json",
        "-m", alias, "--",
        "Respond with only the word OK.",
      ]
    }

    do {
      let result = try await Task.detached(priority: .utility) {
        try Self.runProbeCommand(executable: probeCommand, arguments: arguments)
      }.value

      guard result.exitCode == 0 else {
        return nil
      }

      let resolved = parseResolvedModelName(
        from: result.stdout, fallback: result.stdout)
      let displayName = Self.prettyName(forResolved: resolved, alias: alias, cli: cli)
      return DiscoveredChatCLIModel(
        id: alias, displayName: displayName, fullName: resolved)
    } catch {
      return nil
    }
  }

  /// Minimal `Process`-based probe runner. We don't need login-shell
  /// indirection or MCP config or safe mode — we just need a one-shot
  /// `claude -p "OK"` and the JSON it produces. Anything more
  /// elaborate drags in the runtime quirks that make a probe
  /// unreliable (see the long comment on `probeModel`).
  private static func runProbeCommand(
    executable: String,
    arguments: [String],
    timeoutSeconds: TimeInterval = 60
  ) throws -> (exitCode: Int32, stdout: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    // Inherit the user's environment so the CLI finds its own
    // config (e.g. ~/.claude, Codex auth). The probe doesn't need
    // anything special beyond that.
    process.environment = ProcessInfo.processInfo.environment

    let stdoutPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = Pipe()  // discard — the probe only cares about exit + JSON stdout

    try process.run()

    // Cap the probe at 60s. In practice a "Respond with only the word
    // OK" call takes 1-5s; if it doesn't finish in a minute something
    // is fundamentally wrong (auth expired, network hung, account
    // throttled) and we should give up rather than block the UI.
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while process.isRunning && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.1)
    }
    if process.isRunning {
      process.terminate()
      return (exitCode: -1, stdout: "")
    }

    let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let stdout = String(data: data, encoding: .utf8) ?? ""
    return (exitCode: process.terminationStatus, stdout: stdout)
  }

  /// Pulls the first `modelUsage.*` key out of the JSON the CLI
  /// emitted. Handles three shapes the Claude CLI can produce:
  ///
  /// 1. **Plain JSON** (no `--verbose`): a single object on stdout,
  ///    e.g. `{"modelUsage":{"claude-opus-4-8":{...}}}`.
  /// 2. **JSONL** (with `--verbose`, which the `ChatCLIProcessRunner`
  ///    always adds when a `profile` is set): newline-delimited
  ///    objects, the last of which is `{"type":"result", ...,
  ///    "modelUsage":{"claude-opus-4-8":{...}}}`.
  /// 3. **Garbage / older CLI** that we can't parse — we return `""`
  ///    and let the static enum display name be the fallback.
  ///
  /// We split JSONL on newlines and look at every line, because the
  /// exact ordering of stream events has changed between Claude CLI
  /// versions and a naive "last line" assumption bit us with 2.1.197.
  private static func parseResolvedModelName(
    from rawStdout: String, fallback stdout: String
  ) -> String {
    // First try: plain single-object JSON. Cheap, and works when the
    // CLI is invoked without `--verbose` (e.g. directly from a
    // terminal with `claude -p --output-format json ...`).
    if let resolved = parseSingleJSONObjectForModelUsage(rawStdout) {
      return resolved
    }
    // Second try: JSONL. Split on newlines, parse each line as its
    // own JSON object, take the first `modelUsage` we find. We
    // scan the whole stream because in practice `modelUsage` only
    // appears on the final result event, but we don't want to
    // depend on that — if a future CLI version emits usage in an
    // earlier event, we'll still find it.
    for line in rawStdout.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { continue }
      if let resolved = parseSingleJSONObjectForModelUsage(trimmed) {
        return resolved
      }
    }
    // Last-ditch: legacy text scan. Covers older CLI versions whose
    // output we don't recognise as JSON at all.
    for line in stdout.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.hasPrefix("modelUsage") || trimmed.hasPrefix("\"modelUsage") {
        if let start = trimmed.firstIndex(of: "\""),
          let end = trimmed.lastIndex(of: "\""),
          start != end
        {
          let after = trimmed.index(after: start)
          if after < end {
            return String(trimmed[after..<end])
          }
        }
      }
    }
    return ""
  }

  /// Parses a single JSON object string and returns the first key
  /// of its `modelUsage` dictionary, or `nil` if the string isn't a
  /// valid JSON object or doesn't carry `modelUsage`. Extracted so
  /// `parseResolvedModelName` can call it for both the single-object
  /// case and every line of a JSONL stream.
  private static func parseSingleJSONObjectForModelUsage(_ text: String) -> String? {
    guard let data = text.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let modelUsage = obj["modelUsage"] as? [String: Any],
      let firstKey = modelUsage.keys.first
    else {
      return nil
    }
    return firstKey
  }

  /// Builds the user-facing label shown in the picker. We prefer
  /// the resolved full name when it adds information (e.g.
  /// "Claude Sonnet 5" rather than "Sonnet"), and fall back to the
  /// enum's static display name when the probe didn't return
  /// anything useful.
  private static func prettyName(
    forResolved resolved: String,
    alias: String,
    cli: ChatCLITool
  ) -> String {
    let trimmed = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      // Probe returned nothing parseable — fall back to the enum
      // entry. Keeps the picker useful even if the JSON format
      // changes out from under us.
      switch cli {
      case .claude:
        return ClaudeModel(rawValue: alias)?.displayName ?? alias
      case .codex:
        return CodexModel(rawValue: alias)?.displayName ?? alias
      }
    }
    switch cli {
    case .claude:
      // `claude-sonnet-5` → "Claude Sonnet 5"
      if let parsed = ClaudeModel(rawValue: alias) {
        return "\(parsed.displayName) \(versionSuffix(from: trimmed))".trimmingCharacters(
          in: .whitespacesAndNewlines)
      }
      return trimmed
    case .codex:
      if let parsed = CodexModel(rawValue: alias) {
        // The Codex CLI currently echoes the model id back as-is,
        // so the alias and the full name are typically identical.
        // Don't render the parenthetical when that would just
        // duplicate the enum's display name — "GPT 5.4 (gpt-5.4)"
        // is noise. If a future CLI version reports a longer
        // identifier (e.g. "gpt-5.4-mini-2025-09-15") we keep the
        // parenthetical so the user can see the resolved name.
        if trimmed.lowercased() == alias.lowercased() {
          return parsed.displayName
        }
        return "\(parsed.displayName) (\(trimmed))"
      }
      return trimmed
    }
  }

  /// Extracts a human-readable version label from a resolved Claude
  /// model name. Handles the patterns the CLI currently emits:
  ///
  /// - `claude-sonnet-5`           → `5`
  /// - `claude-opus-4-8`           → `4.8`
  /// - `claude-haiku-4-5-20251001` → `4.5`   (build date dropped)
  /// - `claude-fable-5-preview`    → `5`     (preview tag dropped)
  ///
  /// We walk the dash-separated segments and take the leading run
  /// of "version-like" digit segments after the family name. We
  /// stop at the first segment that is either non-numeric (a
  /// `preview` tag, a date string, etc.) or a "long" number —
  /// anything 5+ digits is almost certainly a build date or
  /// snapshot id, not a version (current Anthropic versions are
  /// 1-2 digits, e.g. "4-8" or "4-5"). The leading run of digit
  /// segments is then joined with `.` so multi-segment versions
  /// render naturally.
  private static func versionSuffix(from fullName: String) -> String {
    let segments = fullName.split(separator: "-").map(String.init)
    // Find the first all-digit segment. Anything before it is the
    // family/prefix name (e.g. "claude-sonnet", "claude-haiku")
    // and we don't include it in the version because the caller
    // already prepends the family display name.
    guard
      let firstDigitIndex = segments.firstIndex(where: { $0.allSatisfy(\.isNumber) })
    else {
      return ""
    }
    // Take the leading run of "version-like" digit segments. We
    // treat any 5+ digit number as a build date / snapshot id and
    // stop before it. This makes `claude-haiku-4-5-20251001`
    // resolve to `4.5` (not `4.5.20251001`).
    let versionParts = segments[firstDigitIndex...].prefix { segment in
      segment.allSatisfy(\.isNumber) && segment.count <= 4
    }
    return versionParts.joined(separator: ".")
  }
}

// MARK: - Caching envelope

/// JSON-encodable wrapper so the cache survives across launches
/// without depending on the in-memory type's identity.
private struct CachedEnvelope: Codable {
  let discoveredAt: Date
  let claude: [DiscoveredChatCLIModel]
  let codex: [DiscoveredChatCLIModel]

  func toResult() -> ChatCLIModelCatalogResult {
    ChatCLIModelCatalogResult(
      claude: claude, codex: codex, discoveredAt: discoveredAt)
  }
}
