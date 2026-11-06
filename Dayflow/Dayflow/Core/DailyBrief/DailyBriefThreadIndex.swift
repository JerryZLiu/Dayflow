//
//  DailyBriefThreadIndex.swift
//  Dayflow
//
//  Lists the person's recent Claude Code (desktop app) and Codex threads for the Spring run,
//  so it can tell when a task was already started and send the hand-off to that thread.
//  Each thread shows its first and last few messages, cut short, plus the path of its full
//  transcript, which the run can open when the short version isn't enough.
//
//  Where the threads live:
//    Claude Code  ~/Library/Application Support/Claude/claude-code-sessions/**/local_<id>.json
//                 (id, title, folder, last activity) with the transcript in
//                 ~/.claude/projects/<folder>/<cliSessionId>.jsonl
//    Codex        ~/.codex/sessions/<yyyy>/<mm>/<dd>/rollout-<...>.jsonl, titles in
//                 ~/.codex/session_index.jsonl. `codex exec` runs and subagents are skipped:
//                 they're scripts, not threads the person works in.
//

import Foundation

enum DailyBriefThreadIndex {
  /// How far back to look.
  static let lookback: TimeInterval = 3 * 24 * 60 * 60
  private static let messagesPerEnd = 3
  private static let maxMessageCharacters = 300
  private static let maxThreads = 30

