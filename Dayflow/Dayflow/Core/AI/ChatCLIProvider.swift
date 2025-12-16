//
//  ChatCLIProvider.swift
//  Dayflow
//
//  Runs ChatGPT (Codex CLI) or Claude Code in headless mode.
//  MCP servers are disabled dynamically via CLI flags.
//  Uses the user's default auth from ~/.codex/ or ~/.claude/.
//

import Foundation
import AppKit

enum ChatCLITool: String, Codable {
    case codex
    case claude
}

// MARK: - Login Shell Runner
// Unified utility for invoking CLI commands via the user's login shell.
// This ensures we get the same PATH/environment the user has in Terminal.app.

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

        // Parse JSON array of server objects with "name" field
        struct MCPServer: Codable {
            let name: String
        }

        guard let servers = try? JSONDecoder().decode([MCPServer].self, from: data) else {
            return []
        }

        return servers.map { $0.name }
    }

    /// Run a command via login shell and wait for completion.
    /// - Parameters:
    ///   - command: The command to run (e.g., "claude --version")
    ///   - environment: Additional environment variables to set INSIDE the shell command (immune to .zshrc overrides)
    ///   - timeout: Maximum time to wait (default 30 seconds)
    /// - Returns: The result containing stdout, stderr, and exit code
    static func run(
        _ command: String,
        environment: [String: String] = [:],
        timeout: TimeInterval = 30
    ) -> LoginShellResult {
        // Build env exports that happen AFTER shell init (immune to .zshrc overrides)
        let envExports = environment.map { key, value in
            "\(key)=\(shellEscape(value))"
        }.joined(separator: " ")

        let fullCommand = envExports.isEmpty ? command : "\(envExports) \(command)"

        let process = Process()
        // Dynamically use the user's actual shell (Bash, Zsh, etc.)
        process.executableURL = userLoginShell
        // -l = login shell (sources .bash_profile/.zprofile)
        // -i = interactive (sources .bashrc/.zshrc)
        process.arguments = ["-l", "-i", "-c", fullCommand]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice  // Prevent interactive prompts

        do {
            try process.run()
        } catch {
            return LoginShellResult(stdout: "", stderr: error.localizedDescription, exitCode: -1)
        }

        // Timeout handling
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
        // Remove null bytes that could truncate at C API boundary
        let sanitized = string.replacingOccurrences(of: "\0", with: "")
        // Single-quote escaping: replace ' with '\''
        let escaped = sanitized.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}

private struct ChatCLIConfigManager {
    static let shared = ChatCLIConfigManager()

    /// Working directory for temporary files (e.g., resized images)
    let workingDirectory: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        workingDirectory = appSupport.appendingPathComponent("Dayflow/chatcli", isDirectory: true)
    }

    /// Ensure working directory exists for temp files
    func ensureWorkingDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: workingDirectory.path) {
            try? fm.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        }
    }
}

private struct ChatCLIRunResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let startedAt: Date
    let finishedAt: Date
    let usage: TokenUsage?
}

private struct TokenUsage: Sendable {
    let input: Int
    let cachedInput: Int
    let output: Int

    static var zero: TokenUsage { TokenUsage(input: 0, cachedInput: 0, output: 0) }

    func adding(_ other: TokenUsage?) -> TokenUsage {
        guard let other else { return self }
        return TokenUsage(input: input + other.input, cachedInput: cachedInput + other.cachedInput, output: output + other.output)
    }
}

private struct ChatCLIProcessRunner {

    // Extract final assistant text and usage from CLI JSONL so higher layers can parse domain JSON.
    private func parseAssistant(tool: ChatCLITool, raw: String) -> (text: String, usage: TokenUsage?) {
        // Without CLI JSON envelopes, treat stdout as final message.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed, nil)
    }

    private func promptWithImageHints(prompt: String, imagePaths: [String]) -> String {
        guard !imagePaths.isEmpty else { return prompt }
        let hints = imagePaths.map { "- " + $0 }.joined(separator: "\n")
        return prompt + "\nImages:\n" + hints
    }

    func run(tool: ChatCLITool, prompt: String, workingDirectory: URL, imagePaths: [String] = [], model: String? = nil, reasoningEffort: String? = nil) throws -> ChatCLIRunResult {
        let toolName = tool.rawValue  // "codex" or "claude"

        // Build the command exactly as user would type in Terminal
        var cmdParts: [String] = [toolName]
        switch tool {
        case .codex:
            cmdParts.append(contentsOf: ["exec", "--skip-git-repo-check"])
            if let model = model { cmdParts.append(contentsOf: ["-m", model]) }
            if let effort = reasoningEffort { cmdParts.append(contentsOf: ["-c", "model_reasoning_effort=\(effort)"]) }
            // Disable MCP servers dynamically by detecting all configured servers
            let mcpServers = LoginShellRunner.getCodexMCPServerNames()
            for serverName in mcpServers {
                cmdParts.append(contentsOf: ["--config", "mcp_servers.\(serverName).enabled=false"])
            }
            // Also disable rmcp_client and web search
            cmdParts.append(contentsOf: ["-c", "rmcp_client=false", "-c", "features.web_search_request=false"])
            for path in imagePaths { cmdParts.append(contentsOf: ["--image", LoginShellRunner.shellEscape(path)]) }
            cmdParts.append("--")
            cmdParts.append(LoginShellRunner.shellEscape(prompt))
        case .claude:
            cmdParts.append("-p")
            if let model = model { cmdParts.append(contentsOf: ["--model", model]) }
            cmdParts.append("--dangerously-skip-permissions")
            cmdParts.append("--strict-mcp-config")
            cmdParts.append("--")
            cmdParts.append(LoginShellRunner.shellEscape(promptWithImageHints(prompt: prompt, imagePaths: imagePaths)))
        }

        // Use `exec` to replace shell process (ensures terminate() kills the CLI, not just zsh)
        // No sandbox - use default ~/.codex/ or ~/.claude/ auth
        let shellCommand = "cd \(LoginShellRunner.shellEscape(workingDirectory.path)) && exec \(cmdParts.joined(separator: " "))"

        let shell = LoginShellRunner.userLoginShell
        debugCommand(tool: tool, model: model, shell: shell, shellCommand: shellCommand)

        let started = Date()
        let process = Process()
        // Dynamically use the user's actual shell (Bash, Zsh, etc.)
        process.executableURL = shell
        // -l = login shell (sources .bash_profile/.zprofile)
        // -i = interactive (sources .bashrc/.zshrc)
        process.arguments = ["-l", "-i", "-c", shellCommand]
        process.standardInput = FileHandle.nullDevice  // Prevent interactive prompts

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // 5-minute timeout to prevent indefinite hangs
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

        let rawOut = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        // Check for "command not found" to give user-friendly error
        if process.terminationStatus == 127 || stderr.contains("command not found") {
            throw NSError(domain: "ChatCLI", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "\(toolName) CLI not found. Please install it and run '\(tool == .codex ? "codex auth" : "claude login")' in Terminal."
            ])
        }

