//
//  GeminiService.swift
//  Dayflow
//
//  2025‑05‑08  —  Switch from **inline video** to the **Files API** so we can
//  send >20 MB batches without hitting the inline limit.  Flow:
//    1. Stitch chunk files → single .mp4.
//    2. Resumable upload via `upload/v1beta/files` (two‑step start + upload).
//    3. Call `generateContent` referencing the returned `file_uri`.
//    4. Still dumps shell‑ready curl scripts in /tmp for debugging.
//
import Foundation
import AVFoundation
import UniformTypeIdentifiers

// MARK: – Protocol -----------------------------------------------------------

protocol GeminiServicing {
    func processBatch(_ batchId: Int64,
                      completion: @escaping (Result<[ActivityCard], Error>) -> Void)
    func transcribeChunk(batchId: Int64, stitchedFileURL: URL, mimeType: String, apiKey: String) async throws -> (transcripts: [TranscriptChunk], log: LLMCall)
    func generateActivityCardsFromTranscript(batchId: Int64, transcripts: [TranscriptChunk], apiKey: String,
                                            previousSegmentsJSON: String, userTaxonomy: String, extractedTaxonomy: String) async throws -> (cards: [ActivityCard], log: LLMCall)
    func evaluateQuestionsFromTranscript(questionIds: [Int64], questions: [String], previousValues: [Double], transcripts: [ClockTranscriptChunk], apiKey: String) async throws -> (results: [Double], log: LLMCall)
    func evaluateTodosFromTranscript(todos: [String], transcripts: [ClockTranscriptChunk], apiKey: String) async throws -> (completions: [Bool], log: LLMCall)
    func apiKey() -> String?
    func setApiKey(_ key: String)
}

// MARK: – DTOs & Errors ------------------------------------------------------

struct ActivityCard: Codable {
    let startTime: String
    let endTime: String
    let category: String
    let subcategory: String
    let title: String
    let summary: String
    let detailedSummary: String
    let distractions: [Distraction]?
}

/// Minimal info from the most recent segment used as context for the prompt
/// when processing the next batch.
struct PreviousSegmentSummary: Codable {
    let category: String
    let subcategory: String
    let title: String
    let summary: String
    let detailedSummary: String
}

struct TranscriptChunk: Codable, Sendable {
    let startTimestamp: String   // MM:SS
    let endTimestamp:   String   // MM:SS
    let description:    String
}

// New struct for clock-time based transcripts
struct ClockTranscriptChunk: Codable, Sendable, Identifiable { // Made Codable for potential storage
    let id = UUID()
    let clockStartTime: Date
    let clockEndTime: Date
    let description: String
}

enum GeminiServiceError: Error, LocalizedError {
    case missingApiKey, noChunks, stitchingFailed
    case uploadStartFailed(String), uploadFailed(String)
    case processingTimeout, processingFailed(String)
    case requestFailed(String), invalidResponse
    var errorDescription: String? {
        switch self {
        case .missingApiKey: return "Missing Gemini API key. Set it in Settings."
        case .noChunks: return "Batch contains no video chunks."
        case .stitchingFailed: return "Failed to stitch video chunks."
        case .uploadStartFailed(let m): return "File‑API start failed – \(m)"
        case .uploadFailed(let m): return "File‑API upload failed – \(m)"
        case .processingTimeout: return "File processing exceeded 5 minutes."
        case .processingFailed(let s): return "File processing failed – \(s)"
        case .requestFailed(let m): return "Gemini request failed – \(m)"
        case .invalidResponse: return "Gemini returned an unexpected payload."
        }
    }
}

enum TranscriptionError: Error, LocalizedError {
    case invalidTimestampFormat
    case apiError(String)
    case decodingError(String)
    case fileUploadFailed(String) // Added for consistency

    var errorDescription: String? {
        switch self {
        case .invalidTimestampFormat: return "Invalid timestamp format. Expected MM:SS."
        case .apiError(let msg): return "Transcription API error: \(msg)"
        case .decodingError(let msg): return "Transcription decoding error: \(msg)"
        case .fileUploadFailed(let msg): return "Transcription file upload failed: \(msg)"
        }
    }
}

// Intermediate structs to parse the Gemini API's wrapped response
private struct GeminiAPIContentPart: Codable {
    let text: String
}

private struct GeminiAPIContent: Codable {
    let parts: [GeminiAPIContentPart]
    let role: String? // role might not always be present or needed for our specific extraction
}

private struct GeminiAPICandidate: Codable {
    let content: GeminiAPIContent
    // We don't need finishReason, index, etc. for this step
}

private struct GeminiAPIResponse: Codable {
    let candidates: [GeminiAPICandidate]
    // We don't need usageMetadata for this step
}

// MARK: – Service ------------------------------------------------------------

