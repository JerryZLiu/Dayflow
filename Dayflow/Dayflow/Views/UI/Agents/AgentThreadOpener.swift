//
//  AgentThreadOpener.swift
//  Dayflow
//
//  Opens a recap thread in its native surface (the card's "Source" button):
//  - Codex threads deep-link into the Codex desktop app.
//  - Claude threads focus the Ghostty tab running that session when one can
//    be found, otherwise resume the session in a new Ghostty window.
//  Every failure path falls back to revealing the transcript in Finder, so
//  the button never dead-ends.
//
//  Scripting Ghostty requires the one-time Automation permission ("Dayflow
//  wants to control Ghostty") and NSAppleEventsUsageDescription in Info.plist.
//

import AppKit
import Foundation

enum AgentThreadOpener {

  private static let ghosttyBundleID = "com.mitchellh.ghostty"

  @MainActor
  static func open(_ thread: AgentThread) {
    guard !thread.sessionPath.isEmpty else { return }
    switch thread.source {
    case .codex:
      openCodexThread(sessionPath: thread.sessionPath)
    case .claude:
      let sessionPath = thread.sessionPath
      Task.detached(priority: .userInitiated) {
        openClaudeThread(sessionPath: sessionPath)
      }
    }
  }

  // MARK: - Codex: deep link into the desktop app

  @MainActor
  private static func openCodexThread(sessionPath: String) {
    guard
      let threadID = codexThreadID(fromSessionPath: sessionPath),
      let url = URL(string: "codex://threads/\(threadID)"),
      NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    else {
      revealInFinder(sessionPath)
      return
    }
    NSWorkspace.shared.open(url)
  }

  /// rollout-2026-07-06T19-45-03-<uuid>.jsonl → <uuid>
  /// (the UUID is the last five hyphen-separated groups of the stem)
  static func codexThreadID(fromSessionPath path: String) -> String? {
    let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    guard stem.hasPrefix("rollout-") else { return nil }
    let parts = stem.split(separator: "-")
    guard parts.count >= 11 else { return nil }
    return parts.suffix(5).joined(separator: "-")
  }

  // MARK: - Claude: focus the live Ghostty tab, or resume in a new window

  private nonisolated static func openClaudeThread(sessionPath: String) {
    let sessionID = URL(fileURLWithPath: sessionPath)
      .deletingPathExtension().lastPathComponent
    let transcript = transcriptInfo(sessionPath)

    if let surface = liveSurface(forSessionPath: sessionPath, transcript: transcript),
      focusSurface(id: surface.id)
    {
      return
    }
    if resumeSession(id: sessionID, cwd: transcript.cwd) { return }

    Task { @MainActor in
      revealInFinder(sessionPath)
    }
  }

  private struct GhosttySurface {
    let id: String
    let pid: Int
    let workingDirectory: String
    let title: String
  }

  /// The `claude` process doesn't expose its session ID, so the join is
  /// heuristic: surfaces in the session's working directory whose foreground
  /// process is claude, disambiguated by tab title against the transcript's
  /// summary lines (exact when available), else by whichever process
  /// launched closest to the session's first message. When the project has
  /// any live claude tab we always focus rather than open a duplicate.
  private nonisolated static func liveSurface(
    forSessionPath sessionPath: String, transcript: TranscriptInfo
  ) -> GhosttySurface? {
    guard let cwd = transcript.cwd else { return nil }

    let surfaces = listGhosttySurfaces()
    let claudePIDs = pidsRunningClaude(surfaces.map(\.pid))
    let candidates = surfaces.filter {
      $0.workingDirectory == cwd && claudePIDs.contains($0.pid)
    }
    guard candidates.count > 1 else { return candidates.first }

    let summaries = transcriptSummaries(sessionPath).map(normalized)
    if let titleMatch = candidates.first(where: { summaries.contains(normalized($0.title)) }) {
      return titleMatch
    }

    guard let sessionStart = transcript.firstTimestamp else { return candidates.first }
    let launchDates = processStartDates(candidates.map(\.pid))
    return candidates.min { lhs, rhs in
      distance(launchDates[lhs.pid], from: sessionStart)
        < distance(launchDates[rhs.pid], from: sessionStart)
    }
  }

  private nonisolated static func distance(_ date: Date?, from reference: Date) -> TimeInterval {
    guard let date else { return .infinity }
    return abs(date.timeIntervalSince(reference))
  }

  private nonisolated static func listGhosttySurfaces() -> [GhosttySurface] {
    // `tell application` would launch Ghostty just to enumerate; only script
    // it when it's already running.
    guard !NSRunningApplication.runningApplications(withBundleIdentifier: ghosttyBundleID).isEmpty
    else { return [] }

    let script = """
      set fs to string id 31
      set out to ""
      tell application "Ghostty"
        repeat with t in terminals
          set out to out & (id of t) & fs & (pid of t) & fs \
            & (working directory of t) & fs & (name of t) & linefeed
        end repeat
      end tell
      return out
      """
    guard let output = runAppleScript(script) else { return [] }

    return output.split(separator: "\n").compactMap { line in
      let fields = line.components(separatedBy: "\u{1F}")
      guard fields.count == 4, let pid = Int(fields[1]) else { return nil }
      return GhosttySurface(
        id: fields[0], pid: pid, workingDirectory: fields[2], title: fields[3])
    }
  }

