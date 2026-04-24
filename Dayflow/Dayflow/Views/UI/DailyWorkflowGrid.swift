import AppKit
import Foundation
import SwiftUI
import UserNotifications

struct DailyWorkflowGrid: View {
  let rows: [DailyWorkflowGridRow]
  let timelineWindow: DailyWorkflowTimelineWindow
  let distractionMarkers: [DailyWorkflowDistractionMarker]
  let showDistractionRow: Bool
  let scale: CGFloat

  @Binding var hoveredDistractionId: String?
  @Binding var hoveredCellKey: String?
  @State private var hoverClearTask: Task<Void, Never>? = nil
  private let hoverExitDelayNanoseconds: UInt64 = 80_000_000

  private var renderRows: [DailyWorkflowGridRow] {
    if rows.isEmpty {
      return DailyWorkflowGridRow.placeholderRows(slotCount: timelineWindow.slotCount)
    }
    // Hide the Distraction/Distractions category row when we have a dedicated distractions row
    if showDistractionRow {
      return rows.filter {
        !isDistractionCategoryKey($0.id)
      }
    }
    return rows
  }

  var body: some View {
    GeometryReader { geo in
      let hourTicks = timelineWindow.hourTickHours
      let slotCount = max(
        1, renderRows.map { $0.slotOccupancies.count }.max() ?? timelineWindow.slotCount)
      let layoutScale = scale

      let leftInset: CGFloat = 36 * layoutScale
      let categoryLabelWidth = labelColumnWidth(for: renderRows, layoutScale: layoutScale)
      let labelToGridSpacing: CGFloat = 13 * layoutScale
      let rightInset: CGFloat = 52 * layoutScale
      let topInset: CGFloat = 25 * layoutScale
      let axisTopSpacing: CGFloat = 10 * layoutScale
      let axisLabelSpacing: CGFloat = 5 * layoutScale

      let distractionRowHeight: CGFloat = 10 * layoutScale
      let distractionRowSpacing: CGFloat = 6 * layoutScale
      let distractionCornerRadius: CGFloat = max(1, 2 * layoutScale)
      let showDistractions = showDistractionRow && !distractionMarkers.isEmpty
      let distractionLabelWidth =
        showDistractions
        ? labelColumnWidth(
          for: [
            DailyWorkflowGridRow(
              id: "d", name: "Distractions", colorHex: "FF5950",
              slotOccupancies: [], slotCardInfos: [])
          ], layoutScale: layoutScale) : 0
      let effectiveLabelWidth =
        showDistractions
        ? max(categoryLabelWidth, distractionLabelWidth) : categoryLabelWidth

      let gridViewportWidth = max(
        80, geo.size.width - leftInset - effectiveLabelWidth - labelToGridSpacing - rightInset)
      let baselineCellSize: CGFloat = 18 * layoutScale
      let baselineGap: CGFloat = 2 * layoutScale
      let cellSize = baselineCellSize
      let columnSpacing = baselineGap
      let rowSpacing = baselineGap
      let cellCornerRadius = max(1.2, 2.5 * layoutScale)
      let categoryLabelFontSize: CGFloat = 12 * layoutScale
      let axisLabelFontSize: CGFloat = 10 * layoutScale
      let totalGap = columnSpacing * CGFloat(slotCount - 1)
      let gridWidth = (cellSize * CGFloat(slotCount)) + totalGap
      let axisWidth = gridWidth

      VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .top, spacing: labelToGridSpacing) {
          VStack(alignment: .trailing, spacing: rowSpacing) {
            ForEach(renderRows) { row in
              Text(row.name)
                .font(.custom("Nunito-Regular", size: categoryLabelFontSize))
                .foregroundStyle(Color.black.opacity(0.9))
                .frame(width: effectiveLabelWidth, height: cellSize, alignment: .trailing)
            }
            if showDistractions {
              Text("Distractions")
                .font(.custom("Nunito-Regular", size: categoryLabelFontSize))
                .foregroundStyle(Color.black.opacity(0.9))
                .frame(
                  width: effectiveLabelWidth, height: distractionRowHeight, alignment: .trailing
                )
                .padding(.top, distractionRowSpacing - rowSpacing)
            }
          }
          .padding(.top, topInset)

          ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
              VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: rowSpacing) {
                  ForEach(Array(renderRows.enumerated()), id: \.element.id) { rowIndex, row in
                    HStack(spacing: columnSpacing) {
                      ForEach(0..<slotCount, id: \.self) { slotIndex in
                        let cellKey = "\(rowIndex)-\(slotIndex)"
                        Rectangle()
                          .foregroundStyle(.clear)
                          .background(fillColor(for: row, slotIndex: slotIndex))
                          .cornerRadius(cellCornerRadius)
                          .frame(width: cellSize, height: cellSize)
                          .onHover { hovering in
                            handleCellHover(hovering, cellKey: cellKey)
                          }
                          .anchorPreference(
                            key: DailyWorkflowHoverBoundsPreferenceKey.self,
                            value: .bounds
                          ) {
                            [.cell(cellKey): $0]
                          }
                      }
                    }
                    .frame(width: gridWidth, alignment: .leading)
                  }
                }

                if showDistractions {
                  let totalMinutes = timelineWindow.endMinute - timelineWindow.startMinute

                  ZStack(alignment: .topLeading) {
                    Rectangle()
                      .fill(Color(red: 0.95, green: 0.93, blue: 0.92))
                      .cornerRadius(distractionCornerRadius)
                      .frame(width: gridWidth, height: distractionRowHeight)

                    ForEach(distractionMarkers) { marker in
                      let startFraction =
                        (marker.startMinute - timelineWindow.startMinute) / totalMinutes
                      let endFraction =
                        (marker.endMinute - timelineWindow.startMinute) / totalMinutes
                      let leadingPad = CGFloat(startFraction) * gridWidth
                      let markerWidth = max(
                        3 * layoutScale, CGFloat(endFraction - startFraction) * gridWidth)

                      HStack(spacing: 0) {
                        Color.clear.frame(width: leadingPad, height: distractionRowHeight)
                        Rectangle()
                          .fill(Color(hex: "FF5950"))
                          .opacity(hoveredDistractionId == marker.id ? 1.0 : 0.85)
                          .cornerRadius(distractionCornerRadius)
                          .frame(width: markerWidth, height: distractionRowHeight)
                          .contentShape(Rectangle())
                          .onHover { hovering in
                            handleDistractionHover(hovering, markerID: marker.id)
                          }
                          .anchorPreference(
                            key: DailyWorkflowHoverBoundsPreferenceKey.self,
                            value: .bounds
                          ) {
                            [.distraction(marker.id): $0]
                          }
                        Spacer(minLength: 0)
                      }
                      .frame(width: gridWidth, height: distractionRowHeight)
                    }
                  }
                  .frame(width: gridWidth, height: distractionRowHeight)
                  .padding(.top, distractionRowSpacing)
                }
              }
              .frame(width: gridWidth, alignment: .leading)
              .padding(.top, topInset)

