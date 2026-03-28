//
//  ChatDataProvider.swift
//  Dayflow
//

import Foundation
import AppKit

final class ChatDataProvider {

    // MARK: - Tier 1: Card Summaries

    func fetchTier1Data(day: String) -> String {
        let cards = StorageManager.shared.fetchTimelineCards(forDay: day)
        guard !cards.isEmpty else { return "" }

        return cards.map { card in
            var line = "\(card.startTimestamp)–\(card.endTimestamp) [\(card.category)]: \(card.title)"
            if !card.summary.isEmpty {
                line += " — \(card.summary)"
            }
            if let sites = card.appSites {
                var apps: [String] = []
                if let p = sites.primary, !p.isEmpty { apps.append(p) }
                if let s = sites.secondary, !s.isEmpty { apps.append(s) }
                if !apps.isEmpty { line += " (apps: \(apps.joined(separator: ", ")))" }
            }
            if let distractions = card.distractions, !distractions.isEmpty {
                let dStr = distractions.map { "\($0.startTime)–\($0.endTime) \($0.title)" }.joined(separator: "; ")
                line += " [distractions: \(dStr)]"
            }
            return line
        }.joined(separator: "\n")
    }

    // MARK: - Tier 2: Detailed Summaries + Observations

    func fetchTier2Data(day: String, startTs: Int?, endTs: Int?) -> String {
        let dayInfo = dayBoundary(for: day)

        // Fetch cards — use time-range query if narrowed, otherwise full day
        let cards: [TimelineCard]
        if let s = startTs, let e = endTs {
            cards = StorageManager.shared.fetchTimelineCardsByTimeRange(
                from: Date(timeIntervalSince1970: TimeInterval(s)),
                to: Date(timeIntervalSince1970: TimeInterval(e))
            )
        } else {
            cards = StorageManager.shared.fetchTimelineCards(forDay: day)
        }

        guard !cards.isEmpty else { return "" }

        var result = cards.map { card in
            var section = "[\(card.startTimestamp)–\(card.endTimestamp)] \(card.title)\n"
            section += "Category: \(card.category)\n"
            section += "Summary: \(card.summary)\n"
            if !card.detailedSummary.isEmpty {
                section += "Detailed: \(card.detailedSummary)"
            }
            return section
        }.joined(separator: "\n\n")

        // Also fetch observations in the time range
        let obsStart = startTs ?? Int(dayInfo.start.timeIntervalSince1970)
        let obsEnd = endTs ?? Int(dayInfo.end.timeIntervalSince1970)
        let observations = StorageManager.shared.fetchObservations(startTs: obsStart, endTs: obsEnd)
        if !observations.isEmpty {
            result += "\n\n--- Raw Observations ---\n"
            result += observations.map { obs in
                let startFmt = formatTs(obs.startTs)
                let endFmt = formatTs(obs.endTs)
                return "[\(startFmt)–\(endFmt)]: \(obs.observation)"
            }.joined(separator: "\n")
        }

        return result
    }

    // MARK: - Tier 3: Screenshots

    func fetchTier3Screenshots(day: String, startTs: Int?, endTs: Int?, maxCount: Int = 10) -> [(screenshot: Screenshot, data: Data)] {
        let dayInfo = dayBoundary(for: day)
        let rangeStart = startTs ?? Int(dayInfo.start.timeIntervalSince1970)
        let rangeEnd = endTs ?? Int(dayInfo.end.timeIntervalSince1970)

        let screenshots = StorageManager.shared.fetchScreenshotsInTimeRange(startTs: rangeStart, endTs: rangeEnd)
        let sampled = subsample(screenshots, maxCount: maxCount)

        return sampled.compactMap { ss in
            guard let imageData = resizedScreenshotData(filePath: ss.filePath, maxWidth: 1024, quality: 0.6) else { return nil }
            return (ss, imageData)
        }
    }

    // MARK: - Helpers

    func hasDayData(day: String) -> Bool {
        !StorageManager.shared.fetchTimelineCards(forDay: day).isEmpty
    }

    private func dayBoundary(for day: String) -> (start: Date, end: Date) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = Calendar.current.timeZone
        guard let date = formatter.date(from: day) else {
            let now = Date()
            return (now, now)
        }
        let calendar = Calendar.current
        let fourAM = calendar.date(bySettingHour: 4, minute: 0, second: 0, of: date)!
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: fourAM)!
        return (fourAM, endOfDay)
    }

    private func formatTs(_ ts: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    private func subsample(_ screenshots: [Screenshot], maxCount: Int) -> [Screenshot] {
        guard screenshots.count > maxCount else { return screenshots }
        let step = Double(screenshots.count) / Double(maxCount)
        return (0..<maxCount).map { i in
            screenshots[min(Int(Double(i) * step), screenshots.count - 1)]
        }
    }

    private func resizedScreenshotData(filePath: String, maxWidth: CGFloat, quality: CGFloat) -> Data? {
        let url = URL(fileURLWithPath: filePath)
        guard let image = NSImage(contentsOf: url) else { return nil }

        let originalSize = image.size
        guard originalSize.width > 0, originalSize.height > 0 else { return nil }

        let scale: CGFloat
        if originalSize.width > maxWidth {
            scale = maxWidth / originalSize.width
        } else {
            scale = 1.0
        }

        let newSize = NSSize(width: originalSize.width * scale, height: originalSize.height * scale)
        let resized = NSImage(size: newSize)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: originalSize),
                   operation: .copy,
                   fraction: 1.0)
        resized.unlockFocus()

        guard let tiffData = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            return nil
        }
        return jpegData
    }
}
