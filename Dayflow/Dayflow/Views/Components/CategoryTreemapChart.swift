//
//  CategoryTreemapChart.swift
//  Dayflow
//
//  A treemap chart showing most used apps per category,
//  with rectangles sized proportionally to time spent.
//

import SwiftUI

// MARK: - Data Models

struct TreemapAppItem: Identifiable {
  let id: UUID
  let name: String
  let duration: TimeInterval  // seconds
  let changeMinutes: Int  // positive = green increase, negative = red decrease

  init(id: UUID = UUID(), name: String, duration: TimeInterval, changeMinutes: Int = 0) {
    self.id = id
    self.name = name
    self.duration = duration
    self.changeMinutes = changeMinutes
  }

  var formattedDuration: String {
    let totalMinutes = Int(duration / 60)
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours > 0 && minutes > 0 {
      return "\(hours)hr \(minutes)m"
    } else if hours > 0 {
      return "\(hours)hr"
    } else {
      return "\(minutes)m"
    }
  }

  var formattedChange: String {
    if changeMinutes >= 0 {
      return "+ \(abs(changeMinutes))m"
    } else {
      return "− \(abs(changeMinutes))m"
    }
  }

  var changeColor: Color {
    changeMinutes >= 0
      ? Color(red: 0.29, green: 0.69, blue: 0.31)
      : Color(red: 0.91, green: 0.30, blue: 0.24)
  }
}

struct TreemapCategory: Identifiable {
  let id: UUID
  let name: String
  let colorHex: String
  let apps: [TreemapAppItem]

  init(id: UUID = UUID(), name: String, colorHex: String, apps: [TreemapAppItem]) {
    self.id = id
    self.name = name
    self.colorHex = colorHex
    self.apps = apps
  }

  var totalDuration: TimeInterval {
    apps.reduce(0) { $0 + $1.duration }
  }

  var formattedTotalDuration: String {
    let totalMinutes = Int(totalDuration / 60)
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours > 0 && minutes > 0 {
      return "\(hours)hr \(minutes)m"
    } else if hours > 0 {
      return "\(hours)hr"
    } else {
      return "\(minutes)m"
    }
  }

  var borderColor: Color { Color(hex: colorHex) }
  var backgroundColor: Color { Color(hex: colorHex).opacity(0.06) }
}

// MARK: - Squarified Treemap Layout Engine

private struct LayoutRect {
  var x: CGFloat
  var y: CGFloat
  var width: CGFloat
  var height: CGFloat
}

private struct PlacedItem<T> {
  let item: T
  let rect: LayoutRect
}

private enum SquarifiedLayout {
  /// Lay out items proportionally within a rectangle using the squarified treemap algorithm.
  /// Each item is a tuple of (value, weight) where weight determines its area proportion.
  static func compute<T>(items: [(T, CGFloat)], in rect: LayoutRect) -> [PlacedItem<T>] {
    let sorted = items.sorted { $0.1 > $1.1 }
    let total = sorted.reduce(CGFloat(0)) { $0 + $1.1 }
    guard total > 0, rect.width > 0, rect.height > 0 else { return [] }

    let area = rect.width * rect.height
    let scaled: [(T, CGFloat)] = sorted.map { ($0.0, ($0.1 / total) * area) }
    return squarify(items: scaled, rect: rect)
  }

  private static func squarify<T>(items: [(T, CGFloat)], rect: LayoutRect) -> [PlacedItem<T>] {
    guard !items.isEmpty, rect.width > 0, rect.height > 0 else { return [] }
    if items.count == 1 {
      return [PlacedItem(item: items[0].0, rect: rect)]
    }

    var result: [PlacedItem<T>] = []
    var remaining = items
    var cur = rect

    while !remaining.isEmpty {
      guard cur.width > 0, cur.height > 0 else { break }
      let short = min(cur.width, cur.height)

      // Find the optimal row — greedily add items while aspect ratio improves
      var row: [(T, CGFloat)] = []
      var rowArea: CGFloat = 0
      var bestWorst: CGFloat = .infinity

      for i in 0..<remaining.count {
        let testAreas = row.map(\.1) + [remaining[i].1]
        let testTotal = rowArea + remaining[i].1
        let w = worstRatio(areas: testAreas, total: testTotal, short: short)
        if w <= bestWorst || row.isEmpty {
          row.append(remaining[i])
          rowArea = testTotal
          bestWorst = w
        } else {
          break
        }
      }

      // Place the row along the shorter axis
      let horiz = cur.width >= cur.height
      let strip = rowArea / short
      var offset: CGFloat = 0

      for (item, area) in row {
        let span = strip > 0 ? area / strip : 0
        let r: LayoutRect
        if horiz {
          r = LayoutRect(x: cur.x, y: cur.y + offset, width: strip, height: span)
        } else {
          r = LayoutRect(x: cur.x + offset, y: cur.y, width: span, height: strip)
        }
        result.append(PlacedItem(item: item, rect: r))
        offset += span
      }

      // Shrink the remaining rectangle
      if horiz {
        cur = LayoutRect(
          x: cur.x + strip, y: cur.y,
          width: cur.width - strip, height: cur.height
        )
      } else {
        cur = LayoutRect(
          x: cur.x, y: cur.y + strip,
          width: cur.width, height: cur.height - strip
        )
      }
      remaining = Array(remaining.dropFirst(row.count))
    }
    return result
  }

