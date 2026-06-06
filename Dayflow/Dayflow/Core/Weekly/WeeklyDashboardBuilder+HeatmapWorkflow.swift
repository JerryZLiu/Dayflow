//
//  WeeklyDashboardBuilder+HeatmapWorkflow.swift
//  Dayflow
//

import Foundation

extension WeeklyDashboardBuilder {
  static func buildHeatmap(
    from facts: [WeeklyCardFact],
    weekRange: WeeklyDateRange
  ) -> WeeklyFocusHeatmapSnapshot {
    let visibleFacts = facts.filter { !$0.isSystem && !$0.isIdle }
    let visibleWindow = weeklyActivityWindow(from: visibleFacts)
    let bucketMinutes = 5.0
    let bucketCount = max(1, Int(ceil((visibleWindow.end - visibleWindow.start) / bucketMinutes)))
    let descriptors = heatmapDayDescriptors(for: weekRange)
    let rows = descriptors.map { descriptor in
      let dayFacts = visibleFacts.filter {
        $0.dayString == descriptor.dayString
      }

      return WeeklyFocusHeatmapRow(
        id: descriptor.id,
        label: descriptor.label,
        values: heatmapValues(
          for: dayFacts,
          visibleStart: visibleWindow.start,
          bucketMinutes: bucketMinutes,
          bucketCount: bucketCount
        )
      )
    }

    return WeeklyFocusHeatmapSnapshot(
      title: "Focus and distraction heat map",
      focusedLabel: "Focused work",
      distractedLabel: "Distracted",
      startMinute: visibleWindow.start,
      endMinute: visibleWindow.start + (Double(bucketCount) * bucketMinutes),
      bucketMinutes: bucketMinutes,
      timeLabels: weeklyTimeLabels(
        startMinute: visibleWindow.start,
        endMinute: visibleWindow.start + (Double(bucketCount) * bucketMinutes)
      ),
      rows: rows
    )
  }

  static func buildWorkflow(
    from facts: [WeeklyCardFact],
    weekRange: WeeklyDateRange
  ) -> WeeklyWorkflowSnapshot {
    let visibleFacts = facts.filter { !$0.isSystem && !$0.isIdle }
    let visibleWindow = weeklyActivityWindow(from: visibleFacts)
    let visibleStart = visibleWindow.start
    let visibleEnd = visibleWindow.end
    let slotMinutes = 15.0
    let slotCount = max(1, Int((visibleEnd - visibleStart) / slotMinutes))
    let descriptors = dayDescriptors(for: weekRange, offsets: Array(0..<7))

    let rows = descriptors.map { descriptor in
      let dayFacts = visibleFacts.filter { $0.dayString == descriptor.dayString }
      let cells = (0..<slotCount).map { slotIndex in
        workflowCell(
          slotIndex: slotIndex,
          dayFacts: dayFacts,
          visibleStart: visibleStart,
          slotMinutes: slotMinutes
        )
      }

      return WeeklyWorkflowRow(
        id: descriptor.id,
        label: descriptor.label,
        cells: cells
      )
    }

    return WeeklyWorkflowSnapshot(
      title: "Your workflow this week",
      startMinute: visibleStart,
      endMinute: visibleEnd,
      slotMinutes: slotMinutes,
      timeLabels: weeklyTimeLabels(startMinute: visibleStart, endMinute: visibleEnd),
      rows: rows,
      totals: workflowTotals(from: visibleFacts)
    )
  }

  private static func heatmapValues(
    for facts: [WeeklyCardFact],
    visibleStart: Double,
    bucketMinutes: Double,
    bucketCount: Int
  ) -> [Double] {
    var focusMinutes = Array(repeating: 0.0, count: bucketCount)
    var distractionMinutes = Array(repeating: 0.0, count: bucketCount)
    var switchPressure = Array(repeating: 0.0, count: bucketCount)
    var previousFact: WeeklyCardFact?

    for fact in facts.sorted(by: { $0.startMinute < $1.startMinute }) {
      if let previousFact,
        fact.startMinute - previousFact.endMinute <= 20,
        heatmapSignature(for: fact) != heatmapSignature(for: previousFact)
      {
        addHeatmapSwitch(
          at: fact.startMinute,
          to: &switchPressure,
          visibleStart: visibleStart,
          bucketMinutes: bucketMinutes
        )
      }

      addHeatmapFact(
        fact,
        focusMinutes: &focusMinutes,
        distractionMinutes: &distractionMinutes,
        visibleStart: visibleStart,
        bucketMinutes: bucketMinutes
      )
      previousFact = fact
    }

    return heatmapScores(
      focusMinutes: focusMinutes,
      distractionMinutes: distractionMinutes,
      switchPressure: switchPressure,
      bucketMinutes: bucketMinutes
    )
  }

