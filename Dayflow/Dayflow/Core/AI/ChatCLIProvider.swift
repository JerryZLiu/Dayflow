//
//  ChatCLIProvider.swift
//  Dayflow
//
//  High-level LLM provider that uses ChatCLIRunner for CLI execution.
//

import Foundation
import AppKit

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

final class ChatCLIProvider {
    private let tool: ChatCLITool
    private let runner = ChatCLIProcessRunner()
    private let config = ChatCLIConfigManager.shared

    init(tool: ChatCLITool) {
        self.tool = tool
        config.ensureWorkingDirectory()
    }

    /// Run the CLI and clean up temp files after.
    private func runAndScrub(prompt: String, imagePaths: [String] = [], model: String? = nil, reasoningEffort: String? = nil, disableTools: Bool = false) throws -> ChatCLIRunResult {
        // Prepare downsized copies of images (~720p) so Codex input stays compact.
        let (preparedImages, cleanupImages) = try prepareImagesForCLI(imagePaths)
        defer {
            cleanupImages()
        }
        return try runner.run(tool: tool, prompt: prompt, workingDirectory: config.workingDirectory, imagePaths: preparedImages, model: model, reasoningEffort: reasoningEffort, disableTools: disableTools)
    }

    private func runStreamingAndCollect(prompt: String, model: String?, reasoningEffort: String?, sessionId: String?) async throws -> (run: ChatCLIRunResult, sessionId: String?) {
        let started = Date()
        var collectedText = ""
        var sawTextDelta = false
        var capturedSessionId = sessionId

        let stream = runner.runStreaming(
            tool: tool,
            prompt: prompt,
            workingDirectory: config.workingDirectory,
            model: model,
            reasoningEffort: reasoningEffort,
            sessionId: sessionId
        )

        do {
            for try await event in stream {
                switch event {
                case .sessionStarted(let id):
                    if capturedSessionId == nil {
                        capturedSessionId = id
                    }
                case .textDelta(let chunk):
                    sawTextDelta = true
                    collectedText += chunk
                case .complete(let text):
                    if !sawTextDelta {
                        collectedText = text
                    }
                case .error(let message):
                    throw NSError(domain: "ChatCLI", code: -4, userInfo: [NSLocalizedDescriptionKey: message])
                default:
                    break
                }
            }
        } catch {
            throw error
        }

        let finished = Date()
        let run = ChatCLIRunResult(
            exitCode: 0,
            stdout: collectedText,
            rawStdout: collectedText,
            stderr: "",
            startedAt: started,
            finishedAt: finished,
            usage: nil
        )

        return (run, capturedSessionId)
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
            model = "gpt-5.2"
            effort = "medium"
        }

        var lastError: Error?
        var lastRun: ChatCLIRunResult?
        var lastRawOutput: String = ""
        var parsedCards: [ActivityCardData] = []
        var sessionId: String? = nil

