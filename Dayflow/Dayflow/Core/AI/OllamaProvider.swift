//
//  OllamaProvider.swift
//  Dayflow
//

import Foundation
import AVFoundation
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

final class OllamaProvider: LLMProvider {
    private let endpoint: String
    private let frameExtractionInterval: TimeInterval = 30.0 // Extract frame every 30 seconds
    
    init(endpoint: String = "http://localhost:1234") {
        self.endpoint = endpoint
    }
    
    func transcribeVideo(videoData: Data, mimeType: String, prompt: String, batchStartTime: Date, videoDuration: TimeInterval) async throws -> (observations: [Observation], log: LLMCall) {
        let callStart = Date()
        
        // Save video to temporary file for processing
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        try videoData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        // Step 1: Extract frames at intervals
        let extractionStart = Date()
        let frames = try await extractFrames(from: tempURL)
        let extractionTime = Date().timeIntervalSince(extractionStart)
        
        
        // Step 2: Get simple descriptions for each frame
        var frameDescriptions: [(timestamp: TimeInterval, description: String)] = []
        
        for (index, frame) in frames.enumerated() {
            let frameStart = Date()
            
            let description = try await getSimpleFrameDescription(frame)
            frameDescriptions.append((timestamp: frame.timestamp, description: description))
            
            let frameTime = Date().timeIntervalSince(frameStart)
        }
        
        // Step 3: Merge frame descriptions into coherent observations
        let mergeStart = Date()
        let observations = try await mergeFrameDescriptions(frameDescriptions, batchStartTime: batchStartTime, videoDuration: videoDuration)
        let mergeTime = Date().timeIntervalSince(mergeStart)
        
        
        let totalTime = Date().timeIntervalSince(callStart)
        
        let log = LLMCall(
            timestamp: callStart,
            latency: totalTime,
            input: "Two-stage processing: \(frames.count) frames → \(observations.count) observations",
            output: "Extracted \(frames.count) frames, merged into \(observations.count) observations in \(String(format: "%.2f", totalTime))s"
        )
        
        return (observations, log)
    }
    
    func generateActivityCards(observations: [Observation], context: ActivityGenerationContext) async throws -> (cards: [ActivityCard], log: LLMCall) {
        let callStart = Date()
        var logs: [String] = []
        
        let sortedObservations = context.batchObservations.sorted { $0.startTs < $1.startTs }
        
        
        // Generate initial activity card for these observations
        let (titleSummary, firstLog) = try await generateTitleAndSummary(observations: sortedObservations)
        logs.append(firstLog)
        
        let initialCard = ActivityCard(
            startTime: formatTimestampForPrompt(sortedObservations.first!.startTs),
            endTime: formatTimestampForPrompt(sortedObservations.last!.endTs),
            category: titleSummary.category,
            subcategory: "",
            title: titleSummary.title,
            summary: titleSummary.summary,
            detailedSummary: "",
            distractions: nil
        )
        
        var allCards = context.existingCards
        
        // Check if we should merge with the last existing card
        if !allCards.isEmpty, let lastExistingCard = allCards.last {
            // Hard cap: Don't even try to merge if the last card is already 25+ minutes
            let lastCardDuration = calculateDurationInMinutes(from: lastExistingCard.startTime, to: lastExistingCard.endTime)
            
            print("[DEBUG] Last card: \(lastExistingCard.startTime) - \(lastExistingCard.endTime) (\(lastCardDuration) minutes)")
            print("[DEBUG] New card: \(initialCard.startTime) - \(initialCard.endTime)")
            
            if lastCardDuration >= 40 {
                print("[DEBUG] Skipping merge - last card already \(lastCardDuration) minutes")
                allCards.append(initialCard)
            } else {
                let (shouldMerge, mergeLog) = try await checkShouldMerge(previousCard: lastExistingCard, newCard: initialCard)
                logs.append(mergeLog)
                
                print("[DEBUG] Merge decision: \(shouldMerge)")
                
                if shouldMerge {
                    let (mergedCard, mergeCreateLog) = try await mergeTwoCards(previousCard: lastExistingCard, newCard: initialCard)
                    logs.append(mergeCreateLog)
                    
                    let mergedDuration = calculateDurationInMinutes(from: mergedCard.startTime, to: mergedCard.endTime)
                    print("[DEBUG] Merged card: \(mergedCard.startTime) - \(mergedCard.endTime) (\(mergedDuration) minutes)")
                    
                    // Replace the last card with the merged version
                    allCards[allCards.count - 1] = mergedCard
                } else {
                    // Add as new card
                    allCards.append(initialCard)
                }
            }
        } else {
            // No existing cards, just add the initial card
            print("[DEBUG] No existing cards, adding initial card")
            allCards.append(initialCard)
        }
        
        let totalLatency = Date().timeIntervalSince(callStart)
        
        
        let combinedLog = LLMCall(
            timestamp: callStart,
            latency: totalLatency,
            input: "Two-pass activity card generation",
            output: logs.joined(separator: "\n\n---\n\n")
        )
        
        return (allCards, combinedLog)
    }
    