  private static func addHeatmapFact(
    _ fact: WeeklyCardFact,
    focusMinutes: inout [Double],
    distractionMinutes: inout [Double],
    visibleStart: Double,
    bucketMinutes: Double
  ) {
    if isFullDistractionFact(fact) {
      addHeatmapInterval(
        start: fact.startMinute,
        end: fact.endMinute,
        to: &distractionMinutes,
        visibleStart: visibleStart,
        bucketMinutes: bucketMinutes
      )
      return
    }

    addHeatmapInterval(
      start: fact.startMinute,
      end: fact.endMinute,
      to: &focusMinutes,
      visibleStart: visibleStart,
      bucketMinutes: bucketMinutes
    )

    for interval in embeddedDistractionIntervals(for: fact) {
      addHeatmapInterval(
        start: interval.start,
        end: interval.end,
        to: &distractionMinutes,
        visibleStart: visibleStart,
        bucketMinutes: bucketMinutes
      )
      addHeatmapInterval(
        start: interval.start,
        end: interval.end,
        to: &focusMinutes,
        visibleStart: visibleStart,
        bucketMinutes: bucketMinutes,
        weight: -1
      )
    }
  }

  private static func addHeatmapInterval(
    start rawStart: Double,
    end rawEnd: Double,
    to values: inout [Double],
    visibleStart: Double,
    bucketMinutes: Double,
    weight: Double = 1
  ) {
    let visibleEnd = visibleStart + Double(values.count) * bucketMinutes
    let start = max(rawStart, visibleStart)
    let end = min(rawEnd, visibleEnd)
    guard end > start else { return }

    let firstIndex = max(0, Int(floor((start - visibleStart) / bucketMinutes)))
    let lastIndex = min(values.count - 1, Int(ceil((end - visibleStart) / bucketMinutes)) - 1)
    guard firstIndex <= lastIndex else { return }

    for index in firstIndex...lastIndex where values.indices.contains(index) {
      let bucketStart = visibleStart + (Double(index) * bucketMinutes)
      let bucketEnd = bucketStart + bucketMinutes
      let overlap = max(0, min(end, bucketEnd) - max(start, bucketStart))
      values[index] += overlap * weight
    }
  }

  private static func addHeatmapSwitch(
    at minute: Double,
    to values: inout [Double],
    visibleStart: Double,
    bucketMinutes: Double
  ) {
    let visibleEnd = visibleStart + Double(values.count) * bucketMinutes
    guard minute >= visibleStart && minute < visibleEnd else { return }

    let index = Int((minute - visibleStart) / bucketMinutes)
    guard values.indices.contains(index) else { return }
    values[index] += 1
  }

  private static func heatmapScores(
    focusMinutes: [Double],
    distractionMinutes: [Double],
    switchPressure: [Double],
    bucketMinutes: Double
  ) -> [Double] {
    let cleanFocus = focusMinutes.indices.map { index in
      focusMinutes[index] >= bucketMinutes * 0.6 && distractionMinutes[index] < 1
    }
    let focusRunLengths = heatmapRunLengths(from: cleanFocus)

    let rawScores = focusMinutes.indices.map { index -> Double in
      let focusRatio = max(0, min(1, focusMinutes[index] / bucketMinutes))
      let distractionRatio = max(0, min(1, distractionMinutes[index] / bucketMinutes))
      let sustainedFocusBoost = min(1, Double(focusRunLengths[index]) / 6)
      let focusStrength = focusRatio * (0.35 + (0.65 * sustainedFocusBoost))
      let distractionStrength = min(1, distractionRatio * 1.25)
      let switchStrength = min(1, switchPressure[index] / 2) * 0.22

      return max(-1, min(1, distractionStrength + switchStrength - focusStrength))
    }

    return smoothFocusedHeatmapScores(rawScores)
  }

  private static func heatmapRunLengths(from values: [Bool]) -> [Int] {
    var lengths = Array(repeating: 0, count: values.count)
    var index = 0

    while index < values.count {
      guard values[index] else {
        index += 1
        continue
      }

      let startIndex = index
      while index < values.count && values[index] {
        index += 1
      }

      let runLength = index - startIndex
      for runIndex in startIndex..<index {
        lengths[runIndex] = runLength
      }
    }

    return lengths
  }