        for attempt in 1...3 {
            do {
                let runResult = try await runStreamingAndCollect(prompt: actualPromptUsed, model: model, reasoningEffort: effort, sessionId: sessionId)
                let run = runResult.run
                sessionId = runResult.sessionId
                lastRun = run
                lastRawOutput = run.stdout
                let cards = try parseCards(from: run.stdout, stderr: run.stderr)
                guard !cards.isEmpty else { throw CardParseError.empty(rawOutput: run.stdout) }

                let normalizedCards = normalizeCards(cards, descriptors: context.categories)
                let (coverageValid, coverageError) = validateTimeCoverage(existingCards: context.existingCards, newCards: normalizedCards)
                let (durationValid, durationError) = validateTimeline(normalizedCards)

                if coverageValid && durationValid {
                    parsedCards = normalizedCards
                    let finishedAt = run.finishedAt
                    logSuccess(ctx: makeCtx(batchId: batchId, operation: "generate_cards", startedAt: callStart, attempt: attempt), finishedAt: finishedAt, stdout: run.stdout, stderr: run.stderr, responseHeaders: tokenHeaders(from: run.usage))
                    let llmCall = makeLLMCall(start: callStart, end: finishedAt, input: actualPromptUsed, output: run.stdout)
                    return (parsedCards, llmCall)
                }

                // Validation failed - prepare retry with error feedback
                var errorMessages: [String] = []
                if !coverageValid, let coverageError {
                    AnalyticsService.shared.captureValidationFailure(
                        provider: "chat_cli",
                        operation: "generate_activity_cards",
                        validationType: "time_coverage",
                        attempt: attempt,
                        model: model,
                        batchId: batchId,
                        errorDetail: coverageError
                    )
                    errorMessages.append(coverageError)
                }
                if !durationValid, let durationError {
                    AnalyticsService.shared.captureValidationFailure(
                        provider: "chat_cli",
                        operation: "generate_activity_cards",
                        validationType: "duration",
                        attempt: attempt,
                        model: model,
                        batchId: batchId,
                        errorDetail: durationError
                    )
                    errorMessages.append(durationError)
                }
                let combinedError = errorMessages.joined(separator: "\n\n")
                lastError = CardParseError.validationFailed(details: combinedError, rawOutput: run.stdout)
                if sessionId == nil {
                    actualPromptUsed = basePrompt + "\n\nPREVIOUS ATTEMPT FAILED - CRITICAL REQUIREMENTS NOT MET:\n\n" + combinedError + "\n\nPlease fix these issues and ensure your output meets all requirements."
                } else {
                    actualPromptUsed = buildCardsCorrectionPrompt(validationError: combinedError)
                }
                print("[ChatCLI] generate_cards validation failed (attempt " + String(attempt) + "): " + combinedError)
            } catch {
                lastError = error
                print("[ChatCLI] generate_cards attempt " + String(attempt) + " failed: " + error.localizedDescription + " — retrying")
                actualPromptUsed = basePrompt
                sessionId = nil
            }
        }

        let finishedAt = lastRun?.finishedAt ?? Date()
        let finalError = lastError ?? CardParseError.decodeFailure(rawOutput: lastRawOutput)
        logFailure(ctx: makeCtx(batchId: batchId, operation: "generate_cards", startedAt: callStart, attempt: 3), finishedAt: finishedAt, error: finalError, stdout: lastRawOutput, stderr: lastRun?.stderr)
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

        let languageBlock = LLMOutputLanguagePreferences.languageInstruction(forJSON: true)
            .map { "\n\n\($0)" } ?? ""

        return """
        You are synthesizing a user's activity log into timeline cards. Each card represents one main thing they did.

        CORE PRINCIPLE:
        Each card = one coherent activity. Time is a constraint (10-60 min), not a goal. 

        CARD BOUNDARIES:
        - Minimum card length: 10 minutes
        - Maximum card length: 60 minutes
        - Brief interruptions (<5 min) that don't change your focus = distractions within the card

        WHEN TO SPLIT (new card):
        - The user's GOAL changes, not just their tool/app
        - You'd need "and" to connect two genuinely unrelated activities in the title

        WHEN TO MERGE (same card):
        - Consecutive activities serve the same project or goal (e.g., reviewing mockups → discussing those mockups → iterating on those mockups = one design session)
        - Switching apps/tools within the same task (Figma → Meet → Figma for one design review)
        - Back-to-back games of the same game = one gaming session
        - Debugging across IDE + Terminal + Browser = one debugging session

        BIAS: Default to MERGING. Ask "would the user describe this as one sitting/session?" If yes, it's one card. Fewer rich cards are better than many granular ones.

        CONTINUITY RULE:
        Never introduce gaps or overlaps. Adjacent cards should meet cleanly. Preserve any original gaps from the source timeline.

        """ + promptSections.title + """


        """ + promptSections.summary + """


        """ + promptSections.detailedSummary + """

        """ + languageBlock + """

        DISTRACTIONS

        A distraction is a brief (<5 min) unrelated interruption that doesn't change the card's main focus.

        NOT distractions:
        - A 24-minute League game (that's its own card)
        - A 10-minute Twitter scroll (new card or merge thoughtfully)
        - Sub-tasks related to the main activity

        """ + categoriesSectionText + """


        APP SITES (Website Logos)

        Identify the main app or website used for each card. Output the canonical DOMAIN, not the app name.

        Rules:
        - primary: The canonical domain of the main app/website used in the card.
        - secondary: Another meaningful app used during this session, if relevant.
        - Format: lower-case, no protocol, no query or fragments.
        - Use product subdomains/paths when canonical (e.g., docs.google.com for Google Docs).
        - Be specific: prefer product domains over generic ones (docs.google.com over google.com).
        - If you cannot determine a secondary, omit it.
        - Do not invent brands; rely on evidence from observations.

        Canonical examples (app → domain):
        - Figma → figma.com
        - Notion → notion.so
        - Google Docs → docs.google.com
        - Gmail → mail.google.com
        - VS Code → code.visualstudio.com
        - Xcode → developer.apple.com/xcode
        - Slack → slack.com
        - Twitter/X → x.com
        - Messages → support.apple.com/messages
        - Terminal → omit (no canonical domain)

        ✗ WRONG: "primary": "Messages" (app name, not a domain)
        ✗ WRONG: "primary": "Ghostty IDE" (app name, not a domain)
        ✓ CORRECT: "primary": "figma.com", "secondary": "notion.so"

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

    private func buildCardsCorrectionPrompt(validationError: String) -> String {
        """
        The previous JSON output has validation errors. Fix the existing output using the context from our ongoing conversation.

