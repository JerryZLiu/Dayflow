import Foundation

struct CodexMCPRegistration: @unchecked Sendable {
  struct CommandResult: Equatable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
  }

  enum Status: Equatable {
    case notInstalled
    case available
    case disabled
    case stale
    case connected
    case conflict(String)
    case failed(String)
  }

  enum MutationResult: Equatable {
    case notInstalled
    case connected
    case disconnected
    case failed(String)
  }

  typealias ExecutableResolver = () -> URL?
  typealias CommandRunner = (URL, [String]) -> CommandResult

  private struct ServerConfiguration: Decodable {
    struct Transport: Decodable {
      let type: String
      let command: String?
      let args: [String]?
    }

    let enabled: Bool?
    let transport: Transport
  }

  let cliPath: String
  private let resolveExecutable: ExecutableResolver
  private let runCommand: CommandRunner

  init(
    cliPath: String,
    resolveExecutable: @escaping ExecutableResolver = {
      CodexExecutableResolver.shared.resolve()?.executableURL
    },
    runCommand: @escaping CommandRunner = CodexMCPCommandRunner.run
  ) {
    self.cliPath = cliPath
    self.resolveExecutable = resolveExecutable
    self.runCommand = runCommand
  }

  func status() -> Status {
    guard let executableURL = resolveExecutable() else { return .notInstalled }
    return status(using: executableURL)
  }

  func connect() -> MutationResult {
    guard let executableURL = resolveExecutable() else { return .notInstalled }

    switch status(using: executableURL) {
    case .connected:
      return .connected
    case .available, .disabled, .stale:
      break
    case .conflict(let message), .failed(let message):
      return .failed(message)
    case .notInstalled:
      return .notInstalled
    }

    let result = runCommand(
      executableURL,
      ["mcp", "add", "dayflow", "--", cliPath, "mcp"]
    )
    guard result.exitCode == 0 else {
      return .failed(commandFailureMessage(action: "connect", result: result))
    }

    guard status(using: executableURL) == .connected else {
      return .failed("Codex updated its configuration, but Dayflow couldn't verify the connection.")
    }
    return .connected
  }

  func disconnect() -> MutationResult {
    guard let executableURL = resolveExecutable() else { return .notInstalled }

    switch status(using: executableURL) {
    case .available:
      return .disconnected
    case .conflict(let message):
      return .failed(message)
    case .failed(let message):
      return .failed(message)
    case .notInstalled:
      return .notInstalled
    case .connected, .disabled, .stale:
      break
    }

    let result = runCommand(executableURL, ["mcp", "remove", "dayflow"])
    guard result.exitCode == 0 else {
      return .failed(commandFailureMessage(action: "disconnect", result: result))
    }

    guard status(using: executableURL) == .available else {
      return .failed("Codex removed the connection, but Dayflow couldn't verify the change.")
    }
    return .disconnected
  }

  func repairStaleRegistration() {
    guard let executableURL = resolveExecutable(), status(using: executableURL) == .stale else {
      return
    }

    let result = runCommand(
      executableURL,
      ["mcp", "add", "dayflow", "--", cliPath, "mcp"]
    )
    if result.exitCode == 0, status(using: executableURL) == .connected {
      print("AgentAccess: repaired stale Dayflow path in Codex")
    }
  }

  private func status(using executableURL: URL) -> Status {
    let result = runCommand(executableURL, ["mcp", "get", "dayflow", "--json"])
    guard result.exitCode == 0 else {
      if isMissingServerResult(result) {
        return .available
      }
      return .failed(commandFailureMessage(action: "check", result: result))
    }

    guard let data = result.stdout.data(using: .utf8),
      let configuration = try? JSONDecoder().decode(ServerConfiguration.self, from: data)
    else {
      return .failed("Codex returned an unreadable Dayflow MCP configuration.")
    }

    let transport = configuration.transport
    guard transport.type == "stdio", let command = transport.command else {
      return .conflict(conflictingRegistrationMessage)
    }

    let args = transport.args ?? []
    let isCurrentRegistration =
      standardizedPath(command) == standardizedPath(cliPath) && args == ["mcp"]
    let isRecognizableRegistration = isBundledDayflowHelper(command: command, args: args)
    if isCurrentRegistration || isRecognizableRegistration {
      if configuration.enabled == false {
        return .disabled
      }
      return isCurrentRegistration ? .connected : .stale
    }
    return .conflict(conflictingRegistrationMessage)
  }

  private func isMissingServerResult(_ result: CommandResult) -> Bool {
    let output = (result.stdout + "\n" + result.stderr).lowercased()
    return output.contains("dayflow")
      && (output.contains("no mcp server") || output.contains("not found"))
  }

  private func isBundledDayflowHelper(command: String, args: [String]) -> Bool {
    guard args == ["mcp"] else { return false }

    let commandURL = URL(fileURLWithPath: command).standardizedFileURL
    let helpersURL = commandURL.deletingLastPathComponent()
    let contentsURL = helpersURL.deletingLastPathComponent()
    let appURL = contentsURL.deletingLastPathComponent()
    return commandURL.lastPathComponent == "dayflow"
      && helpersURL.lastPathComponent == "Helpers"
      && contentsURL.lastPathComponent == "Contents"
      && appURL.pathExtension == "app"
      && appURL.deletingPathExtension().lastPathComponent == "Dayflow"
  }

  private func standardizedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }

  private func commandFailureMessage(action: String, result: CommandResult) -> String {
    let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let detail = stderr.isEmpty ? stdout : stderr
    if detail.isEmpty {
      return "Codex couldn't \(action) the Dayflow connection."
    }
    return "Codex couldn't \(action) the Dayflow connection: \(detail)"
  }

  private var conflictingRegistrationMessage: String {
    "Codex already has a custom MCP server named dayflow. Dayflow left it unchanged."
  }
}

