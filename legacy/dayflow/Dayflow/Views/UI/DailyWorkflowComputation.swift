import AppKit
import Foundation
import SwiftUI
import UserNotifications

// MARK: - Daily Workflow Computation

func computeDailyWorkflow(cards: [TimelineCard], categories: [TimelineCategory])
  -> DailyWorkflowComputationResult
{
  let systemCategoryKey = normalizedCategoryKey("System")
  let orderedCategories =
    categories
    .sorted { $0.order < $1.order }
    .filter { normalizedCategoryKey($0.name) != systemCategoryKey }

  let categoryLookup = firstCategoryLookup(
    from: orderedCategories,
    normalizedKey: normalizedCategoryKey
  )
  let colorMap = categoryLookup.mapValues { normalizedHex($0.colorHex) }
  let nameMap = categoryLookup.mapValues {
    $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  struct RawDailyWorkflowSegment {
    let categoryKey: String
    let displayName: String
    let colorHex: String
    let startMinute: Double
    let endMinute: Double
    let hasDistraction: Bool
    let cardTitle: String
    let cardDurationMinutes: Double
  }

  var rawSegments: [RawDailyWorkflowSegment] = []
  rawSegments.reserveCapacity(cards.count)

  for card in cards {
    guard var startMinute = parseCardMinute(card.startTimestamp),
      var endMinute = parseCardMinute(card.endTimestamp)
    else {
      continue
    }

    let normalized = normalizedMinuteRange(start: startMinute, end: endMinute)
    startMinute = normalized.start
    endMinute = normalized.end

    let trimmed = card.category.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayName = trimmed.isEmpty ? "Uncategorized" : trimmed
    let key = normalizedCategoryKey(displayName)
    guard key != systemCategoryKey else { continue }
    let colorHex = colorMap[key] ?? fallbackColorHex(for: key)

    rawSegments.append(
      RawDailyWorkflowSegment(
        categoryKey: key,
        displayName: displayName,
        colorHex: colorHex,
        startMinute: startMinute,
        endMinute: endMinute,
        hasDistraction: !(card.distractions?.isEmpty ?? true),
        cardTitle: card.title,
        cardDurationMinutes: endMinute - startMinute
      )
    )
  }

  let workflowWindow: DailyWorkflowTimelineWindow = {
    guard !rawSegments.isEmpty else { return .placeholder }

    let firstUsedMinute = rawSegments.map(\.startMinute).min() ?? DailyGridConfig.visibleStartMinute
    let lastUsedMinute = rawSegments.map(\.endMinute).max() ?? DailyGridConfig.visibleEndMinute

    let alignedStart = floor(firstUsedMinute / 60) * 60
    let alignedDataEnd = ceil(lastUsedMinute / 60) * 60
    let minWindowDuration = DailyGridConfig.visibleEndMinute - DailyGridConfig.visibleStartMinute
    let computedEnd = max(alignedStart + minWindowDuration, alignedDataEnd)

    return DailyWorkflowTimelineWindow(startMinute: alignedStart, endMinute: computedEnd)
  }()

  let visibleStart = workflowWindow.startMinute
  let visibleEnd = workflowWindow.endMinute
  let slotCount = workflowWindow.slotCount
  let slotDuration = DailyGridConfig.slotDurationMinutes

  let segments: [DailyWorkflowSegment] = rawSegments.compactMap { raw in
    let clippedStart = max(raw.startMinute, visibleStart)
    let clippedEnd = min(raw.endMinute, visibleEnd)
    guard clippedEnd > clippedStart else { return nil }
    return DailyWorkflowSegment(
      categoryKey: raw.categoryKey,
      displayName: raw.displayName,
      colorHex: raw.colorHex,
      startMinute: clippedStart,
      endMinute: clippedEnd,
      hasDistraction: raw.hasDistraction,
      cardTitle: raw.cardTitle,
      cardDurationMinutes: raw.cardDurationMinutes
    )
  }

  var durationByCategory: [String: Double] = [:]
  var resolvedNameByCategory: [String: String] = [:]
  var resolvedColorByCategory: [String: String] = [:]

  for segment in segments {
    let overlap = max(0, segment.endMinute - segment.startMinute)
    guard overlap > 0 else { continue }
    durationByCategory[segment.categoryKey, default: 0] += overlap
    resolvedNameByCategory[segment.categoryKey] = segment.displayName
    resolvedColorByCategory[segment.categoryKey] = segment.colorHex
  }

  let sortedSegments = segments.sorted { lhs, rhs in
    if lhs.startMinute == rhs.startMinute {
      return lhs.endMinute < rhs.endMinute
    }
    return lhs.startMinute < rhs.startMinute
  }

  let idleCategoryKeys = Set(
    orderedCategories.filter(\.isIdle).map { normalizedCategoryKey($0.name) })
  var contextSwitches = 0
  var interruptions = 0
  var focusedMinutes = 0.0
  var distractedMinutes = 0.0
  var transitionMinutes = 0.0
  var previousCategory: String? = nil
  var previousEndMinute: Double? = nil

  for segment in sortedSegments {
    let duration = max(0, segment.endMinute - segment.startMinute)
    guard duration > 0 else { continue }

    if idleCategoryKeys.contains(segment.categoryKey) {
      distractedMinutes += duration
    } else {
      focusedMinutes += duration
    }

    if segment.hasDistraction {
      interruptions += 1
    }

    if let previousCategory, previousCategory != segment.categoryKey {
      contextSwitches += 1
    }
    previousCategory = segment.categoryKey

    if let priorEndMinute = previousEndMinute {
      let gap = segment.startMinute - priorEndMinute
      if gap > 0 {
        transitionMinutes += gap
      }
      previousEndMinute = max(priorEndMinute, segment.endMinute)
    } else {
      previousEndMinute = segment.endMinute
    }
  }

  var selectedKeys: [String] = []
  var seenKeys = Set<String>()

  for category in orderedCategories {
    let key = normalizedCategoryKey(category.name)
    guard !key.isEmpty else { continue }
    guard seenKeys.insert(key).inserted else { continue }
    selectedKeys.append(key)
  }

  let unknownUsedKeys = durationByCategory.keys
    .filter { !seenKeys.contains($0) && $0 != systemCategoryKey }
    .sorted()

  for key in unknownUsedKeys {
    selectedKeys.append(key)
    seenKeys.insert(key)
  }

  let segmentsByCategory = Dictionary(grouping: segments, by: { $0.categoryKey })

  let rows: [DailyWorkflowGridRow] = selectedKeys.map { key in
    let rowSegments = segmentsByCategory[key] ?? []

    var occupancies: [Double] = []
    var cardInfos: [DailyWorkflowSlotCardInfo?] = []
    occupancies.reserveCapacity(slotCount)
    cardInfos.reserveCapacity(slotCount)

    for slotIndex in 0..<slotCount {
      let slotStart = visibleStart + (Double(slotIndex) * slotDuration)
      let slotEnd = min(visibleEnd, slotStart + slotDuration)
      let slotMinutes = max(1, slotEnd - slotStart)

      var totalOccupied = 0.0
      var bestOverlap = 0.0
      var bestSegment: DailyWorkflowSegment?

      for segment in rowSegments {
        let overlap = max(
          0, min(segment.endMinute, slotEnd) - max(segment.startMinute, slotStart))
        totalOccupied += overlap
        if overlap > bestOverlap {
          bestOverlap = overlap
          bestSegment = segment
        }
      }

      occupancies.append(min(1, totalOccupied / slotMinutes))
      if let best = bestSegment, bestOverlap > 0 {
        cardInfos.append(
          DailyWorkflowSlotCardInfo(
            title: best.cardTitle,
            durationMinutes: best.cardDurationMinutes
          ))
      } else {
        cardInfos.append(nil)
      }
    }

    let displayName =
      resolvedNameByCategory[key] ?? nameMap[key]
      ?? (key.isEmpty ? "Uncategorized" : key.capitalized)
    let colorHex = resolvedColorByCategory[key] ?? colorMap[key] ?? fallbackColorHex(for: key)

    return DailyWorkflowGridRow(
      id: key,
      name: displayName,
      colorHex: colorHex,
      slotOccupancies: occupancies,
      slotCardInfos: cardInfos
    )
  }

  let totals = selectedKeys.compactMap { key -> DailyWorkflowTotalItem? in
    guard let minutes = durationByCategory[key], minutes > 0 else { return nil }
    let name = resolvedNameByCategory[key] ?? nameMap[key] ?? "Uncategorized"
    let colorHex = resolvedColorByCategory[key] ?? colorMap[key] ?? fallbackColorHex(for: key)
    return DailyWorkflowTotalItem(id: key, name: name, minutes: minutes, colorHex: colorHex)
  }

  let stats = [
    DailyWorkflowStatChip(
      id: "context-switched",
      title: "Context switched",
      value: formatCount(contextSwitches)
    ),
    DailyWorkflowStatChip(
      id: "interrupted",
      title: "Interrupted",
      value: formatCount(interruptions)
    ),
    DailyWorkflowStatChip(
      id: "focused-for",
      title: "Focused for",
      value: formatDurationValue(focusedMinutes)
    ),
    DailyWorkflowStatChip(
      id: "distracted-for",
      title: "Distracted for",
      value: formatDurationValue(distractedMinutes)
    ),
    DailyWorkflowStatChip(
      id: "transitioning-time",
      title: "Transitioning time",
      value: formatDurationValue(transitionMinutes)
    ),
  ]

  // Check if user has a Distraction category
  let distractionCategoryKey = normalizedCategoryKey("Distraction")
  let hasDistractionCategory = orderedCategories.contains {
    normalizedCategoryKey($0.name) == distractionCategoryKey
  }

  // Collect distraction markers from both sources
  var distractionMarkers: [DailyWorkflowDistractionMarker] = []

  if hasDistractionCategory {
    var markerIndex = 0

    for card in cards {
      // Source 1: Full cards categorized as "Distraction"
      let cardCategoryKey = normalizedCategoryKey(
        card.category.trimmingCharacters(in: .whitespacesAndNewlines))
      if cardCategoryKey == distractionCategoryKey {
        if let rawStart = parseCardMinute(card.startTimestamp),
          let rawEnd = parseCardMinute(card.endTimestamp)
        {
          let (startMin, endMin) = normalizedMinuteRange(start: rawStart, end: rawEnd)
          let clippedStart = max(startMin, visibleStart)
          let clippedEnd = min(endMin, visibleEnd)
          if clippedEnd > clippedStart {
            distractionMarkers.append(
              DailyWorkflowDistractionMarker(
                id: "distraction-macro-\(markerIndex)",
                title: card.title,
                startMinute: clippedStart,
                endMinute: clippedEnd
              ))
            markerIndex += 1
          }
        }
      }

      // Source 2: Mini distractions embedded within any card
      if let distractions = card.distractions {
        guard let rawCardStart = parseCardMinute(card.startTimestamp),
          let rawCardEnd = parseCardMinute(card.endTimestamp)
        else {
          continue
        }

        let parentRange = normalizedMinuteRange(start: rawCardStart, end: rawCardEnd)

        for distraction in distractions {
          if let rawStart = parseCardMinute(distraction.startTime),
            let rawEnd = parseCardMinute(distraction.endTime)
          {
            guard
              let (startMin, endMin) = normalizedMiniDistractionRange(
                start: rawStart,
                end: rawEnd,
                parentStart: parentRange.start,
                parentEnd: parentRange.end
              )
            else {
              continue
            }

            let clippedStart = max(startMin, visibleStart)
            let clippedEnd = min(endMin, visibleEnd)
            if clippedEnd > clippedStart {
              distractionMarkers.append(
                DailyWorkflowDistractionMarker(
                  id: "distraction-mini-\(markerIndex)",
                  title: distraction.title,
                  startMinute: clippedStart,
                  endMinute: clippedEnd
                ))
              markerIndex += 1
            }
          }
        }
      }
    }

    // Merge overlapping/adjacent markers into single continuous blocks
    if distractionMarkers.count > 1 {
      distractionMarkers.sort { $0.startMinute < $1.startMinute }
      var merged: [DailyWorkflowDistractionMarker] = []
      var currentStart = distractionMarkers[0].startMinute
      var currentEnd = distractionMarkers[0].endMinute
      var currentTitles = [distractionMarkers[0].title]

      for i in 1..<distractionMarkers.count {
        let marker = distractionMarkers[i]
        // Merge if overlapping or within 2 minutes of each other
        if marker.startMinute <= currentEnd + 2 {
          // Overlapping or touching — extend and collect title
          currentEnd = max(currentEnd, marker.endMinute)
          if !currentTitles.contains(marker.title) {
            currentTitles.append(marker.title)
          }
        } else {
          // Gap — flush current merged marker
          merged.append(
            DailyWorkflowDistractionMarker(
              id: "distraction-merged-\(merged.count)",
              title: currentTitles.joined(separator: ", "),
              startMinute: currentStart,
              endMinute: currentEnd
            ))
          currentStart = marker.startMinute
          currentEnd = marker.endMinute
          currentTitles = [marker.title]
        }
      }
      // Flush last
      merged.append(
        DailyWorkflowDistractionMarker(
          id: "distraction-merged-\(merged.count)",
          title: currentTitles.joined(separator: ", "),
          startMinute: currentStart,
          endMinute: currentEnd
        ))
      distractionMarkers = merged
    }
  }

  return DailyWorkflowComputationResult(
    rows: rows, totals: totals, stats: stats, window: workflowWindow,
    distractionMarkers: distractionMarkers, hasDistractionCategory: hasDistractionCategory)
}

func isDistractionCategoryKey(_ key: String) -> Bool {
  let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  return normalized == "distraction" || normalized == "distractions"
}

func normalizedMinuteRange(start: Double, end: Double) -> (start: Double, end: Double) {
  let s = start < 240 ? start + 1440 : start
  var e = end < 240 ? end + 1440 : end
  if e <= s { e += 1440 }
  return (s, e)
}

func normalizedMiniDistractionRange(
  start rawStart: Double,
  end rawEnd: Double,
  parentStart: Double,
  parentEnd: Double
) -> (start: Double, end: Double)? {
  guard parentEnd > parentStart else { return nil }

  let start = anchoredMinute(rawStart, parentStart: parentStart, parentEnd: parentEnd)
  let end = anchoredMinute(rawEnd, parentStart: parentStart, parentEnd: parentEnd)

  let isValidParentAnchoredRange =
    end > start
    && start >= parentStart
    && end <= parentEnd

  if isValidParentAnchoredRange {
    return (start, end)
  }

  let latestValidStart = max(parentStart, parentEnd - 1)
  let collapsedStart = min(max(start, parentStart), latestValidStart)
  let collapsedEnd = min(parentEnd, collapsedStart + 1)

  guard collapsedEnd > collapsedStart else { return nil }
  return (collapsedStart, collapsedEnd)
}

func anchoredMinute(
  _ rawMinute: Double,
  parentStart: Double,
  parentEnd: Double
) -> Double {
  let candidates = [rawMinute, rawMinute + 1440, rawMinute - 1440]

  return candidates.min {
    distanceToRange($0, start: parentStart, end: parentEnd)
      < distanceToRange($1, start: parentStart, end: parentEnd)
  } ?? rawMinute
}

func distanceToRange(_ value: Double, start: Double, end: Double) -> Double {
  if value < start { return start - value }
  if value > end { return value - end }
  return 0
}

func parseCardMinute(_ value: String) -> Double? {
  guard let parsed = parseTimeHMMA(timeString: value) else { return nil }
  return Double(parsed)
}

func normalizedCategoryKey(_ value: String) -> String {
  value
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .lowercased()
}

func normalizedHex(_ value: String) -> String {
  value.replacingOccurrences(of: "#", with: "")
}

func fallbackColorHex(for key: String) -> String {
  let hash = key.utf8.reduce(5381) { current, byte in
    ((current << 5) &+ current) &+ Int(byte)
  }
  let palette = DailyGridConfig.fallbackColorHexes
  let index = abs(hash) % palette.count
  return palette[index]
}

func formatAxisHourLabel(fromAbsoluteHour hour: Int) -> String {
  let normalized = ((hour % 24) + 24) % 24
  let period = normalized >= 12 ? "pm" : "am"
  let display = normalized % 12 == 0 ? 12 : normalized % 12
  return "\(display)\(period)"
}

func formatCount(_ count: Int) -> String {
  "\(count) \(count == 1 ? "time" : "times")"
}

func formatDurationValue(_ minutes: Double) -> String {
  let rounded = max(0, Int(minutes.rounded()))
  let hours = rounded / 60
  let mins = rounded % 60

  if hours > 0 && mins > 0 { return "\(hours)h \(mins)m" }
  if hours > 0 { return "\(hours)h" }
  return "\(mins)m"
}
