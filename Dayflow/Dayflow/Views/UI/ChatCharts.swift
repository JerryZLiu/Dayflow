import AppKit
import Charts
import SwiftUI

// MARK: - Inline Charts

enum ChatContentBlock: Identifiable {
  case text(id: UUID, content: String)
  case chart(ChatChartSpec)

  var id: UUID {
    switch self {
    case .text(let id, _):
      return id
    case .chart(let spec):
      return spec.id
    }
  }
}

enum ChatChartSpec: Identifiable {
  case bar(BasicChartSpec)
  case line(BasicChartSpec)
  case stackedBar(StackedBarChartSpec)
  case donut(DonutChartSpec)
  case heatmap(HeatmapChartSpec)
  case gantt(GanttChartSpec)

  var id: UUID {
    switch self {
    case .bar(let spec):
      return spec.id
    case .line(let spec):
      return spec.id
    case .stackedBar(let spec):
      return spec.id
    case .donut(let spec):
      return spec.id
    case .heatmap(let spec):
      return spec.id
    case .gantt(let spec):
      return spec.id
    }
  }

  var title: String {
    switch self {
    case .bar(let spec):
      return spec.title
    case .line(let spec):
      return spec.title
    case .stackedBar(let spec):
      return spec.title
    case .donut(let spec):
      return spec.title
    case .heatmap(let spec):
      return spec.title
    case .gantt(let spec):
      return spec.title
    }
  }

  static func parse(type: String, jsonString: String) -> ChatChartSpec? {
    guard let data = jsonString.data(using: .utf8) else { return nil }
    switch type {
    case "bar":
      guard let payload = try? JSONDecoder().decode(BasicPayload.self, from: data) else {
        return nil
      }
      guard !payload.x.isEmpty, payload.x.count == payload.y.count else { return nil }
      return .bar(
        BasicChartSpec(
          title: payload.title,
          labels: payload.x,
          values: payload.y,
          colorHex: sanitizeHex(payload.color)
        ))
    case "line":
      guard let payload = try? JSONDecoder().decode(BasicPayload.self, from: data) else {
        return nil
      }
      guard !payload.x.isEmpty, payload.x.count == payload.y.count else { return nil }
      return .line(
        BasicChartSpec(
          title: payload.title,
          labels: payload.x,
          values: payload.y,
          colorHex: sanitizeHex(payload.color)
        ))
    case "stacked_bar":
      guard let payload = try? JSONDecoder().decode(StackedPayload.self, from: data) else {
        return nil
      }
      guard !payload.x.isEmpty, !payload.series.isEmpty else { return nil }

      let series = payload.series.compactMap { entry -> StackedBarChartSpec.Series? in
        guard !entry.values.isEmpty, entry.values.count == payload.x.count else { return nil }
        return StackedBarChartSpec.Series(
          name: entry.name,
          values: entry.values,
          colorHex: sanitizeHex(entry.color)
        )
      }
      guard !series.isEmpty else { return nil }

      return .stackedBar(
        StackedBarChartSpec(
          title: payload.title,
          categories: payload.x,
          series: series
        ))
    case "donut", "pie":
      guard let payload = try? JSONDecoder().decode(DonutPayload.self, from: data) else {
        return nil
      }
      guard !payload.labels.isEmpty, payload.labels.count == payload.values.count else {
        return nil
      }
      let colors = payload.colors?.map { sanitizeHex($0) }
      let colorHexes: [String?]
      if let colors, colors.count == payload.labels.count {
        colorHexes = colors
      } else {
        colorHexes = Array(repeating: nil, count: payload.labels.count)
      }
      return .donut(
        DonutChartSpec(
          title: payload.title,
          labels: payload.labels,
          values: payload.values,
          colorHexes: colorHexes
        ))
    case "heatmap":
      guard let payload = try? JSONDecoder().decode(HeatmapPayload.self, from: data) else {
        return nil
      }
      guard !payload.x.isEmpty, !payload.y.isEmpty else { return nil }
      guard payload.values.count == payload.y.count else { return nil }
      for row in payload.values {
        guard row.count == payload.x.count else { return nil }
      }
      return .heatmap(
        HeatmapChartSpec(
          title: payload.title,
          xLabels: payload.x,
          yLabels: payload.y,
          values: payload.values,
          colorHex: sanitizeHex(payload.color)
        ))
    case "gantt":
      guard let payload = try? JSONDecoder().decode(GanttPayload.self, from: data) else {
        return nil
      }
      let items = payload.items.compactMap { item -> GanttChartSpec.Item? in
        guard item.end > item.start else { return nil }
        return GanttChartSpec.Item(
          label: item.label,
          start: item.start,
          end: item.end,
          colorHex: sanitizeHex(item.color)
        )
      }
      guard !items.isEmpty else { return nil }
      return .gantt(
        GanttChartSpec(
          title: payload.title,
          items: items
        ))
    default:
      return nil
    }
  }