// Add String.matches extension
extension String {
    func matches(_ regex: String) -> Bool {
        return self.range(of: regex, options: .regularExpression, range: nil, locale: nil) != nil
    }
}

final class GeminiService: GeminiServicing {
    static let shared: GeminiServicing = GeminiService()
    private init() {}

    private let genEndpoint  = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-04-17:generateContent"
    private let fileEndpoint = "https://generativelanguage.googleapis.com/upload/v1beta/files"

    private let apiKeyKey = "AIzaSyCwblI-EMEw7UAWwdhjklc1eVE_87AHLpE"
    private let userDefaults = UserDefaults.standard
    private let queue = DispatchQueue(label: "com.dayflow.gemini", qos: .utility)

    func apiKey() -> String? { "AIzaSyCwblI-EMEw7UAWwdhjklc1eVE_87AHLpE" }
    func setApiKey(_ key: String) { userDefaults.set(key, forKey: apiKeyKey) }

    // MARK: – Public ---------------------------------------------------------

    func processBatch(_ batchId: Int64,
                      completion: @escaping (Result<[ActivityCard], Error>) -> Void) {
        guard let key = apiKey(), !key.isEmpty else {
            completion(.failure(GeminiServiceError.missingApiKey)); return
        }

        queue.async {
            Task {
                var accumulatedCallLogs: [LLMCall] = []
                var currentPhase = "initial"
                print("GeminiService.processBatch (new flow) starting for batch \(batchId)")

                do {
                    // 1. Gather & Stitch Video Chunks
                    currentPhase = "gather & stitch"
                    let recordingChunks = StorageManager.shared.chunksForBatch(batchId)
                    guard !recordingChunks.isEmpty else { throw GeminiServiceError.noChunks }
                    let videoURLs = recordingChunks.map { URL(fileURLWithPath: $0.fileUrl) }
                    let stitchedVideoURL = try self.stitch(urls: videoURLs)
                    defer { try? FileManager.default.removeItem(at: stitchedVideoURL) }
                    let mimeType = self.mimeType(for: stitchedVideoURL) ?? "video/mp4"

                    // 2. Transcribe Video to Text Chunks
                    currentPhase = "transcribe video"
                    print("Phase: \(currentPhase) for batch \(batchId)")
                    let (transcriptChunks, transcriptionLog) = try await self.transcribeChunk(
                        batchId: batchId, // batchId is mainly for context/logging if transcribeChunk needs it
                        stitchedFileURL: stitchedVideoURL,
                        mimeType: mimeType,
                        apiKey: key
                    )
                    accumulatedCallLogs.append(transcriptionLog)
                    
                    // 2.5. Convert TranscriptChunks to ClockTranscriptChunks and save to database
                    currentPhase = "save transcripts"
                    print("Phase: \(currentPhase) for batch \(batchId)")
                    let batchStartTime = Date(timeIntervalSince1970: TimeInterval(recordingChunks.first?.startTs ?? 0))
                    let clockTranscriptChunks = self.convertToClockTranscripts(
                        transcriptChunks: transcriptChunks,
                        batchStartTime: batchStartTime
                    )
                    StorageManager.shared.saveTranscript(batchId: batchId, chunks: clockTranscriptChunks)
                    print("Saved \(clockTranscriptChunks.count) transcript chunks to database for batch \(batchId)")

                    // 3. Prepare Contextual Information for Activity Card Generation
                    currentPhase = "prepare context for card generation"
                    print("Phase: \(currentPhase) for batch \(batchId)")
                    let todayString = self.getCurrentDayStringFor4AMBoundary()
                    let previousTimelineCards = StorageManager.shared.fetchTimelineCards(forDay: todayString)
                    var previousSegmentsJSON = "No previous segment for today."
                    if let lastCard = previousTimelineCards.last {
                        let summary = PreviousSegmentSummary(
                            category: lastCard.category,
                            subcategory: lastCard.subcategory,
                            title: lastCard.title,
                            summary: lastCard.summary,
                            detailedSummary: lastCard.detailedSummary
                        )
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = .prettyPrinted
                        if let jsonData = try? encoder.encode([summary]), let jsonStr = String(data: jsonData, encoding: .utf8) {
                            previousSegmentsJSON = jsonStr
                        }
                    }
                    var userTaxonomyString = "No custom taxonomy provided by user."
                    var extractedTaxonomyString = "No previous taxonomy found."
                    let taxonomyKey = "userDefinedTaxonomyJSON"
                    var userTaxonomyDict: [String: Set<String>] = [:]
                    if let taxonomyJSONString = self.userDefaults.string(forKey: taxonomyKey), !taxonomyJSONString.isEmpty,
                       let jsonData = taxonomyJSONString.data(using: .utf8) {
                        if let parsedDict = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: [String]] {
                            for (category, subcategories) in parsedDict { userTaxonomyDict[category] = Set(subcategories) }
                            var tempFormattedTaxonomy = ""
                            for (category, subcategories) in parsedDict.sorted(by: { $0.key < $1.key }) {
                                let subcategoriesFormatted = subcategories.sorted().map { "\"\($0)\"" }.joined(separator: ", ")
                                tempFormattedTaxonomy += "\(category): [\(subcategoriesFormatted)]\n"
                            }
                            if !tempFormattedTaxonomy.isEmpty { userTaxonomyString = tempFormattedTaxonomy.trimmingCharacters(in: .whitespacesAndNewlines) }
                        }
                    }
                    var extractedTaxonomyDict: [String: Set<String>] = [:]
                    if !previousTimelineCards.isEmpty {
                        for card in previousTimelineCards {
                            if userTaxonomyDict[card.category]?.contains(card.subcategory) != true {
                                extractedTaxonomyDict[card.category, default: []].insert(card.subcategory)
                            }
                        }
                        if !extractedTaxonomyDict.isEmpty {
                            var tempFormattedTaxonomy = ""
                            for (category, subcategories) in extractedTaxonomyDict.sorted(by: { $0.key < $1.key }) {
                                let subcategoriesFormatted = Array(subcategories).sorted().map { "\"\($0)\"" }.joined(separator: ", ")
                                tempFormattedTaxonomy += "\(category): [\(subcategoriesFormatted)]\n"
                            }
                            if !tempFormattedTaxonomy.isEmpty { extractedTaxonomyString = tempFormattedTaxonomy.trimmingCharacters(in: .whitespacesAndNewlines) }
                        }
                    }

                    // 4. Generate ActivityCards from Transcript Chunks
                    currentPhase = "generate activity cards from transcript"
                    print("Phase: \(currentPhase) for batch \(batchId)")
                    let (finalActivityCards, cardGenerationLog) = try await self.generateActivityCardsFromTranscript(
                        batchId: batchId,
                        transcripts: transcriptChunks,
                        apiKey: key,
                        previousSegmentsJSON: previousSegmentsJSON,
                        userTaxonomy: userTaxonomyString,
                        extractedTaxonomy: extractedTaxonomyString
                    )
                    accumulatedCallLogs.append(cardGenerationLog)

                    // 5. Save the generated ActivityCards
                    currentPhase = "save activity cards"
                    print("Phase: \(currentPhase) for batch \(batchId)")

                    // 6. Update Batch LLM Metadata with all accumulated logs
                    StorageManager.shared.updateBatchLLMMetadata(batchId: batchId, calls: accumulatedCallLogs)
                    
                    print("GeminiService.processBatch (new flow) completed successfully for batch \(batchId).")
                    DispatchQueue.main.async { completion(.success(finalActivityCards)) }

                } catch {
                    print("Error during \(currentPhase) for batch \(batchId) in new flow: \(error.localizedDescription)")
                    // Ensure even on error, any partial logs are saved if possible/desired
                    StorageManager.shared.updateBatchLLMMetadata(batchId: batchId, calls: accumulatedCallLogs)
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
        }
    }

    func evaluateQuestionsFromTranscript(questionIds: [Int64], questions: [String], previousValues: [Double], transcripts: [ClockTranscriptChunk], apiKey: String) async throws -> (results: [Double], log: LLMCall) {
        let callStartTime = Date()
        
        // Convert transcripts to readable format
        let transcriptText = transcripts.map { transcript in
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            let startTime = formatter.string(from: transcript.clockStartTime)
            let endTime = formatter.string(from: transcript.clockEndTime)
            return "[\(startTime) - \(endTime)]: \(transcript.description)"
        }.joined(separator: "\n")
        
        // Create numbered questions list
        let numberedQuestions = questions.enumerated().map { index, question in
            "Q\(index + 1): \(question) (Current value: \(previousValues[index]))"
        }.joined(separator: "\n")
        
        let questionEvaluationPrompt = """
        You are evaluating dashboard questions based on transcript data. Your job is to analyze the transcript and provide updated cumulative values for each question.

        TRANSCRIPT DATA:
        \(transcriptText)

        QUESTIONS TO EVALUATE:
        \(numberedQuestions)

        INSTRUCTIONS:
        - For each question, determine what type it is (count, time duration, or boolean)
        - Add the incremental value from this transcript to the current value
        - For count questions: Count occurrences and add to current value
        - For time questions: Calculate minutes spent and add to current value  
        - For boolean questions: Return 1.0 if true/completed, 0.0 if false/not completed
        - If a question is not relevant to this transcript, return the current value unchanged

        Return a JSON array of numbers corresponding to the updated values for Q1, Q2, Q3, etc.
        Example: [5.0, 180.0, 1.0] for 3 questions
        """
        
        let responseSchema: [String: Any] = [
            "type": "ARRAY",
            "items": ["type": "NUMBER"]
        ]
        
        let generationConfig: [String: Any] = [
            "temperature": 0.1,
            "maxOutputTokens": 4096,
            "responseMimeType": "application/json",
            "responseSchema": responseSchema
        ]
        
        let requestBody: [String: Any] = [
            "contents": [["parts": [["text": questionEvaluationPrompt]]]],
            "generationConfig": generationConfig
        ]
        
        let (results, responseText, _, latency) = try await callGeminiAPI(
            apiKey: apiKey,
            requestBody: requestBody,
            targetType: [Double].self,
            apiEndpoint: self.genEndpoint
        )
        
        let log = LLMCall(timestamp: callStartTime, latency: latency, input: questionEvaluationPrompt, output: responseText)
        return (results, log)
    }

    func evaluateTodosFromTranscript(todos: [String], transcripts: [ClockTranscriptChunk], apiKey: String) async throws -> (completions: [Bool], log: LLMCall) {
        let callStartTime = Date()
        
        // Convert transcripts to readable format
        let transcriptText = transcripts.map { transcript in
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            let startTime = formatter.string(from: transcript.clockStartTime)
            let endTime = formatter.string(from: transcript.clockEndTime)
            return "[\(startTime) - \(endTime)]: \(transcript.description)"
        }.joined(separator: "\n")
        
        // Create numbered todos list
        let numberedTodos = todos.enumerated().map { index, todo in
            "T\(index + 1): \(todo)"
        }.joined(separator: "\n")
        
        let todoEvaluationPrompt = """
        You are evaluating todo completion based on transcript data. Your job is to determine if each todo item was completed based on the activities described.

        TRANSCRIPT DATA:
        \(transcriptText)

        TODOS TO EVALUATE:
        \(numberedTodos)

        INSTRUCTIONS:
        - For each todo, determine if there is evidence in the transcript that it was completed
        - Look for activities that directly relate to completing the todo
        - Be conservative - only mark as completed if there is clear evidence
        - Return true only if the todo appears to have been finished/completed

        Return a JSON array of booleans corresponding to T1, T2, T3, etc.
        Example: [true, false, true] for 3 todos
        """
        
        let responseSchema: [String: Any] = [
            "type": "ARRAY",
            "items": ["type": "BOOLEAN"]
        ]
        
        let generationConfig: [String: Any] = [
            "temperature": 0.1,
            "maxOutputTokens": 4096,
            "responseMimeType": "application/json",
            "responseSchema": responseSchema
        ]
        
        let requestBody: [String: Any] = [
            "contents": [["parts": [["text": todoEvaluationPrompt]]]],
            "generationConfig": generationConfig
        ]
        
        let (results, responseText, _, latency) = try await callGeminiAPI(
            apiKey: apiKey,
            requestBody: requestBody,
            targetType: [Bool].self,
            apiEndpoint: self.genEndpoint
        )
        
        let log = LLMCall(timestamp: callStartTime, latency: latency, input: todoEvaluationPrompt, output: responseText)
        return (results, log)
    }

    // MARK: – Upload helper ---------------------------------------------------

    private func uploadAndAwait(_ file: URL, mimeType: String, key: String) throws -> (String,String) {
            let size = (try FileManager.default.attributesOfItem(atPath:file.path)[.size] as! NSNumber).stringValue
            // start
            var startURL=URLComponents(string:fileEndpoint)!; startURL.queryItems=[URLQueryItem(name:"key",value:key)]
            var sReq=URLRequest(url:startURL.url!); sReq.httpMethod="POST"; sReq.setValue("resumable",forHTTPHeaderField:"X-Goog-Upload-Protocol"); sReq.setValue("start",forHTTPHeaderField:"X-Goog-Upload-Command"); sReq.setValue(size,forHTTPHeaderField:"X-Goog-Upload-Header-Content-Length"); sReq.setValue(mimeType,forHTTPHeaderField:"X-Goog-Upload-Header-Content-Type"); sReq.setValue("application/json",forHTTPHeaderField:"Content-Type"); sReq.httpBody=try JSONSerialization.data(withJSONObject:["file":["display_name":"VIDEO"]])
            let (_,sResp)=try URLSession.shared.syncDataTask(with:sReq); guard let http1=sResp as? HTTPURLResponse, let upURLString=http1.value(forHTTPHeaderField:"X-Goog-Upload-URL"), let upURL=URL(string:upURLString) else { throw GeminiServiceError.uploadStartFailed("missing upload URL") }
            // upload
            var uReq=URLRequest(url:upURL); uReq.httpMethod="PUT"; uReq.setValue(size,forHTTPHeaderField:"Content-Length"); uReq.setValue("0",forHTTPHeaderField:"X-Goog-Upload-Offset"); uReq.setValue("upload, finalize",forHTTPHeaderField:"X-Goog-Upload-Command"); uReq.httpBody=try Data(contentsOf:file); let (uData,_)=try URLSession.shared.syncDataTask(with:uReq)
            guard let uData=uData, let json=try? JSONSerialization.jsonObject(with:uData) as? [String:Any], let fileDict=json["file"] as? [String:Any], let fileName=fileDict["name"] as? String else { throw GeminiServiceError.uploadFailed("bad response") }
            // poll
            let pollURL = "https://generativelanguage.googleapis.com/v1beta/\(fileName)?key=\(key)"
            print(pollURL)
            var state="PROCESSING";
            var fileURI:String?;
            let deadline=Date().addingTimeInterval(300)
            
        while Date() < deadline {
            // 1. GET the file object
            var req = URLRequest(url: URL(string: pollURL)!)
            req.httpMethod = "GET"
            
            // synchronous helper; you can wrap this in async/await if preferred
            let (data, _) = try URLSession.shared.syncDataTask(with: req)
            
            // 2. Parse the top‑level JSON keys
            guard
                let bytes = data,
                let root  = try JSONSerialization.jsonObject(with: bytes) as? [String:Any],
                let newState = root["state"] as? String
            else {
                throw GeminiServiceError.invalidResponse          // malformed JSON
            }
            
            state = newState          // update loop variable
            
            if state == "ACTIVE" {
                fileURI = root["uri"] as? String
                break                                   // 
            }
            if state == "FAILED" {
                throw GeminiServiceError.processingFailed("File‑processing returned FAILED")
            }
            // else still PROCESSING
            Thread.sleep(forTimeInterval: 1)            // wait 1 s before next poll
        }
            if state=="PROCESSING" { throw GeminiServiceError.processingTimeout }
            if state=="FAILED" { throw GeminiServiceError.processingFailed(state) }
            guard let uri=fileURI else { throw GeminiServiceError.invalidResponse }
            return (fileName,uri)
        }

    // MARK: – Stitch helper ---------------------------------------------------

    private func stitch(urls: [URL]) throws -> URL {
        let comp = AVMutableComposition()
        guard let trak = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw GeminiServiceError.stitchingFailed
        }
        var cursor = CMTime.zero
        for u in urls {
            let asset = AVURLAsset(url: u)
            guard let src = asset.tracks(withMediaType: .video).first else { continue }
            try trak.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: src, at: cursor)
            cursor = CMTimeAdd(cursor, asset.duration)
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        guard let exp = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { throw GeminiServiceError.stitchingFailed }
        exp.outputURL = out; exp.outputFileType = .mp4
        let sema = DispatchSemaphore(value: 0); exp.exportAsynchronously { sema.signal() }; sema.wait()
        guard exp.status == .completed else { throw GeminiServiceError.stitchingFailed }
        return out
    }