  private static let home = FileManager.default.homeDirectoryForCurrentUser
  static let claudeProjectsFolder = home.appendingPathComponent(
    ".claude/projects", isDirectory: true)
  static let codexSessionsFolder = home.appendingPathComponent(".codex/sessions", isDirectory: true)
  private static let claudeSessionsFolder = home.appendingPathComponent(
    "Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
  private static let codexTitlesFile = home.appendingPathComponent(".codex/session_index.jsonl")

  /// Folders whose transcripts the Spring run may read.
  static var transcriptFolders: [URL] { [claudeProjectsFolder, codexSessionsFolder] }

  struct Message {
    let fromPerson: Bool
    let text: String
  }

  struct Thread {
    let app: String
    let id: String
    let title: String?
    let folder: String?
    let lastActive: Date
    let transcript: URL?
    var messages: [Message] = []
    var hasMoreInBetween = false
  }

  // MARK: - Prompt block

  /// The threads as text for the prompt, newest first, or a plain note when there are none.
  static func promptBlock(now: Date = Date()) -> String {
    let cutoff = now.addingTimeInterval(-lookback)
    // The same Claude session can be saved in more than one place; keep its newest copy.
    var newestByID: [String: Thread] = [:]
    for thread in claudeThreads(since: cutoff) + codexThreads(since: cutoff) {
      if let kept = newestByID[thread.id], kept.lastActive >= thread.lastActive { continue }
      newestByID[thread.id] = thread
    }
    let allThreads = newestByID.values.sorted { $0.lastActive > $1.lastActive }
    guard !allThreads.isEmpty else { return "None in the last 3 days." }
    // Messages are read last, and only for the threads that make the list, since
    // transcripts can be tens of megabytes.
    let threads = allThreads.prefix(maxThreads).map(withMessages)
    return ([usageSummary(allThreads)] + threads.map(describe)).joined(separator: "\n\n")
  }

  /// How much they use each app, overall and per folder, so the run can tell which app they
  /// prefer for a kind of work.
  private static func usageSummary(_ threads: [Thread]) -> String {
    func counts(_ threads: [Thread]) -> String {
      let claude = threads.filter { $0.app == "Claude Code" }.count
      return "\(claude) Claude Code, \(threads.count - claude) Codex"
    }
    var lines = ["Usage in the last 3 days: \(counts(threads)) threads."]
    // The Claude app gives each no-project chat its own scratch folder; count those as one.
    let byFolder = Dictionary(grouping: threads) { thread -> String in
      guard let folder = thread.folder else { return "no folder" }
      return folder.contains("/Claude/scratch-workspaces/")
        ? "Claude scratch folders (no project)" : folder
    }
    for (folder, folderThreads) in byFolder.sorted(by: { $0.value.count > $1.value.count }) {
      lines.append("- \(folder): \(counts(folderThreads))")
    }
    return lines.joined(separator: "\n")
  }

  private static func withMessages(_ thread: Thread) -> Thread {
    guard let transcript = thread.transcript else { return thread }
    let read: ([[String: Any]]) -> [Message] =
      thread.app == "Codex" ? codexMessages : claudeMessages
    var result = thread
    // Only the start and end of the file matter here, so long transcripts are read in two
    // slices; a short file is read once, whole.
    let (head, tail) = slices(of: transcript)
    let first = read(head)
    if let tail {
      result.messages =
        Array(first.prefix(messagesPerEnd)) + Array(read(tail).suffix(messagesPerEnd))
      result.hasMoreInBetween = true
    } else {
      result.messages = first
    }
    return result
  }

  private static func describe(_ thread: Thread) -> String {
    var header = "- \(thread.app) thread `\(thread.id)`"
    if let title = thread.title { header += " · \"\(title)\"" }
    header += " · last active \(timestamp(thread.lastActive))"
    var lines = [header]
    if let folder = thread.folder { lines.append("  Folder: \(folder)") }
    if let transcript = thread.transcript { lines.append("  Full transcript: \(transcript.path)") }

    let messages = thread.messages
    if messages.count <= messagesPerEnd * 2 && !thread.hasMoreInBetween {
      lines.append("  Messages:")
      lines += messages.map(describe)
    } else {
      lines.append("  First messages:")
      lines += messages.prefix(messagesPerEnd).map(describe)
      lines.append("  (more in between)")
      lines.append("  Last messages:")
      lines += messages.suffix(messagesPerEnd).map(describe)
    }
    return lines.joined(separator: "\n")
  }

  private static func describe(_ message: Message) -> String {
    "    \(message.fromPerson ? "Them" : "Agent"): \(shortened(message.text))"
  }

  // MARK: - Claude Code

  private struct ClaudeSessionFile: Decodable {
    let sessionId: String
    let title: String?
    let cwd: String?
    let lastActivityAt: Double?
    let cliSessionId: String?
  }

  private static func claudeThreads(since cutoff: Date) -> [Thread] {
    let transcripts = claudeTranscriptsByID()
    return files(in: claudeSessionsFolder).compactMap { url -> Thread? in
      // The file is rewritten on every turn, so an old file means an old thread; this skips
      // reading the many large session files that can't qualify.
      guard url.lastPathComponent.hasPrefix("local_"), url.pathExtension == "json",
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate,
        modified >= cutoff,
        let data = try? Data(contentsOf: url),
        let session = try? JSONDecoder().decode(ClaudeSessionFile.self, from: data),
        let millis = session.lastActivityAt
      else { return nil }
      let lastActive = Date(timeIntervalSince1970: millis / 1000)
      guard lastActive >= cutoff else { return nil }
      let transcript = session.cliSessionId.flatMap { transcripts[$0] }
      return Thread(
        app: "Claude Code", id: session.sessionId, title: clean(session.title), folder: session.cwd,
        lastActive: lastActive, transcript: transcript)
    }
  }

  /// Every Claude Code transcript, by its file name (the CLI session id).
  private static func claudeTranscriptsByID() -> [String: URL] {
    var result: [String: URL] = [:]
    let projects =
      (try? FileManager.default.contentsOfDirectory(
        at: claudeProjectsFolder, includingPropertiesForKeys: nil)) ?? []
    for project in projects {
      let files =
        (try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil))
        ?? []
      for file in files where file.pathExtension == "jsonl" {
        result[file.deletingPathExtension().lastPathComponent] = file
      }
    }
    return result
  }

  /// The person's and the agent's written messages, skipping tool calls, tool results,
  /// and the system text Claude Code adds (it starts with "<").
  private static func claudeMessages(_ lines: [[String: Any]]) -> [Message] {
    lines.compactMap { line -> Message? in
      guard let role = line["type"] as? String, role == "user" || role == "assistant",
        line["isMeta"] as? Bool != true,
        let body = line["message"] as? [String: Any]
      else { return nil }
      let text: String
      if let string = body["content"] as? String {
        text = string
      } else if let blocks = body["content"] as? [[String: Any]] {
        text = blocks.filter { $0["type"] as? String == "text" }
          .compactMap { $0["text"] as? String }
          .joined(separator: " ")
      } else {
        return nil
      }
      return message(text, fromPerson: role == "user")
    }
  }

  // MARK: - Codex