              VStack(alignment: .leading, spacing: axisLabelSpacing) {
                Rectangle()
                  .fill(Color(hex: "E0D9D5"))
                  .frame(width: axisWidth, height: max(0.7, 0.9 * layoutScale))

                if hourTicks.count > 1 {
                  let intervalCount = hourTicks.count - 1
                  let intervalWidth = axisWidth / CGFloat(intervalCount)
                  let labelWidth = max(22 * layoutScale, min(34 * layoutScale, intervalWidth * 1.4))

                  ZStack(alignment: .leading) {
                    ForEach(Array(hourTicks.enumerated()), id: \.offset) { index, hour in
                      let tickX = CGFloat(index) * intervalWidth
                      Text(formatAxisHourLabel(fromAbsoluteHour: hour))
                        .font(.custom("Nunito-Regular", size: axisLabelFontSize))
                        .kerning(-0.08 * layoutScale)
                        .foregroundStyle(Color.black.opacity(0.78))
                        .frame(
                          width: labelWidth,
                          alignment: axisLabelAlignment(
                            tickIndex: index,
                            tickCount: hourTicks.count
                          )
                        )
                        .offset(
                          x: axisLabelOffset(
                            tickIndex: index,
                            tickCount: hourTicks.count,
                            tickX: tickX,
                            axisWidth: axisWidth,
                            labelWidth: labelWidth
                          )
                        )
                    }
                  }
                  .frame(width: axisWidth, alignment: .leading)
                } else if let onlyTick = hourTicks.first {
                  Text(formatAxisHourLabel(fromAbsoluteHour: onlyTick))
                    .font(.custom("Nunito-Regular", size: axisLabelFontSize))
                    .kerning(-0.08 * layoutScale)
                    .foregroundStyle(Color.black.opacity(0.78))
                    .frame(width: axisWidth, alignment: .leading)
                }
              }
              .padding(.top, axisTopSpacing)
            }
            .frame(width: gridWidth, alignment: .leading)
          }
          .frame(width: gridViewportWidth, alignment: .leading)
        }
      }
      .padding(.leading, leftInset)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(
      height: contentHeight(
        for: renderRows.count, layoutScale: scale,
        includeDistractionRow: showDistractionRow && !distractionMarkers.isEmpty)
    )
  }

  private func contentHeight(
    for rowCount: Int, layoutScale: CGFloat, includeDistractionRow: Bool = false
  ) -> CGFloat {
    let rows = max(1, rowCount)
    let topInset: CGFloat = 25 * layoutScale
    let cell: CGFloat = 18 * layoutScale
    let gap: CGFloat = 2 * layoutScale
    let rowsHeight = (cell * CGFloat(rows)) + (gap * CGFloat(max(0, rows - 1)))
    let distractionHeight: CGFloat =
      includeDistractionRow ? (6 * layoutScale) + (10 * layoutScale) : 0
    let axisTopSpacing: CGFloat = 10 * layoutScale
    let axisLineHeight: CGFloat = max(0.7, 0.9 * layoutScale)
    let axisLabelSpacing: CGFloat = 5 * layoutScale
    let axisLabelHeight: CGFloat = 14 * layoutScale
    let bottomBuffer: CGFloat = 6 * layoutScale
    return topInset + rowsHeight + distractionHeight + axisTopSpacing + axisLineHeight
      + axisLabelSpacing + axisLabelHeight + bottomBuffer
  }

  private func fillColor(for row: DailyWorkflowGridRow, slotIndex: Int) -> Color {
    guard slotIndex < row.slotOccupancies.count else {
      return Color(red: 0.95, green: 0.93, blue: 0.92)
    }
    let occupancy = min(max(row.slotOccupancies[slotIndex], 0), 1)
    guard occupancy > 0 else { return Color(red: 0.95, green: 0.93, blue: 0.92) }

    // Partial occupancy stays dimmer; full occupancy reaches full intensity.
    let alpha = 0.3 + (occupancy * 0.7)
    return Color(hex: row.colorHex).opacity(alpha)
  }

  private func axisLabelAlignment(tickIndex: Int, tickCount: Int) -> Alignment {
    if tickIndex == tickCount - 1 { return .trailing }
    return .leading
  }

  private func axisLabelOffset(
    tickIndex: Int,
    tickCount: Int,
    tickX: CGFloat,
    axisWidth: CGFloat,
    labelWidth: CGFloat
  ) -> CGFloat {
    if tickIndex == tickCount - 1 { return max(0, axisWidth - labelWidth) }
    return min(max(0, tickX), max(0, axisWidth - labelWidth))
  }

  private func labelColumnWidth(for rows: [DailyWorkflowGridRow], layoutScale: CGFloat) -> CGFloat {
    gridLabelColumnWidth(for: rows, layoutScale: layoutScale)
  }

  private func handleCellHover(_ hovering: Bool, cellKey: String) {
    if hovering {
      cancelPendingHoverClear()
      hoveredCellKey = cellKey
      hoveredDistractionId = nil
      return
    }

    scheduleHoverClear(cellKey: cellKey)
  }

  private func handleDistractionHover(_ hovering: Bool, markerID: String) {
    if hovering {
      cancelPendingHoverClear()
      hoveredDistractionId = markerID
      hoveredCellKey = nil
      return
    }

    scheduleHoverClear(distractionID: markerID)
  }

  private func scheduleHoverClear(cellKey: String? = nil, distractionID: String? = nil) {
    cancelPendingHoverClear()

    if hoverExitDelayNanoseconds == 0 {
      if let cellKey, hoveredCellKey == cellKey {
        hoveredCellKey = nil
      }
      if let distractionID, hoveredDistractionId == distractionID {
        hoveredDistractionId = nil
      }
      return
    }

    hoverClearTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: hoverExitDelayNanoseconds)
      guard !Task.isCancelled else { return }

      if let cellKey, hoveredCellKey == cellKey {
        hoveredCellKey = nil
      }
      if let distractionID, hoveredDistractionId == distractionID {
        hoveredDistractionId = nil
      }

      hoverClearTask = nil
    }
  }

  private func cancelPendingHoverClear() {
    hoverClearTask?.cancel()
    hoverClearTask = nil
  }

}

