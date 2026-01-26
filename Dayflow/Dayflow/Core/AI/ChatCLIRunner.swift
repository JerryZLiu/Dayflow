//
//  ChatCLIRunner.swift
//  Dayflow
//
//  Process execution and JSONL parsing for ChatCLI providers.
//  Handles PTY allocation, shell execution, and streaming event parsing.
//

import Foundation
import AppKit
import Darwin

// MARK: - Core Types

enum ChatCLITool: String, Codable {
    case codex
    case claude
}

/// Events emitted during JSONL streaming from CLI tools
enum ChatStreamEvent: Sendable {
    /// Session started with ID (for session persistence)
    case sessionStarted(id: String)
    /// Thinking/reasoning content (shown in collapsible UI)
    case thinking(String)
    /// Tool/command execution started
    case toolStart(command: String)
    /// Tool/command execution completed
    case toolEnd(output: String, exitCode: Int?)
    /// Incremental text chunk from response
    case textDelta(String)
    /// Final complete response
    case complete(text: String)
    /// Error occurred
    case error(String)
}

struct ChatCLIRunResult {
    let exitCode: Int32
    let stdout: String      // Parsed/cleaned response
    let rawStdout: String   // Original stdout for thinking extraction
    let stderr: String
    let startedAt: Date
    let finishedAt: Date
    let usage: TokenUsage?
}

struct TokenUsage: Sendable {
    let input: Int
    let cachedInput: Int
    let output: Int

    static var zero: TokenUsage { TokenUsage(input: 0, cachedInput: 0, output: 0) }

    func adding(_ other: TokenUsage?) -> TokenUsage {
        guard let other else { return self }
        return TokenUsage(input: input + other.input, cachedInput: cachedInput + other.cachedInput, output: output + other.output)
    }
}

// MARK: - Login Shell Runner

struct LoginShellResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

/// Invokes commands via the user's login shell to replicate Terminal.app behavior.
/// This ensures CLIs installed via nvm, homebrew, cargo, etc. are found.
struct LoginShellRunner {

    /// Detects the user's configured login shell (e.g., /bin/bash or /bin/zsh)
    static var userLoginShell: URL {
        if let entry = getpwuid(getuid()),
           let shellPath = String(validatingUTF8: entry.pointee.pw_shell) {
            return URL(fileURLWithPath: shellPath)
        }
        return URL(fileURLWithPath: "/bin/zsh")
    }

    /// Get names of all MCP servers configured in Codex CLI.
    /// Used to generate `--config mcp_servers.<name>.enabled=false` flags.
    static func getCodexMCPServerNames() -> [String] {
        let result = run("codex mcp list --json", timeout: 10)
        guard result.exitCode == 0,
              let data = result.stdout.data(using: .utf8) else {
            return []
        }

        struct MCPServer: Codable {
            let name: String
        }

        guard let servers = try? JSONDecoder().decode([MCPServer].self, from: data) else {
            return []
        }

        return servers.map { $0.name }
    }

    /// Run a command via login shell and wait for completion.
    static func run(
        _ command: String,
        environment: [String: String] = [:],
        timeout: TimeInterval = 30
    ) -> LoginShellResult {
        let envExports = environment.map { key, value in
            "\(key)=\(shellEscape(value))"
        }.joined(separator: " ")

        let fullCommand = envExports.isEmpty ? command : "\(envExports) \(command)"

        let process = Process()
        process.executableURL = userLoginShell
        process.arguments = ["-l", "-i", "-c", fullCommand]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return LoginShellResult(stdout: "", stderr: error.localizedDescription, exitCode: -1)
        }

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            semaphore.signal()
        }

        let result = semaphore.wait(timeout: .now() + timeout)
        if result == .timedOut {
            process.terminate()
            return LoginShellResult(stdout: "", stderr: "Command timed out after \(Int(timeout))s", exitCode: -2)
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        return LoginShellResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }

    /// Check if a CLI tool is installed by running `tool --version`
    static func isInstalled(_ toolName: String) -> Bool {
        let result = run("\(toolName) --version", timeout: 10)
        return result.exitCode == 0
    }

    /// Get version string of a CLI tool, or nil if not installed
    static func version(of toolName: String) -> String? {
        let result = run("\(toolName) --version", timeout: 10)
        guard result.exitCode == 0 else { return nil }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.components(separatedBy: .newlines).first ?? trimmed
    }

    /// Escape a string for safe inclusion in a shell command (single-quote escaping)
    static func shellEscape(_ string: String) -> String {
        let sanitized = string.replacingOccurrences(of: "\0", with: "")
        let escaped = sanitized.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}

// MARK: - Config Manager

struct ChatCLIConfigManager {
    static let shared = ChatCLIConfigManager()

    let workingDirectory: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
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
private struct CodexJSONLEvent: Decodable {
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
private struct ClaudeJSONLEvent: Decodable {
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

// MARK: - Process Runner

struct ChatCLIProcessRunner {
    private struct PseudoTerminal {
        let master: FileHandle
        let slaveFd: Int32
    }

