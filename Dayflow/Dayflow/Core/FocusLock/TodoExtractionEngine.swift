//
//  TodoExtractionEngine.swift
//  FocusLock
//
//  Intelligent todo extraction from conversations, journals, and activity patterns
//  with smart scheduling and dependency detection
//

import Foundation
import SwiftUI
import Combine
import os.log

@MainActor
class TodoExtractionEngine: ObservableObject {
    static let shared = TodoExtractionEngine()
    
    // MARK: - Published Properties
    @Published var extractedTodos: [SmartTodo] = []
    @Published var isExtracting = false
    
    // MARK: - Dependencies
    private let llmService: LLMServicing
    private let storageManager = StorageManager.shared
    private let logger = Logger(subsystem: "FocusLock", category: "TodoExtractionEngine")
    
    // User schedule context (Darius's schedule)
    private let userSchedule: [ScheduleBlock] = [
        ScheduleBlock(dayOfWeek: 2, startTime: "09:30", endTime: "13:30", activity: "School", isRecurring: true), // Monday
        ScheduleBlock(dayOfWeek: 3, startTime: "09:30", endTime: "13:30", activity: "School", isRecurring: true), // Tuesday
        ScheduleBlock(dayOfWeek: 4, startTime: "08:30", endTime: "13:30", activity: "School", isRecurring: true), // Wednesday
        ScheduleBlock(dayOfWeek: 5, startTime: "09:30", endTime: "13:30", activity: "School", isRecurring: true), // Thursday
        ScheduleBlock(dayOfWeek: 6, startTime: "09:30", endTime: "13:30", activity: "School", isRecurring: true), // Friday
        ScheduleBlock(dayOfWeek: 2, startTime: "18:00", endTime: "21:00", activity: "Astronomy Class", isRecurring: true) // Monday evening
    ]
    
    private var hasLoadedTodos = false

    private init(llmService: LLMServicing = LLMService.shared) {
        self.llmService = llmService
        // ✅ Defer database loading to async initialization
        // loadExistingTodos() moved to ensureInitialized()
    }

    /// Ensures existing todos are loaded before use
    func ensureInitialized() {
        // Load existing todos on first access (lazy loading)
        guard !hasLoadedTodos else { return }
        hasLoadedTodos = true
        loadExistingTodos()
    }
    
    // MARK: - Public Interface
    
    /// Extract todos from a Jarvis conversation
    func extractTodosFromConversation(_ messages: [ChatMessage]) async throws -> [SmartTodo] {
        ensureInitialized()

        guard !messages.isEmpty else { return [] }

        isExtracting = true
        defer { isExtracting = false }
        
        // Build conversation context
        let conversationText = messages.map { message in
            "\(message.role.rawValue): \(message.content)"
        }.joined(separator: "\n")
        
        let prompt = """
        Extract actionable todos from this conversation. For each todo, identify:
        - Title (verb-first, 6 words max)
        - Description (brief context)
        - Project (m3rcury_agent, precision_detail, window_washing, acne_ai, school, personal, self_care)
        - Priority (P0 = moves KPI this week/unlocks work, P1 = this week, P2 = later)
        - Duration estimate in minutes
        - Context (phone, laptop, in_person, errands)
        - Dependencies (if this todo requires another to be completed first)
        
        Conversation:
        \(conversationText)
        
        Return a JSON array of todos. Example:
        [
          {
            "title": "Call Mrs. Simms re: install",
            "description": "Confirm 4pm window installation appointment",
            "project": "window_washing",
            "priority": "P0",
            "duration": 10,
            "context": "phone",
            "dependencies": []
          }
        ]
        
        Only extract clear, actionable items. Omit vague or already-completed tasks.
        """
        
        let response = try await llmService.generateText(
            prompt: prompt,
            systemPrompt: "You are an AI assistant that extracts actionable todos from conversations. Return only valid JSON."
        )
        
        let todos = try parseTodosFromJSON(response, source: .jarvis)
        
        // Auto-schedule based on priority and user schedule
        let scheduledTodos = todos.map { autoSchedule($0) }
        
        // Save to database and add to extracted list
        for todo in scheduledTodos {
            do {
                _ = try storageManager.saveTodo(todo)
                extractedTodos.append(todo)
            } catch {
                logger.error("Failed to save todo: \(error.localizedDescription)")
            }
        }
        
        logger.info("Extracted \(scheduledTodos.count) todos from conversation")
        return scheduledTodos
    }
    