  private static func worstRatio(areas: [CGFloat], total: CGFloat, short: CGFloat) -> CGFloat {
    let strip = total / short
    guard strip > 0 else { return .infinity }
    var worst: CGFloat = 0
    for a in areas {
      let span = a / strip
      guard span > 0 else { continue }
      worst = max(worst, max(strip / span, span / strip))
    }
    return worst
  }
}

// MARK: - Main View

struct CategoryTreemapChart: View {
  let categories: [TreemapCategory]
  let title: String

  init(categories: [TreemapCategory], title: String = "Most used per category") {
    self.categories = categories
    self.title = title
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(title)
        .font(.custom("InstrumentSerif-Regular", size: 22))
        .foregroundColor(Color(red: 0.72, green: 0.49, blue: 0.25))

      GeometryReader { geo in
        let outerRect = LayoutRect(x: 0, y: 0, width: geo.size.width, height: geo.size.height)
        let items: [(TreemapCategory, CGFloat)] = categories.map {
          ($0, CGFloat($0.totalDuration))
        }
        let placed = SquarifiedLayout.compute(items: items, in: outerRect)

        ZStack(alignment: .topLeading) {
          ForEach(Array(placed.enumerated()), id: \.element.item.id) { _, p in
            CategoryCellView(category: p.item, rect: p.rect)
          }
        }
      }
    }
  }
}

// MARK: - Category Cell

private struct CategoryCellView: View {
  let category: TreemapCategory
  let rect: LayoutRect

  private let gap: CGFloat = 4
  private let headerHeight: CGFloat = 26
  private let innerPad: CGFloat = 6

  private var insetW: CGFloat { max(rect.width - gap, 0) }
  private var insetH: CGFloat { max(rect.height - gap, 0) }
  private var isCompact: Bool { insetW < 120 }

  private var appAreaWidth: CGFloat { max(insetW - innerPad * 2, 0) }
  private var appAreaHeight: CGFloat { max(insetH - headerHeight - innerPad, 0) }

  private var placedApps: [PlacedItem<TreemapAppItem>] {
    let appRect = LayoutRect(x: 0, y: 0, width: appAreaWidth, height: appAreaHeight)
    let items: [(TreemapAppItem, CGFloat)] = category.apps.map { ($0, CGFloat($0.duration)) }
    return SquarifiedLayout.compute(items: items, in: appRect)
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      // Category background + border
      RoundedRectangle(cornerRadius: 8)
        .fill(category.backgroundColor)
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(category.borderColor.opacity(0.45), lineWidth: 1.5)
        )

      VStack(alignment: .leading, spacing: 0) {
        // Category header: name + total duration
        HStack(spacing: 4) {
          Text(category.name)
            .font(.custom("NunitoSans-SemiBold", size: isCompact ? 10 : 12))
            .foregroundColor(category.borderColor)
            .lineLimit(1)
          Spacer(minLength: 4)
          Text(category.formattedTotalDuration)
            .font(.custom("NunitoSans-Regular", size: isCompact ? 10 : 12))
            .foregroundColor(category.borderColor)
            .lineLimit(1)
        }
        .padding(.horizontal, isCompact ? 6 : 10)
        .frame(height: headerHeight)

        // App cells treemap
        if appAreaWidth > 0, appAreaHeight > 0 {
          ZStack(alignment: .topLeading) {
            ForEach(Array(placedApps.enumerated()), id: \.element.item.id) { _, p in
              AppCellView(
                app: p.item,
                rect: p.rect,
                categoryColor: category.borderColor
              )
            }
          }
          .frame(width: appAreaWidth, height: appAreaHeight)
          .padding(.horizontal, innerPad)
          .padding(.bottom, innerPad)
        }
      }
    }
    .frame(width: insetW, height: insetH)
    .offset(x: rect.x + gap / 2, y: rect.y + gap / 2)
  }
}

// MARK: - App Cell

