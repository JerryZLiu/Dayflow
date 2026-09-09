import Foundation

struct JournalEntry: Codable, Sendable {
  var id: Int64?
  var day: String  // "2025-01-15" format (4AM boundary)
  var intentions: String?  // Morning intentions
  var notes: String?  // Additional notes
  var goals: String?  // Long-term goals
  var reflections: String?  // Evening reflection
  var summary: String?  // AI-generated summary
  var status: String  // "draft", "intentions_set", "complete"
  var createdAt: Date?
  var updatedAt: Date?

  init(
    id: Int64? = nil,
    day: String,
    intentions: String? = nil,
    notes: String? = nil,
    goals: String? = nil,
    reflections: String? = nil,
    summary: String? = nil,
    status: String = "draft",
    createdAt: Date? = nil,
    updatedAt: Date? = nil
  ) {
    self.id = id
    self.day = day
    self.intentions = intentions
    self.notes = notes
    self.goals = goals
    self.reflections = reflections
    self.summary = summary
    self.status = status
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

// Daily standup document stored as a JSON blob keyed by standup day.
struct DailyStandupEntry: Codable, Sendable {
  let standupDay: String  // "2025-01-15" format (Gregorian, local timezone)
  let payloadJSON: String  // Serialized standup payload blob
  let createdAt: Date?
  let updatedAt: Date?
}

// NEW: Observation struct for first-class transcript storage
struct Observation: Codable, Sendable {
  let id: Int64?
  let batchId: Int64
  let startTs: Int
  let endTs: Int
  let observation: String
  let metadata: String?
  let llmModel: String?
  let createdAt: Date?
}

// Re-add Distraction struct, as it's used by TimelineCard
struct Distraction: Codable, Sendable, Identifiable {
  let id: UUID
  let startTime: String
  let endTime: String
  let title: String
  let summary: String
  let videoSummaryURL: String?  // Optional link to video summary for the distraction

  // Custom decoder to handle missing 'id'
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Try to decode 'id', if not found or nil, assign a new UUID
    self.id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
    self.startTime = try container.decode(String.self, forKey: .startTime)
    self.endTime = try container.decode(String.self, forKey: .endTime)
    self.title = try container.decode(String.self, forKey: .title)
    self.summary = try container.decode(String.self, forKey: .summary)
    self.videoSummaryURL = try container.decodeIfPresent(String.self, forKey: .videoSummaryURL)
  }

  // Add explicit init to maintain memberwise initializer if needed elsewhere,
  // though Codable synthesis might handle this. It's good practice.
  init(
    id: UUID = UUID(), startTime: String, endTime: String, title: String, summary: String,
    videoSummaryURL: String? = nil
  ) {
    self.id = id
    self.startTime = startTime
    self.endTime = endTime
    self.title = title
    self.summary = summary
    self.videoSummaryURL = videoSummaryURL
  }

  // CodingKeys needed for custom decoder
  enum CodingKeys: String, CodingKey {
    case id, startTime, endTime, title, summary, videoSummaryURL
  }
}

struct TimelineCard: Codable, Sendable, Identifiable {
  var id = UUID()
  let recordId: Int64?
  let batchId: Int64?  // Tracks source batch for retry functionality
  let startTimestamp: String
  let endTimestamp: String
  let category: String
  let subcategory: String
  let title: String
  let summary: String
  let detailedSummary: String
  let day: String
  let distractions: [Distraction]?
  let videoSummaryURL: String?  // Optional link to primary video summary
  let otherVideoSummaryURLs: [String]?  // For merged cards, subsequent video URLs
  let appSites: AppSites?
  let isBackupGenerated: Bool?