        Issues:
        \(validationError)

        Requirements:
        - Return the FULL corrected JSON output (not a diff).
        - Preserve the same overall time coverage: no gaps or overlaps.
        - Each card must be 10-60 minutes, except the final card may be shorter.
        - If a mid-card is too short, merge it with an adjacent card and update title/summary accordingly.
        - Output JSON only. No code fences or extra text.
        """
    }

    // MARK: - Parsing

    /// Strip OSC (Operating System Command) escape sequences from CLI output.
    /// These are injected by terminal integrations like iTerm2 and pollute JSON responses.
    /// Examples: ]1337;RemoteHost=user@host, ]9;4;0;, ]1337;CurrentDir=/path
    /// Safety: Only strips if semicolon appears within first 5 chars (real OSC always has it)
    private func stripOSCEscapes(_ input: String) -> String {
        var result = ""
        var i = input.startIndex
        while i < input.endIndex {
            if input[i] == "]" {
                let next = input.index(after: i)
                if next < input.endIndex, input[next].isNumber {
                    // Look ahead to see if there's a semicolon within first 5 chars (OSC signature)
                    var hasSemicolon = false
                    var lookAhead = next
                    var lookCount = 0
                    while lookAhead < input.endIndex, lookCount < 5 {
                        if input[lookAhead] == ";" {
                            hasSemicolon = true
                            break
                        }
                        if !input[lookAhead].isNumber { break }
                        lookAhead = input.index(after: lookAhead)
                        lookCount += 1
                    }

                    if hasSemicolon {
                        // This is a real OSC sequence - skip it
                        var j = next
                        while j < input.endIndex {
                            let c = input[j]
                            if c.isNumber || c == ";" || c == "=" || c.isLetter || c == "@" || c == "." || c == "-" || c == "_" || c == "/" {
                                j = input.index(after: j)
                            } else {
                                break
                            }
                        }
                        i = j
                        continue
                    }
                }
            }
            result.append(input[i])
            i = input.index(after: i)
        }
        return result
    }

    /// Extract user-facing error message from CLI stderr/stdout.
    /// Returns the actual error message from the CLI tool if found, nil otherwise.
    private func extractCLIError(stdout: String, stderr: String) -> String? {
        // Check stderr for ERROR: lines (Codex format)
        // e.g. "ERROR: You've hit your usage limit..."
        // e.g. "ERROR: Your access token could not be refreshed..."
        for line in stderr.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("ERROR:") {
                return trimmed
            }
        }

        // Check stdout for API Error messages (Claude format)
        // e.g. "API Error: The SSO session associated with this profile has expired..."
        // e.g. "You've hit your limit · resets 3pm (Asia/Shanghai)"
        // e.g. "Invalid API key · Please run /login"
        for line in stdout.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("API Error:") ||
               trimmed.hasPrefix("Invalid API key") ||
               trimmed.hasPrefix("You've hit your limit") {
                // Strip trailing escape sequences like ]9;4;0;
                let cleaned = trimmed.replacingOccurrences(of: #"\][\d;]+$"#, with: "", options: .regularExpression)
                return cleaned
            }
        }

        return nil
    }

    private func parseCards(from output: String, stderr: String) throws -> [ActivityCardData] {
        // Try parsing without modifications first, OSC stripping is a fallback
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

        // Strategy 3: LLM may output preamble text containing brackets (e.g., git help `[-v | --version]`).
        // Use bracket balancing: start from the last ']' and walk backwards tracking balance.
        // When balance hits 0, we've found the '[' that opens our JSON array.
        func findBalancedArrayStart(_ str: String, endBracket: String.Index) -> String.Index? {
            var balance = 0
            var index = endBracket
            while true {
                let char = str[index]
                if char == "]" {
                    balance += 1
                } else if char == "[" {
                    balance -= 1
                    if balance == 0 {
                        return index
                    }
                }
                if index == str.startIndex { break }
                index = str.index(before: index)
            }
            return nil
        }

        if let lastBracket = output.lastIndex(of: "]"),
           let firstBracket = findBalancedArrayStart(output, endBracket: lastBracket) {
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

        // Strategy 4 (fallback): Strip OSC escapes and retry bracket extraction
        let oscCleaned = stripOSCEscapes(output)
        if let lastBracket = oscCleaned.lastIndex(of: "]"),
           let firstBracket = findBalancedArrayStart(oscCleaned, endBracket: lastBracket) {
            let sliced = String(oscCleaned[firstBracket...lastBracket])
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let slicedData = sliced.data(using: .utf8) {
                if let arrayCards = try? decoder.decode([ActivityCardData].self, from: slicedData) {
                    return arrayCards
                }
            }
        }

        // Log full raw output to PostHog for debugging decode failures
        AnalyticsService.shared.capture("llm_decode_failed", [
            "provider": "chat_cli",
            "operation": "parse_cards",
            "tool": tool.rawValue,
            "raw_output": output,
            "output_length": output.count,
            "stderr": stderr,
            "stderr_length": stderr.count
        ])

        // Surface CLI error messages to the user if available
        if let cliError = extractCLIError(stdout: output, stderr: stderr) {
            throw NSError(domain: "ChatCLI", code: -33, userInfo: [NSLocalizedDescriptionKey: cliError])
        }

        throw NSError(domain: "ChatCLI", code: -32, userInfo: [NSLocalizedDescriptionKey: "Failed to decode activity cards"])
    }

    private struct SegmentMergeResponse: Codable {
        struct Segment: Codable {
            let start: String
            let end: String
            let description: String
        }
        let segments: [Segment]
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

    private func makeCtx(batchId: Int64?, operation: String, startedAt: Date, attempt: Int = 1) -> LLMCallContext {
        LLMCallContext(
            batchId: batchId,
            callGroupId: nil,
            attempt: attempt,
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

    private func logFailure(ctx: LLMCallContext, finishedAt: Date, error: Error, stdout: String? = nil, stderr: String? = nil) {
        let http: LLMHTTPInfo?
        let out = stdout ?? ""
        let err = stderr ?? ""

        if out.isEmpty && err.isEmpty {
            http = nil
        } else {
            let separator = out.isEmpty || err.isEmpty ? "" : "\n\n[stderr]\n"
            let combined = out + separator + err
            http = LLMHTTPInfo(httpStatus: nil, responseHeaders: nil, responseBody: combined.data(using: .utf8))
        }

        LLMLogger.logFailure(ctx: ctx, http: http, finishedAt: finishedAt, errorDomain: "ChatCLI", errorCode: (error as NSError).code, errorMessage: error.localizedDescription)
    }

    private func makeLLMCall(start: Date, end: Date, input: String?, output: String?) -> LLMCall {
        LLMCall(timestamp: end, latency: end.timeIntervalSince(start), input: input, output: output)
    }

    /// Parse thinking content from Codex stderr (between "thinking" markers)
    private func parseThinkingFromStderr(_ stderr: String) -> String? {
        // Codex outputs thinking like:
        // thinking
        // **Some thinking text**
        // thinking
        // **More thinking**
        // codex
        // <actual response>

        var thinkingParts: [String] = []
        let lines = stderr.components(separatedBy: .newlines)
        var inThinking = false
        var currentThinking: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "thinking" {
                if inThinking {
                    // End of thinking block
                    if !currentThinking.isEmpty {
                        thinkingParts.append(currentThinking.joined(separator: "\n"))
                    }
                    currentThinking = []
                }
                inThinking = !inThinking
            } else if inThinking && !trimmed.isEmpty {
                // Clean up markdown bold markers if present
                let cleaned = trimmed.replacingOccurrences(of: "**", with: "")
                currentThinking.append(cleaned)
            }
        }

        // Handle unclosed thinking block
        if inThinking && !currentThinking.isEmpty {
            thinkingParts.append(currentThinking.joined(separator: "\n"))
        }

        guard !thinkingParts.isEmpty else { return nil }
        return thinkingParts.joined(separator: "\n\n")
    }

    // MARK: - Screenshot Transcription

    private func buildScreenshotTranscriptionPrompt(numFrames: Int, duration: String, startTime: String, endTime: String) -> String {
        return """
        Analyze these \(numFrames) screenshots from a \(duration) screen recording
        (\(startTime) to \(endTime)). They are 1 min apart and in order.

