//
//  OpenRouterProvider+Transcription.swift
//  Dayflow
//
//  Screenshot transcription via OpenRouter's vision API.
//  Sends screen grabs as base64 images in the OpenAI chat format.
//

import AppKit
import Foundation

extension OpenRouterProvider {

    /// Transcribe a batch of screenshots into observations using the vision model.
    func transcribeScreenshots(
        _ screenshots: [Screenshot],
        batchStartTime: Date,
        batchId: Int64?
    ) async throws -> (observations: [Observation], log: LLMCall) {
        let callStart = Date()

        guard !screenshots.isEmpty else {
            return ([], LLMCall(timestamp: callStart, latency: 0, input: "", output: ""))
        }

        // Limit how many screenshots we send to avoid token blowout
        let maxFrames = 20
        let sampled = screenshots.count <= maxFrames
            ? screenshots
            : stride(from: 0, to: screenshots.count, by: max(1, screenshots.count / maxFrames))
                .map { screenshots[$0] }

        // Build timestamped image content
        var contentParts: [ORContentPart] = []
        let transcriptionPrompt = """
        You are analyzing a series of screenshots from someone's computer taken over a period of time.
        Describe what the person was doing in each screenshot. Be specific about:
        - What application or website is visible
        - What they appear to be working on
        - Any notable content on screen (files, messages, code, etc.)

        Keep each description to 1-2 sentences. Focus on being factual and specific.
        Timestamps are shown in the format MM:SS from the start of the recording.
        """

        contentParts.append(ORContentPart(type: "text", text: transcriptionPrompt, image_url: nil))

        for (index, screenshot) in sampled.enumerated() {
            // Better screenshot timestamps from actual capture time
            let timing = Double(screenshot.capturedAt) - batchStartTime.timeIntervalSince1970
            let minutes = Int(timing) / 60
            let seconds = Int(timing) % 60

            // Get the screenshot image data
            guard let imageData = try? Data(contentsOf: screenshot.fileURL) else {
                continue
            }

            // Downsize to ~720p
            let resized = resizeImageData(imageData, maxDimension: 720)
            let base64 = resized.base64EncodedString()

            let timeLabel = String(format: "[%02d:%02d]", minutes, seconds)
            contentParts.append(ORContentPart(type: "text", text: timeLabel, image_url: nil))
            contentParts.append(ORContentPart(
                type: "image_url",
                text: nil,
                image_url: ORContentPart.ORImageURL(url: "data:image/jpeg;base64,\(base64)")
            ))
        }

        let message = ORMessage(role: "user", content: contentParts)

        let (response, usedModel) = try await callChatAPI(
            messages: [message],
            operation: "transcribe_screenshots",
            batchId: batchId,
            maxRetries: 2
        )

        let rawText = response.choices.first?.message.content ?? ""

        // Parse the text into observations
        let observations = parseTranscriptionResponse(rawText, batchStartTime: batchStartTime, screenshotCount: screenshots.count)

        let latency = Date().timeIntervalSince(callStart)
        let log = LLMCall(
            timestamp: callStart,
            latency: latency,
            input: "Transcribed \(screenshots.count) screenshots via \(usedModel)",
            output: rawText
        )

        return (observations, log)
    }

    // MARK: - Transcription Parsing

    private func parseTranscriptionResponse(
        _ text: String,
        batchStartTime: Date,
        screenshotCount: Int
    ) -> [Observation] {
        // Split into lines and try to extract observations
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return [] }

        var observations: [Observation] = []
        let baseTimestamp = Int(batchStartTime.timeIntervalSince1970)
        let interval = max(1, (screenshotCount * 10) / max(1, lines.count))

        for (i, line) in lines.enumerated() {
            let clean = line
                .replacingOccurrences(of: #"^\[\d{2}:\d{2}\]\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)

            guard !clean.isEmpty else { continue }

            let startTs = baseTimestamp + (i * interval)
            let endTs = startTs + interval

            observations.append(Observation(
                observation: clean,
                startTs: startTs,
                endTs: endTs,
                apps: extractApps(from: clean)
            ))
        }

        return observations
    }

    private func extractApps(from text: String) -> [String] {
        let knownApps = [
            "Xcode", "VS Code", "Cursor", "Zed", "Terminal", "iTerm",
            "Chrome", "Safari", "Firefox", "Arc", "Brave",
            "Slack", "Discord", "Teams", "Zoom",
            "Mail", "Gmail", "Outlook",
            "Finder", "Notes", "Notion", "Obsidian",
            "Photoshop", "Figma", "Sketch",
            "Spotify", "Music", "Calendar",
            "GitHub", "GitLab",
        ]
        let lower = text.lowercased()
        return knownApps.filter { lower.contains($0.lowercased()) }
    }