    private func parseActivityCards(from data: Data) throws -> [ActivityCard] {
        // Define response structure
        struct ResponseCard: Codable {
            let startTime: String
            let endTime: String
            let category: String
            let subcategory: String
            let title: String
            let summary: String
            let detailedSummary: String
            let distractions: [ResponseDistraction]?
        }
        
        struct ResponseDistraction: Codable {
            let startTime: String
            let endTime: String
            let title: String
            let summary: String
        }
        
        // Helper function to convert ResponseCard to ActivityCard
        func convertCard(_ card: ResponseCard) -> ActivityCard {
            return ActivityCard(
                startTime: card.startTime,
                endTime: card.endTime,
                category: card.category,
                subcategory: card.subcategory,
                title: card.title,
                summary: card.summary,
                detailedSummary: card.detailedSummary,
                distractions: card.distractions?.map { d in
                    Distraction(
                        startTime: d.startTime,
                        endTime: d.endTime,
                        title: d.title,
                        summary: d.summary
                    )
                }
            )
        }
        
        // First try to decode as array
        do {
            let responseCards = try JSONDecoder().decode([ResponseCard].self, from: data)
            return responseCards.map(convertCard)
        } catch {
            // Try to decode as single object
            do {
                let singleCard = try JSONDecoder().decode(ResponseCard.self, from: data)
                return [convertCard(singleCard)]
            } catch {
                // If that fails, try to extract JSON from the response
            
            guard let responseString = String(data: data, encoding: .utf8) else {
                throw NSError(domain: "OllamaProvider", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to decode response as string"])
            }
            
            // Try to find JSON array in the response
            if let startIndex = responseString.firstIndex(of: "["),
               let endIndex = responseString.lastIndex(of: "]") {
                let jsonSubstring = responseString[startIndex...endIndex]
                if let jsonData = jsonSubstring.data(using: .utf8) {
                    let responseCards = try JSONDecoder().decode([ResponseCard].self, from: jsonData)
                    return responseCards.map(convertCard)
                }
            }
            
                throw NSError(domain: "OllamaProvider", code: 7, userInfo: [NSLocalizedDescriptionKey: "Could not find valid JSON array in response: \(error.localizedDescription)"])
            }
        }
    }
    
    // MARK: - Frame Extraction
    
    private struct FrameData {
        let image: Data  // Base64 encoded image
        let timestamp: TimeInterval  // Seconds from video start
    }
    
    private func extractFrames(from videoURL: URL) async throws -> [FrameData] {
        let asset = AVAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        
        
        guard durationSeconds > 0 else {
            throw NSError(domain: "OllamaProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid video duration"])
        }
        
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
        
        var frames: [FrameData] = []
        var currentTime: TimeInterval = 0
        
        while currentTime < durationSeconds {
            let cmTime = CMTime(seconds: currentTime, preferredTimescale: 600)
            
            do {
                let cgImage = try generator.copyCGImage(at: cmTime, actualTime: nil)
                
                // Convert CGImage to JPEG data
                // Downscale by 2/3 for optimal quality/size balance
                if let scaledImage = downscaleImage(cgImage: cgImage, scale: 2.0/3.0) {
                    if let imageData = cgImageToJPEGData(scaledImage) {
                        // Convert to base64
                        let base64String = imageData.base64EncodedString()
                        let base64Data = Data(base64String.utf8)
                        
                        frames.append(FrameData(image: base64Data, timestamp: currentTime))
                    }
                }
            } catch {
                print("[OLLAMA] WARNING: Failed to extract frame at \(currentTime)s: \(error)")
            }
            
            currentTime += frameExtractionInterval
        }
        
        return frames
    }
    