// MARK: - Shared tooltip builders and grid helpers

enum DailyWorkflowHoverTargetID: Hashable {
  case cell(String)
  case distraction(String)
}

struct DailyWorkflowHoverBoundsPreferenceKey: PreferenceKey {
  static var defaultValue: [DailyWorkflowHoverTargetID: Anchor<CGRect>] = [:]

  static func reduce(
    value: inout [DailyWorkflowHoverTargetID: Anchor<CGRect>],
    nextValue: () -> [DailyWorkflowHoverTargetID: Anchor<CGRect>]
  ) {
    value.merge(nextValue(), uniquingKeysWith: { $1 })
  }
}

func gridLabelColumnWidth(
  for rows: [DailyWorkflowGridRow], layoutScale: CGFloat
) -> CGFloat {
  let fontSize = 12 * layoutScale
  let font =
    NSFont(name: "Nunito-Regular", size: fontSize)
    ?? NSFont.systemFont(ofSize: fontSize, weight: .regular)
  let measuredMax = rows.reduce(CGFloat.zero) { currentMax, row in
    let width = (row.name as NSString).size(withAttributes: [.font: font]).width
    return max(currentMax, width)
  }
  return ceil(measuredMax + 1)
}

func workflowTooltip(
  durationMinutes: Double,
  title: String,
  accentColor: Color,
  layoutScale: CGFloat
) -> some View {
  VStack(alignment: .leading, spacing: 4 * layoutScale) {
    Text(formatDurationValue(durationMinutes))
      .font(.custom("Nunito-SemiBold", size: 12 * layoutScale))
      .foregroundStyle(accentColor)
    Text(title)
      .font(.custom("Nunito-Regular", size: 12 * layoutScale))
      .foregroundStyle(Color.black)
      .fixedSize(horizontal: false, vertical: true)
  }
  .padding(8 * layoutScale)
  .frame(width: 200 * layoutScale, alignment: .leading)
  .background(tooltipBackground(layoutScale: layoutScale))
  .allowsHitTesting(false)
}