  private nonisolated static func focusSurface(id: String) -> Bool {
    let script = """
      tell application "Ghostty"
        activate
        focus (first terminal whose id is "\(id)")
      end tell
      """
    return runAppleScript(script) != nil
  }

  private nonisolated static func resumeSession(id sessionID: String, cwd: String?) -> Bool {
    var configuration = "{command:\"claude --resume \(sessionID)\", wait after command:true"
    if let cwd {
      configuration += ", initial working directory:\"\(appleScriptEscaped(cwd))\""
    }
    configuration += "}"

    let script = """
      tell application "Ghostty"
        activate
        new window with configuration \(configuration)
      end tell
      """
    return runAppleScript(script) != nil
  }

  // MARK: - Transcript reading

  private struct TranscriptInfo {
    var cwd: String?
    var firstTimestamp: Date?
  }

  /// The session's cwd and first message timestamp are recorded on the
  /// transcript's early lines.
  private nonisolated static func transcriptInfo(_ path: String) -> TranscriptInfo {
    var info = TranscriptInfo()
    guard
      let handle = FileHandle(forReadingAtPath: path),
      let data = try? handle.read(upToCount: 64_000),
      let text = String(data: data, encoding: .utf8)
    else { return info }
    try? handle.close()

    for line in text.split(separator: "\n") {
      guard
        let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
      else { continue }
      if info.cwd == nil {
        info.cwd = object["cwd"] as? String
      }
      if info.firstTimestamp == nil, let timestamp = object["timestamp"] as? String {
        info.firstTimestamp = parseISO8601(timestamp)
      }
      if info.cwd != nil && info.firstTimestamp != nil { break }
    }
    return info
  }

  private nonisolated static func parseISO8601(_ text: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: text) { return date }
    return ISO8601DateFormatter().date(from: text)
  }

  /// Claude Code writes summary lines into the transcript and uses them as
  /// the live tab title. Transcripts can be tens of MB, so grep instead of
  /// loading the file.
  private nonisolated static func transcriptSummaries(_ path: String) -> [String] {
    let output = runCommand("/usr/bin/grep", ["-F", "\"type\":\"summary\"", path]) ?? ""
    return output.split(separator: "\n").compactMap { line in
      guard
        let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
      else { return nil }
      return object["summary"] as? String
    }
  }

  /// Tab titles carry a leading status glyph (e.g. "✳ Fix sign-in sheet");
  /// strip it so they compare against raw summary strings.
  private nonisolated static func normalized(_ text: String) -> String {
    text
      .replacingOccurrences(of: "✳", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  // MARK: - Process helpers

  /// Launch time per pid via `ps lstart` (e.g. "Mon Jul  7 02:14:33 2026").
  private nonisolated static func processStartDates(_ pids: [Int]) -> [Int: Date] {
    guard !pids.isEmpty else { return [:] }
    let list = pids.map(String.init).joined(separator: ",")
    let output = runCommand("/bin/ps", ["-o", "pid=,lstart=", "-p", list]) ?? ""

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"

    var result: [Int: Date] = [:]
    for line in output.split(separator: "\n") {
      let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
      guard parts.count >= 6, let pid = Int(parts[0]) else { continue }
      if let date = formatter.date(from: parts[1...5].joined(separator: " ")) {
        result[pid] = date
      }
    }
    return result
  }

  private nonisolated static func pidsRunningClaude(_ pids: [Int]) -> Set<Int> {
    guard !pids.isEmpty else { return [] }
    let list = pids.map(String.init).joined(separator: ",")
    let output = runCommand("/bin/ps", ["-o", "pid=,comm=", "-p", list]) ?? ""

    var result = Set<Int>()
    for line in output.split(separator: "\n") {
      let parts = line.split(separator: " ", omittingEmptySubsequences: true)
      guard parts.count >= 2, let pid = Int(parts[0]) else { continue }
      if parts.last == "claude" || parts.last?.hasSuffix("/claude") == true {
        result.insert(pid)
      }
    }
    return result
  }

  private nonisolated static func runAppleScript(_ source: String) -> String? {
    runCommand("/usr/bin/osascript", ["-e", source])
  }

  private nonisolated static func runCommand(_ launchPath: String, _ arguments: [String])
    -> String?
  {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()

    do { try process.run() } catch { return nil }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private nonisolated static func appleScriptEscaped(_ text: String) -> String {
    text
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }

  @MainActor
  private static func revealInFinder(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
  }
}