    /// Extract todos from a journal entry
    func extractTodosFromJournal(_ journal: EnhancedDailyJournal) async throws -> [SmartTodo] {
        isExtracting = true
        defer { isExtracting = false }
        
        // Focus on unfinished tasks section
        guard let unfinishedSection = journal.section(ofType: .unfinishedTasks) else {
            return []
        }
        
        let prompt = """
        Convert these unfinished tasks into structured todos:
        
        \(unfinishedSection.content)
        
        For each task, determine:
        - Title (actionable, verb-first)
        - Description
        - Project (infer from context)
        - Priority (P0, P1, or P2)
        - Duration estimate
        - Context (phone, laptop, in_person, errands)
        
        Return JSON array format:
        [
          {
            "title": "Fix brandzy backend",
            "description": "Resolve Redis connection and PostgreSQL migration errors",
            "project": "m3rcury_agent",
            "priority": "P0",
            "duration": 180,
            "context": "laptop",
            "dependencies": []
          }
        ]
        """
        
        let response = try await llmService.generateText(
            prompt: prompt,
            systemPrompt: "You are extracting todos from unfinished work. Return only valid JSON."
        )
        
        let todos = try parseTodosFromJSON(response, source: .journal)
        let scheduledTodos = todos.map { autoSchedule($0) }
        
        // Save to database and add to extracted list
        for todo in scheduledTodos {
            do {
                _ = try storageManager.saveTodo(todo)
                extractedTodos.append(todo)
            } catch {
                logger.error("Failed to save todo: \(error.localizedDescription)")
            }
        }
        
        logger.info("Extracted \(scheduledTodos.count) todos from journal")
        return scheduledTodos
    }
    
    /// Extract todos from activity patterns (detect recurring incomplete work)
    func extractTodosFromActivities(_ timelineCards: [TimelineCard]) async throws -> [SmartTodo] {
        isExtracting = true
        defer { isExtracting = false }
        
        // Look for patterns of started but not finished work
        var incompleteTasks: [String: Int] = [:]
        
        for card in timelineCards {
            let titleLower = card.title.lowercased()
            let summaryLower = card.summary.lowercased()
            
            // Detect incomplete work patterns
            if (titleLower.contains("start") || titleLower.contains("began") || titleLower.contains("working on"))
                && !summaryLower.contains("complete") && !summaryLower.contains("finish") {
                incompleteTasks[card.title, default: 0] += 1
            }
        }
        
        // Generate todos for tasks mentioned multiple times (strong signal of importance)
        let significantTasks = incompleteTasks.filter { $0.value >= 2 }
        
        if significantTasks.isEmpty {
            return []
        }
        
        let tasksText = significantTasks.map { "\($0.key) (mentioned \($0.value) times)" }.joined(separator: "\n")
        
        let prompt = """
        These tasks appear repeatedly but seem unfinished. Create actionable todos:
        
        \(tasksText)
        
        For each, provide:
        - Title (actionable)
        - Description (what needs to be completed)
        - Project (infer from task name)
        - Priority (P1 or P2 - these are not urgent but important)
        - Duration estimate
        - Context
        
        Return JSON array.
        """
        
        let response = try await llmService.generateText(
            prompt: prompt,
            systemPrompt: "You are identifying recurring incomplete work. Return only valid JSON."
        )
        
        let todos = try parseTodosFromJSON(response, source: .activity)
        let scheduledTodos = todos.map { autoSchedule($0) }
        
        // Save to database and add to extracted list
        for todo in scheduledTodos {
            do {
                _ = try storageManager.saveTodo(todo)
                extractedTodos.append(todo)
            } catch {
                logger.error("Failed to save todo: \(error.localizedDescription)")
            }
        }
        
        logger.info("Extracted \(scheduledTodos.count) todos from activity patterns")
        return scheduledTodos
    }
    
