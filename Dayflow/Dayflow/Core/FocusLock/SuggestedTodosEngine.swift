//
//  SuggestedTodosEngine.swift
//  FocusLock
//
//  Intelligent task suggestion engine that analyzes user activity data to extract actionable tasks
//  with priority scoring, context awareness, and learning capabilities
//

import Foundation
import CoreML
import NaturalLanguage
import GRDB
import os.log
import SwiftUI

@MainActor
class SuggestedTodosEngine: ObservableObject {
    private let logger = Logger(subsystem: "FocusLock", category: "SuggestedTodosEngine")

    // Dependencies
    private let activityTap = ActivityTap.shared
    private let sessionManager = SessionManager.shared

    // Database
    private var databaseQueue: DatabaseQueue?

    // Configuration
    private var config = SuggestionEngineConfig()

    // NLP Components
    private var nlpTagger: NLTagger?
    private var actionClassifier: NLModel?

    // Published data for UI
    @Published var currentSuggestions: [SuggestedTodo] = []

    // Learning data
    private var userPreferences = UserPreferenceProfile()
    private var suggestionHistory: [SuggestedTodo] = []

    // Performance tracking
    private var processingTimes: [TimeInterval] = []
    private var generationStats: GenerationStats

    // Async initialization tracking
    private var isInitialized = false
    private var initializationTask: Task<Void, Never>?

    private init() {
        // ✅ NO synchronous database operations in init
        // Initialize only non-blocking components
        generationStats = GenerationStats()
        // Database setup deferred to ensureInitialized()
    }

    /// Ensures the database and components are initialized before use
    func ensureInitialized() async {
        // Check if already initialized
        guard !isInitialized else { return }

        // Check if initialization is in progress
        if let task = initializationTask {
            await task.value
            return
        }

        // Start initialization
        let task = Task {
            await performInitialization()
        }
        initializationTask = task
        await task.value
    }

    private func performInitialization() async {
        guard !isInitialized else { return }

        do {
            // Initialize database path
            let dbPath = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("FocusLock")
                .appendingPathComponent("SuggestedTodos.sqlite")

            try FileManager.default.createDirectory(at: dbPath.deletingLastPathComponent(), withIntermediateDirectories: true)

            // Create database queue with proper configuration
            var config = Configuration()
            config.qos = .userInitiated // Prevent priority inversion
            config.prepareDatabase { db in
                db.busyMode = .timeout(5.0)
                try db.execute(sql: "PRAGMA journal_mode = WAL")
            }

            let queue = try DatabaseQueue(path: dbPath.path, configuration: config)
            self.databaseQueue = queue

            // Setup database schema asynchronously
            try await setupDatabaseAsync(queue: queue)

            // Load data asynchronously
            await loadUserPreferencesAsync()
            await loadSuggestionHistoryAsync()

            // Initialize NLP components (non-blocking)
            initializeNLPComponents()

            // Start background processing
            startBackgroundProcessing()

            isInitialized = true
            logger.info("✅ SuggestedTodosEngine initialized successfully")

        } catch {
            logger.error("❌ Failed to initialize SuggestedTodosEngine: \(error.localizedDescription)")
            // Set initialized to prevent infinite retry loops
            isInitialized = true
        }
    }

    // MARK: - Public Interface