    private func downscaleImage(cgImage: CGImage, scale: CGFloat) -> CGImage? {
        
        // Create CIImage and apply Lanczos scaling
        let ciImage = CIImage(cgImage: cgImage)
        
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        
        guard var outputImage = filter.outputImage else { return nil }
        
        // Apply slight sharpening for text clarity
        if let sharpen = CIFilter(name: "CISharpenLuminance") {
            sharpen.setValue(outputImage, forKey: kCIInputImageKey)
            sharpen.setValue(0.3, forKey: "inputSharpness")
            outputImage = sharpen.outputImage ?? outputImage
        }
        
        // Render with high quality
        let context = CIContext(options: [
            .highQualityDownsample: true
        ])
        
        return context.createCGImage(outputImage, from: outputImage.extent)
    }
    
    private func cgImageToJPEGData(_ cgImage: CGImage) -> Data? {
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        
        // Higher quality JPEG for better text
        let jpegData = bitmapRep.representation(using: .jpeg, properties: [
            NSBitmapImageRep.PropertyKey.compressionFactor: 0.95
        ])
        
        
        return jpegData
    }
    
    // MARK: - OpenAI-Compatible API
    
    private struct ChatRequest: Codable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double = 0.7
        let max_tokens: Int = -1
        let stream: Bool = false
    }
    
    private struct ChatMessage: Codable {
        let role: String
        let content: [MessageContent]
    }
    
    private struct MessageContent: Codable {
        let type: String
        let text: String?
        let image_url: ImageURL?
        
        struct ImageURL: Codable {
            let url: String
        }
    }
    
    private struct ChatResponse: Codable {
        let choices: [Choice]
        
        struct Choice: Codable {
            let message: ResponseMessage
        }
        
        struct ResponseMessage: Codable {
            let content: String
        }
    }
    
    private func getSimpleFrameDescription(_ frame: FrameData) async throws -> String {
        // Simple prompt focused on just describing what's happening
        let prompt = """
        Describe what you see on this computer screen in 1-2 sentences.
        Focus on: what application is open, what the user is doing, and any relevant details visible.
        Be specific and factual.
        
        GOOD EXAMPLES:
        ✓ "VS Code open with index.js file, writing a React component for user authentication."
        ✓ "Gmail compose window writing email to client@company.com about project timeline."
        ✓ "Slack conversation in #engineering channel discussing API rate limiting issues."
        
        BAD EXAMPLES:
        ✗ "User is coding" (too vague)
        ✗ "Looking at a website" (doesn't identify which site)
        ✗ "Working on computer" (completely non-specific)
        """
        
        // Convert base64 data back to string
        guard let base64String = String(data: frame.image, encoding: .utf8) else {
            throw NSError(domain: "OllamaProvider", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to convert image data"])
        }
        
        // Build message content with image and text
        var content: [MessageContent] = [
            MessageContent(type: "text", text: prompt, image_url: nil),
            MessageContent(type: "image_url", text: nil, image_url: MessageContent.ImageURL(url: "data:image/jpeg;base64,\(base64String)"))
        ]
        
        let request = ChatRequest(
            model: "google/gemma-3n-e4b",
            messages: [
                ChatMessage(role: "user", content: content)
            ]
        )
        
        let response = try await callChatAPI(request)
        
        // Return the raw text response (no JSON parsing needed for simple descriptions)
        return response.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    
    private func callChatAPI(_ request: ChatRequest) async throws -> ChatResponse {
        let url = URL(string: "\(endpoint)/v1/chat/completions")!
        
        // Retry logic with exponential backoff
        let maxRetries = 3
        var lastError: Error?
        
        for attempt in 0..<maxRetries {
            do {
                var urlRequest = URLRequest(url: url)
                urlRequest.httpMethod = "POST"
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                urlRequest.httpBody = try JSONEncoder().encode(request)
                urlRequest.timeoutInterval = 30.0  // 30-second timeout
                
                let apiStart = Date()
                let (data, response) = try await URLSession.shared.data(for: urlRequest)
                let apiTime = Date().timeIntervalSince(apiStart)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NSError(domain: "OllamaProvider", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
                }
                
                
                guard httpResponse.statusCode == 200 else {
                    let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                    throw NSError(domain: "OllamaProvider", code: 4, userInfo: [NSLocalizedDescriptionKey: "Ollama API request failed with status \(httpResponse.statusCode): \(errorBody)"])
                }
                
                
                do {
                    let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)
                    return chatResponse
                } catch {
                    throw error
                }
                
            } catch {
                lastError = error
                print("[OLLAMA] Request failed (attempt \(attempt + 1)/\(maxRetries)): \(error)")
                
                // If it's not the last attempt, wait before retrying
                if attempt < maxRetries - 1 {
                    let backoffDelay = pow(2.0, Double(attempt)) * 2.0 // 2s, 4s, 8s
                    try await Task.sleep(nanoseconds: UInt64(backoffDelay * 1_000_000_000))
                }
            }
        }
        
        throw lastError ?? NSError(domain: "OllamaProvider", code: 4, userInfo: [NSLocalizedDescriptionKey: "Request failed after \(maxRetries) attempts"])
    }
    
    // Helper method for text-only requests
    private func callTextAPI(_ prompt: String, expectJSON: Bool = false) async throws -> String {
        let systemPrompt = expectJSON ? "You are a helpful assistant. Always respond with valid JSON." : "You are a helpful assistant."
        
        let request = ChatRequest(
            model: "google/gemma-3n-e4b",
            messages: [
                ChatMessage(role: "system", content: [MessageContent(type: "text", text: systemPrompt, image_url: nil)]),
                ChatMessage(role: "user", content: [MessageContent(type: "text", text: prompt, image_url: nil)])
            ]
        )
        
        let response = try await callChatAPI(request)
        return response.choices.first?.message.content ?? ""
    }
    
    // MARK: - Two-Pass Activity Card Generation
    
    private struct TitleSummaryResponse: Codable {
        let reasoning: String
        let title: String
        let summary: String
        let category: String
    }
    
    private func generateTitleAndSummary(observations: [Observation]) async throws -> (TitleSummaryResponse, String) {
        let observationsText = observations.map { obs in
            let startTime = formatTimestampForPrompt(obs.startTs)
            let endTime = formatTimestampForPrompt(obs.endTs)
            return "[\(startTime) - \(endTime)]: \(obs.observation)"
        }.joined(separator: "\n")
        
        let prompt = """
        You are observing someone's computer activity from the last 15 minutes.
        
        Here are the observations:
        \(observationsText)
        
        Create a title and summary following these guidelines:
        
        TITLE GUIDELINES:
        Write titles like you're texting a friend about what you did. Natural, conversational, direct.
        Keep it short - aim for 5-10 words. Be specific, not vague.
        
        GOOD EXAMPLES:
        ✓ "Fixed CORS bugs in API endpoints" - specific action + what
        ✓ "Python pandas tutorial on DataCamp" - learning activity + platform  
        ✓ "Wrote docs, kept checking Twitter" - honest about distractions
        ✓ "Debugged auth flow, tested endpoints" - two related actions
        ✓ "Reddit rabbit hole about React patterns" - casual and honest
        ✓ "Figured out that timezone bug finally!" - conversational with emotion
        
        BAD EXAMPLES:
        ✗ "Early morning digital drift" 
          WHY BAD: Too vague and poetic. What were you actually doing?
        ✗ "Extended Browsing Session" 
          WHY BAD: "Session" is formal. Just say what sites you visited!
        ✗ "Working on the computer" 
          WHY BAD: Completely generic. Working on what exactly?
        ✗ "Working on Dayflow project"
          WHY BAD: "Working on" is lazy. Say what you DID: debugged? coded? tested?
        ✗ "AI-assisted research activities"
          WHY BAD: "Activities" is formal corporate-speak. Be specific!
        
        SUMMARY GUIDELINES:
        Write like you're catching up a friend on what you did. Natural, casual, conversational.
        FIRST PERSON perspective without using "I" - like writing in your own journal.
        Maximum 2-3 sentences. Include specific details.
        
        ⚠️ NEVER EVER say "The user", "User", or "They" - ALL FORBIDDEN!
        ⚠️ Write in FIRST PERSON without "I": "Debugged the API" not "They debugged"
        ⚠️ Start sentences with VERBS: "Debugged...", "Fixed...", "Browsed..."
        ⚠️ Keep it to 2-3 sentences MAX - be concise!
        
        GOOD EXAMPLES:
        "Refactored the user auth module in React, added OAuth support. Debugged CORS issues with the backend API."
        "Analyzed Q3 sales data in Google Sheets, creating pivot tables. Quick detour to respond to urgent Slack."
        "Configured GitHub Actions CI/CD pipeline. Tests failed initially due to Node version mismatch - fixed and deployed."
        
        BAD EXAMPLES:
        ✗ "Started by opening VS Code and worked on various tasks."
          WHY BAD: "Various tasks" is vague. What tasks specifically?
        ✗ "The user engaged in development activities."
          WHY BAD: NEVER say "the user"! Use first person without "I"
        ✗ "Did some work on the project."
          WHY BAD: "Some work" tells us nothing. What did you actually do?
        ✗ "The user spent time debugging code and checking emails."
          WHY BAD: "The user" is forbidden! Say: "Debugged auth flow, responded to client emails."
        ✗ "I was working on fixing bugs in the codebase."
          WHY BAD: Don't use "I"! Say: "Fixed race condition in auth flow, added mutex locks."
        
        CATEGORIES (you MUST pick one of the following):
        - Work
        - Personal
        - Distractions
        
        🚨 FINAL CHECKLIST BEFORE RESPONDING:
        1. Title: Casual like texting a friend? No "working on/with"?
        2. Summary: Check EVERY word - NO "the user", "User", or "They" ANYWHERE?
        3. Summary: Starts with action verbs? EXACTLY 2-3 sentences?
        4. Category: Work, Personal, or Distractions ONLY?
        
        REASONING FIELD (REQUIRED):
        You MUST use the "reasoning" field to plan your response. Think step by step:
        1. What was the main activity in these observations?
        2. Draft your summary - check: did I write "the user" or "User"? Fix it!
        3. Draft your title - check: did I use "working on/with"? Make it casual!
        4. Pick category: Is this Work, Personal, or Distractions?
        
        Return JSON:
        {
          "reasoning": "Your thinking process here",
          "title": "Your title here",
          "summary": "Your summary here",
          "category": "Category name"
        }
        """
        
        let response = try await callTextAPI(prompt, expectJSON: true)
        
        // Parse response
        guard let data = response.data(using: .utf8) else {
            throw NSError(domain: "OllamaProvider", code: 12, userInfo: [NSLocalizedDescriptionKey: "Failed to parse title/summary response"])
        }
        
        let result = try parseJSONResponse(TitleSummaryResponse.self, from: data)
        
        print("[DEBUG] Title/Summary generation result:")
        print("  Reasoning: \(result.reasoning)")
        print("  Title: \(result.title)")
        print("  Summary: \(result.summary)")
        print("  Category: \(result.category)")
        
        return (result, response)
    }
    
    private func checkShouldMerge(previousCard: ActivityCard, newCard: ActivityCard) async throws -> (Bool, String) {
        let prompt = """
        Look at these two consecutive activity periods and decide if they should be combined into one card.
        
        Previous activity (\(previousCard.startTime) - \(previousCard.endTime)):
        Title: \(previousCard.title)
        Summary: \(previousCard.summary)
        
        New activity (\(newCard.startTime) - \(newCard.endTime)):
        Title: \(newCard.title)
        Summary: \(newCard.summary)
        
        MERGE DECISION RULE:
        The Golden Rule: When merged, they should tell one coherent story, not two different ones
        
        ⚠️ BE STRICT! When in doubt, keep them separate.
        
        MERGE ONLY IF:
        ✓ Same project or closely related task
        ✓ Not a context switch
        ✓ You're 80%+ confident they're the same activity
        
        GOOD MERGING EXAMPLES:
        ✓ MERGE: "Debugging auth flow in VS Code" + "Testing auth endpoints in Postman"
          (Same exact auth bug work continuing, confidence: 0.95)
        ✓ MERGE: "Writing Q3 report in Docs" + "Adding charts to Q3 report"
          (Same document, natural progression, confidence: 0.92)
        ✓ MERGE: "Refactoring UserProfile component" + "Testing UserProfile after refactor"
          (Same component, testing what was just built, confidence: 0.91)
        
        BAD MERGING EXAMPLES:
        ✗ DON'T MERGE: "Debugging Dayflow timeline cards" + "Checking Twitter & Reddit"
          (Work interrupted by social media = context switch, confidence: 0.4)
        ✗ DON'T MERGE: "Fixed CORS bug in API" + "Started implementing user dashboard"
          (Different features, even same project, confidence: 0.6)
        ✗ DON'T MERGE: "Writing docs for API" + "Debugging API endpoints"
          (Documentation vs. coding = different mental modes, confidence: 0.7)
        ✗ DON'T MERGE: "Reviewing PR comments" + "Working on new feature"
          (Review work vs. creation work, confidence: 0.5)
        ✗ DON'T MERGE: "Python data analysis" + "Answering Slack messages"
          (Deep work vs. communication, confidence: 0.3)
        ✗ DON'T MERGE: "Researching React patterns" + "Implementing React component"
          (Research/learning vs. actual coding, confidence: 0.8)
        ✗ DON'T MERGE: "Email, Twitter, general browsing" + "More email and browsing"
          (Too vague - what emails? what browsing?, confidence: 0.4)
        
        CONFIDENCE SCORING:
        - 0.9-1.0: Same exact activity continuing (merge)
        - 0.7-0.9: Related but slightly different (probably don't merge)
        - 0.5-0.7: Somewhat related (don't merge)
        - 0.0-0.5: Different activities (definitely don't merge)
        
        Remember: You need 0.8+ confidence to merge!
        
        Return JSON:
        {
          "reason": "Brief explanation of your decision",
          "combine": true or false,
          "confidence": 0.0 to 1.0
        }
        """
        
        let response = try await callTextAPI(prompt, expectJSON: true)
        
        // Parse response
        struct MergeDecision: Codable {
            let reason: String
            let combine: Bool
            let confidence: Double
        }
        
        guard let data = response.data(using: .utf8) else {
            throw NSError(domain: "OllamaProvider", code: 13, userInfo: [NSLocalizedDescriptionKey: "Failed to parse merge decision"])
        }
        
        let decision = try parseJSONResponse(MergeDecision.self, from: data)
        
        // Apply confidence threshold
        let confidenceThreshold = 0.8
        let shouldMerge = decision.combine && decision.confidence >= confidenceThreshold
        
        print("[DEBUG] Merge check input:")
        print("  Previous: \(previousCard.title) (\(previousCard.startTime) - \(previousCard.endTime))")
        print("  New: \(newCard.title) (\(newCard.startTime) - \(newCard.endTime))")
        print("[DEBUG] Merge check result:")
        print("  Raw decision: \(decision.combine ? "MERGE" : "KEEP SEPARATE")")
        print("  Confidence: \(String(format: "%.2f", decision.confidence))")
        print("  Final decision: \(shouldMerge ? "MERGE" : "KEEP SEPARATE") (threshold: \(confidenceThreshold))")
        print("  Reason: \(decision.reason)")
        
        return (shouldMerge, response)
    }
    
    private func mergeTwoCards(previousCard: ActivityCard, newCard: ActivityCard) async throws -> (ActivityCard, String) {
        let prompt = """
        Create a single activity card that covers both time periods.
        
        Activity 1 (\(previousCard.startTime) - \(previousCard.endTime)):
        Title: \(previousCard.title)
        Summary: \(previousCard.summary)
        
        Activity 2 (\(newCard.startTime) - \(newCard.endTime)):
        Title: \(newCard.title)
        Summary: \(newCard.summary)
        
        Create a unified title and summary that covers the entire period from \(previousCard.startTime) to \(newCard.endTime).
        Title: Natural, conversational (5-10 words). Synthesize both activities.
        Summary: First person without "I", 2-3 sentences max. Tell the complete story.
        
        GOOD EXAMPLES:
        
        Card 1: "Debugging login flow" + Card 2: "Fixed auth bug and testing"
        MERGED Title: "Fixed authentication race condition bug"
        MERGED Summary: "Debugged race condition in auth token refresh logic. Implemented mutex lock solution and verified fix through integration tests."
        
        Card 1: "Email campaign planning" + Card 2: "Creating email templates"
        MERGED Title: "Q4 email campaign setup in Mailchimp"
        MERGED Summary: "Planned Q4 newsletter strategy with topic outline. Created two template variations in Mailchimp and configured A/B testing."
        
        Card 1: "Research React patterns" + Card 2: "Refactoring components"
        MERGED Title: "Refactored React components with modern patterns"
        MERGED Summary: "Researched component composition patterns and custom hooks. Applied learnings to refactor Dashboard components."
        
        Return JSON:
        {
          "title": "Your merged title",
          "summary": "Your merged summary"
        }
        """
        
        let response = try await callTextAPI(prompt, expectJSON: true)
        
        // Parse response
        struct MergedContent: Codable {
            let title: String
            let summary: String
        }
        
        guard let data = response.data(using: .utf8) else {
            throw NSError(domain: "OllamaProvider", code: 14, userInfo: [NSLocalizedDescriptionKey: "Failed to parse merged card"])
        }
        
        let merged = try parseJSONResponse(MergedContent.self, from: data)
        
        // Handle both chronological orders - use earliest start and latest end
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        
        let prevStart = formatter.date(from: previousCard.startTime) ?? Date()
        let prevEnd = formatter.date(from: previousCard.endTime) ?? Date()
        let newStart = formatter.date(from: newCard.startTime) ?? Date()
        let newEnd = formatter.date(from: newCard.endTime) ?? Date()
        
        // Use the earlier start time and later end time
        let mergedStartTime = prevStart < newStart ? previousCard.startTime : newCard.startTime
        let mergedEndTime = prevEnd > newEnd ? previousCard.endTime : newCard.endTime
        
        let mergedCard = ActivityCard(
            startTime: mergedStartTime,
            endTime: mergedEndTime,
            category: previousCard.category,
            subcategory: previousCard.subcategory,
            title: merged.title,
            summary: merged.summary,
            detailedSummary: previousCard.detailedSummary,
            distractions: previousCard.distractions
        )
        
        
        return (mergedCard, response)
    }
    
    private func parseJSONResponse<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
        // First try direct parsing
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            // Try to extract JSON from the response
            guard let responseString = String(data: data, encoding: .utf8) else {
                throw error
            }
            
            // Look for JSON object
            if let startIndex = responseString.firstIndex(of: "{"),
               let endIndex = responseString.lastIndex(of: "}") {
                let jsonSubstring = responseString[startIndex...endIndex]
                if let jsonData = jsonSubstring.data(using: .utf8) {
                    return try JSONDecoder().decode(type, from: jsonData)
                }
            }
            
            throw error
        }
    }
    
    private func formatTimestampForPrompt(_ timestamp: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
    
    private func calculateDurationInMinutes(from startTime: String, to endTime: String) -> Int {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        
        guard let start = formatter.date(from: startTime),
              let end = formatter.date(from: endTime) else {
            return 0
        }
        
        var duration = end.timeIntervalSince(start)
        
        // Handle day boundary - if end is before start, assume it's the next day
        if duration < 0 {
            duration += 24 * 60 * 60  // Add 24 hours in seconds
        }
        
        return Int(duration / 60)
    }
    
    // MARK: - New Merging Logic
    
    private struct VideoSegment: Codable {
        let startTimestamp: String  // MM:SS format
        let endTimestamp: String    // MM:SS format
        let description: String
    }
    
    private func mergeFrameDescriptions(_ frameDescriptions: [(timestamp: TimeInterval, description: String)], 
                                      batchStartTime: Date, 
                                      videoDuration: TimeInterval) async throws -> [Observation] {
        
        // Format frame descriptions for the prompt
        var formattedDescriptions = ""
        for frame in frameDescriptions {
            let minutes = Int(frame.timestamp) / 60
            let seconds = Int(frame.timestamp) % 60
            let timeStr = String(format: "%02d:%02d", minutes, seconds)
            formattedDescriptions += "[\(timeStr)] \(frame.description)\n"
        }
        
        // Format video duration for the prompt
        let durationMinutes = Int(videoDuration / 60)
        let durationSeconds = Int(videoDuration.truncatingRemainder(dividingBy: 60))
        let durationString = String(format: "%02d:%02d", durationMinutes, durationSeconds)
        
        let mergePrompt = """
        You have \(frameDescriptions.count) snapshots from a \(durationString) video showing someone's computer usage.
        
        CRITICAL TASK: Group these snapshots into EXACTLY 2-5 segments. DO NOT create more than 5 segments under any circumstances.
        
        <thinking>
        Plan how to group the snapshots before outputting. Consider which activities belong together and where natural breaks occur.
        </thinking>
        
        Here are the snapshots:
        \(formattedDescriptions)
        
        STRICT RULES:
        - You MUST create between 2 and 5 segments total
        - Brief interruptions (<2 min) should be absorbed into the main activity
        - All timestamps MUST be within 00:00 to \(durationString)
        - Segments must cover at least 80% of the video duration
        
        GOOD EXAMPLES:
        
        3 segments from 15:00 video:
        [
          {
            "startTimestamp": "00:00",
            "endTimestamp": "05:30",
            "description": "Researched React performance optimization techniques. Read articles about memo and useMemo patterns, took notes in Notion."
          },
          {
            "startTimestamp": "05:30",
            "endTimestamp": "11:00",
            "description": "Implemented performance optimizations in VS Code. Added React.memo to components, quick Slack check for team question."
          },
          {
            "startTimestamp": "11:00",
            "endTimestamp": "14:45",
            "description": "Tested performance improvements using Chrome DevTools. Documented 40% reduction in render time, updated PR description."
          }
        ]
        
        2 segments from 10:00 video:
        [
          {
            "startTimestamp": "00:00",
            "endTimestamp": "06:30",
            "description": "Client communication - drafted status email in Gmail, updated timeline in Sheets, sent Slack updates about deadlines."
          },
          {
            "startTimestamp": "06:30",
            "endTimestamp": "09:45",
            "description": "Fixed CSS layout issues in customer dashboard, tested responsive design. Created pull request with screenshots."
          }
        ]
        
        Return a JSON array with EXACTLY 2-5 segments:
        [
          {
            "startTimestamp": "MM:SS",
            "endTimestamp": "MM:SS",
            "description": "Natural description of the activity"
          }
        ]
        
        REMEMBER: Output EXACTLY 2-5 segments. If you output more than 5 segments, you have failed the task.
        """
        
        let response = try await callTextAPI(mergePrompt, expectJSON: true)
        
        // Parse the JSON response
        guard let responseData = response.data(using: String.Encoding.utf8) else {
            throw NSError(domain: "OllamaProvider", code: 8, userInfo: [NSLocalizedDescriptionKey: "Failed to parse merge response"])
        }
        
        // Try to extract JSON array from response
        let segments: [VideoSegment]
        do {
            segments = try JSONDecoder().decode([VideoSegment].self, from: responseData)
        } catch {
            // Try to find JSON in the response
            guard let startIndex = response.firstIndex(of: "["),
                  let endIndex = response.lastIndex(of: "]") else {
                throw NSError(domain: "OllamaProvider", code: 9, userInfo: [NSLocalizedDescriptionKey: "Could not find JSON array in merge response"])
            }
            
            let jsonSubstring = response[startIndex...endIndex]
            guard let jsonData = jsonSubstring.data(using: .utf8) else {
                throw NSError(domain: "OllamaProvider", code: 10, userInfo: [NSLocalizedDescriptionKey: "Failed to extract JSON from response"])
            }
            
            segments = try JSONDecoder().decode([VideoSegment].self, from: jsonData)
        }
        
        // Convert segments to Observations with validation
        var validObservations: [Observation] = []
        var totalSegmentDuration: TimeInterval = 0
        var lastEndTime: TimeInterval? = nil
        
        for (index, segment) in segments.enumerated() {
            let startSeconds = TimeInterval(parseVideoTimestamp(segment.startTimestamp))
            let endSeconds = TimeInterval(parseVideoTimestamp(segment.endTimestamp))
            
            // Validate timestamps are within video duration (with 30 second tolerance)
            let tolerance: TimeInterval = 30.0
            if startSeconds < -tolerance || endSeconds > videoDuration + tolerance {
                print("[OLLAMA] ❌ Segment \(index + 1) exceeds video duration: \(segment.startTimestamp)-\(segment.endTimestamp) (video is \(durationString))")
                continue
            }
            
            // Check for gaps between segments
            if let prevEnd = lastEndTime {
                let gap = startSeconds - prevEnd
                if gap > 60.0 { // More than 60 seconds gap
                    print("[OLLAMA] ⚠️ Gap of \(Int(gap))s between segments at \(String(format: "%02d:%02d", Int(prevEnd)/60, Int(prevEnd)%60))")
                }
            }
            
            totalSegmentDuration += (endSeconds - startSeconds)
            lastEndTime = endSeconds
            
            let startDate = batchStartTime.addingTimeInterval(TimeInterval(startSeconds))
            let endDate = batchStartTime.addingTimeInterval(TimeInterval(endSeconds))
            
            validObservations.append(Observation(
                id: nil,
                batchId: 0,  // Will be set when saved
                startTs: Int(startDate.timeIntervalSince1970),
                endTs: Int(endDate.timeIntervalSince1970),
                observation: segment.description,
                metadata: nil,
                llmModel: "qwen2.5vl:3b",
                createdAt: Date()
            ))
        }
        
        // Validate coverage
        let coverageRatio = totalSegmentDuration / videoDuration
        if coverageRatio < 0.8 {
            throw NSError(domain: "OllamaProvider", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "Segments only cover \(Int(coverageRatio * 100))% of video (expected >80%). Video is \(durationString) long. LLM needs to generate observations that span the full video duration."
            ])
        }
        if coverageRatio > 1.2 {
            // Still just warn for over-coverage as it's less critical
            print("[OLLAMA] ⚠️ Segments exceed video duration by \(Int((coverageRatio - 1) * 100))%")
        }
        
        // Validate we got a reasonable number of observations
        if validObservations.isEmpty {
            throw NSError(domain: "OllamaProvider", code: 11, userInfo: [NSLocalizedDescriptionKey: "No valid observations generated from merge"])
        }
        
        if validObservations.count > 5 {
            throw NSError(domain: "OllamaProvider", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "Generated \(validObservations.count) observations, but expected 2-5. The LLM must follow the instruction to create EXACTLY 2-5 segments."
            ])
        }
        
        let observations = validObservations
        
        return observations
    }
}