  private static func smoothFocusedHeatmapScores(_ scores: [Double]) -> [Double] {
    guard scores.count > 2 else { return scores }

    return scores.indices.map { index in
      let value = scores[index]
      guard value < 0 else { return value }

      let lowerBound = max(scores.startIndex, index - 1)
      let upperBound = min(scores.index(before: scores.endIndex), index + 1)
      let focusedNeighbors = scores[lowerBound...upperBound].filter { $0 < 0 }
      guard focusedNeighbors.count > 1 else { return value }

      let average = focusedNeighbors.reduce(0, +) / Double(focusedNeighbors.count)
      return max(-1, min(1, (value * 0.55) + (average * 0.45)))
    }
  }

  private static func embeddedDistractionIntervals(for fact: WeeklyCardFact) -> [(
    start: Double, end: Double
  )] {
    guard let distractions = fact.card.distractions, !distractions.isEmpty else { return [] }

    return distractions.compactMap { distraction in
      guard let startMinute = parseCardMinute(distraction.startTime),
        let endMinute = parseCardMinute(distraction.endTime)
      else {
        return nil
      }

      return alignedDistractionRange(
        start: startMinute,
        end: endMinute,
        parentStart: fact.startMinute,
        parentEnd: fact.endMinute
      )
    }
  }

  private static func alignedDistractionRange(
    start: Double,
    end: Double,
    parentStart: Double,
    parentEnd: Double
  ) -> (start: Double, end: Double)? {
    let normalized = normalizedMinuteRange(start: start, end: end)
    let candidates = [
      normalized,
      (start: normalized.start - 1440, end: normalized.end - 1440),
      (start: normalized.start + 1440, end: normalized.end + 1440),
    ]

    return
      candidates
      .filter { candidate in
        candidate.start >= parentStart - 2
          && candidate.end <= parentEnd + 2
          && candidate.end > candidate.start
      }
      .min { lhs, rhs in
        let lhsDistance = abs(lhs.start - parentStart) + abs(parentEnd - lhs.end) * 0.1
        let rhsDistance = abs(rhs.start - parentStart) + abs(parentEnd - rhs.end) * 0.1
        return lhsDistance < rhsDistance
      }
  }

  private static func isFullDistractionFact(_ fact: WeeklyCardFact) -> Bool {
    let categoryText = "\(fact.categoryName) \(fact.card.subcategory)".lowercased()
    if categoryText.contains("distraction") || categoryText.contains("distracted") {
      return true
    }

    if fact.card.distractions?.isEmpty == false {
      return false
    }

    return fact.isDistraction
  }

  private static func heatmapSignature(for fact: WeeklyCardFact) -> String {
    "\(fact.categoryKey)|\(fact.appKey)"
  }

  private static func workflowCell(
    slotIndex: Int,
    dayFacts: [WeeklyCardFact],
    visibleStart: Double,
    slotMinutes: Double
  ) -> WeeklyWorkflowCell {
    let slotStart = visibleStart + (Double(slotIndex) * slotMinutes)
    let slotEnd = slotStart + slotMinutes
    var buckets: [String: WeeklyWorkflowBucket] = [:]

    for fact in dayFacts {
      let overlap = max(0, min(fact.endMinute, slotEnd) - max(fact.startMinute, slotStart))
      guard overlap > 0 else { continue }

      let bucket = workflowBucket(for: fact)
      var updatedBucket = buckets[bucket.id] ?? bucket
      updatedBucket.minutes += overlap
      buckets[bucket.id] = updatedBucket
    }

    let totalMinutes = buckets.values.reduce(0) { $0 + $1.minutes }
    guard let dominant = buckets.values.sorted(by: workflowBucketSort).first else {
      return WeeklyWorkflowCell(
        id: "slot-\(slotIndex)",
        categoryName: nil,
        colorHex: nil,
        minutes: 0,
        occupancy: 0
      )
    }

    return WeeklyWorkflowCell(
      id: "slot-\(slotIndex)",
      categoryName: dominant.name,
      colorHex: dominant.colorHex,
      minutes: Int(totalMinutes.rounded()),
      occupancy: min(1, totalMinutes / slotMinutes)
    )
  }