  struct BasicPayload: Decodable {
    let title: String
    let x: [String]
    let y: [Double]
    let color: String?
  }

  struct StackedPayload: Decodable {
    let title: String
    let x: [String]
    let series: [SeriesPayload]

    struct SeriesPayload: Decodable {
      let name: String
      let values: [Double]
      let color: String?
    }
  }

  struct DonutPayload: Decodable {
    let title: String
    let labels: [String]
    let values: [Double]
    let colors: [String]?
  }

  struct HeatmapPayload: Decodable {
    let title: String
    let x: [String]
    let y: [String]
    let values: [[Double]]
    let color: String?
  }

  struct GanttPayload: Decodable {
    let title: String
    let items: [ItemPayload]

    struct ItemPayload: Decodable {
      let label: String
      let start: Double
      let end: Double
      let color: String?
    }
  }

  static func sanitizeHex(_ value: String?) -> String? {
    guard var raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty
    else { return nil }
    if raw.hasPrefix("#") {
      raw.removeFirst()
    }
    let length = raw.count
    guard length == 6 || length == 8 else { return nil }
    let allowed = CharacterSet(charactersIn: "0123456789ABCDEFabcdef")
    guard raw.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
    return raw.uppercased()
  }
}

struct BasicChartSpec: Identifiable {
  let id = UUID()
  let title: String
  let labels: [String]
  let values: [Double]
  let colorHex: String?
}

struct StackedBarChartSpec: Identifiable {
  let id = UUID()
  let title: String
  let categories: [String]
  let series: [Series]

  struct Series: Identifiable {
    let id = UUID()
    let name: String
    let values: [Double]
    let colorHex: String?
  }
}

struct DonutChartSpec: Identifiable {
  let id = UUID()
  let title: String
  let labels: [String]
  let values: [Double]
  let colorHexes: [String?]
}

struct HeatmapChartSpec: Identifiable {
  let id = UUID()
  let title: String
  let xLabels: [String]
  let yLabels: [String]
  let values: [[Double]]
  let colorHex: String?
}

struct GanttChartSpec: Identifiable {
  let id = UUID()
  let title: String
  let items: [Item]

  struct Item: Identifiable {
    let id = UUID()
    let label: String
    let start: Double
    let end: Double
    let colorHex: String?
  }
}

struct ChatContentParser {
  static func blocks(from text: String) -> [ChatContentBlock] {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    let pattern = "```chart\\s+type\\s*=\\s*([A-Za-z_]+)\\s*\\n?([\\s\\S]*?)\\n?```"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
      return [.text(id: UUID(), content: text)]
    }

    let range = NSRange(normalized.startIndex..., in: normalized)
    let matches = regex.matches(in: normalized, range: range)
    guard !matches.isEmpty else { return [.text(id: UUID(), content: text)] }

    var blocks: [ChatContentBlock] = []
    var currentIndex = normalized.startIndex

    for match in matches {
      guard let matchRange = Range(match.range, in: normalized) else { continue }

      if matchRange.lowerBound > currentIndex {
        let chunk = String(normalized[currentIndex..<matchRange.lowerBound])
        if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          blocks.append(.text(id: UUID(), content: chunk))
        }
      }

      if let typeRange = Range(match.range(at: 1), in: normalized),
        let jsonRange = Range(match.range(at: 2), in: normalized)
      {
        let typeString = normalized[typeRange].lowercased()
        let jsonString = normalized[jsonRange].trimmingCharacters(in: .whitespacesAndNewlines)
        if let spec = ChatChartSpec.parse(type: typeString, jsonString: jsonString) {
          blocks.append(.chart(spec))
        } else {
          blocks.append(.text(id: UUID(), content: String(normalized[matchRange])))
        }
      }

      currentIndex = matchRange.upperBound
    }

    if currentIndex < normalized.endIndex {
      let tail = String(normalized[currentIndex...])
      if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        blocks.append(.text(id: UUID(), content: tail))
      }
    }

    return blocks.isEmpty ? [.text(id: UUID(), content: text)] : blocks
  }
}

