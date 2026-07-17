import AppKit
import Foundation

final class CodexExecutableResolver: @unchecked Sendable {
  enum Source: String {
    case path
    case codexApp = "codex_app"
    case chatGPTApp = "chatgpt_app"
  }

  struct Candidate {
    let executableURL: URL
    let source: Source
  }

  struct Resolution {
    let executableURL: URL
    let source: Source
    let version: String
    let versionSummary: String
  }

  typealias CandidateProvider = () -> [Candidate]
  typealias VersionProbe = (URL) -> String?

  static let shared = CodexExecutableResolver()

  private struct SemanticVersion: Comparable {
    let components: [Int]
    let text: String

    init?(_ versionSummary: String) {
      guard
        let range = versionSummary.range(
          of: #"\d+(?:\.\d+){1,3}"#,
          options: .regularExpression
        )
      else { return nil }

      text = String(versionSummary[range])
      components = text.split(separator: ".").compactMap { Int($0) }
      guard components.count >= 2 else { return nil }
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
      let componentCount = max(lhs.components.count, rhs.components.count)
      for index in 0..<componentCount {
        let lhsComponent = index < lhs.components.count ? lhs.components[index] : 0
        let rhsComponent = index < rhs.components.count ? rhs.components[index] : 0
        if lhsComponent != rhsComponent {
          return lhsComponent < rhsComponent
        }
      }
      return false
    }
  }

  private struct RankedResolution {
    let resolution: Resolution
    let semanticVersion: SemanticVersion?
    let candidateIndex: Int
  }

  private let candidateProvider: CandidateProvider
  private let versionProbe: VersionProbe
  private let lock = NSLock()
  private var cachedResolution: Resolution?
  private var rejectedPaths = Set<String>()

  init(
    candidateProvider: @escaping CandidateProvider = CodexExecutableResolver.defaultCandidates,
    versionProbe: @escaping VersionProbe = CodexExecutableResolver.probeVersion
  ) {
    self.candidateProvider = candidateProvider
    self.versionProbe = versionProbe
  }

  func resolve() -> Resolution? {
    lock.lock()
    defer { lock.unlock() }

    if let cachedResolution {
      return cachedResolution
    }

    var seenPaths = Set<String>()
    let candidates = candidateProvider().filter { candidate in
      let path = Self.standardizedPath(candidate.executableURL)
      guard !rejectedPaths.contains(path), seenPaths.insert(path).inserted else {
        return false
      }
      return true
    }

    var bestResolution: RankedResolution?
    for (index, candidate) in candidates.enumerated() {
      guard let versionSummary = versionProbe(candidate.executableURL) else { continue }

      let semanticVersion = SemanticVersion(versionSummary)
      let resolution = Resolution(
        executableURL: candidate.executableURL.standardizedFileURL,
        source: candidate.source,
        version: semanticVersion?.text ?? versionSummary,
        versionSummary: versionSummary
      )
      let rankedResolution = RankedResolution(
        resolution: resolution,
        semanticVersion: semanticVersion,
        candidateIndex: index
      )

      if let currentBest = bestResolution {
        if isPreferred(rankedResolution, over: currentBest) {
          bestResolution = rankedResolution
        }
      } else {
        bestResolution = rankedResolution
      }
    }

    cachedResolution = bestResolution?.resolution
    if let cachedResolution {
      print(
        "[ChatCLI] Resolved Codex \(cachedResolution.version) from "
          + "\(cachedResolution.source.rawValue): \(cachedResolution.executableURL.path)"
      )
    }
    return cachedResolution
  }

  func reject(_ executableURL: URL) {
    lock.lock()
    defer { lock.unlock() }

    let path = Self.standardizedPath(executableURL)
    rejectedPaths.insert(path)
    if cachedResolution.map({ Self.standardizedPath($0.executableURL) }) == path {
      cachedResolution = nil
    }
  }

  func invalidate() {
    lock.lock()
    cachedResolution = nil
    rejectedPaths.removeAll()
    lock.unlock()
  }

  private func isPreferred(
    _ candidate: RankedResolution,
    over current: RankedResolution
  ) -> Bool {
    switch (candidate.semanticVersion, current.semanticVersion) {
    case let (candidateVersion?, currentVersion?):
      if candidateVersion != currentVersion {
        return candidateVersion > currentVersion
      }
    case (.some, .none):
      return true
    case (.none, .some):
      return false
    case (.none, .none):
      break
    }

    return candidate.candidateIndex < current.candidateIndex
  }

  private static func defaultCandidates() -> [Candidate] {
    var candidates: [Candidate] = []

    let marker = "__DAYFLOW_CODEX_PATH__="
    let shellPathResult = LoginShellRunner.run(
      "printf '__DAYFLOW_CODEX_PATH__=%s\\n' \"$PATH\"",
      timeout: 5
    )
    let shellPath = shellPathResult.stdout
      .components(separatedBy: .newlines)
      .last(where: { $0.hasPrefix(marker) })
      .map { String($0.dropFirst(marker.count)) }

    for path in [shellPath, ProcessInfo.processInfo.environment["PATH"]].compactMap({ $0 }) {
      appendPathCandidates(from: path, to: &candidates)
    }

    if let installedAppURL = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: "com.openai.codex"
    ) {
      candidates.append(appCandidate(for: installedAppURL))
    }

    let homeApplicationsURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Applications", isDirectory: true)
    let knownApps: [(URL, Source)] = [
      (URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true), .codexApp),
      (URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true), .chatGPTApp),
      (homeApplicationsURL.appendingPathComponent("Codex.app", isDirectory: true), .codexApp),
      (
        homeApplicationsURL.appendingPathComponent("ChatGPT.app", isDirectory: true),
        .chatGPTApp
      ),
    ]
    for (appURL, source) in knownApps {
      candidates.append(
        Candidate(
          executableURL: appURL.appendingPathComponent("Contents/Resources/codex"),
          source: source
        )
      )
    }

    return candidates
  }

  private static func appendPathCandidates(from path: String, to candidates: inout [Candidate]) {
    let fileManager = FileManager.default
    for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
      let directoryPath = directory.isEmpty ? fileManager.currentDirectoryPath : String(directory)
      candidates.append(
        Candidate(
          executableURL: URL(fileURLWithPath: directoryPath, isDirectory: true)
            .appendingPathComponent("codex"),
          source: .path
        )
      )
    }
  }

  private static func appCandidate(for appURL: URL) -> Candidate {
    let source: Source =
      appURL.lastPathComponent.caseInsensitiveCompare("ChatGPT.app") == .orderedSame
      ? .chatGPTApp : .codexApp
    return Candidate(
      executableURL: appURL.appendingPathComponent("Contents/Resources/codex"),
      source: source
    )
  }

  private static func probeVersion(at executableURL: URL) -> String? {
    guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { return nil }

    let result = LoginShellRunner.run(
      "\(LoginShellRunner.shellEscape(executableURL.path)) --version",
      timeout: 5
    )
    guard result.exitCode == 0 else { return nil }

    let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    let output = stdout.isEmpty ? stderr : stdout
    return output.components(separatedBy: .newlines).first(where: { !$0.isEmpty })
  }

  private static func standardizedPath(_ url: URL) -> String {
    url.standardizedFileURL.path
  }
}