func tooltipBackground(layoutScale: CGFloat) -> some View {
  RoundedRectangle(cornerRadius: 4, style: .continuous)
    .fill(Color.white)
    .overlay(
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .stroke(Color(hex: "EDE0CE"), lineWidth: 1)
    )
    .shadow(
      color: Color(red: 1, green: 0.63, blue: 0.54).opacity(0.25), radius: 2, x: 0, y: 2)
}

struct DailyStatChip: View {
  let title: String
  let value: String
  let scale: CGFloat

  var body: some View {
    HStack(spacing: 4) {
      Text(title)
        .font(.custom("Nunito-Regular", size: 10 * scale))
        .foregroundStyle(Color(hex: "5D5651"))
      Text(value)
        .font(.custom("Nunito-SemiBold", size: 10 * scale))
        .foregroundStyle(Color(hex: "D77A43"))
    }
    .padding(.horizontal, 12 * scale)
    .padding(.vertical, 6 * scale)
    .background(
      Capsule(style: .continuous)
        .fill(Color(hex: "F7F3F0"))
    )
    .overlay(
      Capsule(style: .continuous)
        .stroke(Color(hex: "DDD6CF"), lineWidth: max(0.6, 0.8 * scale))
    )
  }
}

struct DailyModeToggle: View {
  enum ActiveMode {
    case highlights
    case details
  }

  let activeMode: ActiveMode
  let scale: CGFloat

  private var cornerRadius: CGFloat { 8 * scale }
  private var borderWidth: CGFloat { max(0.7, 1 * scale) }
  private var borderColor: Color { Color(hex: "C7C2C0") }

  var body: some View {
    HStack(spacing: 0) {
      segment(
        text: "Highlights",
        isActive: activeMode == .highlights,
        isLeading: true
      )
      segment(
        text: "Details",
        isActive: activeMode == .details,
        isLeading: false
      )
    }
    .overlay(
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .stroke(borderColor, lineWidth: borderWidth)
    )
  }

  @ViewBuilder
  private func segment(text: String, isActive: Bool, isLeading: Bool) -> some View {
    let fill = isActive ? Color(hex: "FFA767") : Color(hex: "FFFAF7").opacity(0.6)

    Text(text)
      .font(.custom("Nunito-Regular", size: 14 * scale))
      .lineLimit(1)
      .foregroundStyle(isActive ? Color.white : Color(hex: "837870"))
      .padding(.horizontal, 12 * scale)
      .padding(.vertical, 8 * scale)
      .frame(minHeight: 33 * scale)
      .background(
        UnevenRoundedRectangle(
          cornerRadii: .init(
            topLeading: isLeading ? cornerRadius : 0,
            bottomLeading: isLeading ? cornerRadius : 0,
            bottomTrailing: isLeading ? 0 : cornerRadius,
            topTrailing: isLeading ? 0 : cornerRadius
          ),
          style: .continuous
        )
        .fill(fill)
      )
      .overlay(alignment: .trailing) {
        if isLeading {
          Rectangle()
            .fill(borderColor)
            .frame(width: borderWidth)
        }
      }
  }
}