    /// Manually create a todo
    func createTodo(
        title: String,
        description: String? = nil,
        project: TodoProject,
        priority: TodoPriority,
        scheduledTime: Date? = nil,
        duration: TimeInterval = 1800,
        context: TodoContext = .laptop,
        subtasks: [Subtask]? = nil
    ) -> SmartTodo {
        var todo = SmartTodo(
            title: title,
            description: description,
            project: project,
            priority: priority,
            scheduledTime: scheduledTime,
            duration: duration,
            context: context,
            source: .manual,
            subtasks: subtasks
        )
        
        // Auto-schedule if no time provided
        if scheduledTime == nil {
            todo = autoSchedule(todo)
        }
        
        // Save to database
        do {
            _ = try storageManager.saveTodo(todo)
            extractedTodos.append(todo)
        } catch {
            logger.error("Failed to save todo: \(error.localizedDescription)")
        }
        
        return todo
    }
    
    /// Update todo status
    func updateTodoStatus(_ todoId: UUID, status: TodoStatus) {
        guard let index = extractedTodos.firstIndex(where: { $0.id == todoId }) else { return }
        
        var todo = extractedTodos[index]
        todo.status = status
        todo.updatedAt = Date()
        
        if status == .completed {
            todo.completedAt = Date()
        }
        
        // Update in database
        do {
            try storageManager.updateTodoStatus(id: todoId, status: status)
            extractedTodos[index] = todo
        } catch {
            logger.error("Failed to update todo status: \(error.localizedDescription)")
        }
    }
    
    /// Get todos filtered by various criteria
    func getTodos(
        status: TodoStatus? = nil,
        priority: TodoPriority? = nil,
        project: TodoProject? = nil,
        dueToday: Bool = false
    ) -> [SmartTodo] {
        var filtered = extractedTodos
        
        if let status = status {
            filtered = filtered.filter { $0.status == status }
        }
        
        if let priority = priority {
            filtered = filtered.filter { $0.priority == priority }
        }
        
        if let project = project {
            filtered = filtered.filter { $0.project == project }
        }
        
        if dueToday {
            let today = Calendar.current.startOfDay(for: Date())
            guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today) else {
                return []  // Safety: Return empty if calendar operation fails
            }
            filtered = filtered.filter { todo in
                guard let scheduled = todo.scheduledTime else { return false }
                return scheduled >= today && scheduled < tomorrow
            }
        }
        