private struct AppCellView: View {
  let app: TreemapAppItem
  let rect: LayoutRect
  let categoryColor: Color

  private let gap: CGFloat = 4

  private var w: CGFloat { max(rect.width - gap, 0) }
  private var h: CGFloat { max(rect.height - gap, 0) }

  private enum CellSize {
    case tiny, compact, regular

    var nameFont: CGFloat {
      switch self {
      case .tiny: 11
      case .compact: 13
      case .regular: 16
      }
    }

    var detailFont: CGFloat {
      switch self {
      case .tiny: 9
      case .compact: 11
      case .regular: 13
      }
    }

    var spacing: CGFloat {
      switch self {
      case .tiny: 1
      case .compact: 2
      case .regular: 4
      }
    }

    var padding: CGFloat {
      switch self {
      case .tiny: 4
      case .compact: 6
      case .regular: 10
      }
    }
  }

  private var cellSize: CellSize {
    if w < 75 || h < 50 { return .tiny }
    if w < 130 || h < 80 { return .compact }
    return .regular
  }

  var body: some View {
    let size = cellSize

    ZStack {
      RoundedRectangle(cornerRadius: 6)
        .fill(Color.white)
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .stroke(categoryColor.opacity(0.18), lineWidth: 1)
        )

      VStack(spacing: size.spacing) {
        // App name
        Text(app.name)
          .font(.custom("NunitoSans-SemiBold", size: size.nameFont))
          .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.2))
          .lineLimit(1)

        // Duration (+ change inline for tiny cells)
        if h > 40 {
          if size == .tiny {
            // Compact: duration and change on one line
            HStack(spacing: 4) {
              Text(app.formattedDuration)
                .font(.custom("NunitoSans-Regular", size: size.detailFont))
                .foregroundColor(Color(red: 0.5, green: 0.5, blue: 0.5))
              Text(app.formattedChange)
                .font(.custom("NunitoSans-SemiBold", size: size.detailFont))
                .foregroundColor(app.changeColor)
            }
          } else {
            // Standard: duration on its own line
            Text(app.formattedDuration)
              .font(.custom("NunitoSans-Regular", size: size.detailFont))
              .foregroundColor(Color(red: 0.5, green: 0.5, blue: 0.5))
          }
        }

        // Change on its own line (for non-tiny cells)
        if size != .tiny, h > 60 {
          Text(app.formattedChange)
            .font(.custom("NunitoSans-SemiBold", size: size.detailFont))
            .foregroundColor(app.changeColor)
        }
      }
      .padding(size.padding)
    }
    .frame(width: w, height: h)
    .offset(x: rect.x + gap / 2, y: rect.y + gap / 2)
  }
}

// MARK: - Preview

#Preview("Category Treemap") {
  let categories: [TreemapCategory] = [
    TreemapCategory(
      name: "Design", colorHex: "#C084FC",
      apps: [
        TreemapAppItem(name: "Figma", duration: 18 * 3600 + 24 * 60, changeMinutes: 45),
        TreemapAppItem(name: "Midjourney", duration: 6 * 3600 + 7 * 60, changeMinutes: -45),
      ]),
    TreemapCategory(
      name: "Communication", colorHex: "#3B82F6",
      apps: [
        TreemapAppItem(name: "Zoom", duration: 18 * 3600 + 24 * 60, changeMinutes: 2),
        TreemapAppItem(name: "Slack", duration: 5 * 3600 + 24 * 60, changeMinutes: -45),
        TreemapAppItem(name: "ClickUp", duration: 24 * 60, changeMinutes: 2),
      ]),
    TreemapCategory(
      name: "Testing", colorHex: "#FB923C",
      apps: [
        TreemapAppItem(name: "Dayflow", duration: 5 * 3600 + 24 * 60, changeMinutes: 45),
        TreemapAppItem(name: "ClickUp", duration: 4 * 3600 + 24 * 60, changeMinutes: -45),
        TreemapAppItem(name: "Slack", duration: 3 * 3600 + 24 * 60, changeMinutes: 45),
      ]),
    TreemapCategory(
      name: "Research", colorHex: "#2DD4BF",
      apps: [
        TreemapAppItem(name: "ChatGPT", duration: 4 * 3600 + 24 * 60, changeMinutes: 2),
        TreemapAppItem(name: "Google", duration: 3 * 3600 + 24 * 60, changeMinutes: 2),
        TreemapAppItem(name: "Claude", duration: 2 * 3600 + 24 * 60, changeMinutes: -45),
      ]),
  ]

  CategoryTreemapChart(categories: categories)
    .frame(width: 700, height: 500)
    .padding(32)
    .background(Color(red: 0.98, green: 0.97, blue: 0.96))
}
