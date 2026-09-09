import AppKit
import Darwin
import Foundation

// MARK: - Config Manager

struct ChatCLIConfigManager {
  static let shared = ChatCLIConfigManager()

  let workingDirectory: URL

  init() {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first!
    workingDirectory = appSupport.appendingPathComponent("Dayflow/chatcli", isDirectory: true)
  }

  func ensureWorkingDirectory() {
    let fm = FileManager.default
    if !fm.fileExists(atPath: workingDirectory.path) {
      try? fm.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    }
  }
}

// MARK: - JSONL Event Types

/// Codex `--json` event format
struct CodexJSONLEvent: Decodable {
  let type: String
  let thread_id: String?
  let item: CodexItem?

  struct CodexItem: Decodable {
    let type: String
    let text: String?
    let command: String?
    let status: String?
    let aggregated_output: String?
    let exit_code: Int?
  }
}

/// Claude `--output-format stream-json` event format
struct ClaudeJSONLEvent: Decodable {
  let type: String
  let session_id: String?
  let event: ClaudeEvent?
  let result: String?

  struct ClaudeEvent: Decodable {
    let type: String
    let delta: ClaudeDelta?
  }

  struct ClaudeDelta: Decodable {
    let type: String?
    let text: String?
    let thinking: String?
  }
}