        return filtered.sorted { $0.urgencyScore > $1.urgencyScore }
    }
    
    // MARK: - Private Methods
    
    private func parseTodosFromJSON(_ jsonString: String, source: TodoSource) throws -> [SmartTodo] {
        // Clean up response (remove markdown code blocks if present)
        var cleaned = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```json") {
            cleaned = cleaned.replacingOccurrences(of: "```json", with: "")
        }
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.replacingOccurrences(of: "```", with: "")
        }
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3))
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let data = cleaned.data(using: .utf8) else {
            throw TodoExtractionError.invalidJSON
        }
        
        struct TodoJSON: Codable {
            let title: String
            let description: String?
            let project: String
            let priority: String
            let duration: Int
            let context: String
            let dependencies: [String]?
        }
        
        let decoder = JSONDecoder()
        let todosJSON = try decoder.decode([TodoJSON].self, from: data)
        
        return todosJSON.compactMap { json in
            guard let project = TodoProject(rawValue: json.project),
                  let priority = TodoPriority(rawValue: json.priority),
                  let context = TodoContext(rawValue: json.context) else {
                return nil
            }
            
            return SmartTodo(
                title: json.title,
                description: json.description,
                project: project,
                priority: priority,
                duration: TimeInterval(json.duration * 60),
                context: context,
                source: source
            )
        }
    }
    
    private func autoSchedule(_ todo: SmartTodo) -> SmartTodo {
        var scheduled = todo
        
        // If already scheduled, return as-is
        if todo.scheduledTime != nil {
            return scheduled
        }
        
        let now = Date()
        let calendar = Calendar.current
        
        // Get next available slot based on priority
        let targetDate: Date
        
        switch todo.priority {
        case .p0:
            // Schedule today after 2pm PT if possible
            if let today2pm = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: now),
               today2pm > now {
                targetDate = today2pm
            } else {
                // If past 2pm, schedule for next available afternoon
                targetDate = getNextAvailableSlot(after: now, preferredHour: 14)
            }
            
        case .p1:
            // Schedule this week, prefer afternoons
            targetDate = getNextAvailableSlot(after: now, preferredHour: 15)
            
        case .p2:
            // Schedule next week
            if let nextWeek = calendar.date(byAdding: .day, value: 7, to: now) {
                targetDate = getNextAvailableSlot(after: nextWeek, preferredHour: 15)
            } else {
                targetDate = getNextAvailableSlot(after: now, preferredHour: 15)
            }
        }
        
        scheduled.scheduledTime = targetDate
        return scheduled
    }
    
    private func getNextAvailableSlot(after date: Date, preferredHour: Int) -> Date {
        let calendar = Calendar.current
        var checkDate = date
        
        // Find next weekday afternoon slot (avoid school hours)
        for _ in 0..<14 { // Check up to 2 weeks ahead
            let weekday = calendar.component(.weekday, from: checkDate)
            let hour = calendar.component(.hour, from: checkDate)
            
            // Skip weekends
            if weekday == 1 || weekday == 7 {
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: checkDate) else {
                    break  // Safety: Exit loop if calendar fails
                }
                checkDate = nextDay
                continue
            }
            
            // Check if this time conflicts with school schedule
            if let scheduleBlock = userSchedule.first(where: { $0.dayOfWeek == weekday }) {
                // Parse schedule times
                let startHour = Int(scheduleBlock.startTime.split(separator: ":")[0]) ?? 0
                let endHour = Int(scheduleBlock.endTime.split(separator: ":")[0]) ?? 0
                
                // If current time conflicts, move to end of block
                if hour >= startHour && hour < endHour {
                    if let adjusted = calendar.date(bySettingHour: endHour, minute: 0, second: 0, of: checkDate) {
                        checkDate = adjusted
                        continue
                    }
                }
            }
            
            // If before 1:30pm PT (13:30), move to 2pm
            if hour < 13 || (hour == 13 && calendar.component(.minute, from: checkDate) < 30) {
                if let afternoon = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: checkDate) {
                    return afternoon
                }
            }
            
            // If after 10pm, move to next day
            if hour >= 22 {
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: checkDate) else {
                    break  // Safety: Exit loop if calendar fails
                }
                if let morning = calendar.date(bySettingHour: preferredHour, minute: 0, second: 0, of: nextDay) {
                    checkDate = morning
                } else {
                    checkDate = nextDay
                }
                continue
            }
            
            // This slot works
            return checkDate
        }
        
        // Fallback: just return preferred hour tomorrow
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) else {
            return date  // Safety: Return original date if calendar fails
        }
        return calendar.date(bySettingHour: preferredHour, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }
    
    private func loadExistingTodos() {
        // Load all pending and in-progress todos from database
        do {
            let pendingTodos = try storageManager.fetchTodos(status: .pending)
            let inProgressTodos = try storageManager.fetchTodos(status: .inProgress)
            extractedTodos = pendingTodos + inProgressTodos
            logger.info("Loaded \(self.extractedTodos.count) existing todos from database")
        } catch {
            logger.error("Failed to load existing todos: \(error.localizedDescription)")
            extractedTodos = []
        }
    }
}

// MARK: - Supporting Types

enum TodoExtractionError: LocalizedError {
    case invalidJSON
    case parsingFailed
    case noActionableItems
    
    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Failed to parse JSON response"
        case .parsingFailed:
            return "Failed to parse todo data"
        case .noActionableItems:
            return "No actionable items found"
        }
    }
}