  init(
    id: UUID = UUID(),
    recordId: Int64?,
    batchId: Int64?,
    startTimestamp: String,
    endTimestamp: String,
    category: String,
    subcategory: String,
    title: String,
    summary: String,
    detailedSummary: String,
    day: String,
    distractions: [Distraction]?,
    videoSummaryURL: String?,
    otherVideoSummaryURLs: [String]?,
    appSites: AppSites?,
    isBackupGenerated: Bool? = nil
  ) {
    self.id = id
    self.recordId = recordId
    self.batchId = batchId
    self.startTimestamp = startTimestamp
    self.endTimestamp = endTimestamp
    self.category = category
    self.subcategory = subcategory
    self.title = title
    self.summary = summary
    self.detailedSummary = detailedSummary
    self.day = day
    self.distractions = distractions
    self.videoSummaryURL = videoSummaryURL
    self.otherVideoSummaryURLs = otherVideoSummaryURLs
    self.appSites = appSites
    self.isBackupGenerated = isBackupGenerated
  }
}

/// Metadata about a single LLM request/response cycle
struct LLMCall: Codable, Sendable {
  let timestamp: Date?
  let latency: TimeInterval?
  let input: String?
  let output: String?
}

// DB record for llm_calls table
struct LLMCallDBRecord: Sendable {
  let batchId: Int64?
  let callGroupId: String?
  let attempt: Int
  let provider: String
  let model: String?
  let operation: String
  let status: String  // "success" | "failure"
  let latencyMs: Int?
  let httpStatus: Int?
  let requestMethod: String?
  let requestURL: String?
  let requestHeadersJSON: String?
  let requestBody: String?
  let responseHeadersJSON: String?
  let responseBody: String?
  let errorDomain: String?
  let errorCode: Int?
  let errorMessage: String?
}

struct TimelineCardDebugEntry: Sendable {
  let createdAt: Date?
  let batchId: Int64?
  let day: String
  let startTime: String
  let endTime: String
  let category: String
  let subcategory: String?
  let title: String
  let summary: String?
  let detailedSummary: String?
}

struct TimelineReviewRatingSegment: Sendable {
  let id: Int64
  let startTs: Int
  let endTs: Int
  let rating: String
}

struct LLMCallDebugEntry: Sendable {
  let createdAt: Date?
  let batchId: Int64?
  let callGroupId: String?
  let attempt: Int
  let provider: String
  let model: String?
  let operation: String
  let status: String
  let latencyMs: Int?
  let httpStatus: Int?
  let requestMethod: String?
  let requestURL: String?
  let requestBody: String?
  let responseBody: String?
  let errorMessage: String?
}

// Add TimelineCardShell struct for the new save function
struct TimelineCardShell: Sendable {
  let startTimestamp: String
  let endTimestamp: String
  let category: String
  let subcategory: String
  let title: String
  let summary: String
  let detailedSummary: String
  let distractions: [Distraction]?  // Keep this, it's part of the initial save
  let appSites: AppSites?
  let isBackupGenerated: Bool?
  let idleMetadata: IdleCardMetadata?
  // No videoSummaryURL here, as it's added later
  // No batchId here, as it's passed as a separate parameter to the save function

  init(
    startTimestamp: String,
    endTimestamp: String,
    category: String,
    subcategory: String,
    title: String,
    summary: String,
    detailedSummary: String,
    distractions: [Distraction]?,
    appSites: AppSites?,
    isBackupGenerated: Bool? = nil,
    idleMetadata: IdleCardMetadata? = nil
  ) {
    self.startTimestamp = startTimestamp
    self.endTimestamp = endTimestamp
    self.category = category
    self.subcategory = subcategory
    self.title = title
    self.summary = summary
    self.detailedSummary = detailedSummary
    self.distractions = distractions
    self.appSites = appSites
    self.isBackupGenerated = isBackupGenerated
    self.idleMetadata = idleMetadata
  }
}

struct IdleCardMetadata: Codable, Sendable {
  let classifierVersion: String
  let inputCoverageRatio: Double
  let coveredSeconds: Int
  let batchDurationSeconds: Int
  let largestUncoveredGapSeconds: Int
  let screenshotCount: Int
  let sampledIdleScreenshotCount: Int
  let averageIdleSecondsAtCapture: Double
  let maxIdleSecondsAtCapture: Int
  let mergedWithPreviousIdle: Bool
  let mergeGapSeconds: Int?
  let skippedLLM: Bool
}

// New metadata envelope to support multiple fields under one JSON column
struct TimelineMetadata: Codable {
  let distractions: [Distraction]?
  let appSites: AppSites?
  let isBackupGenerated: Bool?
  let idle: IdleCardMetadata?
}

struct AnalysisBatchDebugEntry: Sendable {
  let id: Int64
  let status: String
  let startTs: Int
  let endTs: Int
  let createdAt: Date?
  let reason: String?
}

// Extended TimelineCard with timestamp fields for internal use
struct TimelineCardWithTimestamps {
  let id: Int64
  let startTimestamp: String
  let endTimestamp: String
  let startTs: Int
  let endTs: Int
  let category: String
  let subcategory: String
  let title: String
  let summary: String
  let detailedSummary: String
  let day: String
  let distractions: [Distraction]?
  let videoSummaryURL: String?
}