        Create an activity log detailed enough that someone could reconstruct what
        the user did.

        For each segment, ask yourself: "What EXACTLY did they do? What SPECIFIC
        things can I see?"

        Capture from screenshots:
        - Exact app/site names visible
        - Exact file names, URLs, page titles
        - Exact usernames, search queries, messages
        - Exact numbers, stats, prices shown

        Bad: "Checked email"
        Good: "Gmail: Read email from boss@company.com 'RE: Budget approval' - replied 'Looks good'"

        Bad: "Browsing Twitter"
        Good: "Twitter/X: Scrolled feed - viewed posts by @pmarca about AI, @sama thread on GPT-5 (12 tweets)"

        Bad: "Working on code"
        Good: "VS Code: Editing StorageManager.swift - fixed type error on line 47, changed String to String?"

        3-8 segments total.
        Exception: You may use 1 segment only if the user appears idle for most of the recording.
        Group by GOAL not app (debugging across IDE+Terminal+Browser = 1 segment).

        Timestamps must start at \(startTime) and end at \(endTime). No gaps.

        Return JSON only:
        {"segments":[{"start":"HH:MM:SS","end":"HH:MM:SS","description":"..."}]}
        """
    }

    private func parseSegments(from output: String, stderr: String) throws -> [SegmentMergeResponse.Segment] {
        // First try parsing without any modifications
        let basicCleaned = output
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var lastDecodeError: String?

        // Strategy 1: Direct decode
        if let data = basicCleaned.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(SegmentMergeResponse.self, from: data),
           !parsed.segments.isEmpty {
            return parsed.segments
        }

        // Strategy 2: Array decode
        if let data = basicCleaned.data(using: .utf8),
           let parsed = try? JSONDecoder().decode([SegmentMergeResponse.Segment].self, from: data),
           !parsed.isEmpty {
            return parsed
        }

        // Strategy 3: Brace extraction
        if let firstBrace = basicCleaned.firstIndex(of: "{"),
           let lastBrace = basicCleaned.lastIndex(of: "}"),
           firstBrace < lastBrace {
            let slice = String(basicCleaned[firstBrace...lastBrace])
            if let data = slice.data(using: .utf8),
               let parsed = try? JSONDecoder().decode(SegmentMergeResponse.self, from: data),
               !parsed.segments.isEmpty {
                return parsed.segments
            }
        }

        // Strategy 4 (fallback): Strip OSC escapes and retry brace extraction
        let oscCleaned = stripOSCEscapes(basicCleaned)
        if let firstBrace = oscCleaned.firstIndex(of: "{"),
           let lastBrace = oscCleaned.lastIndex(of: "}"),
           firstBrace < lastBrace {
            let slice = String(oscCleaned[firstBrace...lastBrace])
            if let data = slice.data(using: .utf8) {
                do {
                    let parsed = try JSONDecoder().decode(SegmentMergeResponse.self, from: data)
                    if !parsed.segments.isEmpty { return parsed.segments }
                } catch {
                    lastDecodeError = "Strategy 4 (OSC strip + brace): \(error.localizedDescription)"
                }
            }
        } else {
            lastDecodeError = "No JSON object found in output"
        }

        // Log full raw output to PostHog for debugging decode failures
        AnalyticsService.shared.capture("llm_decode_failed", [
            "provider": "chat_cli",
            "operation": "parse_segments",
            "tool": tool.rawValue,
            "raw_output": output,
            "output_length": output.count,
            "stderr": stderr,
            "stderr_length": stderr.count,
            "decode_error": lastDecodeError ?? "no JSON found"
        ])

        // Surface CLI error messages to the user if available
        if let cliError = extractCLIError(stdout: output, stderr: stderr) {
            throw NSError(domain: "ChatCLI", code: -33, userInfo: [NSLocalizedDescriptionKey: cliError])
        }

        throw NSError(domain: "ChatCLI", code: -31, userInfo: [NSLocalizedDescriptionKey: "Failed to decode segments JSON"])
    }

    private func validateSegments(_ segments: [SegmentMergeResponse.Segment], duration: TimeInterval) -> String? {
        guard !segments.isEmpty else { return "No segments returned." }

        let tolerance: TimeInterval = 2.0
        var parsed: [(start: TimeInterval, end: TimeInterval, description: String)] = []

        for segment in segments {
            let startSeconds = TimeInterval(parseVideoTimestamp(segment.start))
            let endSeconds = TimeInterval(parseVideoTimestamp(segment.end))
            if endSeconds <= startSeconds {
                return "Segment end time must be after start time: \(segment.start) -> \(segment.end)"
            }
            if startSeconds < 0 {
                return "Segment start time must be >= 00:00:00 (got \(segment.start))."
            }
            if duration > 0, endSeconds > duration + tolerance {
                return "Segment out of bounds: \(segment.start) -> \(segment.end) (duration \(formatSeconds(duration)))"
            }
            parsed.append((startSeconds, endSeconds, segment.description))
        }

        let ordered = parsed.sorted { $0.start < $1.start }
        if duration > 0, let first = ordered.first, first.start > tolerance {
            return "First segment must start at 00:00:00 (starts at \(formatSeconds(first.start)))."
        }

        for i in 1..<ordered.count {
            let prev = ordered[i - 1]
            let next = ordered[i]
            let gap = next.start - prev.end
            if gap > tolerance {
                return "Gap detected between segments: \(formatSeconds(prev.end)) -> \(formatSeconds(next.start))"
            }
            if gap < -tolerance {
                return "Overlap detected between segments: \(formatSeconds(next.start)) starts before \(formatSeconds(prev.end))"
            }
        }

        if duration > 0, let last = ordered.last, duration - last.end > tolerance {
            return "Last segment must end at \(formatSeconds(duration)) (ends at \(formatSeconds(last.end)))."
        }

        return nil
    }

    /// Transcribe observations from screenshots using a single-shot prompt.
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

        let firstTs = sortedScreenshots.first!.capturedAt
        let lastTs = sortedScreenshots.last!.capturedAt
        let durationSeconds = TimeInterval(lastTs - firstTs)
        let durationString = formatSeconds(durationSeconds)

        let imagePaths: [String] = sampledScreenshots.compactMap { screenshot in
            guard FileManager.default.fileExists(atPath: screenshot.filePath) else {
                print("[ChatCLI] ⚠️ Screenshot file not found: \(screenshot.filePath)")
                return nil
            }

            return screenshot.filePath
        }

        guard !imagePaths.isEmpty else {
            throw NSError(
                domain: "ChatCLI",
                code: -97,
                userInfo: [NSLocalizedDescriptionKey: "No valid screenshot files found"]
            )
        }

        let model: String
        let effort: String?
        switch tool {
        case .claude:
            model = "haiku"
            effort = nil
        case .codex:
            model = "gpt-5.1-codex-mini"
            effort = "low"
        }

        let basePrompt = buildScreenshotTranscriptionPrompt(
            numFrames: imagePaths.count,
            duration: durationString,
            startTime: "00:00:00",
            endTime: durationString
        )
        var actualPrompt = basePrompt
        var lastError: Error?
        var lastRun: ChatCLIRunResult?

        let maxTranscribeAttempts = 3
        for attempt in 1...maxTranscribeAttempts {
            do {
                let run = try runAndScrub(prompt: actualPrompt, imagePaths: imagePaths, model: model, reasoningEffort: effort)
                lastRun = run

                let segments = try parseSegments(from: run.stdout, stderr: run.stderr)
                if let validationError = validateSegments(segments, duration: durationSeconds) {
                    lastError = NSError(domain: "ChatCLI", code: -98, userInfo: [NSLocalizedDescriptionKey: validationError])
                    actualPrompt = basePrompt + "\n\nPREVIOUS ATTEMPT FAILED - FIX THE FOLLOWING:\n" + validationError + "\n\nReturn JSON only."
                    if attempt < maxTranscribeAttempts {
                        print("[ChatCLI] Screenshot transcribe validation failed (attempt \(attempt)): \(validationError)")
                        let backoffSeconds = pow(2.0, Double(attempt - 1)) * 2.0
                        try await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
                        continue
                    }
                } else {
                    let ordered = segments.sorted { parseVideoTimestamp($0.start) < parseVideoTimestamp($1.start) }
                    var observations: [Observation] = []
                    for segment in ordered {
                        let startSeconds = TimeInterval(parseVideoTimestamp(segment.start))
                        let endSeconds = TimeInterval(parseVideoTimestamp(segment.end))
                        let clampedStart = max(0.0, startSeconds)
                        let clampedEnd = durationSeconds > 0 ? min(endSeconds, durationSeconds) : endSeconds
                        guard clampedEnd > clampedStart else { continue }

                        let startDate = batchStartTime.addingTimeInterval(clampedStart)
                        let endDate = batchStartTime.addingTimeInterval(clampedEnd)
                        let startEpoch = Int(startDate.timeIntervalSince1970)
                        let endEpoch = max(startEpoch + 1, Int(endDate.timeIntervalSince1970))

                        let trimmedDescription = segment.description.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmedDescription.isEmpty { continue }

                        observations.append(
                            Observation(
                                id: nil,
                                batchId: batchId ?? -1,
                                startTs: startEpoch,
                                endTs: endEpoch,
                                observation: trimmedDescription,
                                metadata: nil,
                                llmModel: tool.rawValue,
                                createdAt: Date()
                            )
                        )
                    }

                    if observations.isEmpty {
                        lastError = NSError(domain: "ChatCLI", code: -99, userInfo: [NSLocalizedDescriptionKey: "No observations could be created from segments."])
                        if attempt < maxTranscribeAttempts {
                            let backoffSeconds = pow(2.0, Double(attempt - 1)) * 2.0
                            try await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
                            continue
                        }
                    } else {
                        let finishedAt = run.finishedAt
                        logSuccess(ctx: makeCtx(batchId: batchId, operation: "transcribe_screenshots", startedAt: callStart, attempt: attempt), finishedAt: finishedAt, stdout: run.stdout, stderr: run.stderr, responseHeaders: tokenHeaders(from: run.usage))
                        let llmCall = makeLLMCall(start: callStart, end: finishedAt, input: actualPrompt, output: run.stdout)
                        return (observations, llmCall)
                    }
                }
            } catch {
                lastError = error
                if attempt < maxTranscribeAttempts {
                    print("[ChatCLI] Screenshot transcribe attempt \(attempt) failed: \(error.localizedDescription) — retrying")
                    let backoffSeconds = pow(2.0, Double(attempt - 1)) * 2.0
                    try await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
                    continue
                }

                break
            }
        }

        let finishedAt = lastRun?.finishedAt ?? Date()
        let finalError = lastError ?? NSError(domain: "ChatCLI", code: -99, userInfo: [
            NSLocalizedDescriptionKey: "Screenshot transcription failed after \(maxTranscribeAttempts) attempts from \(imagePaths.count) screenshots"
        ])
        logFailure(ctx: makeCtx(batchId: batchId, operation: "transcribe_screenshots", startedAt: callStart, attempt: maxTranscribeAttempts), finishedAt: finishedAt, error: finalError, stdout: lastRun?.stdout, stderr: lastRun?.stderr)
        throw finalError
    }

    // MARK: - Text Generation (Streaming)

    /// Stream chat responses with real-time thinking and tool execution events
    /// - Parameter sessionId: Optional session ID to resume a previous conversation
    func generateChatStreaming(prompt: String, sessionId: String? = nil) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let model: String
        let effort: String?
        switch tool {
        case .claude:
            model = "sonnet"
            effort = nil
        case .codex:
            model = "gpt-5.2"
            effort = "low"
        }

        return runner.runStreaming(
            tool: tool,
            prompt: prompt,
            workingDirectory: config.workingDirectory,
            model: model,
            reasoningEffort: effort,
            sessionId: sessionId
        )
    }

    /// Stream text-only output for protocol conformance
    func generateTextStreaming(prompt: String) -> AsyncThrowingStream<String, Error> {
        let stream = generateChatStreaming(prompt: prompt)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await event in stream {
                        switch event {
                        case .textDelta(let chunk):
                            continuation.yield(chunk)
                        case .error(let message):
                            continuation.finish(throwing: NSError(
                                domain: "ChatCLI",
                                code: -1,
                                userInfo: [NSLocalizedDescriptionKey: message]
                            ))
                            return
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Text Generation (Non-Streaming)

    func generateText(prompt: String) async throws -> (text: String, log: LLMCall) {
        let callStart = Date()
        let ctx = makeCtx(batchId: nil, operation: "generateText", startedAt: callStart)

        let model: String
        switch tool {
        case .claude:
            model = "sonnet"
        case .codex:
            model = "gpt-5.2"
        }

        let run: ChatCLIRunResult
        do {
            run = try await Task.detached {
                // Enable tools so LLM can query the database directly
                try self.runAndScrub(prompt: prompt, model: model, reasoningEffort: "high", disableTools: false)
            }.value
        } catch {
            logFailure(ctx: ctx, finishedAt: Date(), error: error)
            throw error
        }

        guard run.exitCode == 0 else {
            let errorMessage = run.stderr.isEmpty ? "CLI exited with code \(run.exitCode)" : run.stderr
            let error = NSError(domain: "ChatCLI", code: Int(run.exitCode), userInfo: [NSLocalizedDescriptionKey: errorMessage])
            logFailure(ctx: ctx, finishedAt: run.finishedAt, error: error, stdout: run.stdout, stderr: run.stderr)
            throw error
        }

        logSuccess(ctx: ctx, finishedAt: run.finishedAt, stdout: run.stdout, stderr: run.stderr, responseHeaders: tokenHeaders(from: run.usage))

        // Parse thinking - Codex puts it in stdout, Claude in stderr
        let thinking: String?
        if tool == .codex {
            thinking = runner.parseThinkingFromOutput(run.rawStdout)
        } else {
            thinking = parseThinkingFromStderr(run.stderr)
        }

        let log = makeLLMCall(start: callStart, end: run.finishedAt, input: prompt, output: run.stdout)

        // Return text with thinking prefix if present (ChatService will split on marker)
        let text = run.stdout.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if let thinking = thinking, !thinking.isEmpty {
            return ("---THINKING---\n\(thinking)\n---END_THINKING---\n\(text)", log)
        }
        return (text, log)
    }

    private func parseVideoTimestamp(_ timestamp: String) -> Int {
        let components = timestamp.components(separatedBy: ":")

        if components.count == 3 {
            guard let hours = Int(components[0]),
                  let minutes = Int(components[1]),
                  let seconds = Int(components[2]) else {
                return 0
            }
            return hours * 3600 + minutes * 60 + seconds
        } else if components.count == 2 {
            guard let minutes = Int(components[0]),
                  let seconds = Int(components[1]) else {
                return 0
            }
            return minutes * 60 + seconds
        }

        return 0
    }

    private func formatTimestampForPrompt(_ unixTime: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixTime))
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }
}
