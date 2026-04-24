import AppKit
import Darwin
import Foundation

// MARK: - Process Runner

struct ChatCLIProcessRunner {
  enum Constants {
    static let readChunkSize = 64 * 1024
    static let timeoutSeconds: TimeInterval = 300
    static let codexFallbackDirectoryPrefix = "Dayflow-codex-home-"
  }

  struct CodexFallbackContext {
    let environment: [String: String]
    let brokenConfigURL: URL
    let didCopyAuth: Bool
    let cleanup: () -> Void
  }

  final class BufferedPipeReader {
    let handle: FileHandle
    let queue: DispatchQueue
    let stateQueue: DispatchQueue
    let group = DispatchGroup()
    var buffer = Data()

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
          let chunk: Data
          do {
            guard let data = try self.handle.read(upToCount: Constants.readChunkSize), !data.isEmpty
            else { break }
            chunk = data
          } catch {
            break
          }

          self.stateQueue.sync {
            self.buffer.append(chunk)
          }
        }
      }
    }

    func wait(timeout: DispatchTime = .distantFuture) -> DispatchTimeoutResult {
      group.wait(timeout: timeout)
    }

    func snapshotData() -> Data {
      stateQueue.sync { buffer }
    }

    func snapshotString() -> String {
      String(data: snapshotData(), encoding: .utf8) ?? ""
    }
  }

  struct PseudoTerminal {
    let master: FileHandle
    let slaveFd: Int32
  }

  func makePseudoTerminal() throws -> PseudoTerminal {
    var master: Int32 = 0
    var slave: Int32 = 0
    // Claude Code 2.x's native TUI (alacritty_terminal) panics with
    // "index out of bounds: len is 0" when the PTY has a 0x0 grid.
    // Initialize with a standard 80x24 winsize so the child sees a sized terminal.
    var winSize = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    let result = openpty(&master, &slave, nil, nil, &winSize)
    guard result == 0 else {
      throw NSError(
        domain: "ChatCLI", code: -50,
        userInfo: [
          NSLocalizedDescriptionKey: "Failed to allocate pseudo-terminal for Claude streaming."
        ])
    }
    let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
    return PseudoTerminal(master: masterHandle, slaveFd: slave)
  }

  func makeShellProcess(shellCommand: String, environment: [String: String] = [:])
    -> Process
  {
    let process = Process()
    process.executableURL = LoginShellRunner.userLoginShell
    process.arguments = ["-l", "-i", "-c", shellCommand]
    if !environment.isEmpty {
      var mergedEnvironment = ProcessInfo.processInfo.environment
      for (key, value) in environment {
        mergedEnvironment[key] = value
      }
      process.environment = mergedEnvironment
    }
    return process
  }

  func invalidTransportConfigURL(from stderr: String) -> URL? {
    let pattern = #"Error:\s+(.+?):\d+:\d+:\s+invalid transport"#
    guard
      let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
      let match = regex.firstMatch(
        in: stderr, options: [], range: NSRange(stderr.startIndex..., in: stderr)),
      match.numberOfRanges >= 2,
      let range = Range(match.range(at: 1), in: stderr)
    else {
      return nil
    }

    return URL(fileURLWithPath: String(stderr[range])).standardizedFileURL
  }

  func isProjectScopedCodexConfig(_ configURL: URL, workingDirectory: URL) -> Bool {
    let targetPath = configURL.standardizedFileURL.path
    var currentDirectory = workingDirectory.standardizedFileURL

    while true {
      let candidatePath =
        currentDirectory
        .appendingPathComponent(".codex", isDirectory: true)
        .appendingPathComponent("config.toml")
        .standardizedFileURL
        .path
      if candidatePath == targetPath {
        return true
      }

      let parent = currentDirectory.deletingLastPathComponent().standardizedFileURL
      if parent.path == currentDirectory.path {
        break
      }
      currentDirectory = parent
    }

    return false
  }

  func makeCodexFallbackContext(
    fromInvalidTransportStderr stderr: String,
    workingDirectory: URL
  ) -> CodexFallbackContext? {
    guard let brokenConfigURL = invalidTransportConfigURL(from: stderr) else {
      return nil
    }
    guard !isProjectScopedCodexConfig(brokenConfigURL, workingDirectory: workingDirectory) else {
      return nil
    }

    let fileManager = FileManager.default
    let tempCodexHome = fileManager.temporaryDirectory
      .appendingPathComponent(
        Constants.codexFallbackDirectoryPrefix + UUID().uuidString, isDirectory: true)

    do {
      try fileManager.createDirectory(at: tempCodexHome, withIntermediateDirectories: true)
    } catch {
      print("[ChatCLI] Failed to create temporary CODEX_HOME: \(error.localizedDescription)")
      return nil
    }

    var didCopyAuth = false
    let sourceAuthURL = brokenConfigURL.deletingLastPathComponent().appendingPathComponent(
      "auth.json")
    let destinationAuthURL = tempCodexHome.appendingPathComponent("auth.json")
    if fileManager.fileExists(atPath: sourceAuthURL.path) {
      do {
        try fileManager.copyItem(at: sourceAuthURL, to: destinationAuthURL)
        didCopyAuth = true
      } catch {
        print(
          "[ChatCLI] Failed to copy Codex auth cache for fallback: \(error.localizedDescription)")
      }
    }

    return CodexFallbackContext(
      environment: ["CODEX_HOME": tempCodexHome.path],
      brokenConfigURL: brokenConfigURL,
      didCopyAuth: didCopyAuth,
      cleanup: {
        try? fileManager.removeItem(at: tempCodexHome)
      }
    )
  }

  func codexFallbackContextIfNeeded(
    tool: ChatCLITool,
    stderr: String,
    workingDirectory: URL,
    hasRetriedInvalidTransport: Bool
  ) -> CodexFallbackContext? {
    guard tool == .codex, !hasRetriedInvalidTransport, stderr.contains("invalid transport") else {
      return nil
    }
    return makeCodexFallbackContext(
      fromInvalidTransportStderr: stderr,
      workingDirectory: workingDirectory
    )
  }

  /// Run a streaming command, yielding events as JSONL lines arrive
  func runStreaming(
    tool: ChatCLITool,
    prompt: String,
    workingDirectory: URL,
    model: String? = nil,
    reasoningEffort: String? = nil,
    sessionId: String? = nil
  ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      Task.detached {
        do {
          try await self.executeStreaming(
            tool: tool,
            prompt: prompt,
            workingDirectory: workingDirectory,
            model: model,
            reasoningEffort: reasoningEffort,
            sessionId: sessionId,
            continuation: continuation
          )
        } catch {
          continuation.yield(.error(error.localizedDescription))
          continuation.finish(throwing: error)
        }
      }
    }
  }

  func executeStreaming(
    tool: ChatCLITool,
    prompt: String,
    workingDirectory: URL,
    model: String?,
    reasoningEffort: String?,
    sessionId: String?,
    continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation,
    processEnvironment: [String: String] = [:],
    hasRetriedInvalidTransport: Bool = false
  ) async throws {
    let toolName = tool.rawValue
    let _ = sessionId != nil  // isResume - unused but kept for clarity

    var cmdParts: [String] = [toolName]
    switch tool {
    case .codex:
      if let sessionId = sessionId {
        cmdParts.append(contentsOf: [
          "exec", "resume", sessionId, "--skip-git-repo-check", "--json",
        ])
      } else {
        cmdParts.append(contentsOf: ["exec", "--skip-git-repo-check", "--json"])
      }
      if let model = model { cmdParts.append(contentsOf: ["-m", model]) }
      if let effort = reasoningEffort {
        cmdParts.append(contentsOf: ["-c", "model_reasoning_effort=\(effort)"])
      }
      let mcpServers = LoginShellRunner.getCodexMCPServerNames()
      for serverName in mcpServers {
        cmdParts.append(contentsOf: ["--config", "mcp_servers.\(serverName).enabled=false"])
      }
      cmdParts.append(contentsOf: ["-c", "rmcp_client=false", "-c", "web_search=disabled"])
      cmdParts.append("--")
      cmdParts.append(LoginShellRunner.shellEscape(prompt))

    case .claude:
      cmdParts.append("-p")
      cmdParts.append(contentsOf: ["--output-format", "stream-json"])
      cmdParts.append("--verbose")
      cmdParts.append("--include-partial-messages")
      if let sessionId = sessionId {
        cmdParts.append(contentsOf: ["--resume", sessionId])
      }
      if let model = model { cmdParts.append(contentsOf: ["--model", model]) }
      cmdParts.append("--dangerously-skip-permissions")
      cmdParts.append("--strict-mcp-config")
      cmdParts.append("--")
      cmdParts.append(LoginShellRunner.shellEscape(prompt))
    }

    let shellCommand =
      "cd \(LoginShellRunner.shellEscape(workingDirectory.path)) && exec \(cmdParts.joined(separator: " "))"

    let process = makeShellProcess(shellCommand: shellCommand, environment: processEnvironment)
    var cleanupPty: (() -> Void)?
    let stdoutHandle: FileHandle
    if tool == .claude {
      let pty = try makePseudoTerminal()
      stdoutHandle = pty.master
      let slaveHandle = FileHandle(fileDescriptor: pty.slaveFd, closeOnDealloc: false)
      process.standardInput = slaveHandle
      process.standardOutput = slaveHandle
      cleanupPty = {
        close(pty.slaveFd)
      }
    } else {
      let stdoutPipe = Pipe()
      process.standardOutput = stdoutPipe
      process.standardInput = FileHandle.nullDevice
      stdoutHandle = stdoutPipe.fileHandleForReading
    }

    let stderrPipe = Pipe()
    let stderrHandle = stderrPipe.fileHandleForReading
    process.standardError = stderrPipe

    let stateQueue = DispatchQueue(label: "ChatCLI.StreamState")
    var accumulatedText = ""
    var lineBuffer = Data()
    var stderrBuffer = Data()
    var sawTextDelta = false
    var didYieldComplete = false
    var didYieldEvent = false

    func cleanupStreamingResources() {
      stdoutHandle.readabilityHandler = nil
      stderrHandle.readabilityHandler = nil
      cleanupPty?()
      cleanupPty = nil
    }

    func drainBufferedLines() -> [ChatStreamEvent] {
      var parsedEvents: [ChatStreamEvent] = []

      while let newlineRange = lineBuffer.range(of: Data([0x0A])) {
        let lineData = lineBuffer.subdata(in: 0..<newlineRange.lowerBound)
        lineBuffer.removeSubrange(0...newlineRange.lowerBound)

        guard let rawLine = String(data: lineData, encoding: .utf8) else { continue }
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = stripANSIEscapes(trimmed)
        guard !line.isEmpty else { continue }

        if let event = parseJSONLLine(tool: tool, line: line) {
          var shouldYield = true
          if case .textDelta(let text) = event {
            sawTextDelta = true
            accumulatedText += text
          } else if case .complete(let text) = event {
            if sawTextDelta || didYieldComplete {
              shouldYield = false
            } else {
              didYieldComplete = true
              accumulatedText = text
            }
          }

          if shouldYield {
            parsedEvents.append(event)
          }
        }
      }

      return parsedEvents
    }

    stdoutHandle.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        return
      }

      let parsedEvents = stateQueue.sync { () -> [ChatStreamEvent] in
        lineBuffer.append(data)
        return drainBufferedLines()
      }

      for event in parsedEvents {
        stateQueue.sync {
          didYieldEvent = true
        }
        continuation.yield(event)
      }
    }

    stderrHandle.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        return
      }

      stateQueue.sync {
        stderrBuffer.append(data)
      }
    }

    try process.run()
    defer {
      cleanupStreamingResources()
    }

    let timeoutSeconds = Constants.timeoutSeconds
    let semaphore = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      process.waitUntilExit()
      semaphore.signal()
    }
    let result = semaphore.wait(timeout: .now() + timeoutSeconds)
    if result == .timedOut {
      process.terminate()
      cleanupStreamingResources()
      // Capture partial streaming output before throwing
      let partial = stateQueue.sync {
        (
          accumulatedText,
          String(data: lineBuffer, encoding: .utf8) ?? "",
          String(data: stderrBuffer, encoding: .utf8) ?? ""
        )
      }
      throw NSError(
        domain: "ChatCLI", code: -3,
        userInfo: [
          NSLocalizedDescriptionKey: "CLI process timed out after \(Int(timeoutSeconds)) seconds",
          "partialStdout": partial.0.isEmpty ? partial.1 : partial.0,
          "partialStderr": partial.2,
        ])
    }

    cleanupStreamingResources()
    let finalEvents = stateQueue.sync { () -> [ChatStreamEvent] in
      var parsedEvents = drainBufferedLines()
      let remainingStdout = stdoutHandle.readDataToEndOfFile()
      let remainingStderr = stderrHandle.readDataToEndOfFile()

      if !remainingStdout.isEmpty {
        lineBuffer.append(remainingStdout)
        parsedEvents.append(contentsOf: drainBufferedLines())
      }
      if !remainingStderr.isEmpty {
        stderrBuffer.append(remainingStderr)
      }

      if !lineBuffer.isEmpty,
        let rawLine = String(data: lineBuffer, encoding: .utf8)
      {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = stripANSIEscapes(trimmed)
        if !line.isEmpty, let event = parseJSONLLine(tool: tool, line: line) {
          var shouldYield = true
          if case .textDelta(let text) = event {
            sawTextDelta = true
            accumulatedText += text
          } else if case .complete(let text) = event {
            if sawTextDelta || didYieldComplete {
              shouldYield = false
            } else {
              didYieldComplete = true
              accumulatedText = text
            }
          }
          if shouldYield {
            parsedEvents.append(event)
          }
        }
        lineBuffer.removeAll(keepingCapacity: false)
      }

      return parsedEvents
    }

    let finalState = stateQueue.sync {
      (
        accumulatedText,
        didYieldComplete,
        String(data: stderrBuffer, encoding: .utf8) ?? ""
      )
    }

    let hadYieldedEvent = stateQueue.sync { didYieldEvent }

    if process.terminationStatus != 0,
      !hadYieldedEvent,
      let fallback = codexFallbackContextIfNeeded(
        tool: tool,
        stderr: finalState.2,
        workingDirectory: workingDirectory,
        hasRetriedInvalidTransport: hasRetriedInvalidTransport)
    {
      print(
        "[ChatCLI] Retrying Codex with temporary CODEX_HOME after invalid transport in \(fallback.brokenConfigURL.path)"
          + (fallback.didCopyAuth ? " (copied auth.json)" : "")
      )
      defer { fallback.cleanup() }
      try await executeStreaming(
        tool: tool,
        prompt: prompt,
        workingDirectory: workingDirectory,
        model: model,
        reasoningEffort: reasoningEffort,
        sessionId: sessionId,
        continuation: continuation,
        processEnvironment: fallback.environment,
        hasRetriedInvalidTransport: true
      )
      return
    }

    for event in finalEvents {
      stateQueue.sync {
        didYieldEvent = true
      }
      continuation.yield(event)
    }

    if process.terminationStatus != 0 {
      let stderr = finalState.2
      if stderr.contains("command not found") {
        continuation.yield(
          .error(
            "\(toolName) CLI not found. Please install it and run '\(tool == .codex ? "codex auth" : "claude login")' in Terminal."
          ))
      } else if !stderr.isEmpty {
        continuation.yield(.error(stderr))
      }
    }

    if !finalState.0.isEmpty, !finalState.1 {
      continuation.yield(.complete(text: finalState.0))
    }

    continuation.finish()
  }

  func parseJSONLLine(tool: ChatCLITool, line: String) -> ChatStreamEvent? {
    guard let data = line.data(using: .utf8) else { return nil }

    switch tool {
    case .codex:
      return parseCodexEvent(data)
    case .claude:
      return parseClaudeEvent(data)
    }
  }

  func parseCodexEvent(_ data: Data) -> ChatStreamEvent? {
    guard let event = try? JSONDecoder().decode(CodexJSONLEvent.self, from: data) else {
      return nil
    }

    if event.type == "thread.started", let threadId = event.thread_id {
      return .sessionStarted(id: threadId)
    }

    guard let item = event.item else { return nil }

    switch item.type {
    case "reasoning":
      if let text = item.text, !text.isEmpty {
        return .thinking(text)
      }

    case "command_execution":
      if event.type == "item.started", let command = item.command {
        return .toolStart(command: command)
      } else if event.type == "item.completed" {
        let output = item.aggregated_output ?? ""
        return .toolEnd(output: output, exitCode: item.exit_code)
      }

    case "agent_message":
      if let text = item.text, !text.isEmpty {
        return .textDelta(text)
      }

    default:
      break
    }

    return nil
  }

  func parseClaudeEvent(_ data: Data) -> ChatStreamEvent? {
    guard let event = try? JSONDecoder().decode(ClaudeJSONLEvent.self, from: data) else {
      return nil
    }

    if event.type == "system", let sessionId = event.session_id {
      return .sessionStarted(id: sessionId)
    }

    if event.type == "stream_event", let streamEvent = event.event {
      if streamEvent.type == "content_block_delta", let delta = streamEvent.delta {
        if delta.type == "thinking_delta", let thinking = delta.thinking, !thinking.isEmpty {
          return .thinking(thinking)
        }
        if delta.type == "text_delta", let text = delta.text, !text.isEmpty {
          return .textDelta(text)
        }
      }
    }

    if event.type == "result", let result = event.result, !result.isEmpty {
      return .complete(text: result)
    }

    return nil
  }

  func stripANSIEscapes(_ input: String) -> String {
    var output = ""
    var index = input.startIndex
    while index < input.endIndex {
      let ch = input[index]
      if ch == "\u{1B}" {
        var cursor = input.index(after: index)
        if cursor < input.endIndex, input[cursor] == "[" {
          cursor = input.index(after: cursor)
          while cursor < input.endIndex {
            let scalar = input[cursor].unicodeScalars.first
            if let scalar, scalar.value >= 0x40 && scalar.value <= 0x7E {
              cursor = input.index(after: cursor)
              break
            }
            cursor = input.index(after: cursor)
          }
          index = cursor
          continue
        }
      }
      output.append(ch)
      index = input.index(after: index)
    }
    return output
  }

  func buildClaudeCommandParts(
    prompt: String,
    imagePaths: [String],
    model: String?,
    disableTools: Bool
  ) -> [String] {
    var cmdParts: [String] = ["claude", "-p"]
    if let model = model {
      cmdParts.append(contentsOf: ["--model", model])
    }
    if disableTools {
      cmdParts.append("--allowedTools")
      cmdParts.append(LoginShellRunner.shellEscape("[]"))
    } else {
      cmdParts.append("--dangerously-skip-permissions")
    }
    cmdParts.append("--strict-mcp-config")
    cmdParts.append("--")
    cmdParts.append(
      LoginShellRunner.shellEscape(promptWithImageHints(prompt: prompt, imagePaths: imagePaths)))
    return cmdParts
  }

  func parseAssistant(tool: ChatCLITool, raw: String) -> (text: String, usage: TokenUsage?) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

    if tool == .codex {
      if let codexRange = trimmed.range(of: "\ncodex\n", options: .backwards) {
        var response = String(trimmed[codexRange.upperBound...])
        if let tokensRange = response.range(of: "\ntokens used", options: .caseInsensitive) {
          response = String(response[..<tokensRange.lowerBound])
        }
        return (response.trimmingCharacters(in: .whitespacesAndNewlines), nil)
      }
    }

    return (trimmed, nil)
  }

  /// Extract thinking blocks from Codex stdout (between "thinking\n" markers)
  func parseThinkingFromOutput(_ output: String) -> String? {
    var thinkingParts: [String] = []
    let lines = output.components(separatedBy: .newlines)
    var inThinking = false
    var currentThinking: [String] = []

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed == "thinking" {
        if inThinking && !currentThinking.isEmpty {
          thinkingParts.append(currentThinking.joined(separator: " "))
          currentThinking = []
        }
        inThinking = !inThinking
      } else if inThinking && !trimmed.isEmpty && !trimmed.hasPrefix("exec")
        && !trimmed.hasPrefix("/bin")
      {
        let cleaned = trimmed.replacingOccurrences(of: "**", with: "")
        currentThinking.append(cleaned)
      }
    }

    if !currentThinking.isEmpty {
      thinkingParts.append(currentThinking.joined(separator: " "))
    }

    guard !thinkingParts.isEmpty else { return nil }
    return thinkingParts.joined(separator: " → ")
  }

  func promptWithImageHints(prompt: String, imagePaths: [String]) -> String {
    guard !imagePaths.isEmpty else { return prompt }
    let hints = imagePaths.map { "- " + $0 }.joined(separator: "\n")
    return prompt + "\nImages:\n" + hints
  }

  func run(
    tool: ChatCLITool, prompt: String, workingDirectory: URL, imagePaths: [String] = [],
    model: String? = nil, reasoningEffort: String? = nil, disableTools: Bool = false
  ) throws -> ChatCLIRunResult {
    try run(
      tool: tool,
      prompt: prompt,
      workingDirectory: workingDirectory,
      imagePaths: imagePaths,
      model: model,
      reasoningEffort: reasoningEffort,
      disableTools: disableTools,
      processEnvironment: [:],
      hasRetriedInvalidTransport: false
    )
  }

  func run(
    tool: ChatCLITool,
    prompt: String,
    workingDirectory: URL,
    imagePaths: [String],
    model: String?,
    reasoningEffort: String?,
    disableTools: Bool,
    processEnvironment: [String: String],
    hasRetriedInvalidTransport: Bool
  ) throws -> ChatCLIRunResult {
    let toolName = tool.rawValue

    var cmdParts: [String] = [toolName]
    switch tool {
    case .codex:
      cmdParts.append(contentsOf: ["exec", "--skip-git-repo-check"])
      if let model = model { cmdParts.append(contentsOf: ["-m", model]) }
      if let effort = reasoningEffort {
        cmdParts.append(contentsOf: ["-c", "model_reasoning_effort=\(effort)"])
      }
      let mcpServers = LoginShellRunner.getCodexMCPServerNames()
      for serverName in mcpServers {
        cmdParts.append(contentsOf: ["--config", "mcp_servers.\(serverName).enabled=false"])
      }
      cmdParts.append(contentsOf: ["-c", "rmcp_client=false", "-c", "web_search=disabled"])
      for path in imagePaths {
        cmdParts.append(contentsOf: ["--image", LoginShellRunner.shellEscape(path)])
      }
      cmdParts.append("--")
      cmdParts.append(LoginShellRunner.shellEscape(prompt))
    case .claude:
      cmdParts = buildClaudeCommandParts(
        prompt: prompt,
        imagePaths: imagePaths,
        model: model,
        disableTools: disableTools
      )
    }

    let shellCommand =
      "cd \(LoginShellRunner.shellEscape(workingDirectory.path)) && exec \(cmdParts.joined(separator: " "))"

    let started = Date()
    let process = makeShellProcess(shellCommand: shellCommand, environment: processEnvironment)
    let stdoutPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardInput = FileHandle.nullDevice
    let stdoutHandle = stdoutPipe.fileHandleForReading

    let stderrPipe = Pipe()
    let stderrHandle = stderrPipe.fileHandleForReading
    process.standardError = stderrPipe

    try process.run()

    let stdoutReader = BufferedPipeReader(
      handle: stdoutHandle, label: "ChatCLI.StdoutCollector")
    let stderrReader = BufferedPipeReader(
      handle: stderrHandle, label: "ChatCLI.StderrCollector")
    stdoutReader.start()
    stderrReader.start()

    let timeoutSeconds = Constants.timeoutSeconds
    let semaphore = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      process.waitUntilExit()
      semaphore.signal()
    }
    let result = semaphore.wait(timeout: .now() + timeoutSeconds)
    if result == .timedOut {
      process.terminate()
      _ = stdoutReader.wait(timeout: .now() + 2)
      _ = stderrReader.wait(timeout: .now() + 2)
      let partialStdout = stdoutReader.snapshotString()
      let partialStderr = stderrReader.snapshotString()
      throw NSError(
        domain: "ChatCLI", code: -3,
        userInfo: [
          NSLocalizedDescriptionKey: "CLI process timed out after \(Int(timeoutSeconds)) seconds",
          "partialStdout": partialStdout,
          "partialStderr": partialStderr,
        ])
    }
    let finished = Date()

    _ = stdoutReader.wait()
    _ = stderrReader.wait()
    let stdoutBuffer = stdoutReader.snapshotData()
    let stderrBuffer = stderrReader.snapshotData()

    var rawOut = String(data: stdoutBuffer, encoding: .utf8) ?? ""
    if tool == .claude {
      // Plain pipes are sufficient for Claude non-streaming mode and avoid PTY escape noise.
      rawOut = stripANSIEscapes(rawOut)
    }
    let stderr = String(data: stderrBuffer, encoding: .utf8) ?? ""

    if process.terminationStatus != 0,
      let fallback = codexFallbackContextIfNeeded(
        tool: tool,
        stderr: stderr,
        workingDirectory: workingDirectory,
        hasRetriedInvalidTransport: hasRetriedInvalidTransport)
    {
      print(
        "[ChatCLI] Retrying Codex with temporary CODEX_HOME after invalid transport in \(fallback.brokenConfigURL.path)"
          + (fallback.didCopyAuth ? " (copied auth.json)" : "")
      )
      defer { fallback.cleanup() }
      return try run(
        tool: tool,
        prompt: prompt,
        workingDirectory: workingDirectory,
        imagePaths: imagePaths,
        model: model,
        reasoningEffort: reasoningEffort,
        disableTools: disableTools,
        processEnvironment: fallback.environment,
        hasRetriedInvalidTransport: true
      )
    }

    if process.terminationStatus == 127
      || (process.terminationStatus != 0 && stderr.contains("command not found"))
    {
      throw NSError(
        domain: "ChatCLI", code: -2,
        userInfo: [
          NSLocalizedDescriptionKey:
            "\(toolName) CLI not found. Please install it and run '\(tool == .codex ? "codex auth" : "claude login")' in Terminal."
        ])
    }

    let parsed = parseAssistant(tool: tool, raw: rawOut)
    let duration = finished.timeIntervalSince(started)
    let modelLabel = model ?? "default"
    print("⏱️ [ChatCLI] \(tool.rawValue) \(modelLabel) \(String(format: "%.2f", duration))s")
    return ChatCLIRunResult(
      exitCode: process.terminationStatus, stdout: parsed.text, rawStdout: rawOut, stderr: stderr,
      startedAt: started, finishedAt: finished, usage: parsed.usage)
  }
}