    // MARK: – Misc -----------------------------------------------------------

    private func mimeType(for url: URL) -> String? {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
    }

    private func dumpCurl(batchId: Int64, json: Data, key: String) {
        guard let js = String(data: json, encoding: .utf8) else { return }
        var comps = URLComponents(string: genEndpoint)!; comps.queryItems = [URLQueryItem(name: "key", value: key)]
        let script = """
#!/usr/bin/env bash
curl "\(comps.url!.absoluteString)" \
  -H 'Content-Type: application/json' \
  -X POST \
  -d '\(js)'
"""
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("gemini_batch_\(batchId).sh")
        try? script.write(to: path, atomically: true, encoding: .utf8)
        print(" curl \(path.path)")
    }

    // MARK: – Helper function to get current day string based on 4 AM boundary
    private func getCurrentDayStringFor4AMBoundary() -> String {
        let now = Date()
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current // Ensure it uses the local timezone

        // Check if current time is before 4 AM
        let hour = calendar.component(.hour, from: now)
        
        let targetDate: Date
        if hour < 4 {
            // If before 4 AM, it's considered part of the previous day's 4AM-4AM cycle
            targetDate = calendar.date(byAdding: .day, value: -1, to: now)!
        } else {
            // If 4 AM or later, it's part of the current day's 4AM-4AM cycle
            targetDate = now
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone.current // Ensure formatter also uses local timezone
        return dateFormatter.string(from: targetDate)
    }
    
    // MARK: – Helper function to convert TranscriptChunks to ClockTranscriptChunks
    private func convertToClockTranscripts(transcriptChunks: [TranscriptChunk], batchStartTime: Date) -> [ClockTranscriptChunk] {
        return transcriptChunks.compactMap { chunk in
            guard let startSeconds = parseVideoTimestamp(chunk.startTimestamp),
                  let endSeconds = parseVideoTimestamp(chunk.endTimestamp) else {
                print("Warning: Could not parse video timestamps for transcript chunk: \(chunk.startTimestamp) - \(chunk.endTimestamp)")
                return nil
            }
            
            let clockStartTime = batchStartTime.addingTimeInterval(startSeconds)
            let clockEndTime = batchStartTime.addingTimeInterval(endSeconds)
            
            return ClockTranscriptChunk(
                clockStartTime: clockStartTime,
                clockEndTime: clockEndTime,
                description: chunk.description
            )
        }
    }
    
    // MARK: – Helper function to parse video timestamps (MM:SS format)
    private func parseVideoTimestamp(_ timestamp: String) -> TimeInterval? {
        let components = timestamp.components(separatedBy: ":")
        guard components.count == 2,
              let minutes = Int(components[0]),
              let seconds = Int(components[1]) else {
            return nil
        }
        
        return TimeInterval(minutes * 60 + seconds)
    }

    // Helper function to validate Gemini output
    private func validateGeminiOutput(prompt: String, output: String, key: String) throws -> (String, LLMCall) {
        let validationPrompt = """
        Given this prompt:
        
        \(prompt)
        
        And this output:
        
        \(output)
        
        Reflect on whether the output satisfies 1. each segment is 5+ minutes long. 2. segments  If it does, return "pass". If it does not, return "fail".
        """
        
        print(" Validating Gemini output...")
        
        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": validationPrompt]
                ]
            ]],
            "generationConfig": [
                "temperature": 0,
                "maxOutputTokens": 10000,
                "thinkingConfig": [
                                "thinkingBudget": 24576
                            ]
            ]
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let requestString = String(data: jsonData, encoding: .utf8) ?? ""
        var comps = URLComponents(string: self.genEndpoint)!; comps.queryItems = [URLQueryItem(name: "key", value: key)]
        var req = URLRequest(url: comps.url!);
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = jsonData; req.timeoutInterval = 60
        
        let startCall = Date()
        let (d, r) = try URLSession.shared.syncDataTask(with: req)
        let latency = Date().timeIntervalSince(startCall)
        guard let http = r as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = String(data: d ?? Data(), encoding: .utf8) ?? "<no body>"
            throw GeminiServiceError.requestFailed("Validation request failed: \(msg)")
        }
        
        guard let data = d,
              let apiResponse = try? JSONDecoder().decode(GeminiAPIResponse.self, from: data),
              let firstCandidate = apiResponse.candidates.first,
              let firstPart = firstCandidate.content.parts.first else {
            throw GeminiServiceError.invalidResponse
        }
        
        let validationResponse = firstPart.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        print(" Validation response: \(validationResponse)")
        
        let call = LLMCall(timestamp: startCall, latency: latency, input: requestString, output: validationResponse)
        return (validationResponse, call)
    }

    // MARK: - Private Gemini API Call Helper (Updated)
    private func callGeminiAPI<T: Decodable>(
        apiKey: String,
        requestBody: [String: Any],
        targetType: T.Type,
        apiEndpoint: String
    ) async throws -> (decodedObject: T, responseText: String, requestTimestamp: Date, latency: TimeInterval) {
        var attempts = 0
        let maxAttempts = 3
        var lastError: Error = GeminiServiceError.requestFailed("Unknown API error after \(maxAttempts) attempts.")
        let requestTimestamp = Date() // Timestamp for the start of the first attempt

        while attempts < maxAttempts {
            attempts += 1
            let attemptStartTime = Date()

            do {
                var req = URLRequest(url: URL(string: apiEndpoint + "?key=\(apiKey)")!)
                req.httpMethod = "POST"
                req.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.timeoutInterval = 300

                let (data, resp) = try await URLSession.shared.data(for: req)
                let latency = Date().timeIntervalSince(attemptStartTime)

                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    let responseBody = String(data: data, encoding: .utf8) ?? "No response body"
                    print("Gemini API Error: HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0): \(responseBody)")
                    lastError = GeminiServiceError.requestFailed("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0): \(responseBody)")
                    if attempts >= maxAttempts { throw lastError }
                    await Task.sleep(UInt64(2 * Double(attempts) * 1_000_000_000.0))
                    continue
                }

                let apiResp = try JSONDecoder().decode(GeminiAPIResponse.self, from: data)
                guard let firstCandidate = apiResp.candidates.first,
                      let textPart = firstCandidate.content.parts.first?.text,
                      let jsonBytes = textPart.data(using: .utf8) else {
                    lastError = GeminiServiceError.invalidResponse
                    if attempts >= maxAttempts { throw lastError }
                    await Task.sleep(UInt64(2 * Double(attempts) * 1_000_000_000.0))
                    continue
                }
                
                let decodedObject = try JSONDecoder().decode(T.self, from: jsonBytes)
                print(decodedObject)
                let responseText = String(data: jsonBytes, encoding: .utf8) ?? "Could not decode response text from JSON bytes"
                // Use requestTimestamp for the overall call, latency for this specific successful attempt
                let overallLatency = Date().timeIntervalSince(requestTimestamp)
                return (decodedObject, responseText, requestTimestamp, overallLatency)

            } catch let specificError as DecodingError {
                 print("Gemini API decoding error: \(specificError)")
                 lastError = specificError
                 if attempts >= maxAttempts { throw lastError }
            } catch let specificError as GeminiServiceError {
                lastError = specificError
                if attempts >= maxAttempts { throw lastError }
            } catch {
                lastError = GeminiServiceError.requestFailed("Attempt \(attempts)/\(maxAttempts) failed: \(error.localizedDescription)")
                if attempts >= maxAttempts { throw lastError }
            }
            
            if attempts < maxAttempts {
                print("Gemini API call attempt \(attempts) failed. Retrying in \(2 * attempts) seconds...")
                await Task.sleep(UInt64(2 * Double(attempts) * 1_000_000_000.0))
            }
        }
        throw lastError
    }

    // MARK: – Transcription (Updated to return LLMCall)
    func transcribeChunk(batchId: Int64, stitchedFileURL: URL, mimeType: String, apiKey: String) async throws -> (transcripts: [TranscriptChunk], log: LLMCall) {
        let callStartTime = Date() // For the LLMCall timestamp
        let fileURI: String
        do {
            (_, fileURI) = try await uploadAndAwait(stitchedFileURL, mimeType: mimeType, key: apiKey)
        } catch {
            // ... error handling ...
            if let geminiError = error as? GeminiServiceError { throw TranscriptionError.fileUploadFailed(geminiError.localizedDescription) }
            throw TranscriptionError.fileUploadFailed(error.localizedDescription)
        }

        let finalTranscriptionPrompt = """
        Your job is to act as an expert transcriber for someone's computer usage. your descriptions should capture context and intent of the what the user is doing. 
        for example, if the user is watching a youtube video, what's important is capturing the essence of what the video is about, not necessarily every invidiaul detail about the video. 
        Each transcription should include a timestamp range of the particular action eg (MM:SS - MM:SS). Each transcription should also be >30seconds long, although exercise your judgement.
         If you're going to start a separate transcription, it should be because of a big shift in context.
        """

        let transcriptionSchema: [String:Any] = [
          "type":"ARRAY",
          "items": [
            "type":"OBJECT",
            "properties":[
              "startTimestamp":["type":"STRING"],
              "endTimestamp":  ["type":"STRING"],
              "description":   ["type":"STRING"]
            ],
            "required":["startTimestamp","endTimestamp","description"],
            "propertyOrdering":["startTimestamp","endTimestamp","description"]
          ]
        ]
        
        let generationConfig: [String: Any] = [
            "temperature": 0.3,
            "maxOutputTokens": 65536,
            "responseMimeType": "application/json",
            "responseSchema": transcriptionSchema,
            "thinkingConfig": ["thinkingBudget": 24576]
        ]

        let requestBody: [String: Any] = [
            "contents": [["parts": [
                ["file_data": ["mime_type": mimeType, "file_uri": fileURI]],
                ["text": finalTranscriptionPrompt]
            ]]],
            "generationConfig": generationConfig
        ]
        
        let (videoTranscriptChunks, responseText, _, latency) = try await callGeminiAPI(
            apiKey: apiKey,
            requestBody: requestBody,
            targetType: [TranscriptChunk].self,
            apiEndpoint: self.genEndpoint
        )
        
        let mmssRegex = #"^\d{1,2}:[0-5]\d$"#
        let badChunk = videoTranscriptChunks.first { !$0.startTimestamp.matches(mmssRegex) || !$0.endTimestamp.matches(mmssRegex) }
        if badChunk != nil {
            print("Invalid timestamp found: start='\(badChunk!.startTimestamp)', end='\(badChunk!.endTimestamp)' for batch \(batchId)")
            throw TranscriptionError.invalidTimestampFormat
        }
        
        let log = LLMCall(timestamp: callStartTime, latency: latency, input: finalTranscriptionPrompt, output: responseText)
        return (videoTranscriptChunks, log)
    }

    // MARK: - Generate ActivityCards from Transcript (Updated to return LLMCall and take context)
    func generateActivityCardsFromTranscript(
        batchId: Int64,
        transcripts: [TranscriptChunk],
        apiKey: String,
        previousSegmentsJSON: String, // Added parameter
        userTaxonomy: String,         // Added parameter
        extractedTaxonomy: String     // Added parameter
    ) async throws -> (cards: [ActivityCard], log: LLMCall) {
        let callStartTime = Date()
        let transcriptText = transcripts.map { "[\($0.startTimestamp) - \($0.endTimestamp)]: \($0.description)" }.joined(separator: "\n")

        let activityGenerationPrompt = """
        You are Dayflow, an AI that converts screen recordings into a JSON timeline.
        –––––  OUTPUT  –––––
        Return only a JSON array of segments, each with:
        startTimestamp (video timestamp, like 1:32)
        endTimestamp
        category
        subcategory
        title  (max 3 words, should be 1-2 usually. Something like Coding or Twitter so the user has a quick high level understanding, more precise than subcategory)
        summary (1-2 casual sentences, **no “I”/first-person pronouns**; start with a verb and focus on what was accomplished)
        detailed summary (longer factual description used only as context for future analysis)
        distractions (optional array of {startTime, endTime, title, summary})
        –––––  CORE RULES  –––––
        Segments should always be 5+ minutes
        Strongly prioritize keeping all continuous work related to a single project, feature, or overall goal within one segment.
        Sub‑5 min detours → put in distractions.
        Segments must not overlap.
        Always try to adhere and use the user provided categories and subcategories wherever possible. If none fit, try adhering to the categories and subcategories in previous segments, which will be provided below. However, if the segment doesn't fit any of the provided taxonomy, or no taxonomy is provided, try to go with broad categories/subcategories. Some examples for reference Productive Work: [Coding, Writing, Design, Data Analysis, Project Management] Communication & Collaboration: [Email, Meetings, Slack] Distractions [Twitter, Social Media, Texting] Idle: [Idle]
        Try not to exceed 4 subcategories.
        Sometimes, users will be idle, in other words nothing will happen on the screen for 5+ minutes. we should create a new segment and label it Idle - Idle in that case.
        –––––  SCATTERED‑ACTIVITY RULE  –––––
        For any 5 + min window of rapid switching:
        • If one activity recurs most, make it the segment; others → distractions.
        –––––  DISTRACTION DETAILS  –––––
        Log any distraction ≥ 30 s and < 5 min. do not log distractions that are shorter than 30s
        –––––  CONTINUITY  –––––
        Examine the most recent previous Segment carefully. More likely than not, the first segment of this video analysis is a continuation of the previous segment. In that case, you should do your best to use the same category/subcategory.
        \(transcriptText)
        OUTPUT FORMAT: JSON array of ActivityCards. startTime/endTime as MM:SS strings.
            USER PREFERRED TAXONOMY:
            \(userTaxonomy)
            SYSTEM GENERATED TAXONOMY:
            \(extractedTaxonomy)
            PREVIOUS SEGMENT:
            \(previousSegmentsJSON)
        """
        print(activityGenerationPrompt)
        let distractionSchema: [String: Any] = [
            "type": "OBJECT", "properties": ["startTime": ["type": "STRING"], "endTime": ["type": "STRING"], "title": ["type": "STRING"], "summary": ["type": "STRING"]],
            "required": ["startTime", "endTime", "title", "summary"], "propertyOrdering": ["startTime", "endTime", "title", "summary"]
        ]
        let activityCardSchema: [String: Any] = [
            "type": "OBJECT", "properties": [
                "startTime": ["type": "STRING"], "endTime": ["type": "STRING"], "category": ["type": "STRING"], "subcategory": ["type": "STRING"],
                "title": ["type": "STRING"], "summary": ["type": "STRING"], "detailedSummary": ["type": "STRING"],
                "distractions": ["type": "ARRAY", "items": distractionSchema, "nullable": true]
            ],
            "required": ["startTime", "endTime", "category", "subcategory", "title", "summary", "detailedSummary"],
            "propertyOrdering": ["startTime", "endTime", "category", "subcategory", "title", "summary", "detailedSummary", "distractions"]
        ]
        let responseSchemaForApi: [String: Any] = ["type": "ARRAY", "items": activityCardSchema]

        let generationConfig: [String: Any] = [
            "temperature": 0.3,
            "maxOutputTokens": 65536,
            "responseMimeType": "application/json",
            "responseSchema": responseSchemaForApi,
            "thinkingConfig": ["thinkingBudget": 24576]
        ]
        let requestBody: [String: Any] = [
            "contents": [["parts": [["text": activityGenerationPrompt]]]],
            "generationConfig": generationConfig
        ]

        let (generatedCards, responseText, _, latency) = try await callGeminiAPI(
            apiKey: apiKey,
            requestBody: requestBody,
            targetType: [ActivityCard].self,
            apiEndpoint: self.genEndpoint
        )
        
        let log = LLMCall(timestamp: callStartTime, latency: latency, input: activityGenerationPrompt, output: responseText)
        return (generatedCards, log)
    }

}

// MARK: – URLSession sync helper -------------------------------------------

private extension URLSession {
    func syncDataTask(with req: URLRequest) throws -> (Data?, URLResponse?) {
        let sema = DispatchSemaphore(value: 0)
        var d: Data?; var r: URLResponse?; var e: Error?
        dataTask(with: req) { d = $0; r = $1; e = $2; sema.signal() }.resume(); sema.wait()
        if let err = e { throw err }; return (d, r)
    }
}