  private static func codexThreads(since cutoff: Date) -> [Thread] {
    let titles = codexTitles()
    return files(in: codexSessionsFolder).compactMap { url -> Thread? in
      guard url.pathExtension == "jsonl",
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate,
        modified >= cutoff
      else { return nil }
      guard let meta = firstJSONLine(url), meta["type"] as? String == "session_meta",
        let payload = meta["payload"] as? [String: Any],
        let id = payload["id"] as? String,
        // A plain string source is a thread someone works in; "exec" is a script run, and
        // a subagent's source is a dictionary.
        let source = payload["source"] as? String, source != "exec"
      else { return nil }
      return Thread(
        app: "Codex", id: id, title: titles[id], folder: payload["cwd"] as? String,
        lastActive: modified, transcript: url)
    }
  }

  /// Thread names by id. Later lines win, since a thread can be renamed.
  private static func codexTitles() -> [String: String] {
    var result: [String: String] = [:]
    for line in jsonLines(codexTitlesFile) {
      if let id = line["id"] as? String, let name = clean(line["thread_name"] as? String) {
        result[id] = name
      }
    }
    return result
  }

  /// The person's and the agent's messages, skipping the setup text Codex adds (instructions
  /// files and environment notes).
  private static func codexMessages(_ lines: [[String: Any]]) -> [Message] {
    lines.compactMap { line -> Message? in
      guard line["type"] as? String == "response_item",
        let payload = line["payload"] as? [String: Any],
        payload["type"] as? String == "message",
        let role = payload["role"] as? String, role == "user" || role == "assistant",
        let blocks = payload["content"] as? [[String: Any]]
      else { return nil }
      let text = blocks.compactMap { $0["text"] as? String }.joined(separator: " ")
      if text.hasPrefix("# AGENTS.md") { return nil }
      return message(text, fromPerson: role == "user")
    }
  }

  // MARK: - Helpers

  /// A message worth showing, or nil for empty text and text the app added itself.
  private static func message(_ text: String, fromPerson: Bool) -> Message? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("<"),
      // Claude Code's summary when a long thread runs out of context.
      !trimmed.hasPrefix("This session is being continued from a previous conversation")
    else { return nil }
    return Message(fromPerson: fromPerson, text: trimmed)
  }

  /// One line, cut to a readable length.
  private static func shortened(_ text: String) -> String {
    let oneLine = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard oneLine.count > maxMessageCharacters else { return oneLine }
    return String(oneLine.prefix(maxMessageCharacters)) + "…"
  }

  private static func clean(_ text: String?) -> String? {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
      return nil
    }
    return text
  }

  /// Every file under a folder, or none when it doesn't exist.
  private static func files(in folder: URL) -> [URL] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles])
    else { return [] }
    return enumerator.compactMap { $0 as? URL }
  }

  private static let sliceBytes = 2 * 1024 * 1024

  /// A transcript's lines, whole when it's small, or as its first and last couple of
  /// megabytes when it's large (tail is nil when the file was read whole).
  private static func slices(of url: URL) -> (head: [[String: Any]], tail: [[String: Any]]?) {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], nil) }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    try? handle.seek(toOffset: 0)
    guard size > UInt64(sliceBytes * 2) else {
      return (jsonLines(handle.readDataToEndOfFile()), nil)
    }
    let head = (try? handle.read(upToCount: sliceBytes)) ?? Data()
    try? handle.seek(toOffset: size - UInt64(sliceBytes))
    let tail = handle.readDataToEndOfFile()
    // Each slice cuts a line in half at its edge; that line doesn't parse and is skipped.
    return (jsonLines(head), jsonLines(tail))
  }

  /// Each line of a JSON Lines file as a dictionary. Lines that don't parse are skipped.
  private static func jsonLines(_ url: URL) -> [[String: Any]] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    return jsonLines(data)
  }

  private static func jsonLines(_ data: Data) -> [[String: Any]] {
    let text = String(decoding: data, as: UTF8.self)
    return text.split(separator: "\n").compactMap { line -> [String: Any]? in
      // Transcripts are mostly tool calls and results; skip parsing lines that can't be a
      // message or a thread's header.
      guard
        line.contains("\"message\"") || line.contains("session_meta")
          || line.contains("thread_name"),
        let data = line.data(using: .utf8)
      else { return nil }
      return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
  }

  /// The first line of a JSON Lines file, read without loading the rest.
  private static func firstJSONLine(_ url: URL) -> [String: Any]? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var data = Data()
    while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
      if let newline = chunk.firstIndex(of: UInt8(ascii: "\n")) {
        data.append(chunk[chunk.startIndex..<newline])
        break
      }
      data.append(chunk)
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  private static func timestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
  }
}