    private func makePseudoTerminal() throws -> PseudoTerminal {
        var master: Int32 = 0
        var slave: Int32 = 0
        let result = openpty(&master, &slave, nil, nil, nil)
        guard result == 0 else {
            throw NSError(domain: "ChatCLI", code: -50, userInfo: [
                NSLocalizedDescriptionKey: "Failed to allocate pseudo-terminal for Claude streaming."
            ])
        }
        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        return PseudoTerminal(master: masterHandle, slaveFd: slave)
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

    private func executeStreaming(
        tool: ChatCLITool,
        prompt: String,
        workingDirectory: URL,
        model: String?,
        reasoningEffort: String?,
        sessionId: String?,
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async throws {
        let toolName = tool.rawValue
        let _ = sessionId != nil  // isResume - unused but kept for clarity

        var cmdParts: [String] = [toolName]
        switch tool {
        case .codex:
            if let sessionId = sessionId {
                cmdParts.append(contentsOf: ["exec", "resume", sessionId, "--skip-git-repo-check", "--json"])
            } else {
                cmdParts.append(contentsOf: ["exec", "--skip-git-repo-check", "--json"])
            }
            if let model = model { cmdParts.append(contentsOf: ["-m", model]) }
            if let effort = reasoningEffort { cmdParts.append(contentsOf: ["-c", "model_reasoning_effort=\(effort)"]) }
            let mcpServers = LoginShellRunner.getCodexMCPServerNames()
            for serverName in mcpServers {
                cmdParts.append(contentsOf: ["--config", "mcp_servers.\(serverName).enabled=false"])
            }
            cmdParts.append(contentsOf: ["-c", "rmcp_client=false", "-c", "features.web_search_request=false"])
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

        let shellCommand = "cd \(LoginShellRunner.shellEscape(workingDirectory.path)) && exec \(cmdParts.joined(separator: " "))"
        let shell = LoginShellRunner.userLoginShell

        let process = Process()
        process.executableURL = shell
        process.arguments = ["-l", "-i", "-c", shellCommand]
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
        process.standardError = stderrPipe

        var accumulatedText = ""
        var lineBuffer = Data()
        var sawTextDelta = false
        var didYieldComplete = false

        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            lineBuffer.append(data)

            while let newlineRange = lineBuffer.range(of: Data([0x0A])) {
                let lineData = lineBuffer.subdata(in: 0..<newlineRange.lowerBound)
                lineBuffer.removeSubrange(0...newlineRange.lowerBound)

                guard let rawLine = String(data: lineData, encoding: .utf8) else { continue }
                let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                let line = self.stripANSIEscapes(trimmed)
                guard !line.isEmpty else { continue }

                if let event = self.parseJSONLLine(tool: tool, line: line) {
                    if case .textDelta(let text) = event {
                        sawTextDelta = true
                        accumulatedText += text
                    } else if case .complete(let text) = event {
                        if sawTextDelta || didYieldComplete {
                            continue
                        }
                        didYieldComplete = true
                        accumulatedText = text
                    }
                    continuation.yield(event)
                }
            }
        }

        try process.run()
        defer {
            stdoutHandle.readabilityHandler = nil
            cleanupPty?()
        }

        let timeoutSeconds: TimeInterval = 150
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            semaphore.signal()
        }
        let result = semaphore.wait(timeout: .now() + timeoutSeconds)
        if result == .timedOut {
            process.terminate()
            throw NSError(domain: "ChatCLI", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "CLI process timed out after \(Int(timeoutSeconds)) seconds"
            ])
        }

        if !lineBuffer.isEmpty,
           let rawLine = String(data: lineBuffer, encoding: .utf8) {
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
                    continuation.yield(event)
                }
            }
        }

        if process.terminationStatus != 0 {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if stderr.contains("command not found") {
                continuation.yield(.error("\(toolName) CLI not found. Please install it and run '\(tool == .codex ? "codex auth" : "claude login")' in Terminal."))
            } else if !stderr.isEmpty {
                continuation.yield(.error(stderr))
            }
        }

        if !accumulatedText.isEmpty, !didYieldComplete {
            continuation.yield(.complete(text: accumulatedText))
        }

        continuation.finish()
    }

    private func parseJSONLLine(tool: ChatCLITool, line: String) -> ChatStreamEvent? {
        guard let data = line.data(using: .utf8) else { return nil }

        switch tool {
        case .codex:
            return parseCodexEvent(data)
        case .claude:
            return parseClaudeEvent(data)
        }
    }

