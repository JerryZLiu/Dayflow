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

        queue.async { [weak self] in
            guard let self else { return }
            Task {
                var callLogs: [LLMCall] = []
                do {
                    // 1. gather & stitch -------------------------------------------------
                    let chunks = StorageManager.shared.chunksForBatch(batchId)
                    guard !chunks.isEmpty else { throw GeminiServiceError.noChunks }
                    let urls = chunks.map { URL(fileURLWithPath: $0.fileUrl) }
                    let stitched = try await self.stitch(urls: urls)
                    defer { try? FileManager.default.removeItem(at: stitched) }

                // 2. upload via Files API -------------------------------------------
                let mime = self.mimeType(for: stitched) ?? "video/mp4"
                let (_, fileURI) = try self.uploadAndAwait(stitched, mimeType: mime, key: key)

                // --- Prepare previous segments ---
                let todayString = self.getCurrentDayStringFor4AMBoundary()
                let previousCards = StorageManager.shared.fetchTimelineCards(forDay: todayString)
                var previousSegmentsJSONString = "No previous segment for today."

                if let lastCard = previousCards.last {
                    let summary = PreviousSegmentSummary(
                        category: lastCard.category,
                        subcategory: lastCard.subcategory,
                        title: lastCard.title,
                        summary: lastCard.summary,
                        detailedSummary: lastCard.detailedSummary
                    )

                    let encoder = JSONEncoder()
                    encoder.outputFormatting = .prettyPrinted // easier to read in prompt
                    if let jsonData = try? encoder.encode([summary]) {
                        if let jsonString = String(data: jsonData, encoding: .utf8) {
                            previousSegmentsJSONString = jsonString
                        } else {
                            print("Error: Could not convert the previous segment JSON to string.")
                        }
                    } else {
                        print("Error: Could not encode the previous segment summary to JSON data.")
                    }
                }
                // --- End prepare previous segments ---

                // 3. generateContent -------------------------------------------------
                // --- Load and format user-preferred taxonomy from UserDefaults ---
                var formattedUserTaxonomy = "No custom taxonomy provided by user."
                var formattedExtractedTaxonomy = "No previous taxonomy found."
                let taxonomyKey = "userDefinedTaxonomyJSON" // Key for UserDefaults

                // First, parse the user-defined taxonomy
                var userTaxonomyDict: [String: Set<String>] = [:]
                if let taxonomyJSONString = self.userDefaults.string(forKey: taxonomyKey), !taxonomyJSONString.isEmpty {
                    if let jsonData = taxonomyJSONString.data(using: .utf8) {
                        do {
                            if let parsedDict = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: [String]] {
                                // Convert arrays to sets for faster lookups
                                for (category, subcategories) in parsedDict {
                                    userTaxonomyDict[category] = Set(subcategories)
                                }
                                
                                var tempFormattedTaxonomy = ""
                                for (category, subcategories) in parsedDict.sorted(by: { $0.key < $1.key }) {
                                    // Format subcategories as a JSON-style array with quotes
                                    let subcategoriesFormatted = subcategories.sorted().map { "\"\($0)\"" }.joined(separator: ", ")
                                    tempFormattedTaxonomy += "\(category): [\(subcategoriesFormatted)]\n"
                                }
                                if !tempFormattedTaxonomy.isEmpty {
                                    formattedUserTaxonomy = tempFormattedTaxonomy.trimmingCharacters(in: .whitespacesAndNewlines)
                                } else {
                                    print("Warning: Parsed user taxonomy dictionary was empty.")
                                }
                            } else {
                                print("Error: Could not cast parsed taxonomy JSON to [String: [String]]. JSON: \(taxonomyJSONString)")
                            }
                        } catch {
                            print("Error parsing userDefinedTaxonomyJSON from UserDefaults: \(error.localizedDescription). JSON: \(taxonomyJSONString)")
                        }
                    } else {
                         print("Error: Could not convert taxonomyJSONString to data. JSON: \(taxonomyJSONString)")
                    }
                } else {
                    print("No userDefinedTaxonomyJSON found in UserDefaults or it is empty.")
                }
                
                // Next, extract taxonomy from previous timeline cards
                var extractedTaxonomyDict: [String: Set<String>] = [:]
                if !previousCards.isEmpty {
                    for card in previousCards {
                        let category = card.category
                        let subcategory = card.subcategory
                        
                        // Only add if this category/subcategory pair isn't in the user taxonomy
                        if userTaxonomyDict[category]?.contains(subcategory) != true {
                            // Initialize the set if needed
                            if extractedTaxonomyDict[category] == nil {
                                extractedTaxonomyDict[category] = []
                            }
                            extractedTaxonomyDict[category]?.insert(subcategory)
                        }
                    }
                    
                    // Format the extracted taxonomy
                    if !extractedTaxonomyDict.isEmpty {
                        var tempFormattedTaxonomy = ""
                        for (category, subcategories) in extractedTaxonomyDict.sorted(by: { $0.key < $1.key }) {
                            let subcategoriesFormatted = Array(subcategories).sorted().map { "\"\($0)\"" }.joined(separator: ", ")
                            tempFormattedTaxonomy += "\(category): [\(subcategoriesFormatted)]\n"
                        }
                        if !tempFormattedTaxonomy.isEmpty {
                            formattedExtractedTaxonomy = tempFormattedTaxonomy.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                }
                
                print("User Taxonomy: \(formattedUserTaxonomy)")
                print("System generated Taxonomy: \(formattedExtractedTaxonomy)")
                // --- End load and format taxonomies ---
                
                let prompt = """
                You are Dayflow, an AI that converts screen recordings into a JSON timeline.
                –––––  OUTPUT  –––––
                Return only a JSON array of segments, each with:
                startTimestamp (video timestamp, like 1:32, NEVER reference the system clock time like 3:23PM)
                endTimestamp
                category
                subcategory
                title  (max 3 words, should be 1-2 usually. Something like Coding or Twitter so the user has a quick high level understanding, more precise than subcategory)
                summary (1-2 sentences concise narration of what the user did, think diary entry from the user perspective)
                detailed summary (longer factual description used only as context for future analysis)
                distractions (optional array of {startTime, endTime, title, summary})
                –––––  CORE RULES  –––––
                Segments should always be 5+ minutes
                Strongly prioritize keeping all continuous work related to a single project, feature, or overall goal within one segment.
                Sub‑5 min detours → put in distractions.
                Segments must not overlap.
                Always try to adhere and use the user provided categories and subcategories wherever possible. If none fit, try adhering to the previously extracted taxonomy, which will be provided below. However, if the segment doesn't fit any of the provided taxonomy, or no taxonomy is provided, try to go with broad categories/subcategories. Some examples for reference Productive Work: [Coding, Writing, Design, Data Analysis, Project Management] Communication & Collaboration: [Email, Meetings, Slack] Distractions [Twitter, Social Media, Texting] Idle: [Idle]
                Try not to exceed 4 subcategories.
                Sometimes, users will be idle, in other words nothing will happen on the screen for 5+ minutes. we should create a new segment and label it Idle - Idle in that case.
                –––––  SCATTERED‑ACTIVITY RULE  –––––
                For any 5 + min window of rapid switching:
                • If one activity recurs most, make it the segment; others → distractions.
                –––––  DISTRACTION DETAILS  –––––
                Log any distraction ≥ 30 s and < 5 min. do not log distractions that are shorter than 30s
                –––––  CONTINUITY  –––––
                Examine the most recent previous Segment carefully. More likely than not, the first segment of this video analysis is a continuation of the previous segment. In that case, you should do your best to use the same category/subcategory.
                –––––  USER PREFERRED TAXONOMY  –––––
                Remember to adhere to these user provided categories/subcategories wherever possible.
                \(formattedUserTaxonomy)
                
                –––––  SYSTEM GENERATED TAXONOMY  –––––
                If the user taxonomy doesn't fit, try to use these categories/subcategories extracted from previous segments.
                \(formattedExtractedTaxonomy)
                
                ----- PREVIOUS SEGMENT -----
                \(previousSegmentsJSONString)

                ----- Thinking Instructions/Plan you should always adhere to ------
                First create a high level description of everything the user did using timestamps. Remember that timestamps are in this format MM:SS. so 0:00 to 5:00 is 5 minutes.
                Then, using the instructions above try to group the screentime into larger 5+ minute segments.
                At the end of your thinking each segment should be 5+ minutes long. Do your best to minimize the amount of segments if at all possible. Distractions should be >30s long. At the end of your thinking, reflect rigorously on whether you have met these guidelines and make corrections if you need before outputting the final answer.
                """
                
                // New variables for retry logic
                var attempts = 0
                let maxAttempts = 3  // Original attempt + 2 retries
                var finalDecodedCards: [ActivityCard]? = nil
                
                // Start retry loop
                while attempts < maxAttempts && finalDecodedCards == nil {
                    attempts += 1
                    print("📝 Processing batch \(batchId): Attempt \(attempts) of \(maxAttempts)")
                    
                    let distractionSchema: [String: Any] = [
                        "type": "OBJECT",
                        "properties": [
                            "startTime": ["type": "STRING"],
                            "endTime": ["type": "STRING"],
                            "title": ["type": "STRING"],
                            "summary": ["type": "STRING"]
                        ],
                        "required": ["startTime", "endTime", "title", "summary"],
                        "propertyOrdering": ["startTime", "endTime", "title", "summary"]
                    ]

                    let activityCardSchema: [String: Any] = [
                        "type": "OBJECT",
                        "properties": [
                            "startTime": ["type": "STRING"],
                            "endTime": ["type": "STRING"],
                            "category": ["type": "STRING"],
                            "subcategory": ["type": "STRING"],
                            "title": ["type": "STRING"],
                            "summary": ["type": "STRING"],
                            "detailedSummary": ["type": "STRING"],
                            "distractions": [
                                "type": "ARRAY",
                                "items": distractionSchema,
                                "nullable": true
                            ]
                        ],
                        "required": ["startTime", "endTime", "category", "subcategory", "title", "summary", "detailedSummary"],
                        "propertyOrdering": ["startTime", "endTime", "category", "subcategory", "title", "summary", "detailedSummary", "distractions"]
                    ]

                    let responseSchemaForApi: [String: Any] = [
                        "type": "ARRAY",
                        "items": activityCardSchema
                    ]

                    let body: [String: Any] = [
                        "contents": [[
                            "parts": [
                                ["file_data": [
                                    "mime_type": mime,
                                    "file_uri": fileURI
                                ]],
                                ["text": prompt]
                            ]
                        ]],
                        "generationConfig": [
                            "temperature": 0.3,
                            "maxOutputTokens": 65536,
                            "responseMimeType": "application/json",
                            "responseSchema": responseSchemaForApi,
                            "thinkingConfig": [
                                "thinkingBudget": 24576
                            ]
                        ]
                    ]
                    let jsonData = try JSONSerialization.data(withJSONObject: body)

                    // curl dump -------------------------------------------------------
                    self.dumpCurl(batchId: batchId, json: jsonData, key: key)

                    // request --------------------------------------------------------
                    var comps = URLComponents(string: self.genEndpoint)!; comps.queryItems = [URLQueryItem(name: "key", value: key)]
                    var req = URLRequest(url: comps.url!);
                    req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = jsonData; req.timeoutInterval = 300

                    let requestString = String(data: jsonData, encoding: .utf8) ?? ""
                    let startCall = Date()
                    let (d, r) = try URLSession.shared.syncDataTask(with: req)
                    let latency = Date().timeIntervalSince(startCall)
                    guard let http = r as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        let msg = String(data: d ?? Data(), encoding: .utf8) ?? "<no body>"
                        throw GeminiServiceError.requestFailed(msg)
                    }
                    guard let data = d else { throw GeminiServiceError.invalidResponse }
                    
                    // Log the raw response data as a string for debugging
                    let responseString = String(data: data, encoding: .utf8) ?? ""
                    if !responseString.isEmpty {
                        print("📄 Raw Gemini Response Data:")
                        print(responseString)
                    } else {
                        print("📄 Could not decode raw Gemini response data as UTF-8.")
                    }

                    // 1. Decode the top-level API response
                    let apiResponse = try JSONDecoder().decode(GeminiAPIResponse.self, from: data)

                    // 2. Extract the JSON string from the relevant part
                    guard let firstCandidate = apiResponse.candidates.first,
                          let firstPart = firstCandidate.content.parts.first,
                          let jsonDataString = firstPart.text.data(using: .utf8) else {
                        throw GeminiServiceError.invalidResponse
                    }
                    
                    // 3. Decode the actual [ActivityCard] array from the extracted string data
                    let decodedCards = try JSONDecoder().decode([ActivityCard].self, from: jsonDataString)
                    
                    // Print the decoded cards for verification
                    print("✅ Decoded Activity Cards (Attempt \(attempts)):")
                    print(decodedCards)
                    callLogs.append(LLMCall(timestamp: startCall,
                                            latency: latency,
                                            input: requestString,
                                            output: responseString))
                    
                    // 4. Validate the response with a second Gemini call
                    if attempts < maxAttempts { // Only validate if we have retries left
                        // Convert jsonDataString (Data) to a String before passing to validateGeminiOutput
                        guard let jsonString = String(data: jsonDataString, encoding: .utf8) else {
                            print("❌ Could not convert JSON data to string for validation")
                            continue // Try again in the next iteration
                        }
                        
                        let (validationResult, valCall) = try self.validateGeminiOutput(prompt: prompt, output: jsonString, key: key)
                        callLogs.append(valCall)
                        if validationResult.contains("pass") {
                            print("✅ Validation PASSED for attempt \(attempts)")
                            finalDecodedCards = decodedCards
                        } else {
                            print("❌ Validation FAILED for attempt \(attempts) - will retry")
                            // Will retry in the next loop iteration
                        }
                    } else {
                        // On the last attempt, use whatever we got
                        print("⚠️ Final attempt \(attempts) - using result regardless of validation")
                        finalDecodedCards = decodedCards
                    }
                }
                
                // If we exited the loop without valid cards, throw an error
                guard let finalCards = finalDecodedCards else {
                    throw GeminiServiceError.processingFailed("Failed to generate valid output after \(maxAttempts) attempts")
                }

                StorageManager.shared.updateBatchLLMMetadata(batchId: batchId, calls: callLogs)
                DispatchQueue.main.async { completion(.success(finalCards)) }

            } catch {
                StorageManager.shared.updateBatchLLMMetadata(batchId: batchId, calls: callLogs)
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
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
                break                                   // ✅ ready to use
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

    private func stitch(urls: [URL]) async throws -> URL {
        let comp = AVMutableComposition()
        guard let trak = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw GeminiServiceError.stitchingFailed
        }
        var cursor = CMTime.zero
        for u in urls {
            let asset = AVURLAsset(url: u)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let src = tracks.first else { continue }
            let dur = try await asset.load(.duration)
            try trak.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: src, at: cursor)
            cursor = CMTimeAdd(cursor, dur)
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
curl \"\(comps.url!.absoluteString)\" \
  -H 'Content-Type: application/json' \
  -X POST \
  -d '\(js)'
"""
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("gemini_batch_\(batchId).sh")
        try? script.write(to: path, atomically: true, encoding: .utf8)
        print("📝 curl 👉 \(path.path)")
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

    // Helper function to validate Gemini output
    private func validateGeminiOutput(prompt: String, output: String, key: String) throws -> (String, LLMCall) {
        let validationPrompt = """
        Given this prompt:
        
        \(prompt)
        
        And this output:
        
        \(output)
        
        Reflect on whether the output satisfies 1. each segment is 5+ minutes long. 2. segments  If it does, return "pass". If it does not, return "fail".
        """
        
        print("🔍 Validating Gemini output...")
        
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
        print("🔍 Validation response: \(validationResponse)")

        let call = LLMCall(timestamp: startCall, latency: latency, input: requestString, output: validationResponse)
        return (validationResponse, call)
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