private enum CodexMCPCommandRunner {
  private static let readChunkSize = 64 * 1024
  private static let timeout: TimeInterval = 10

  private final class PipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private let queue: DispatchQueue
    private let stateQueue: DispatchQueue
    private let group = DispatchGroup()
    private var data = Data()

    init(handle: FileHandle, label: String) {
      self.handle = handle
      queue = DispatchQueue(label: label, qos: .utility)
      stateQueue = DispatchQueue(label: label + ".state")
    }

    func start() {
      group.enter()
      queue.async {
        defer { self.group.leave() }
        while true {
          do {
            guard
              let chunk = try self.handle.read(
                upToCount: CodexMCPCommandRunner.readChunkSize
              ),
              !chunk.isEmpty
            else { break }
            self.stateQueue.sync {
              self.data.append(chunk)
            }
          } catch {
            break
          }
        }
      }
    }

    func wait(timeout: DispatchTime = .distantFuture) {
      _ = group.wait(timeout: timeout)
    }

    func snapshotString() -> String {
      let snapshot = stateQueue.sync { data }
      return String(data: snapshot, encoding: .utf8) ?? ""
    }
  }

  static func run(executableURL: URL, arguments: [String]) -> CodexMCPRegistration.CommandResult {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
      try process.run()
    } catch {
      return .init(stdout: "", stderr: error.localizedDescription, exitCode: -1)
    }

    let stdoutReader = PipeReader(
      handle: stdoutPipe.fileHandleForReading,
      label: "AgentAccess.CodexMCP.stdout"
    )
    let stderrReader = PipeReader(
      handle: stderrPipe.fileHandleForReading,
      label: "AgentAccess.CodexMCP.stderr"
    )
    stdoutReader.start()
    stderrReader.start()

    let processFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
      process.waitUntilExit()
      processFinished.signal()
    }

    if processFinished.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      _ = processFinished.wait(timeout: .now() + 2)
      stdoutReader.wait(timeout: .now() + 2)
      stderrReader.wait(timeout: .now() + 2)
      let stdout = stdoutReader.snapshotString()
      let stderr = stderrReader.snapshotString()
      return .init(
        stdout: stdout,
        stderr: stderr.isEmpty ? "Codex command timed out." : stderr,
        exitCode: -2
      )
    }

    stdoutReader.wait()
    stderrReader.wait()
    return .init(
      stdout: stdoutReader.snapshotString(),
      stderr: stderrReader.snapshotString(),
      exitCode: process.terminationStatus
    )
  }
}
