//
//  ChatToolExecutor.swift
//  Dayflow
//
//  Executes tool calls from the chat LLM and formats results.
//

import Foundation

/// Available tools the chat LLM can invoke
enum ChatTool: String, Codable, CaseIterable {
    case fetchTimeline = "fetchTimeline"
    case fetchObservations = "fetchObservations"

    var displayName: String {
        switch self {
        case .fetchTimeline: return "Fetching timeline"
        case .fetchObservations: return "Fetching observations"
        }
    }
}

/// Parsed tool request from LLM JSON output
struct ChatToolRequest: Codable {
    let tool: String
    let date: String?       // YYYY-MM-DD format
    let startDate: String?  // For date range queries (future)
    let endDate: String?    // For date range queries (future)

    /// Parse the tool type, returns nil if unknown
    var toolType: ChatTool? {
        ChatTool(rawValue: tool)
    }
}

/// Result of executing a tool
struct ChatToolResult {
    let tool: ChatTool
    let success: Bool
    let summary: String           // Human-readable summary for UI
    let dataForLLM: String        // Formatted data to inject into conversation
    let itemCount: Int            // Number of items found

    static func failure(tool: ChatTool, error: String) -> ChatToolResult {
        ChatToolResult(
            tool: tool,
            success: false,
            summary: error,
            dataForLLM: "Error: \(error)",
            itemCount: 0
        )
    }
}

/// Executes chat tool calls by querying StorageManager
@MainActor
final class ChatToolExecutor {

    // MARK: - JSON Parsing

    /// Attempt to parse a tool call from LLM output
    /// Returns nil if no valid JSON tool call found
    static func parseToolCall(from text: String) -> ChatToolRequest? {
        // Look for JSON in the response
        guard let jsonStart = text.firstIndex(of: "{"),
              let jsonEnd = text.lastIndex(of: "}") else {
            return nil
        }

        let jsonString = String(text[jsonStart...jsonEnd])
        guard let data = jsonString.data(using: .utf8) else { return nil }

        do {
            let request = try JSONDecoder().decode(ChatToolRequest.self, from: data)
            // Validate that we have a known tool
            guard request.toolType != nil else { return nil }
            return request
        } catch {
            print("[ChatToolExecutor] Failed to parse tool JSON: \(error)")
            return nil
        }
    }

    // MARK: - Tool Execution

    /// Execute a tool request and return the result
    func execute(_ request: ChatToolRequest) -> ChatToolResult {
        guard let tool = request.toolType else {
            return ChatToolResult(
                tool: .fetchTimeline,
                success: false,
                summary: "Unknown tool",
                dataForLLM: "Error: Unknown tool '\(request.tool)'",
                itemCount: 0
            )
        }

        switch tool {
        case .fetchTimeline:
            return executeTimelineFetch(request)
        case .fetchObservations:
            return executeObservationsFetch(request)
        }
    }

    // MARK: - Timeline Fetch

    private func executeTimelineFetch(_ request: ChatToolRequest) -> ChatToolResult {
        guard let dateString = request.date else {
            return .failure(tool: .fetchTimeline, error: "No date provided")
        }

        // Validate date format (YYYY-MM-DD)
        guard isValidDateFormat(dateString) else {
            return .failure(tool: .fetchTimeline, error: "Invalid date format. Use YYYY-MM-DD.")
        }

        let cards = StorageManager.shared.fetchTimelineCards(forDay: dateString)

        if cards.isEmpty {
            return ChatToolResult(
                tool: .fetchTimeline,
                success: true,
                summary: "No activities found for \(formatDateForDisplay(dateString))",
                dataForLLM: "No timeline cards found for \(dateString). Recording may not have been active on this day.",
                itemCount: 0
            )
        }

        let formatted = formatTimelineCardsForLLM(cards, date: dateString)
        let summary = "Found \(cards.count) activit\(cards.count == 1 ? "y" : "ies") for \(formatDateForDisplay(dateString))"

        return ChatToolResult(
            tool: .fetchTimeline,
            success: true,
            summary: summary,
            dataForLLM: formatted,
            itemCount: cards.count
        )
    }

    // MARK: - Observations Fetch