struct ChatChartBlockView: View {
  let spec: ChatChartSpec

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      let title = spec.title.trimmingCharacters(in: .whitespacesAndNewlines)
      if !title.isEmpty {
        Text(title)
          .font(.custom("Nunito", size: 12).weight(.semibold))
          .foregroundColor(Color(hex: "4A4A4A"))
      }
      chartBody
        .frame(height: 180)
        .padding(.top, 4)
    }
  }

  @ViewBuilder
  var chartBody: some View {
    switch spec {
    case .bar(let chartSpec):
      basicChartBody(spec: chartSpec, isLine: false)
    case .line(let chartSpec):
      basicChartBody(spec: chartSpec, isLine: true)
    case .stackedBar(let chartSpec):
      stackedBarBody(spec: chartSpec)
    case .donut(let chartSpec):
      donutBody(spec: chartSpec)
    case .heatmap(let chartSpec):
      heatmapBody(spec: chartSpec)
    case .gantt(let chartSpec):
      ganttBody(spec: chartSpec)
    }
  }

  func basicChartBody(spec: BasicChartSpec, isLine: Bool) -> some View {
    let points = Array(zip(spec.labels, spec.values)).map { ChartPoint(label: $0.0, value: $0.1) }
    let color = seriesColor(for: spec.colorHex, fallbackIndex: 0)

    return Chart(points) { point in
      if isLine {
        LineMark(
          x: .value("Category", point.label),
          y: .value("Value", point.value)
        )
        .interpolationMethod(.catmullRom)
        .foregroundStyle(color)

        PointMark(
          x: .value("Category", point.label),
          y: .value("Value", point.value)
        )
        .foregroundStyle(color)
      } else {
        BarMark(
          x: .value("Category", point.label),
          y: .value("Value", point.value)
        )
        .foregroundStyle(color)
      }
    }
    .chartXAxis {
      AxisMarks(values: points.map(\.label)) { value in
        if let label = value.as(String.self) {
          AxisValueLabel {
            Text(label)
              .font(.system(size: 10))
              .foregroundColor(Color(hex: "666666"))
              .lineLimit(1)
          }
        }
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading) { _ in
        AxisGridLine()
        AxisValueLabel()
      }
    }
  }

  func stackedBarBody(spec: StackedBarChartSpec) -> some View {
    let points = stackedPoints(from: spec)
    let domain = spec.series.map(\.name)
    let range = spec.series.enumerated().map { index, series in
      seriesColor(for: series.colorHex, fallbackIndex: index)
    }

    return Chart(points) { point in
      BarMark(
        x: .value("Category", point.category),
        y: .value("Value", point.value)
      )
      .foregroundStyle(by: .value("Series", point.seriesName))
    }
    .chartForegroundStyleScale(domain: domain, range: range)
    .chartXAxis {
      AxisMarks(values: spec.categories) { value in
        if let label = value.as(String.self) {
          AxisValueLabel {
            Text(label)
              .font(.system(size: 10))
              .foregroundColor(Color(hex: "666666"))
              .lineLimit(1)
          }
        }
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading) { _ in
        AxisGridLine()
        AxisValueLabel()
      }
    }
  }

  func donutBody(spec: DonutChartSpec) -> some View {
    let slices = zip(spec.labels, spec.values).map { DonutSlice(label: $0.0, value: $0.1) }
    let range = spec.labels.enumerated().map { index, _ in
      let hex = spec.colorHexes.indices.contains(index) ? spec.colorHexes[index] : nil
      return seriesColor(for: hex, fallbackIndex: index)
    }

    return Chart(slices) { slice in
      SectorMark(
        angle: .value("Value", slice.value),
        innerRadius: .ratio(0.6),
        angularInset: 1
      )
      .foregroundStyle(by: .value("Label", slice.label))
    }
    .chartForegroundStyleScale(domain: spec.labels, range: range)
    .chartLegend(position: .bottom, alignment: .leading)
  }

  func heatmapBody(spec: HeatmapChartSpec) -> some View {
    let points = heatmapPoints(from: spec)
    let range = heatmapRange(for: spec)
    let baseColor = seriesColor(for: spec.colorHex, fallbackIndex: 1)

    return Chart(points) { point in
      RectangleMark(
        x: .value("X", point.xLabel),
        y: .value("Y", point.yLabel),
        width: .ratio(0.9),
        height: .ratio(0.9)
      )
      .foregroundStyle(heatmapColor(value: point.value, range: range, base: baseColor))
      .cornerRadius(2)
    }
    .chartXAxis {
      AxisMarks(values: spec.xLabels) { value in
        if let label = value.as(String.self) {
          AxisValueLabel {
            Text(label)
              .font(.system(size: 10))
              .foregroundColor(Color(hex: "666666"))
              .lineLimit(1)
          }
        }
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading, values: spec.yLabels) { value in
        if let label = value.as(String.self) {
          AxisValueLabel {
            Text(label)
              .font(.system(size: 10))
              .foregroundColor(Color(hex: "666666"))
              .lineLimit(1)
          }
        }
      }
    }
    .chartLegend(.hidden)
  }

  func ganttBody(spec: GanttChartSpec) -> some View {
    let domain = ganttDomain(for: spec)
    let labels = spec.items.map(\.label)

    return Chart(spec.items) { item in
      BarMark(
        xStart: .value("Start", item.start),
        xEnd: .value("End", item.end),
        y: .value("Label", item.label)
      )
      .foregroundStyle(
        seriesColor(for: item.colorHex, fallbackIndex: itemIndex(for: item, in: spec))
      )
      .cornerRadius(4)
    }
    .chartXScale(domain: domain.min...domain.max)
    .chartXAxis {
      AxisMarks(values: .automatic(desiredCount: 6)) { value in
        if let number = value.as(Double.self) {
          AxisValueLabel {
            Text(number, format: .number.precision(.fractionLength(1)))
              .font(.system(size: 10))
              .foregroundColor(Color(hex: "666666"))
          }
        }
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading, values: labels) { value in
        if let label = value.as(String.self) {
          AxisValueLabel {
            Text(label)
              .font(.system(size: 10))
              .foregroundColor(Color(hex: "666666"))
              .lineLimit(1)
          }
        }
      }
    }
    .chartLegend(.hidden)
  }

  func stackedPoints(from spec: StackedBarChartSpec) -> [StackedPoint] {
    var points: [StackedPoint] = []
    for series in spec.series {
      for (index, category) in spec.categories.enumerated() {
        points.append(
          StackedPoint(
            category: category,
            seriesName: series.name,
            value: series.values[index]
          ))
      }
    }
    return points
  }

  func seriesColor(for hex: String?, fallbackIndex: Int) -> Color {
    if let hex {
      return Color(hex: hex)
    }
    return Self.defaultPalette[fallbackIndex % Self.defaultPalette.count]
  }

  struct ChartPoint: Identifiable {
    let id = UUID()
    let label: String
    let value: Double
  }

  struct StackedPoint: Identifiable {
    let id = UUID()
    let category: String
    let seriesName: String
    let value: Double
  }

  struct DonutSlice: Identifiable {
    let id = UUID()
    let label: String
    let value: Double
  }

  struct HeatmapPoint: Identifiable {
    let id = UUID()
    let xLabel: String
    let yLabel: String
    let value: Double
  }

  struct HeatmapRange {
    let min: Double
    let max: Double
  }

  struct GanttDomain {
    let min: Double
    let max: Double
  }

  func heatmapPoints(from spec: HeatmapChartSpec) -> [HeatmapPoint] {
    var points: [HeatmapPoint] = []
    for (rowIndex, row) in spec.values.enumerated() {
      let yLabel = spec.yLabels[rowIndex]
      for (colIndex, value) in row.enumerated() {
        points.append(
          HeatmapPoint(
            xLabel: spec.xLabels[colIndex],
            yLabel: yLabel,
            value: value
          ))
      }
    }
    return points
  }

  func heatmapRange(for spec: HeatmapChartSpec) -> HeatmapRange {
    let flattened = spec.values.flatMap { $0 }
    let minValue = flattened.min() ?? 0
    let maxValue = flattened.max() ?? minValue
    return HeatmapRange(min: minValue, max: maxValue)
  }

  func heatmapColor(value: Double, range: HeatmapRange, base: Color) -> Color {
    let denominator = range.max - range.min
    let normalized = denominator == 0 ? 1.0 : (value - range.min) / denominator
    let clamped = min(max(normalized, 0), 1)
    let opacity = 0.2 + (0.8 * clamped)
    return base.opacity(opacity)
  }

  func ganttDomain(for spec: GanttChartSpec) -> GanttDomain {
    let starts = spec.items.map(\.start)
    let ends = spec.items.map(\.end)
    let minValue = min(starts.min() ?? 0, ends.min() ?? 0)
    let maxValue = max(starts.max() ?? 0, ends.max() ?? 0)
    return GanttDomain(min: minValue, max: maxValue)
  }

  func itemIndex(for item: GanttChartSpec.Item, in spec: GanttChartSpec) -> Int {
    spec.items.firstIndex(where: { $0.id == item.id }) ?? 0
  }

  static let defaultPalette: [Color] = [
    Color(hex: "F96E00"),
    Color(hex: "1F6FEB"),
    Color(hex: "2E7D32"),
    Color(hex: "8E24AA"),
    Color(hex: "00897B"),
  ]
}