        let parsed = parseAssistant(tool: tool, raw: rawOut)
        debugLog(tool: tool, model: model, phase: "run", prompt: prompt, stdout: rawOut, stderr: stderr, usage: parsed.usage)
        return ChatCLIRunResult(exitCode: process.terminationStatus, stdout: parsed.text, stderr: stderr, startedAt: started, finishedAt: finished, usage: parsed.usage)
    }

    private func debugCommand(tool: ChatCLITool, model: String?, shell: URL, shellCommand: String) {
        let header = "[ChatCLI][\(tool.rawValue)][\(model ?? "")] command"
        print("\(header): \(shell.path) -l -i -c '\(shellCommand)'")
    }

    private func debugLog(tool: ChatCLITool, model: String?, phase: String, prompt: String, stdout: String, stderr: String, usage: TokenUsage?) {
        let header = "[ChatCLI][\(tool.rawValue)][\(model ?? "")] \(phase)"
        print("\(header) prompt:\n\(prompt)")
        if !stdout.isEmpty { print("\(header) stdout:\n\(stdout)") }
        if !stderr.isEmpty { print("\(header) stderr:\n\(stderr)") }
        if let u = usage {
            print("\(header) usage in=\(u.input) cached=\(u.cachedInput) out=\(u.output)")
        }
    }
}

private struct ChatCLIObservationsEnvelope: Codable {
    struct Item: Codable {
        let start: String
        let end: String
        let text: String
    }
    let observations: [Item]
}

private struct ChatCLICardsEnvelope: Codable {
    struct Item: Codable {
        let start: String?
        let end: String?
        let startTime: String?
        let endTime: String?
        let category: String
        let subcategory: String
        let title: String
        let summary: String
        let detailedSummary: String?
        let distractions: [Distraction]?
        let appSites: AppSites?

        var normalizedStart: String? { start ?? startTime }
        var normalizedEnd: String? { end ?? endTime }
    }
    let cards: [Item]
}

final class ChatCLIProvider: LLMProvider {
    private let tool: ChatCLITool
    private let runner = ChatCLIProcessRunner()
    private let config = ChatCLIConfigManager.shared
    /// Screenshot interval used for fallback observation duration calculation
    private let screenshotInterval: TimeInterval = 10.0

    init(tool: ChatCLITool) {
        self.tool = tool
        config.ensureWorkingDirectory()
    }

    /// Run the CLI and clean up temp files after.
    private func runAndScrub(prompt: String, imagePaths: [String] = [], model: String? = nil, reasoningEffort: String? = nil) throws -> ChatCLIRunResult {
        // Prepare downsized copies of images (~720p) so Codex input stays compact.
        let (preparedImages, cleanupImages) = try prepareImagesForCLI(imagePaths)
        defer {
            cleanupImages()
        }
        return try runner.run(tool: tool, prompt: prompt, workingDirectory: config.workingDirectory, imagePaths: preparedImages, model: model, reasoningEffort: reasoningEffort)
    }