    private func parseCodexEvent(_ data: Data) -> ChatStreamEvent? {
        guard let event = try? JSONDecoder().decode(CodexJSONLEvent.self, from: data) else { return nil }

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

    private func parseClaudeEvent(_ data: Data) -> ChatStreamEvent? {
        guard let event = try? JSONDecoder().decode(ClaudeJSONLEvent.self, from: data) else { return nil }

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

    private func stripANSIEscapes(_ input: String) -> String {
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

    private func parseAssistant(tool: ChatCLITool, raw: String) -> (text: String, usage: TokenUsage?) {
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
            } else if inThinking && !trimmed.isEmpty && !trimmed.hasPrefix("exec") && !trimmed.hasPrefix("/bin") {
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

    private func promptWithImageHints(prompt: String, imagePaths: [String]) -> String {
        guard !imagePaths.isEmpty else { return prompt }
        let hints = imagePaths.map { "- " + $0 }.joined(separator: "\n")
        return prompt + "\nImages:\n" + hints
    }

    func run(tool: ChatCLITool, prompt: String, workingDirectory: URL, imagePaths: [String] = [], model: String? = nil, reasoningEffort: String? = nil, disableTools: Bool = false) throws -> ChatCLIRunResult {
        let toolName = tool.rawValue

        var cmdParts: [String] = [toolName]
        switch tool {
        case .codex:
            cmdParts.append(contentsOf: ["exec", "--skip-git-repo-check"])
            if let model = model { cmdParts.append(contentsOf: ["-m", model]) }
            if let effort = reasoningEffort { cmdParts.append(contentsOf: ["-c", "model_reasoning_effort=\(effort)"]) }
            let mcpServers = LoginShellRunner.getCodexMCPServerNames()
            for serverName in mcpServers {
                cmdParts.append(contentsOf: ["--config", "mcp_servers.\(serverName).enabled=false"])
            }
            cmdParts.append(contentsOf: ["-c", "rmcp_client=false", "-c", "features.web_search_request=false"])
            for path in imagePaths { cmdParts.append(contentsOf: ["--image", LoginShellRunner.shellEscape(path)]) }
            cmdParts.append("--")
            cmdParts.append(LoginShellRunner.shellEscape(prompt))
        case .claude:
            cmdParts.append("-p")
            if let model = model { cmdParts.append(contentsOf: ["--model", model]) }
            if disableTools {
                cmdParts.append("--allowedTools")
                cmdParts.append(LoginShellRunner.shellEscape("[]"))
            } else {
                cmdParts.append("--dangerously-skip-permissions")
            }
            cmdParts.append("--strict-mcp-config")
            cmdParts.append("--")
            cmdParts.append(LoginShellRunner.shellEscape(promptWithImageHints(prompt: prompt, imagePaths: imagePaths)))
        }

        let shellCommand = "cd \(LoginShellRunner.shellEscape(workingDirectory.path)) && exec \(cmdParts.joined(separator: " "))"
        let shell = LoginShellRunner.userLoginShell

        let started = Date()
        let process = Process()
        process.executableURL = shell
        process.arguments = ["-l", "-i", "-c", shellCommand]

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
        process.standardError = stderrPipe

        try process.run()

        let outputQueue = DispatchQueue(label: "ChatCLI.Output")
        var stdoutBuffer = Data()
        var stderrBuffer = Data()

        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            outputQueue.sync {
                stdoutBuffer.append(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            outputQueue.sync {
                stderrBuffer.append(data)
            }
        }

        let timeoutSeconds: TimeInterval = 300
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            semaphore.signal()
        }
        let result = semaphore.wait(timeout: .now() + timeoutSeconds)
        if result == .timedOut {
            process.terminate()
            throw NSError(domain: "ChatCLI", code: -3, userInfo: [NSLocalizedDescriptionKey: "CLI process timed out after \(Int(timeoutSeconds)) seconds"])
        }
        let finished = Date()

        cleanupPty?()
        stdoutHandle.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        outputQueue.sync { }
        let remainingStdout = stdoutHandle.readDataToEndOfFile()
        let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        outputQueue.sync {
            if !remainingStdout.isEmpty {
                stdoutBuffer.append(remainingStdout)
            }
            if !remainingStderr.isEmpty {
                stderrBuffer.append(remainingStderr)
            }
        }

        var rawOut = String(data: stdoutBuffer, encoding: .utf8) ?? ""
        if tool == .claude {
            rawOut = stripANSIEscapes(rawOut)
        }
        let stderr = String(data: stderrBuffer, encoding: .utf8) ?? ""

        if process.terminationStatus == 127 || (process.terminationStatus != 0 && stderr.contains("command not found")) {
            throw NSError(domain: "ChatCLI", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "\(toolName) CLI not found. Please install it and run '\(tool == .codex ? "codex auth" : "claude login")' in Terminal."
            ])
        }

        let parsed = parseAssistant(tool: tool, raw: rawOut)
        let duration = finished.timeIntervalSince(started)
        let modelLabel = model ?? "default"
        print("⏱️ [ChatCLI] \(tool.rawValue) \(modelLabel) \(String(format: "%.2f", duration))s")
        return ChatCLIRunResult(exitCode: process.terminationStatus, stdout: parsed.text, rawStdout: rawOut, stderr: stderr, startedAt: started, finishedAt: finished, usage: parsed.usage)
    }
}