    private func executeObservationsFetch(_ request: ChatToolRequest) -> ChatToolResult {
        guard let dateString = request.date else {
            return .failure(tool: .fetchObservations, error: "No date provided")
        }

        guard isValidDateFormat(dateString) else {
            return .failure(tool: .fetchObservations, error: "Invalid date format. Use YYYY-MM-DD.")
        }

        // Convert date string to day boundaries (4 AM to 4 AM)
        guard let (startDate, endDate) = dayBoundaries(for: dateString) else {
            return .failure(tool: .fetchObservations, error: "Could not parse date")
        }

        let observations = StorageManager.shared.fetchObservationsByTimeRange(from: startDate, to: endDate)

        if observations.isEmpty {
            return ChatToolResult(
                tool: .fetchObservations,
                success: true,
                summary: "No observations found for \(formatDateForDisplay(dateString))",
                dataForLLM: "No observations found for \(dateString). Recording may not have been active on this day.",
                itemCount: 0
            )
        }

        let formatted = formatObservationsForLLM(observations, date: dateString)
        let summary = "Found \(observations.count) observation\(observations.count == 1 ? "" : "s") for \(formatDateForDisplay(dateString))"

        return ChatToolResult(
            tool: .fetchObservations,
            success: true,
            summary: summary,
            dataForLLM: formatted,
            itemCount: observations.count
        )
    }

    // MARK: - Formatting

    private func formatTimelineCardsForLLM(_ cards: [TimelineCard], date: String) -> String {
        var output = "Timeline activities for \(date):\n\n"

        for card in cards {
            output += "- \(card.startTimestamp) to \(card.endTimestamp): \(card.title)\n"
            output += "  Category: \(card.category)"
            if !card.subcategory.isEmpty {
                output += " (\(card.subcategory))"
            }
            output += "\n"
            if !card.summary.isEmpty {
                output += "  Summary: \(card.summary)\n"
            }
            if let appSites = card.appSites {
                var apps: [String] = []
                if let primary = appSites.primary { apps.append(primary) }
                if let secondary = appSites.secondary { apps.append(secondary) }
                if !apps.isEmpty {
                    output += "  Apps: \(apps.joined(separator: ", "))\n"
                }
            }
            if let distractions = card.distractions, !distractions.isEmpty {
                output += "  Distractions: \(distractions.count) noted\n"
                for d in distractions {
                    output += "    - \(d.startTime)-\(d.endTime): \(d.title)\n"
                }
            }
            output += "\n"
        }

        return output
    }

    private func formatObservationsForLLM(_ observations: [Observation], date: String) -> String {
        var output = "Detailed observations for \(date):\n\n"

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        for obs in observations {
            let startTime = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(obs.startTs)))
            let endTime = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(obs.endTs)))
            output += "[\(startTime) - \(endTime)]\n"
            output += "\(obs.observation)\n\n"
        }

        return output
    }

    // MARK: - Date Helpers

    private func isValidDateFormat(_ dateString: String) -> Bool {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: dateString) != nil
    }

    /// Convert "YYYY-MM-DD" to day boundaries (4 AM to 4 AM next day)
    private func dayBoundaries(for dateString: String) -> (start: Date, end: Date)? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        guard let date = formatter.date(from: dateString) else { return nil }

        let calendar = Calendar.current
        var startComponents = calendar.dateComponents([.year, .month, .day], from: date)
        startComponents.hour = 4
        startComponents.minute = 0
        startComponents.second = 0

        guard let dayStart = calendar.date(from: startComponents),
              let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return nil
        }

        return (dayStart, dayEnd)
    }

    /// Format date for human-readable display
    private func formatDateForDisplay(_ dateString: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        guard let date = formatter.date(from: dateString) else { return dateString }

        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "EEEE, MMM d"  // e.g., "Tuesday, Jan 7"
        return displayFormatter.string(from: date)
    }
}

// MARK: - Tool Description for System Prompt

extension ChatToolExecutor {
    /// Returns the tool description to include in the system prompt
    static var toolDescription: String {
        """
        ## Available Tools

        When you need activity data, output ONLY a JSON object (no markdown, no explanation):

        1. fetchTimeline - Get activity cards for a specific day
           {"tool": "fetchTimeline", "date": "YYYY-MM-DD"}

        2. fetchObservations - Get detailed observations for a day (use for more context)
           {"tool": "fetchObservations", "date": "YYYY-MM-DD"}

        After the tool executes, you'll receive the data and should formulate your response.
        """
    }
}