    /// Create temporary 720p-max copies of images for Codex/Claude CLI.
    /// Returns the new paths and a cleanup closure.
    private func prepareImagesForCLI(_ imagePaths: [String]) throws -> ([String], () -> Void) {
        guard !imagePaths.isEmpty else { return ([], {}) }

        let fm = FileManager.default
        let tmpDir = config.workingDirectory.appendingPathComponent("tmp_images_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        var processed: [String] = []

        func resize(_ src: URL, into dst: URL) throws {
            guard let image = NSImage(contentsOf: src) else {
                throw NSError(domain: "ChatCLI", code: -41, userInfo: [NSLocalizedDescriptionKey: "Failed to load image at \(src.path)"])
            }
            // Determine pixel size from representations (fallback to point size).
            let rep = image.representations.compactMap { $0 as? NSBitmapImageRep }.first ?? image.representations.first
            let pixelsWide = rep?.pixelsWide ?? Int(image.size.width)
            let pixelsHigh = rep?.pixelsHigh ?? Int(image.size.height)

            let maxHeight: Double = 720.0
            if pixelsHigh <= Int(maxHeight) {
                // No resize needed; just copy to temp to keep paths isolated.
                try fm.copyItem(at: src, to: dst)
                return
            }

            let scale = maxHeight / Double(pixelsHigh)
            let targetW = max(2, Int((Double(pixelsWide) * scale).rounded(.toNearestOrAwayFromZero)))
            let targetH = Int(maxHeight)

            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                                pixelsWide: targetW,
                                                pixelsHigh: targetH,
                                                bitsPerSample: 8,
                                                samplesPerPixel: 4,
                                                hasAlpha: true,
                                                isPlanar: false,
                                                colorSpaceName: .calibratedRGB,
                                                bytesPerRow: 0,
                                                bitsPerPixel: 0) else {
                throw NSError(domain: "ChatCLI", code: -42, userInfo: [NSLocalizedDescriptionKey: "Failed to create bitmap for \(src.path)"])
            }

            bitmap.size = NSSize(width: targetW, height: targetH)
            NSGraphicsContext.saveGraphicsState()
            guard let ctx = NSGraphicsContext(bitmapImageRep: bitmap) else {
                throw NSError(domain: "ChatCLI", code: -43, userInfo: [NSLocalizedDescriptionKey: "Failed to create graphics context for \(src.path)"])
            }
            NSGraphicsContext.current = ctx
            image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(targetW), height: CGFloat(targetH)),
                       from: NSRect(origin: .zero, size: image.size),
                       operation: .copy,
                       fraction: 1.0,
                       respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.high])
            ctx.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()

            // Encode as JPEG to keep size small.
            let props: [NSBitmapImageRep.PropertyKey: Any] = [.compressionFactor: 0.85]
            guard let data = bitmap.representation(using: NSBitmapImageRep.FileType.jpeg, properties: props) else {
                throw NSError(domain: "ChatCLI", code: -44, userInfo: [NSLocalizedDescriptionKey: "Failed to encode resized image for \(src.path)"])
            }
            try data.write(to: dst, options: Data.WritingOptions.atomic)
        }

        for (idx, path) in imagePaths.enumerated() {
            let srcURL = URL(fileURLWithPath: path)
            let dstURL = tmpDir.appendingPathComponent(String(format: "%02d.jpg", idx), isDirectory: false)
            try resize(srcURL, into: dstURL)
            processed.append(dstURL.path)
        }

        let cleanup: () -> Void = {
            try? fm.removeItem(at: tmpDir)
        }

        return (processed, cleanup)
    }

    // MARK: - Activity Cards

    func generateActivityCards(observations: [Observation], context: ActivityGenerationContext, batchId: Int64?) async throws -> (cards: [ActivityCardData], log: LLMCall) {
        enum CardParseError: LocalizedError {
            case empty(rawOutput: String)
            case decodeFailure(rawOutput: String)
            case validationFailed(details: String, rawOutput: String)

            var errorDescription: String? {
                switch self {
                case .empty(let rawOutput):
                    return "No cards returned.\n\n📄 RAW OUTPUT:\n" + rawOutput
                case .decodeFailure(let rawOutput):
                    return "Failed to decode cards.\n\n📄 RAW OUTPUT:\n" + rawOutput
                case .validationFailed(let details, let rawOutput):
                    return details + "\n\n📄 RAW OUTPUT:\n" + rawOutput
                }
            }
        }

        let callStart = Date()
        let basePrompt = buildCardsPrompt(observations: observations, context: context)
        var actualPromptUsed = basePrompt

        let model: String
        let effort: String?
        switch tool {
        case .claude:
            model = "sonnet"
            effort = nil
        case .codex:
            model = "gpt-5.1-codex-mini"
            effort = "high"
        }

        var lastError: Error?
        var lastRun: ChatCLIRunResult?
        var lastRawOutput: String = ""
        var parsedCards: [ActivityCardData] = []

        for attempt in 1...4 {
            do {
                let run = try runAndScrub(prompt: actualPromptUsed, model: model, reasoningEffort: effort)
                lastRun = run
                lastRawOutput = run.stdout
                let cards = try parseCards(from: run.stdout)
                guard !cards.isEmpty else { throw CardParseError.empty(rawOutput: run.stdout) }

                let normalizedCards = normalizeCards(cards, descriptors: context.categories)
                let (coverageValid, coverageError) = validateTimeCoverage(existingCards: context.existingCards, newCards: normalizedCards)
                let (durationValid, durationError) = validateTimeline(normalizedCards)

                if coverageValid && durationValid {
                    parsedCards = normalizedCards
                    let finishedAt = run.finishedAt
                    logSuccess(ctx: makeCtx(batchId: batchId, operation: "generate_cards", startedAt: callStart), finishedAt: finishedAt, stdout: run.stdout, stderr: run.stderr, responseHeaders: tokenHeaders(from: run.usage))
                    let llmCall = makeLLMCall(start: callStart, end: finishedAt, input: actualPromptUsed, output: run.stdout)
                    return (parsedCards, llmCall)
                }

                // Validation failed - prepare retry with error feedback
                var errorMessages: [String] = []
                if !coverageValid, let coverageError { errorMessages.append(coverageError) }
                if !durationValid, let durationError { errorMessages.append(durationError) }
                let combinedError = errorMessages.joined(separator: "\n\n")
                lastError = CardParseError.validationFailed(details: combinedError, rawOutput: run.stdout)
                actualPromptUsed = basePrompt + "\n\nPREVIOUS ATTEMPT FAILED - CRITICAL REQUIREMENTS NOT MET:\n\n" + combinedError + "\n\nPlease fix these issues and ensure your output meets all requirements."
                print("[ChatCLI] generate_cards validation failed (attempt " + String(attempt) + "): " + combinedError)
            } catch {
                lastError = error
                print("[ChatCLI] generate_cards attempt " + String(attempt) + " failed: " + error.localizedDescription + " — retrying")
                actualPromptUsed = basePrompt
            }
        }

        let finishedAt = lastRun?.finishedAt ?? Date()
        let finalError = lastError ?? CardParseError.decodeFailure(rawOutput: lastRawOutput)
        logFailure(ctx: makeCtx(batchId: batchId, operation: "generate_cards", startedAt: callStart), finishedAt: finishedAt, error: finalError)
        throw finalError
    }

    // MARK: - Prompt builders

    private func buildCardsPrompt(observations: [Observation], context: ActivityGenerationContext) -> String {
        // Use explicit string concatenation to avoid GRDB SQL interpolation pollution
        let transcriptText = observations.map { obs in
            let startTime = formatTimestampForPrompt(obs.startTs)
            let endTime = formatTimestampForPrompt(obs.endTs)
            return "[" + startTime + " - " + endTime + "]: " + obs.observation
        }.joined(separator: "\n")

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let existingCardsData = try? encoder.encode(context.existingCards)
        let existingCardsJSON = existingCardsData.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let promptSections = ChatCLIPromptSections(overrides: ChatCLIPromptPreferences.load())

        // Build prompt with explicit concatenation to avoid GRDB SQL interpolation pollution
        let categoriesSectionText = categoriesSection(from: context.categories)

        return """
        You are synthesizing a user's activity log into timeline cards. Each card represents one main thing they did.

        CORE PRINCIPLE:
        Each card = one coherent activity. Time is a constraint (10-60 min), not a goal. Don't stuff unrelated activities into one card just to fill time.

        SPLITTING RULES:
        - Minimum card length: 10 minutes
        - Maximum card length: 60 minutes
        - If an activity clearly shifts focus, start a new card (even if current card is short)
        - If you need "and" to connect two unrelated activities in a title, that's two cards
        - Brief interruptions (<5 min) that don't change your focus = distractions within the card
        - Sustained different activities (>10 min) = new card, not a distraction

        CONTINUITY RULE:
        Never introduce gaps or overlaps. Adjacent cards should meet cleanly. Preserve any original gaps from the source timeline.

        """ + promptSections.title + """


        """ + promptSections.summary + """


        """ + promptSections.detailedSummary + """


        DISTRACTIONS

        A distraction is a brief (<5 min) unrelated interruption that doesn't change the card's main focus.

        NOT distractions:
        - A 24-minute League game (that's its own card)
        - A 10-minute Twitter scroll (new card or merge thoughtfully)
        - Sub-tasks related to the main activity

        """ + categoriesSectionText + """


        APP SITES

        Identify primary and secondary apps/sites used.

        Rules:
        - primary: main app for the card
        - secondary: another meaningful app OR the enclosing app (browser) if relevant
        - Use canonical domains: figma.com, notion.so, docs.google.com, x.com, mail.google.com
        - Be specific: docs.google.com not google.com

        DECISION PROCESS

        Before finalizing a card, ask:
        1. What's the one main thing in this card?
        2. Can I title it without using "and" between unrelated things?
        3. Are there any sustained (>10 min) activities that should be their own card?
        4. Are the "distractions" actually brief interruptions, or separate activities?

        INPUT/OUTPUT CONTRACT:
        Your output cards MUST cover the same total time range as the "Previous cards" plus any new time from observations.
        - If Previous cards span 11:11 AM - 11:53 AM, your output must also cover 11:11 AM - 11:53 AM (you may restructure the cards, but don't drop time segments)
        - If new observations extend beyond the previous cards' time range, create additional cards to cover that new time
        - The only exception: if there's a genuine gap between previous cards (e.g., 11:27 AM to 11:33 AM with no activity), preserve that gap
        - Think of "Previous cards" as a DRAFT that you're revising/extending, not as locked history

        INPUTS:
        Previous cards: \(existingCardsJSON)
        New observations: \(transcriptText)

        OUTPUT:
        Return ONLY a raw JSON array. No code fences, no markdown, no commentary.

        [
          {
            "startTime": "1:12 AM",
            "endTime": "1:30 AM",
            "category": "",
            "subcategory": "",
            "title": "",
            "summary": "",
            "detailedSummary": "",
            "distractions": [
              {
                "startTime": "1:15 AM",
                "endTime": "1:18 AM",
                "title": "",
                "summary": ""
              }
            ],
            "appSites": {
              "primary": "",
              "secondary": ""
            }
          }
        ]
        """
    }

    // MARK: - Parsing

    private func parseObservations(from output: String, batchId: Int64?, batchStartTime: Date) -> [Observation] {
        guard let data = output.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(ChatCLIObservationsEnvelope.self, from: data) else {
            return []
        }
        return envelope.observations.compactMap { item in
            let startSeconds = TimeInterval(parseVideoTimestamp(item.start))
            let endSeconds = TimeInterval(parseVideoTimestamp(item.end))
            guard endSeconds > startSeconds else { return nil }

            let startDate = batchStartTime.addingTimeInterval(startSeconds)
            let endDate = batchStartTime.addingTimeInterval(endSeconds)

            let startEpoch = Int(startDate.timeIntervalSince1970)
            let endEpoch = max(startEpoch + 1, Int(endDate.timeIntervalSince1970))

            return Observation(
                id: nil,
                batchId: batchId ?? -1,
                startTs: startEpoch,
                endTs: endEpoch,
                observation: item.text,
                metadata: nil,
                llmModel: tool.rawValue,
                createdAt: Date()
            )
        }
    }

    private func parseCards(from output: String) throws -> [ActivityCardData] {
        guard let data = output.data(using: .utf8) else {
            throw NSError(domain: "ChatCLI", code: -31, userInfo: [NSLocalizedDescriptionKey: "No stdout to parse"])
        }

        let decoder = JSONDecoder()

        // Strategy 1: {"cards":[...]}
        if let envelope = try? decoder.decode(ChatCLICardsEnvelope.self, from: data) {
            let cards: [ActivityCardData?] = envelope.cards.map { item in
                guard let start = item.normalizedStart, let end = item.normalizedEnd else { return nil }
                return ActivityCardData(
                    startTime: start,
                    endTime: end,
                    category: item.category,
                    subcategory: item.subcategory,
                    title: item.title,
                    summary: item.summary,
                    detailedSummary: item.detailedSummary ?? item.summary,
                    distractions: item.distractions,
                    appSites: item.appSites
                )
            }
            let filtered = cards.compactMap { $0 }
            if !filtered.isEmpty { return filtered }
        }

        // Strategy 2: top-level array of cards (Gemini-style)
        if let arrayCards = try? decoder.decode([ActivityCardData].self, from: data) {
            return arrayCards
        }

        // Strategy 3: Claude often wraps valid JSON in code fences or adds prefix/suffix text.
        // As a last resort, grab the substring between the first '[' and the last ']' and try again.
        if let firstBracket = output.firstIndex(of: "["),
           let lastBracket = output.lastIndex(of: "]"),
           firstBracket < lastBracket {
            let sliced = String(output[firstBracket...lastBracket])
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let slicedData = sliced.data(using: .utf8) {
                if let envelope = try? decoder.decode(ChatCLICardsEnvelope.self, from: slicedData) {
                    let cards: [ActivityCardData?] = envelope.cards.map { item in
                        guard let start = item.normalizedStart, let end = item.normalizedEnd else { return nil }
                        return ActivityCardData(
                            startTime: start,
                            endTime: end,
                            category: item.category,
                            subcategory: item.subcategory,
                            title: item.title,
                            summary: item.summary,
                            detailedSummary: item.detailedSummary ?? item.summary,
                            distractions: item.distractions,
                            appSites: item.appSites
                        )
                    }
                    let filtered = cards.compactMap { $0 }
                    if !filtered.isEmpty { return filtered }
                }

                if let arrayCards = try? decoder.decode([ActivityCardData].self, from: slicedData) {
                    return arrayCards
                }
            }
        }

        throw NSError(domain: "ChatCLI", code: -32, userInfo: [NSLocalizedDescriptionKey: "Failed to decode activity cards"])
    }

    // MARK: - Frame processing and merging

    private struct FrameData {
        let timestamp: TimeInterval
        let path: String
    }

    private struct FrameDescriptionResponse: Codable {
        let description: String
    }

    private struct FrameDescriptionsEnvelope: Codable {
        struct Item: Codable { let index: Int; let description: String }
        let frames: [Item]
    }

    private struct SegmentMergeResponse: Codable {
        struct Segment: Codable {
            let start: String
            let end: String
            let description: String
        }
        let segments: [Segment]
    }

    private func describeFramesBatch(_ frames: [FrameData], overrideModel: String? = nil, overrideEffort: String? = nil) throws -> ([(FrameData, String)], TokenUsage?) {
        guard !frames.isEmpty else { return ([], nil) }

        let prompt = """
        You will see multiple computer screen snapshots attached in the order provided.
        Describe what you see on this computer screen in 1-2 sentences.
        Focus on: what application/site is open, what the user is doing, and any relevant details visible.
        Be specific and factual.
        
        GOOD EXAMPLES:
        ✓ "VS Code open with index.js file, writing a React component for user authentication."
        ✓ "Gmail compose window writing email to client@company.com about project timeline."
        ✓ "Slack conversation in #engineering channel discussing API rate limiting issues."
        
        BAD EXAMPLES:
        ✗ "User is coding" (too vague)
        ✗ "Looking at a website" (doesn't identify which site)
        ✗ "Working on computer" (completely non-specific)
        Reply ONLY with JSON: {"frames":[{"index":1,"description":"<one sentence about the visible activity/app/site>"}]}.
        Include one entry per image in the same order (1 = first image you received). No prose, no extra keys.
        
        """

        let model: String
        let effort: String?
        if let overrideModel {
            model = overrideModel
            effort = overrideEffort
        } else {
            switch tool {
            case .claude:
                model = "haiku"
                effort = nil
            case .codex:
                model = "gpt-5.1-codex-mini"
                effort = "low"
            }
        }

        let run = try runAndScrub(prompt: prompt, imagePaths: frames.map { $0.path }, model: model, reasoningEffort: effort)

        // Full, untrimmed logs for debugging
        print("\n[ChatCLI][describeFramesBatch] model=\(model) effort=\(effort ?? "default") frames=\(frames.count)")
        print("[ChatCLI][describeFramesBatch] stdout:\n\(run.stdout)")
        if !run.stderr.isEmpty {
            print("[ChatCLI][describeFramesBatch] stderr:\n\(run.stderr)")
        }
        guard run.exitCode == 0 else {
            throw NSError(domain: "ChatCLI", code: Int(run.exitCode), userInfo: [
                NSLocalizedDescriptionKey: "CLI exited with code \(run.exitCode). stdout: \(run.stdout) | stderr: \(run.stderr)"
            ])
        }

        // Try strict JSON decode first
        if let data = run.stdout.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(FrameDescriptionsEnvelope.self, from: data),
           !parsed.frames.isEmpty {
            var results: [(FrameData, String)] = []
            for (idx, frame) in frames.enumerated() {
                if let match = parsed.frames.first(where: { $0.index == idx + 1 }) {
                    let desc = match.description.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !desc.isEmpty { results.append((frame, desc)) }
                }
            }
            if !results.isEmpty { return (results, run.usage) }
        }

        // Fallback: try to strip code fences and decode again
        let stripped = run.stdout.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        if let data = stripped.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(FrameDescriptionsEnvelope.self, from: data),
           !parsed.frames.isEmpty {
            var results: [(FrameData, String)] = []
            for (idx, frame) in frames.enumerated() {
                if let match = parsed.frames.first(where: { $0.index == idx + 1 }) {
                    let desc = match.description.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !desc.isEmpty { results.append((frame, desc)) }
                }
            }
            if !results.isEmpty { return (results, run.usage) }
        }

        // Last resort: split lines -> descriptions by order
        var results: [(FrameData, String)] = []
        let lines = run.stdout.split(whereSeparator: { $0.isNewline })
        for (idx, frame) in frames.enumerated() {
            if idx < lines.count {
                let desc = String(lines[idx]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !desc.isEmpty { results.append((frame, desc)) }
            }
        }

        // If we still have no results after all parsing attempts, throw with the raw output
        guard !results.isEmpty else {
            // Capture richer diagnostics to PostHog so we can debug Codex vs Claude failures
            let fullStdout = run.stdout
            let fullStderr = run.stderr

            Task { @MainActor in
                AnalyticsService.shared.capture("llm_cli_failure", [
                    "provider": "chat_cli",
                    "model": tool.rawValue,
                    "operation": "describe_frames",
                    "error_message": "Failed to parse frame descriptions",
                    "stdout_preview": fullStdout,
                    "stderr_preview": fullStderr
                ])
            }

            throw NSError(domain: "ChatCLI", code: -98, userInfo: [
                NSLocalizedDescriptionKey: "Failed to parse frame descriptions. Raw stdout: \(fullStdout)\nRaw stderr: \(fullStderr)"
            ])
        }

        return (results, run.usage)
    }

    private func mergeFrameDescriptionsWithCLI(_ frames: [(timestamp: TimeInterval, description: String)],
                                               batchStartTime: Date,
                                               videoDuration: TimeInterval,
                                               batchId: Int64?,
                                               callStart: Date) throws -> ([Observation], TokenUsage?) {
        guard !frames.isEmpty else { return ([], nil) }

        let durationString = formatSeconds(videoDuration)
        let lines = frames.map { "- " + formatSeconds($0.timestamp) + ": " + $0.description }.joined(separator: "\n")
        let prompt = "You are given timestamped screen descriptions from a video (" + durationString + ").\n" +
            "Produce 2-5 segments that cover the video. Respond ONLY with JSON:\n" +
            "{\"segments\":[{\"start\":\"HH:MM:SS\",\"end\":\"HH:MM:SS\",\"description\":\"...\"}]}\n" +
            "Rules:\n" +
            "- Segments must be in order, non-overlapping, within 00:00:00-" + durationString + ".\n" +
            "- Cover at least 80% of the timeline; merge short gaps.\n" +
            "- No text outside the JSON.\n" +
            "Snapshots:\n" + lines

        let model: String
        let effort: String?
        switch tool {
        case .claude:
            model = "sonnet"
            effort = nil
        case .codex:
            model = "gpt-5.1-codex-mini"
            effort = "low"
        }

        let run = try runAndScrub(prompt: prompt, model: model, reasoningEffort: effort)

        // Full, untrimmed logs for debugging
        print("\n[ChatCLI][mergeFrameDescriptionsWithCLI] model=\(model) effort=\(effort ?? "default") frames=\(frames.count) videoDuration=\(videoDuration)")
        print("[ChatCLI][mergeFrameDescriptionsWithCLI] stdout:\n\(run.stdout)")
        if !run.stderr.isEmpty {
            print("[ChatCLI][mergeFrameDescriptionsWithCLI] stderr:\n\(run.stderr)")
        }
        guard run.exitCode == 0,
              let data = run.stdout.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(SegmentMergeResponse.self, from: data),
              !parsed.segments.isEmpty else {
            return (fallbackObservations(frames: frames, batchId: batchId, batchStartTime: batchStartTime, videoDuration: videoDuration), run.usage)
        }

        var observations: [Observation] = []
        for seg in parsed.segments.prefix(5) {
            let startSeconds = TimeInterval(parseVideoTimestamp(seg.start))
            let endSeconds = TimeInterval(parseVideoTimestamp(seg.end))
            guard endSeconds > startSeconds else { continue }

            let clampedEndSeconds = videoDuration > 0 ? min(endSeconds, videoDuration) : endSeconds
            let startDate = batchStartTime.addingTimeInterval(startSeconds)
            let endDate = batchStartTime.addingTimeInterval(clampedEndSeconds)

            let startEpoch = Int(startDate.timeIntervalSince1970)
            let endEpoch = max(startEpoch + 1, Int(endDate.timeIntervalSince1970))
            observations.append(
                Observation(
                    id: nil,
                    batchId: batchId ?? -1,
                    startTs: startEpoch,
                    endTs: endEpoch,
                    observation: seg.description,
                    metadata: nil,
                    llmModel: tool.rawValue,
                    createdAt: Date()
                )
            )
        }

        if observations.isEmpty {
            return (fallbackObservations(frames: frames, batchId: batchId, batchStartTime: batchStartTime, videoDuration: videoDuration), run.usage)
        }
        return (observations, run.usage)
    }

    private func fallbackObservations(frames: [(timestamp: TimeInterval, description: String)],
                                      batchId: Int64?,
                                      batchStartTime: Date,
                                      videoDuration: TimeInterval) -> [Observation] {
        let sorted = frames.sorted { $0.timestamp < $1.timestamp }
        var result: [Observation] = []
        for item in sorted.prefix(5) {
            let startSeconds = max(0.0, item.timestamp)
            let endSeconds = startSeconds + screenshotInterval
            let clampedEndSeconds = videoDuration > 0 ? min(videoDuration, endSeconds) : endSeconds

            let startDate = batchStartTime.addingTimeInterval(startSeconds)
            let endDate = batchStartTime.addingTimeInterval(max(clampedEndSeconds, startSeconds + 1))

            let startEpoch = Int(startDate.timeIntervalSince1970)
            let endEpoch = max(startEpoch + 1, Int(endDate.timeIntervalSince1970))
            result.append(
                Observation(
                    id: nil,
                    batchId: batchId ?? -1,
                    startTs: startEpoch,
                    endTs: endEpoch,
                    observation: item.description,
                    metadata: nil,
                    llmModel: tool.rawValue,
                    createdAt: Date()
                )
            )
        }
        return result
    }

    private func formatSeconds(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return String(format: "%02d:%02d:%02d", h, m, sec)
    }

    private func categoriesSection(from descriptors: [LLMCategoryDescriptor]) -> String {
        guard !descriptors.isEmpty else {
            return "USER CATEGORIES: No categories configured. Use consistent labels based on the activity story."
        }

        // Use explicit string concatenation to avoid GRDB SQL interpolation pollution
        let allowed = descriptors.map { "\"" + $0.name + "\"" }.joined(separator: ", ")
        var lines: [String] = ["USER CATEGORIES (choose exactly one label):"]

        for (index, descriptor) in descriptors.enumerated() {
            var desc = descriptor.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if descriptor.isIdle && desc.isEmpty {
                desc = "Use when the user is idle for most of this period."
            }
            let suffix = desc.isEmpty ? "" : " — " + desc
            lines.append(String(index + 1) + ". \"" + descriptor.name + "\"" + suffix)
        }

        if let idle = descriptors.first(where: { $0.isIdle }) {
            lines.append("Only use \"" + idle.name + "\" when the user is idle for more than half of the timeframe. Otherwise pick the closest non-idle label.")
        }

        lines.append("Return the category exactly as written. Allowed values: [" + allowed + "].")
        return lines.joined(separator: "\n")
    }

    private func normalizeCategory(_ raw: String, descriptors: [LLMCategoryDescriptor]) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return descriptors.first?.name ?? "" }
        let normalized = cleaned.lowercased()
        if let match = descriptors.first(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized }) {
            return match.name
        }
        if let idle = descriptors.first(where: { $0.isIdle }) {
            let idleLabels = ["idle", "idle time", idle.name.lowercased()]
            if idleLabels.contains(normalized) {
                return idle.name
            }
        }
        return descriptors.first?.name ?? cleaned
    }

    private func normalizeCards(_ cards: [ActivityCardData], descriptors: [LLMCategoryDescriptor]) -> [ActivityCardData] {
        cards.map { card in
            ActivityCardData(
                startTime: card.startTime,
                endTime: card.endTime,
                category: normalizeCategory(card.category, descriptors: descriptors),
                subcategory: card.subcategory,
                title: card.title,
                summary: card.summary,
                detailedSummary: card.detailedSummary,
                distractions: card.distractions,
                appSites: card.appSites
            )
        }
    }

    private struct TimeRange { let start: Double; let end: Double }

    private func timeToMinutes(_ timeStr: String) -> Double {
        let trimmed = timeStr.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("AM") || trimmed.contains("PM") {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            guard let date = formatter.date(from: trimmed) else { return 0 }
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            let hours = Double(components.hour ?? 0)
            let minutes = Double(components.minute ?? 0)
            return hours * 60 + minutes
        } else {
            let seconds = parseVideoTimestamp(timeStr)
            return Double(seconds) / 60.0
        }
    }

    private func mergeOverlappingRanges(_ ranges: [TimeRange]) -> [TimeRange] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted { $0.start < $1.start }
        var merged: [TimeRange] = []
        for range in sorted {
            if merged.isEmpty || range.start > merged.last!.end + 1 {
                merged.append(range)
            } else {
                let last = merged.removeLast()
                merged.append(TimeRange(start: last.start, end: max(last.end, range.end)))
            }
        }
        return merged
    }

    private func validateTimeCoverage(existingCards: [ActivityCardData], newCards: [ActivityCardData]) -> (isValid: Bool, error: String?) {
        guard !existingCards.isEmpty else { return (true, nil) }

        var inputRanges: [TimeRange] = []
        for card in existingCards {
            let startMin = timeToMinutes(card.startTime)
            var endMin = timeToMinutes(card.endTime)
            if endMin < startMin { endMin += 24 * 60 }
            inputRanges.append(TimeRange(start: startMin, end: endMin))
        }
        let mergedInputRanges = mergeOverlappingRanges(inputRanges)

        var outputRanges: [TimeRange] = []
        for card in newCards {
            let startMin = timeToMinutes(card.startTime)
            var endMin = timeToMinutes(card.endTime)
            if endMin < startMin { endMin += 24 * 60 }
            guard endMin - startMin >= 0.1 else { continue }
            outputRanges.append(TimeRange(start: startMin, end: endMin))
        }

        let flexibility = 3.0 // minutes
        var uncoveredSegments: [(start: Double, end: Double)] = []

        for inputRange in mergedInputRanges {
            var coveredStart = inputRange.start
            var safetyCounter = 10000
            while coveredStart < inputRange.end && safetyCounter > 0 {
                safetyCounter -= 1
                var foundCoverage = false
                for outputRange in outputRanges {
                    if outputRange.start - flexibility <= coveredStart && coveredStart <= outputRange.end + flexibility {
                        let newCoveredStart = outputRange.end
                        coveredStart = max(coveredStart + 0.01, newCoveredStart)
                        foundCoverage = true
                        break
                    }
                }

                if !foundCoverage {
                    var nextCovered = inputRange.end
                    for outputRange in outputRanges {
                        if outputRange.start > coveredStart && outputRange.start < nextCovered {
                            nextCovered = outputRange.start
                        }
                    }
                    if nextCovered > coveredStart {
                        uncoveredSegments.append((start: coveredStart, end: min(nextCovered, inputRange.end)))
                        coveredStart = nextCovered
                    } else {
                        uncoveredSegments.append((start: coveredStart, end: inputRange.end))
                        break
                    }
                }
            }
            if safetyCounter == 0 {
                return (false, "Time coverage validation loop exceeded safety limit - possible infinite loop detected")
            }
        }

        if !uncoveredSegments.isEmpty {
            var uncoveredDesc: [String] = []
            for segment in uncoveredSegments {
                let duration = segment.end - segment.start
                if duration > flexibility {
                    let startTime = minutesToTimeString(segment.start)
                    let endTime = minutesToTimeString(segment.end)
                    uncoveredDesc.append(startTime + "-" + endTime + " (" + String(Int(duration)) + " min)")
                }
            }

            if !uncoveredDesc.isEmpty {
                let missing = uncoveredDesc.joined(separator: ", ")
                var errorMsg = "Missing coverage for time segments: " + missing
                errorMsg += "\n\n📥 INPUT CARDS:"
                for (i, card) in existingCards.enumerated() {
                    errorMsg += "\n  " + String(i + 1) + ". " + card.startTime + " - " + card.endTime + ": " + card.title
                }
                errorMsg += "\n\n📤 OUTPUT CARDS:"
                for (i, card) in newCards.enumerated() {
                    errorMsg += "\n  " + String(i + 1) + ". " + card.startTime + " - " + card.endTime + ": " + card.title
                }
                return (false, errorMsg)
            }
        }

        return (true, nil)
    }

    private func validateTimeline(_ cards: [ActivityCardData]) -> (isValid: Bool, error: String?) {
        for (index, card) in cards.enumerated() {
            let startTime = card.startTime
            let endTime = card.endTime
            var durationMinutes: Double = 0

            if startTime.contains("AM") || startTime.contains("PM") {
                let formatter = DateFormatter()
                formatter.dateFormat = "h:mm a"
                formatter.locale = Locale(identifier: "en_US_POSIX")

                if let startDate = formatter.date(from: startTime),
                   let endDate = formatter.date(from: endTime) {
                    var adjustedEndDate = endDate
                    if endDate < startDate {
                        adjustedEndDate = Calendar.current.date(byAdding: .day, value: 1, to: endDate) ?? endDate
                    }
                    durationMinutes = adjustedEndDate.timeIntervalSince(startDate) / 60.0
                } else {
                    durationMinutes = 0
                }
            } else {
                let startSeconds = parseVideoTimestamp(startTime)
                let endSeconds = parseVideoTimestamp(endTime)
                durationMinutes = Double(endSeconds - startSeconds) / 60.0
            }

            if durationMinutes < 10 && index < cards.count - 1 {
                let msg = String(format: "Card %d '%@' is only %.1f minutes long", index + 1, card.title, durationMinutes)
                return (false, msg)
            }
        }

        return (true, nil)
    }

    private func minutesToTimeString(_ minutes: Double) -> String {
        let hours = (Int(minutes) / 60) % 24
        let mins = Int(minutes) % 60
        let period = hours < 12 ? "AM" : "PM"
        var displayHour = hours % 12
        if displayHour == 0 { displayHour = 12 }
        return String(format: "%d:%02d %@", displayHour, mins, period)
    }

    // MARK: - Logging helpers

    private func makeCtx(batchId: Int64?, operation: String, startedAt: Date) -> LLMCallContext {
        LLMCallContext(
            batchId: batchId,
            callGroupId: nil,
            attempt: 1,
            provider: "chat_cli",
            model: tool.rawValue,
            operation: operation,
            requestMethod: nil,
            requestURL: nil,
            requestHeaders: nil,
            requestBody: nil,
            startedAt: startedAt
        )
    }

    private func tokenHeaders(from usage: TokenUsage?) -> [String:String]? {
        guard let usage else { return nil }
        return [
            "x-usage-input": String(usage.input),
            "x-usage-cached-input": String(usage.cachedInput),
            "x-usage-output": String(usage.output)
        ]
    }

    private func logSuccess(ctx: LLMCallContext, finishedAt: Date, stdout: String, stderr: String, responseHeaders: [String:String]? = nil) {
        let separator = stdout.isEmpty || stderr.isEmpty ? "" : "\n\n[stderr]\n"
        let combined = stdout + separator + stderr
        let http = LLMHTTPInfo(httpStatus: nil, responseHeaders: responseHeaders, responseBody: combined.data(using: .utf8))
        LLMLogger.logSuccess(ctx: ctx, http: http, finishedAt: finishedAt)
    }

    private func logFailure(ctx: LLMCallContext, finishedAt: Date, error: Error) {
        LLMLogger.logFailure(ctx: ctx, http: nil, finishedAt: finishedAt, errorDomain: "ChatCLI", errorCode: (error as NSError).code, errorMessage: error.localizedDescription)
    }

    private func makeLLMCall(start: Date, end: Date, input: String?, output: String?) -> LLMCall {
        LLMCall(timestamp: end, latency: end.timeIntervalSince(start), input: input, output: output)
    }

    // MARK: - Screenshot Transcription

    /// Transcribe observations from screenshots.
    func transcribeScreenshots(_ screenshots: [Screenshot], batchStartTime: Date, batchId: Int64?) async throws -> (observations: [Observation], log: LLMCall) {
        guard !screenshots.isEmpty else {
            throw NSError(domain: "ChatCLI", code: -96, userInfo: [NSLocalizedDescriptionKey: "No screenshots to transcribe"])
        }

        let callStart = Date()
        let sortedScreenshots = screenshots.sorted { $0.capturedAt < $1.capturedAt }

        // Sample ~15 evenly spaced screenshots to reduce API calls
        let targetSamples = 15
        let strideAmount = max(1, sortedScreenshots.count / targetSamples)
        let sampledScreenshots = Swift.stride(from: 0, to: sortedScreenshots.count, by: strideAmount).map { sortedScreenshots[$0] }

        // Calculate "video duration" from timestamp range
        let firstTs = sampledScreenshots.first!.capturedAt
        let lastTs = sampledScreenshots.last!.capturedAt
        let videoDuration = TimeInterval(lastTs - firstTs)

        // Convert screenshots to FrameData (reuse existing paths — no need to copy files)
        let frames: [FrameData] = sampledScreenshots.compactMap { screenshot in
            // Calculate timestamp relative to batch start (like video frames)
            let relativeTimestamp = TimeInterval(screenshot.capturedAt - firstTs)

            // Verify the file exists
            guard FileManager.default.fileExists(atPath: screenshot.filePath) else {
                print("[ChatCLI] ⚠️ Screenshot file not found: \(screenshot.filePath)")
                return nil
            }

            return FrameData(timestamp: relativeTimestamp, path: screenshot.filePath)
        }

        guard !frames.isEmpty else {
            throw NSError(
                domain: "ChatCLI",
                code: -97,
                userInfo: [NSLocalizedDescriptionKey: "No valid screenshot files found"]
            )
        }

        // Note: Don't cleanup these frames since they're the original screenshot files, not temp copies!

        var usageTotal = TokenUsage.zero
        var sawUsage = false

        // Retry loop for entire transcription pipeline
        let maxTranscribeAttempts = 2
        for transcribeAttempt in 1...maxTranscribeAttempts {
            // Per-frame descriptions via CLI (reuse existing batching logic)
            var frameDescriptions: [(timestamp: TimeInterval, description: String)] = []
            let batchSize = 10
            for chunk in stride(from: 0, to: frames.count, by: batchSize) {
                let slice = Array(frames[chunk..<min(chunk+batchSize, frames.count)])

                var localPairs: [(FrameData, String)] = []
                var localUsage: TokenUsage? = nil
                var lastError: Error? = nil

                // Try initial call
                do {
                    let (initialPairs, initialUsage) = try describeFramesBatch(slice)
                    localPairs = initialPairs
                    localUsage = initialUsage
                } catch {
                    lastError = error
                    // Retry with more powerful model
                    if tool == .codex {
                        do {
                            let (retryPairs, retryUsage) = try describeFramesBatch(slice, overrideModel: "gpt-5.1-codex-mini", overrideEffort: "high")
                            localPairs = retryPairs
                            localUsage = retryUsage
                            lastError = nil
                        } catch {
                            lastError = error
                        }
                    } else if tool == .claude {
                        do {
                            let (retryPairs, retryUsage) = try describeFramesBatch(slice, overrideModel: "sonnet")
                            localPairs = retryPairs
                            localUsage = retryUsage
                            lastError = nil
                        } catch {
                            lastError = error
                        }
                    }
                }

                if let error = lastError {
                    logFailure(ctx: makeCtx(batchId: batchId, operation: "describe_screenshots", startedAt: callStart), finishedAt: Date(), error: error)
                    throw error
                }

                if let localUsage { usageTotal = usageTotal.adding(localUsage); sawUsage = true }
                for (frame, desc) in localPairs {
                    frameDescriptions.append((timestamp: frame.timestamp, description: desc))
                }
            }

            // Merge descriptions into observations via CLI text prompt
            let (observations, mergeUsage) = try mergeFrameDescriptionsWithCLI(
                frameDescriptions,
                batchStartTime: batchStartTime,
                videoDuration: videoDuration,
                batchId: batchId,
                callStart: callStart
            )

            if let mergeUsage { usageTotal = usageTotal.adding(mergeUsage); sawUsage = true }

            // Check if we got observations
            if !observations.isEmpty {
                let finishedAt = Date()
                let headers = sawUsage ? tokenHeaders(from: usageTotal) : nil
                logSuccess(ctx: makeCtx(batchId: batchId, operation: "transcribe_screenshots", startedAt: callStart), finishedAt: finishedAt, stdout: observations.map { $0.observation }.joined(separator: " | "), stderr: "", responseHeaders: headers)
                let llmCall = makeLLMCall(start: callStart, end: finishedAt, input: "screenshots \(screenshots.count)", output: "obs \(observations.count)")
                return (observations, llmCall)
            }

            // Empty observations - log and maybe retry
            if transcribeAttempt < maxTranscribeAttempts {
                print("[ChatCLI] Screenshot transcribe attempt \(transcribeAttempt) returned 0 observations from \(frames.count) screenshots, retrying...")
                Task { @MainActor in
                    AnalyticsService.shared.capture("transcribe_screenshots_empty_retry", [
                        "batch_id": batchId as Any,
                        "attempt": transcribeAttempt,
                        "screenshot_count": screenshots.count,
                        "frame_descriptions_count": frameDescriptions.count,
                        "tool": tool.rawValue
                    ])
                }
                usageTotal = TokenUsage.zero
                sawUsage = false
            }
        }

        // All attempts returned empty observations
        let finishedAt = Date()
        let emptyError = NSError(domain: "ChatCLI", code: -99, userInfo: [
            NSLocalizedDescriptionKey: "Screenshot transcription produced 0 observations after \(maxTranscribeAttempts) attempts from \(screenshots.count) screenshots"
        ])
        logFailure(ctx: makeCtx(batchId: batchId, operation: "transcribe_screenshots", startedAt: callStart), finishedAt: finishedAt, error: emptyError)
        throw emptyError
    }

    // MARK: - Text Generation

    func generateText(prompt: String) async throws -> (text: String, log: LLMCall) {
        let callStart = Date()
        let ctx = makeCtx(batchId: nil, operation: "generateText", startedAt: callStart)

        let model: String
        switch tool {
        case .claude:
            model = "sonnet"
        case .codex:
            model = "gpt-5.1-codex-mini"
        }

        let run: ChatCLIRunResult
        do {
            run = try await Task.detached {
                try self.runAndScrub(prompt: prompt, model: model, reasoningEffort: "high")
            }.value
        } catch {
            logFailure(ctx: ctx, finishedAt: Date(), error: error)
            throw error
        }

        guard run.exitCode == 0 else {
            let errorMessage = run.stderr.isEmpty ? "CLI exited with code \(run.exitCode)" : run.stderr
            let error = NSError(domain: "ChatCLI", code: Int(run.exitCode), userInfo: [NSLocalizedDescriptionKey: errorMessage])
            logFailure(ctx: ctx, finishedAt: run.finishedAt, error: error)
            throw error
        }

        logSuccess(ctx: ctx, finishedAt: run.finishedAt, stdout: run.stdout, stderr: run.stderr)

        let log = makeLLMCall(start: callStart, end: run.finishedAt, input: prompt, output: run.stdout)

        return (run.stdout.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), log)
    }
}
