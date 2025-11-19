import Foundation

struct TimelineClipboardFormatter {
    static func makeClipboardText(for date: Date, cards: [TimelineCard], now: Date = Date()) -> String {
        let calendar = Calendar.current
        let timelineDate = timelineDisplayDate(from: date, now: now)
        let timelineToday = timelineDisplayDate(from: now, now: now)

        let dateFormatter = DateFormatter()
        if calendar.isDate(timelineDate, inSameDayAs: timelineToday) {
            dateFormatter.dateFormat = "'Today,' MMM d"
        } else {
            dateFormatter.dateFormat = "EEEE, MMM d"
        }
        let header = "Dayflow timeline · \(dateFormatter.string(from: timelineDate))"

        guard !cards.isEmpty else {
            return """
            \(header)

            No timeline activities were recorded for this day.
            """
        }

        let entries = cards.enumerated().map { index, card -> String in
            var lines: [String] = []

            let timeRange = formattedRange(start: card.startTimestamp, end: card.endTimestamp)
            let titleText = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let bullet = "\(index + 1). \(timeRange.isEmpty ? "" : "\(timeRange) — ")\(titleText)"
            lines.append(bullet.trimmingCharacters(in: .whitespaces))

            let metaParts = metadataParts(for: card)
            if !metaParts.isEmpty {
                lines.append("   " + metaParts.joined(separator: " • "))
            }

            if let summary = cleanedParagraph(card.summary) {
                lines.append(block(label: "Summary", text: summary))
            }

            if let details = cleanedParagraph(card.detailedSummary),
               details != cleanedParagraph(card.summary) {
                lines.append(block(label: "Details", text: details))
            }

            return lines.joined(separator: "\n")
        }

        return ([header, ""] + entries).joined(separator: "\n\n")
    }

    private static func formattedRange(start: String, end: String) -> String {
        let trimmedStart = start.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEnd = end.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedStart.isEmpty && trimmedEnd.isEmpty { return "" }
        if trimmedEnd.isEmpty { return trimmedStart }
        if trimmedStart.isEmpty { return trimmedEnd }
        return "\(trimmedStart) – \(trimmedEnd)"
    }

    private static func metadataParts(for card: TimelineCard) -> [String] {
        var parts: [String] = []
        let category = card.category.trimmingCharacters(in: .whitespacesAndNewlines)
        if !category.isEmpty {
            parts.append(category)
        }
        return parts
    }

    private static func block(label: String, text: String) -> String {
        let lines = normalizedLines(text)
        guard !lines.isEmpty else { return "" }
        if lines.count == 1 {
            return "   \(label): \(lines[0])"
        } else {
            var blockLines: [String] = ["   \(label):"]
            for line in lines {
                blockLines.append("      \(line)")
            }
            return blockLines.joined(separator: "\n")
        }
    }

    private static func cleanedParagraph(_ value: String?) -> String? {
        guard let value = value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lines = normalizedLines(trimmed)
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    private static func normalizedLines(_ text: String) -> [String] {
        return text
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