    // MARK: - Image Resizing

    private func resizeImageData(_ data: Data, maxDimension: CGFloat) -> Data {
        guard let image = NSImage(data: data) else { return data }

        let size = image.size
        let scale = min(maxDimension / max(size.width, size.height), 1.0)
        let newWidth = max(1, Int(size.width * scale))
        let newHeight = max(1, Int(size.height * scale))
        let newSize = NSSize(width: CGFloat(newWidth), height: CGFloat(newHeight))

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return data
        }

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: newWidth,
            pixelsHigh: newHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ),
        let ctx = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return data
        }

        bitmap.size = newSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(origin: .zero, size: newSize))
        NSGraphicsContext.restoreGraphicsState()

        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) ?? data
    }
}

// MARK: - Text Generation (LLMCall compatible)

extension OpenRouterProvider {
    func generateTextStreaming(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let result = try await self.generateText(prompt: prompt)
                    continuation.yield(result.text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - Activity Card Generation

extension OpenRouterProvider {
    func generateActivityCards(
        observations: [Observation],
        context: ActivityGenerationContext,
        batchId: Int64?
    ) async throws -> (cards: [ActivityCardData], log: LLMCall) {
        let callStart = Date()

        let sortedObs = observations.sorted { $0.startTs < $1.startTs }
        guard let first = sortedObs.first, let last = sortedObs.last else {
            return ([], LLMCall(timestamp: callStart, latency: 0, input: "", output: ""))
        }

        let obsText = sortedObs.map { obs in
            let start = formatTimestamp(obs.startTs)
            let end = formatTimestamp(obs.endTs)
            return "\(start)-\(end): \(obs.observation)"
        }.joined(separator: "\n")

        let categoriesDesc = context.categories.map { "\($0.name): \($0.description ?? "")" }.joined(separator: "\n")

        let prompt = """
        You are analyzing a work journal. Based on the following observations, create a single activity card.
        Categories available:
        \(categoriesDesc)

        Observations:
        \(obsText)

        Return a JSON object with these fields:
        {
          "category": "one of the categories above",
          "subcategory": "a more specific subcategory",
          "title": "a concise title (max 8 words)",
          "summary": "1-2 sentence summary of what was done"
        }

        Return ONLY valid JSON, no other text.
        """

        let raw = try await callTextAPI(prompt, operation: "generate_cards", expectJSON: true, batchId: batchId, maxTokens: 2000)

        // Parse JSON response
        let card = parseActivityCard(raw, startTime: formatTimestamp(first.startTs), endTime: formatTimestamp(last.endTs))

        let log = LLMCall(
            timestamp: callStart,
            latency: Date().timeIntervalSince(callStart),
            input: prompt,
            output: raw
        )

        return ([card], log)
    }

    private func parseActivityCard(_ jsonText: String, startTime: String, endTime: String) -> ActivityCardData {
        struct RawCard: Codable {
            let category: String?
            let subcategory: String?
            let title: String?
            let summary: String?
        }

        // Try to extract JSON from response
        let cleaned: String
        if let start = jsonText.firstIndex(of: "{"),
           let end = jsonText.lastIndex(of: "}") {
            cleaned = String(jsonText[start...end])
        } else {
            cleaned = jsonText
        }

        if let data = cleaned.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(RawCard.self, from: data) {
            return ActivityCardData(
                startTime: startTime,
                endTime: endTime,
                category: parsed.category ?? "General",
                subcategory: parsed.subcategory ?? "",
                title: parsed.title ?? "Activity",
                summary: parsed.summary ?? observationsSummary(from: cleaned),
                detailedSummary: "",
                distractions: nil,
                appSites: nil
            )
        }

        return ActivityCardData(
            startTime: startTime,
            endTime: endTime,
            category: "General",
            subcategory: "",
            title: "Activity",
            summary: observationsSummary(from: cleaned),
            detailedSummary: "",
            distractions: nil,
            appSites: nil
        )
    }

    private func observationsSummary(from text: String) -> String {
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.prefix(3).joined(separator: "; ")
    }

    private func formatTimestamp(_ ts: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current
        return fmt.string(from: date)
    }
}