  private static func workflowTotals(from facts: [WeeklyCardFact]) -> [WeeklyWorkflowTotalItem] {
    let grouped = Dictionary(grouping: facts) { fact in
      workflowBucket(for: fact).id
    }

    let totals = grouped.values.compactMap { categoryFacts -> WeeklyWorkflowTotalItem? in
      guard let first = categoryFacts.first else { return nil }
      let minutes = categoryFacts.reduce(0) { $0 + $1.durationMinutes }
      guard minutes > 0 else { return nil }
      let bucket = workflowBucket(for: first)

      return WeeklyWorkflowTotalItem(
        id: bucket.id,
        name: bucket.name,
        minutes: minutes,
        duration: durationText(minutes),
        colorHex: bucket.colorHex
      )
    }

    return totals.sorted {
      if $0.minutes == $1.minutes {
        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
      return $0.minutes > $1.minutes
    }
    .prefix(7)
    .map { $0 }
  }

  private static func weeklyActivityWindow(from facts: [WeeklyCardFact]) -> (
    start: Double, end: Double
  ) {
    let fallbackStart = 9.0 * 60.0
    let fallbackEnd = 22.0 * 60.0
    let dayStart = 4.0 * 60.0
    let dayEnd = 28.0 * 60.0
    let padding = 30.0
    let snapMinutes = 15.0

    guard let earliest = facts.map(\.startMinute).min(),
      let latest = facts.map(\.endMinute).max()
    else {
      return (fallbackStart, fallbackEnd)
    }

    let paddedStart = max(dayStart, earliest - padding)
    let paddedEnd = min(dayEnd, latest + padding)
    let snappedStart = floor(paddedStart / snapMinutes) * snapMinutes
    var snappedEnd = ceil(paddedEnd / snapMinutes) * snapMinutes

    if snappedEnd == 24.0 * 60.0 {
      snappedEnd = dayEnd
    }

    guard snappedEnd > snappedStart else {
      return (fallbackStart, fallbackEnd)
    }

    return (snappedStart, snappedEnd)
  }

  private static func weeklyTimeLabels(
    startMinute: Double,
    endMinute: Double
  ) -> [WeeklyWorkflowTimeLabel] {
    let firstHour = ceil(startMinute / 60.0) * 60.0
    let lastHour = floor(endMinute / 60.0) * 60.0

    guard firstHour <= lastHour else {
      return []
    }

    return stride(from: firstHour, through: lastHour, by: 60.0).map { minute in
      WeeklyWorkflowTimeLabel(
        id: "time-\(Int(minute))",
        label: workflowClockLabel(from: minute),
        minute: minute
      )
    }
  }

  private static func workflowClockLabel(from minute: Double) -> String {
    let totalMinutes = Int(minute.rounded())
    let hour24 = (totalMinutes / 60) % 24
    let minutePart = totalMinutes % 60
    let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
    let suffix = hour24 < 12 ? "am" : "pm"
    if minutePart > 0 {
      return String(format: "%d:%02d%@", hour12, minutePart, suffix)
    }
    return "\(hour12)\(suffix)"
  }

  private static func workflowBucket(for fact: WeeklyCardFact) -> WeeklyWorkflowBucket {
    if isDistractionCategory(fact) {
      return WeeklyWorkflowBucket(
        id: "distraction",
        name: "Distraction",
        colorHex: "FF5950",
        minutes: 0
      )
    }

    return WeeklyWorkflowBucket(
      id: fact.categoryKey,
      name: fact.categoryName,
      colorHex: fact.categoryColorHex,
      minutes: 0
    )
  }

  private static func isDistractionCategory(_ fact: WeeklyCardFact) -> Bool {
    fact.categoryKey.contains("distraction")
      || fact.categoryName.localizedCaseInsensitiveContains("distraction")
  }

  private static func workflowBucketSort(
    lhs: WeeklyWorkflowBucket,
    rhs: WeeklyWorkflowBucket
  ) -> Bool {
    if lhs.minutes == rhs.minutes {
      return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
    return lhs.minutes > rhs.minutes
  }

  private static func heatmapDayDescriptors(for weekRange: WeeklyDateRange) -> [WeeklyDayDescriptor]
  {
    dayDescriptors(for: weekRange, offsets: [6, 0, 1, 2, 3, 4, 5])
  }
}

private struct WeeklyWorkflowBucket {
  let id: String
  let name: String
  let colorHex: String
  var minutes: Double
}