    func generateSuggestions(from activity: Activity? = nil) async -> [SuggestedTodo] {
        await ensureInitialized()

        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            // Check if we should interrupt focus session
            guard shouldShowSuggestions() else {
                logger.info("Skipping suggestions due to active focus session")
                return []
            }

            let sourceActivity: Activity?
            if let activity = activity {
                sourceActivity = activity
            } else {
                sourceActivity = activityTap.currentActivity
            }
            guard let currentActivity = sourceActivity else {
                logger.warning("No activity data available for suggestion generation")
                return []
            }

            // Extract task suggestions from activity data
            let extractedTaskSuggestions = await extractTaskSuggestions(from: currentActivity)

            // Apply priority scoring and filtering
            var suggestedTodos = await applyPriorityScoring(to: extractedTaskSuggestions, activity: currentActivity)

            // Apply user preference learning
            suggestedTodos = await applyUserPreferenceLearning(to: suggestedTodos)

            // Filter and limit suggestions
            let finalSuggestions = filterAndLimitSuggestions(suggestedTodos)

            // Store suggestions in database
            for suggestion in finalSuggestions {
                try await storeSuggestion(suggestion)
            }

            suggestionHistory.append(contentsOf: finalSuggestions)

            let duration = CFAbsoluteTimeGetCurrent() - startTime
            updateProcessingStats(duration: duration, suggestionsCount: finalSuggestions.count)

            logger.info("Generated \(finalSuggestions.count) task suggestions in \(String(format: "%.3f", duration))s")

            // Update published property for UI
            await MainActor.run {
                self.currentSuggestions = finalSuggestions
            }

            return finalSuggestions

        } catch {
            logger.error("Failed to generate suggestions: \(error.localizedDescription)")
            return []
        }
    }

    func getSuggestions(limit: Int = 10, priority: SuggestionPriority? = nil, category: String? = nil) async -> [SuggestedTodo] {
        await ensureInitialized()

        return await withCheckedContinuation { continuation in
            do {
                let queue = try getDatabaseQueue()
                try queue.read { db in
                    var query = "SELECT * FROM suggested_todos WHERE is_dismissed = 0"
                    var arguments = StatementArguments()

                    if let priority = priority {
                        query += " AND priority = ?"
                        arguments += [priority.rawValue]
                    }

                    if let category = category {
                        query += " AND context_tags LIKE ?"
                        arguments += ["%\(category)%"]
                    }

                    query += " ORDER BY urgency_score DESC, relevance_score DESC, created_at DESC LIMIT ?"
                    arguments += [limit]

                    let rows = try Row.fetchAll(db, sql: query, arguments: arguments)
                    let suggestions = rows.compactMap { try? parseSuggestedTodo(from: $0) }

                    continuation.resume(returning: suggestions)
                }
            } catch {
                logger.error("Failed to get suggestions: \(error.localizedDescription)")
                continuation.resume(returning: [])
            }
        }
    }

    func recordUserFeedback(for suggestionId: UUID, feedback: UserFeedback, accept: Bool = false) async throws {
        try await databaseQueue.write { db in
            let dismissReason = accept ? nil : feedback.comment
            let isDismissed = !accept && feedback.score < 0.5
            let arguments = StatementArguments([
                feedback.score,
                feedback.timestamp,
                feedback.comment as Any,
                accept,
                isDismissed,
                dismissReason as Any,
                0.0, // Will be updated by learning system
                Date(),
                suggestionId.uuidString
            ])
            try db.execute(sql: """
                UPDATE suggested_todos
                SET user_feedback_score = ?, user_feedback_timestamp = ?, user_feedback_comment = ?,
                    is_accepted = ?, is_dismissed = ?, dismiss_reason = ?, learning_score = ?, last_shown = ?
                WHERE id = ?
            """, arguments: arguments ?? StatementArguments())
        }

        // Update user preferences based on feedback
        if let suggestion = suggestionHistory.first(where: { $0.id == suggestionId }) {
            userPreferences.updateFromFeedback(feedback, suggestion: suggestion)
            try await saveUserPreferences()

            // Update learning scores for similar suggestions
            await updateLearningScores(for: suggestion, feedback: feedback)
        }

        logger.info("Recorded user feedback for suggestion \(suggestionId)")
    }

    func updateConfiguration(_ newConfig: SuggestionEngineConfig) async throws {
        config = newConfig
        try await saveConfiguration()
        logger.info("Updated suggestion engine configuration")
    }

    func getStatistics() -> SuggestionEngineStats {
        return SuggestionEngineStats(
            totalSuggestions: suggestionHistory.count,
            activeSuggestions: suggestionHistory.filter { $0.isActive }.count,
            averageConfidence: suggestionHistory.isEmpty ? 0 : suggestionHistory.reduce(0) { $0 + $1.confidence } / Double(suggestionHistory.count),
            averageProcessingTime: processingTimes.isEmpty ? 0 : processingTimes.reduce(0, +) / Double(processingTimes.count),
            userAcceptanceRate: calculateAcceptanceRate(),
            topActionTypes: getTopActionTypes(),
            userPreferenceProfile: userPreferences,
            generationStats: generationStats
        )
    }

    // MARK: - Private Methods

    private func getDatabaseQueue() throws -> DatabaseQueue {
        guard let queue = databaseQueue else {
            throw DatabaseError.notInitialized
        }
        return queue
    }

    private func setupDatabaseAsync(queue: DatabaseQueue) async throws {
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS suggested_todos (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    description TEXT,
                    priority TEXT NOT NULL,
                    confidence REAL NOT NULL,
                    source_content TEXT NOT NULL,
                    source_type TEXT NOT NULL,
                    source_activity_id TEXT,
                    context_tags TEXT, -- JSON array
                    estimated_duration INTEGER,
                    deadline INTEGER,
                    created_at INTEGER NOT NULL,
                    last_shown INTEGER,
                    user_feedback_score REAL,
                    user_feedback_timestamp INTEGER,
                    user_feedback_comment TEXT,
                    is_accepted INTEGER,
                    is_dismissed INTEGER NOT NULL DEFAULT 0,
                    dismiss_reason TEXT,
                    learning_score REAL NOT NULL DEFAULT 0.5,
                    urgency_score REAL NOT NULL,
                    relevance_score REAL NOT NULL
                )
            """)

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_suggested_todos_created_at
                ON suggested_todos(created_at)
            """)

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_suggested_todos_priority
                ON suggested_todos(priority)
            """)

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_suggested_todos_dismissed
                ON suggested_todos(is_dismissed)
            """)
        }
    }

    private func loadUserPreferencesAsync() async {
        do {
            let prefsPath = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("FocusLock")
                .appendingPathComponent("UserPreferences.json")

            if let data = try? Data(contentsOf: prefsPath) {
                userPreferences = try JSONDecoder().decode(UserPreferenceProfile.self, from: data)
                logger.info("Loaded user preferences from disk")
            }
        } catch {
            logger.error("Failed to load user preferences: \(error.localizedDescription)")
            userPreferences = UserPreferenceProfile()
        }
    }

    private func loadSuggestionHistoryAsync() async {
        let suggestions = await getSuggestions(limit: 1000)
        suggestionHistory = suggestions
        logger.info("Loaded \(suggestions.count) suggestions from database")
    }

    private func initializeNLPComponents() {
        Task {
            do {
                // Initialize NLTagger for NLP processing
                nlpTagger = NLTagger(tagSchemes: [.tokenType, .nameType, .lexicalClass])
                logger.info("Successfully initialized NLTagger")

                // Initialize action classifier if available
                try loadActionClassifier()

            } catch {
                logger.error("Failed to initialize NLP components: \(error.localizedDescription)")
            }
        }
    }

    private func loadActionClassifier() throws {
        // In a production environment, you would load a custom Core ML model
        // For now, we'll use rule-based classification
        logger.info("Using rule-based action classification")
    }

    private func startBackgroundProcessing() {
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task {
                await self?.backgroundProcessing()
            }
        }

        logger.info("Started background processing timer (5-minute intervals)")
    }

    private func backgroundProcessing() async {
        // Clean up old suggestions
        await cleanupOldSuggestions()

        // Update learning scores for pending suggestions
        await updateLearningScores()

        // Periodically re-generate suggestions if needed
        let recentSuggestions = await getSuggestions(limit: 5)
        if recentSuggestions.isEmpty {
            logger.info("No recent suggestions, generating new ones")
            _ = await generateSuggestions()
        }
    }

    @MainActor
    private func shouldShowSuggestions() -> Bool {
        guard sessionManager.isActive else { return true }

        // Use the probability threshold to determine if we should interrupt
        let interruptionProbability = config.focusSessionInterruptionThreshold
        let randomValue = Double.random(in: 0...1)

        return randomValue < interruptionProbability
    }

    private func extractTaskSuggestions(from activity: Activity) async -> [TaskSuggestion] {
        var suggestions: [TaskSuggestion] = []

        // Extract from fusion result
        suggestions.append(contentsOf: extractFromFusionResult(activity.fusionResult))

        // Extract from OCR content
        if let ocrResult = activity.ocrResult {
            suggestions.append(contentsOf: extractFromOCR(ocrResult, insights: activity.fusionResult.ocrInsights))
        }

        // Extract from accessibility content
        if let axResult = activity.axExtraction {
            suggestions.append(contentsOf: extractFromAccessibility(axResult))
        }

        // Extract from detected tasks
        suggestions.append(contentsOf: extractFromDetectedTasks(activity.fusionResult.detectedTasks))

        return suggestions
    }

    private func extractFromFusionResult(_ fusionResult: ActivityFusionResult) -> [TaskSuggestion] {
        var suggestions: [TaskSuggestion] = []

        let text = fusionResult.context

        // Use NLP to extract action items
        suggestions.append(contentsOf: extractActionItems(from: text, context: fusionResult.primaryCategory))

        return suggestions
    }

    private func extractFromOCR(_ ocrResult: OCRResult, insights: [OCRInsight]) -> [TaskSuggestion] {
        var suggestions: [TaskSuggestion] = []

        suggestions.append(contentsOf: extractActionItems(from: ocrResult.text, context: "ocr"))

        // Extract specific patterns from OCR insights
        for insight in insights {
            switch insight.type {
            case "date":
                if parseDate(from: insight.value) != nil {
                    suggestions.append(TaskSuggestion(
                        originalText: insight.value,
                        extractedTask: "Follow up on deadline: \(insight.value)",
                        confidence: 0.8,
                        actionType: .followUp,
                        context: "deadline",
                        suggestedPriority: .medium,
                        estimatedDuration: 15 * 60
                    ))
                }
            case "email":
                suggestions.append(TaskSuggestion(
                    originalText: insight.value,
                    extractedTask: "Process email: \(insight.value)",
                    confidence: 0.9,
                    actionType: .respond,
                    context: "communication",
                    suggestedPriority: .medium,
                    estimatedDuration: 10 * 60
                ))
            case "url":
                suggestions.append(TaskSuggestion(
                    originalText: insight.value,
                    extractedTask: "Review link: \(insight.value)",
                    confidence: 0.6,
                    actionType: .review,
                    context: "browsing",
                    suggestedPriority: .low
                ))
            default:
                break
            }
        }

        for region in ocrResult.regions {
            suggestions.append(contentsOf: extractActionItems(from: region.text, context: "ocr_region"))
        }

        return suggestions
    }

    private func extractFromAccessibility(_ axResult: AXExtractionResult) -> [TaskSuggestion] {
        var suggestions: [TaskSuggestion] = []

        if let content = axResult.content {
            suggestions.append(contentsOf: extractActionItems(from: content, context: "accessibility"))
        }

        // Extract from structured data
        if let structuredData = axResult.structuredData {
            for form in structuredData.forms {
                for element in form.elements {
                    guard let value = element.value?.lowercased() else { continue }
                    if value.contains("submit") || value.contains("send") {
                        suggestions.append(TaskSuggestion(
                            originalText: element.value ?? "",
                            extractedTask: "Complete form: \(element.title ?? "Form")",
                            confidence: 0.7,
                            actionType: .complete,
                            context: "form",
                            suggestedPriority: .medium
                        ))
                    }
                }
            }
        }

        return suggestions
    }

    private func extractFromDetectedTasks(_ tasks: [DetectedTask]) -> [TaskSuggestion] {
        return tasks.map { task in
            let taskText = task.pattern
            let originalText = task.context.isEmpty ? taskText : task.context
            return TaskSuggestion(
                originalText: originalText,
                extractedTask: taskText,
                confidence: task.confidence,
                actionType: inferActionType(from: taskText),
                context: task.category,
                suggestedPriority: inferPriority(from: taskText, confidence: task.confidence)
            )
        }
    }

    private func extractActionItems(from text: String, context: String) -> [TaskSuggestion] {
        var suggestions: [TaskSuggestion] = []

        // Split text into sentences
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?;"))

        for sentence in sentences {
            let trimmedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedSentence.count > 10 else { continue }

            // Look for action-oriented patterns
            let actionPatterns = [
                "(?i)(?:need to|should|must|have to|going to|will)\\s+([^.!?]+)",
                "(?i)(?:remember to|don't forget to)\\s+([^.!?]+)",
                "(?i)(?:todo|TODO)\\s*[:\\-]\\s*([^.!?]+)",
                "(?i)(?:action|action item)\\s*[:\\-]\\s*([^.!?]+)",
                "(?i)(?:please|could you)\\s+([^.!?]+)",
                "(?i)(?:complete|finish|review|check|verify|submit|send|write|create)\\s+([^.!?]+)"
            ]

            for pattern in actionPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                    let matches = regex.matches(in: trimmedSentence, range: NSRange(trimmedSentence.startIndex..., in: trimmedSentence))

                    for match in matches {
                        if match.numberOfRanges > 1 {
                            let taskRange = Range(match.range(at: 1), in: trimmedSentence)
                            if let taskText = taskRange {
                                let task = String(trimmedSentence[taskText])
                                let confidence = calculateConfidence(for: task, in: trimmedSentence, context: context)

                                if confidence >= config.minConfidenceThreshold {
                                    suggestions.append(TaskSuggestion(
                                        originalText: trimmedSentence,
                                        extractedTask: task,
                                        confidence: confidence,
                                        actionType: inferActionType(from: task),
                                        context: context,
                                        suggestedPriority: inferPriority(from: task, confidence: confidence),
                                        estimatedDuration: estimateDuration(for: task)
                                    ))
                                }
                            }
                        }
                    }
                }
            }
        }

        return suggestions
    }

    private func calculateConfidence(for task: String, in sentence: String, context: String) -> Double {
        var confidence = 0.5 // Base confidence
        let lowercaseTask = task.lowercased()

        // Higher confidence for clear action verbs
        let strongActions = ["complete", "submit", "send", "finish", "review", "check"]
        if strongActions.contains(where: { lowercaseTask.contains($0) }) {
            confidence += 0.2
        }

        // Higher confidence in work-related contexts
        let workContexts = ["development", "planning", "review", "meeting", "documentation"]
        if workContexts.contains(context.lowercased()) {
            confidence += 0.1
        }

        // Higher confidence for tasks with specific details
        let detailIndicators = ["by", "before", "after", "at", "on", "due"]
        if detailIndicators.contains(where: { lowercaseTask.contains($0) }) {
            confidence += 0.1
        }

        return min(confidence, 1.0)
    }

    private func inferActionType(from task: String) -> TaskSuggestion.ActionType {
        let lowercaseTask = task.lowercased()

        if lowercaseTask.contains("create") || lowercaseTask.contains("make") || lowercaseTask.contains("build") {
            return .create
        } else if lowercaseTask.contains("review") || lowercaseTask.contains("check") || lowercaseTask.contains("verify") {
            return .review
        } else if lowercaseTask.contains("schedule") || lowercaseTask.contains("plan") || lowercaseTask.contains("organize") {
            return .schedule
        } else if lowercaseTask.contains("research") || lowercaseTask.contains("study") || lowercaseTask.contains("learn") {
            return .research
        } else if lowercaseTask.contains("email") || lowercaseTask.contains("call") || lowercaseTask.contains("message") {
            return .contact
        } else if lowercaseTask.contains("reply") || lowercaseTask.contains("respond") || lowercaseTask.contains("answer") {
            return .respond
        } else if lowercaseTask.contains("follow") || lowercaseTask.contains("check in") {
            return .followUp
        } else if lowercaseTask.contains("prepare") || lowercaseTask.contains("setup") || lowercaseTask.contains("ready") {
            return .prepare
        } else {
            return .complete
        }
    }

    private func inferPriority(from task: String, confidence: Double) -> SuggestionPriority {
        let lowercaseTask = task.lowercased()

        // Check for urgency keywords
        let urgencyKeywords = ["asap", "urgent", "immediately", "right away", "as soon as possible"]
        if urgencyKeywords.contains(where: { lowercaseTask.contains($0) }) {
            return .urgent
        }

        // Check for importance keywords
        let importanceKeywords = ["important", "critical", "priority", "required", "must"]
        if importanceKeywords.contains(where: { lowercaseTask.contains($0) }) {
            return .high
        }

        // Check for low priority keywords
        let lowPriorityKeywords = ["maybe", "consider", "optional", "nice to have", "if time"]
        if lowPriorityKeywords.contains(where: { lowercaseTask.contains($0) }) {
            return .low
        }

        // Use confidence as a fallback
        if confidence > 0.8 {
            return .high
        } else if confidence > 0.6 {
            return .medium
        } else {
            return .low
        }
    }

    private func estimateDuration(for task: String) -> TimeInterval {
        let wordCount = task.components(separatedBy: .whitespaces).count
        let lowercaseTask = task.lowercased()

        // Base estimation: 1 minute per word
        var baseEstimate = TimeInterval(wordCount * 60)

        // Adjust for task complexity
        if lowercaseTask.contains("create") || lowercaseTask.contains("write") {
            baseEstimate *= 1.5
        } else if task.lowercased().contains("review") || task.lowercased().contains("check") {
            baseEstimate *= 0.8
        } else if task.lowercased().contains("research") || task.lowercased().contains("study") {
            baseEstimate *= 2.0
        }

        // Cap at 4 hours and minimum 5 minutes
        return max(5 * 60, min(4 * 60 * 60, baseEstimate))
    }

    private func applyPriorityScoring(to suggestions: [TaskSuggestion], activity: Activity) async -> [SuggestedTodo] {
        var scoredSuggestions: [SuggestedTodo] = []

        for taskSuggestion in suggestions {
            var suggestedTodo = SuggestedTodo(
                title: taskSuggestion.extractedTask,
                description: "Extracted from: \(taskSuggestion.originalText.prefix(100))",
                priority: taskSuggestion.suggestedPriority,
                confidence: taskSuggestion.confidence,
                sourceContent: taskSuggestion.originalText,
                sourceType: .activityFusion,
                sourceActivityId: activity.id,
                contextTags: [taskSuggestion.context],
                estimatedDuration: taskSuggestion.estimatedDuration
            )

            // Calculate comprehensive priority score
            let priorityScore = calculatePriorityScore(
                for: suggestedTodo,
                taskSuggestion: taskSuggestion,
                activity: activity
            )

            suggestedTodo.updateLearningScore(priorityScore)
            scoredSuggestions.append(suggestedTodo)
        }

        return scoredSuggestions.sorted { $0.urgencyScore > $1.urgencyScore }
    }

    private func calculatePriorityScore(for suggestion: SuggestedTodo, taskSuggestion: TaskSuggestion, activity: Activity) -> Double {
        let weights = config.priorityWeights

        var score = 0.0

        // Urgency component
        score += suggestion.urgencyScore * weights.urgencyWeight

        // Importance component (based on priority level)
        score += Double(suggestion.priority.numericValue) / 4.0 * weights.importanceWeight

        // User preference component
        let actionType = taskSuggestion.actionType
        let userPreferenceScore = userPreferences.preferredActionTypes[actionType] ?? 0.5
        score += userPreferenceScore * weights.userPreferenceWeight

        // Deadline component
        if suggestion.deadline != nil {
            let hoursUntilDeadline = suggestion.deadline!.timeIntervalSinceNow / 3600
            let deadlineScore = max(0, 1.0 - hoursUntilDeadline / (24 * 7)) // Decay over a week
            score += deadlineScore * weights.deadlineWeight
        }

        // Context relevance component
        let categoryPreference = userPreferences.preferredCategories[taskSuggestion.context] ?? 0.5
        score += categoryPreference * weights.contextRelevanceWeight

        return min(score, 1.0)
    }

    private func applyUserPreferenceLearning(to suggestions: [SuggestedTodo]) async -> [SuggestedTodo] {
        var learnedSuggestions = suggestions

        // Apply learning scores based on user preferences
        for i in 0..<learnedSuggestions.count {
            let suggestion = learnedSuggestions[i]

            // Boost suggestions that match user preferences
            let actionType = inferActionType(from: suggestion.title)
            let preferenceScore = userPreferences.preferredActionTypes[actionType] ?? 0.5

            // Update learning score with user preference influence
            let currentScore = suggestion.learningScore
            let newScore = (currentScore * 0.7) + (preferenceScore * 0.3)
            learnedSuggestions[i].updateLearningScore(newScore)
        }

        // Sort by learning score
        learnedSuggestions.sort { $0.relevanceScore > $1.relevanceScore }

        return learnedSuggestions
    }

    private func filterAndLimitSuggestions(_ suggestions: [SuggestedTodo]) -> [SuggestedTodo] {
        var filtered = suggestions

        // Filter by minimum confidence threshold
        filtered = filtered.filter { $0.confidence >= config.minConfidenceThreshold }

        // Filter out duplicates
        var seenTitles = Set<String>()
        filtered = filtered.filter { suggestion in
            if seenTitles.contains(suggestion.title.lowercased()) {
                return false
            }
            seenTitles.insert(suggestion.title.lowercased())
            return true
        }

        // Filter out recent duplicates (suggestions shown in the last hour)
        let oneHourAgo = Date().addingTimeInterval(-3600)
        filtered = filtered.filter { suggestion in
            if let lastShown = suggestion.lastShown {
                return lastShown < oneHourAgo
            }
            return true
        }

        // Limit to configured maximum
        return Array(filtered.prefix(config.maxSuggestionsPerSession))
    }

    private func storeSuggestion(_ suggestion: SuggestedTodo) async throws {
        try await databaseQueue.write { db in
            let tagsData = try JSONEncoder().encode(suggestion.contextTags)
            let tagsString = String(data: tagsData, encoding: .utf8)
            let estimatedDuration = suggestion.estimatedDuration.map { Int64($0) }

            let _: [DatabaseValueConvertible?] = [
                suggestion.id.uuidString,
                suggestion.title,
                suggestion.description,
                suggestion.priority.rawValue,
                suggestion.confidence,
                suggestion.sourceContent,
                suggestion.sourceType.rawValue,
                suggestion.sourceActivityId?.uuidString,
                tagsString,
                estimatedDuration,
                suggestion.deadline,
                suggestion.createdAt,
                suggestion.urgencyScore,
                suggestion.relevanceScore,
                suggestion.learningScore
            ]

            try db.execute(sql: """
                INSERT OR REPLACE INTO suggested_todos
                (id, title, description, priority, confidence, source_content, source_type,
                 source_activity_id, context_tags, estimated_duration, deadline, created_at,
                 urgency_score, relevance_score, learning_score)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: StatementArguments([
                suggestion.id.uuidString,
                suggestion.title,
                suggestion.description,
                suggestion.priority.rawValue,
                suggestion.confidence,
                suggestion.sourceContent,
                suggestion.sourceType.rawValue,
                suggestion.sourceActivityId?.uuidString as Any,
                tagsString as Any,
                suggestion.estimatedDuration.map { Int64($0) } as Any,
                suggestion.deadline as Any,
                suggestion.createdAt,
                suggestion.urgencyScore,
                suggestion.relevanceScore,
                suggestion.learningScore
            ]) ?? StatementArguments())
        }
    }

    private func parseSuggestedTodo(from row: Row) throws -> SuggestedTodo {
        let idString: String = row["id"]
        let title: String = row["title"]
        let description: String = row["description"] ?? ""
        let priorityString: String = row["priority"]
        let confidence: Double = row["confidence"]
        let sourceContent: String = row["source_content"]
        let sourceTypeString: String = row["source_type"]
        let sourceActivityIdString: String? = row["source_activity_id"]
        let contextTagsString: String? = row["context_tags"]
        let estimatedDuration: Int64? = row["estimated_duration"]
        let deadline: Date? = row["deadline"]
        let _: Date = row["created_at"]
        let _: Double = row["urgency_score"]
        let _: Double = row["relevance_score"]
        let learningScore: Double = row["learning_score"]
        let _: Bool = row["is_dismissed"]

        guard let _ = UUID(uuidString: idString),
              let priority = SuggestionPriority(rawValue: priorityString),
              let sourceType = SuggestionSourceType(rawValue: sourceTypeString) else {
            throw DatabaseError.invalidData
        }

        var contextTags: [String] = []
        if let tagsString = contextTagsString,
           let tagsData = tagsString.data(using: .utf8) {
            contextTags = try JSONDecoder().decode([String].self, from: tagsData)
        }

        let sourceActivityId = sourceActivityIdString != nil ? UUID(uuidString: sourceActivityIdString!) : nil

        var suggestion = SuggestedTodo(
            title: title,
            description: description,
            priority: priority,
            confidence: confidence,
            sourceContent: sourceContent,
            sourceType: sourceType,
            sourceActivityId: sourceActivityId,
            contextTags: contextTags,
            estimatedDuration: estimatedDuration.map { TimeInterval($0) },
            deadline: deadline
        )

        suggestion.updateLearningScore(learningScore)

        // We'll need to add these properties to the SuggestedTodo model
        // For now, we'll store the computed values

        return suggestion
    }

    private func saveUserPreferences() async throws {
        let prefsPath = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("FocusLock")
            .appendingPathComponent("UserPreferences.json")

        let data = try JSONEncoder().encode(userPreferences)
        try data.write(to: prefsPath)
    }

    private func saveConfiguration() async throws {
        let currentConfig = config

        try await Task.detached(priority: .utility) {
            let directoryURL = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("FocusLock")

            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            let configURL = directoryURL.appendingPathComponent("SuggestionEngineConfig.json")
            let data = try JSONEncoder().encode(currentConfig)
            try data.write(to: configURL, options: .atomic)
        }.value
    }

    private func updateLearningScores(for suggestion: SuggestedTodo, feedback: UserFeedback) async {
        // Update learning scores for similar suggestions
        do {
            try await databaseQueue.write { db in
                let contextPattern = "%\(suggestion.contextTags.joined(separator: ","))%"
                let arguments = StatementArguments([
                    feedback.score,
                    contextPattern,
                    suggestion.id.uuidString
                ])
                try db.execute(sql: """
                    UPDATE suggested_todos
                    SET learning_score = learning_score * 0.9 + ? * 0.1
                    WHERE context_tags LIKE ? AND id != ?
                """, arguments: arguments ?? StatementArguments())
            }
        } catch {
            logger.error("Failed to update learning scores: \(error.localizedDescription)")
        }
    }

    private func updateLearningScores() async {
        // Decay learning scores over time
        do {
            try await databaseQueue.write { db in
                try db.execute(sql: """
                    UPDATE suggested_todos
                    SET learning_score = learning_score * 0.99
                    WHERE learning_score > 0.1
                """)
            }
        } catch {
            logger.error("Failed to decay learning scores: \(error.localizedDescription)")
        }
    }

    private func cleanupOldSuggestions() async {
        let cutoffDate = Date().addingTimeInterval(-TimeInterval(config.contextRetentionDays * 24 * 60 * 60))

        do {
            try await databaseQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM suggested_todos WHERE created_at < ?",
                    arguments: StatementArguments([cutoffDate]) ?? StatementArguments()
                )
            }
            logger.info("Cleaned up old suggestions older than \(self.config.contextRetentionDays) days")
        } catch {
            logger.error("Failed to cleanup old suggestions: \(error.localizedDescription)")
        }
    }

  
    private func parseDate(from dateString: String) -> Date? {
        let formatters: [DateFormatter] = [
            {
                let formatter = DateFormatter()
                formatter.dateFormat = "MM/dd/yyyy"
                return formatter
            }(),
            {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                return formatter
            }(),
            {
                let formatter = DateFormatter()
                formatter.dateFormat = "M/d/yyyy"
                return formatter
            }(),
            {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy/MM/dd"
                return formatter
            }()
        ]

        for formatter in formatters {
            if let date = formatter.date(from: dateString) {
                return date
            }
        }

        return nil
    }

    private func updateProcessingStats(duration: TimeInterval, suggestionsCount: Int) {
        processingTimes.append(duration)
        if processingTimes.count > 100 {
            processingTimes.removeFirst()
        }

        generationStats.totalGenerationCount += 1
        generationStats.totalSuggestionsGenerated += suggestionsCount
        generationStats.lastGenerationDuration = duration
        generationStats.averageGenerationTime = processingTimes.isEmpty ? 0 : processingTimes.reduce(0, +) / Double(processingTimes.count)
    }

    private func calculateAcceptanceRate() -> Double {
        let recentSuggestions = suggestionHistory.suffix(50)
        let acceptedCount = recentSuggestions.filter { $0.isAccepted == true }.count
        return recentSuggestions.isEmpty ? 0 : Double(acceptedCount) / Double(recentSuggestions.count)
    }

    private func getTopActionTypes() -> [(TaskSuggestion.ActionType, Int)] {
        let actionTypes = suggestionHistory.map { inferActionType(from: $0.title) }
        let typeCounts = Dictionary(grouping: actionTypes, by: { $0 }).mapValues { $0.count }
        return typeCounts.sorted { $0.value > $1.value }.prefix(5).map { ($0.key, $0.value) }
    }
}

// MARK: - Supporting Types

struct SuggestionEngineStats {
    let totalSuggestions: Int
    let activeSuggestions: Int
    let averageConfidence: Double
    let averageProcessingTime: TimeInterval
    let userAcceptanceRate: Double
    let topActionTypes: [(TaskSuggestion.ActionType, Int)]
    let userPreferenceProfile: UserPreferenceProfile
    let generationStats: GenerationStats
}

struct GenerationStats {
    var totalGenerationCount: Int = 0
    var totalSuggestionsGenerated: Int = 0
    var lastGenerationDuration: TimeInterval = 0
    var averageGenerationTime: TimeInterval = 0

    var isHealthy: Bool {
        return averageGenerationTime < 2.0 && totalGenerationCount > 0
    }
}

private extension DatabaseError {
    static let invalidData = DatabaseError(message: "Invalid data in database")
    static let notInitialized = DatabaseError(message: "Database not initialized")
}

private extension Formatter {
    func then(_ configure: (Self) -> Void) -> Self {
        configure(self)
        return self
    }
}

// MARK: - Singleton Instance
extension SuggestedTodosEngine {
    static let shared = SuggestedTodosEngine()
}