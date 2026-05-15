import SwiftUI

struct WeeklyWorkflowSection: View {
  let snapshot: WeeklyWorkflowSnapshot
  let width: CGFloat

  init(snapshot: WeeklyWorkflowSnapshot, width: CGFloat = Design.sectionWidth) {
    self.snapshot = snapshot
    self.width = width
  }

  private enum Design {
    static let sectionWidth: CGFloat = 958
    static let cornerRadius: CGFloat = 4
    static let borderColor = Color(hex: "E8E1DA")
    static let backgroundColor = Color.white.opacity(0.78)
    static let dividerColor = Color(hex: "E5DFD9")
    static let titleColor = Color(hex: "B46531")
    static let textColor = Color.black.opacity(0.9)
    static let mutedTextColor = Color(hex: "7F7062")
    static let totalTitleColor = Color(hex: "777777")
    static let totalNameColor = Color(hex: "1F1B18")
    static let emptyCellColor = Color(red: 0.95, green: 0.93, blue: 0.92)
    static let axisColor = Color(hex: "E0D9D5")

    static let titleSpacing: CGFloat = 8
    static let gridPadding = EdgeInsets(top: 25, leading: 36, bottom: 6, trailing: 52)
    static let footerPadding = EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16)
    static let labelWidth: CGFloat = 30
    static let labelToGridSpacing: CGFloat = 13
    static let cellWidth: CGFloat = 13
    static let cellHeight: CGFloat = 13
    static let cellGap: CGFloat = 2
    static let cellCornerRadius: CGFloat = 2.5
    static let axisTopSpacing: CGFloat = 10
    static let axisLabelSpacing: CGFloat = 5
    static let axisLabelHeight: CGFloat = 14
    static let axisLabelWidth: CGFloat = 34
  }

  private var columnCount: Int {
    snapshot.rows.map { $0.cells.count }.max() ?? 0
  }

  private var gridWidth: CGFloat {
    guard columnCount > 0 else { return 0 }

    return (CGFloat(columnCount) * cellWidth)
      + (CGFloat(columnCount - 1) * Design.cellGap)
  }

  private var cellWidth: CGFloat {
    Design.cellWidth
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Design.titleSpacing) {
      Text(snapshot.title)
        .font(.custom("InstrumentSerif-Regular", size: 24))
        .foregroundStyle(Design.titleColor)

      VStack(spacing: 0) {
        gridPanel

        Divider()
          .overlay(Design.dividerColor)

        footerPanel
      }
      .background(
        RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
          .fill(Design.backgroundColor)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
          .stroke(Design.borderColor, lineWidth: 1)
          .allowsHitTesting(false)
      )
    }
    .frame(width: width, alignment: .leading)
  }

  private var gridPanel: some View {
    HStack(alignment: .top, spacing: Design.labelToGridSpacing) {
      dayLabels
      gridAndAxis
    }
    .padding(Design.gridPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var dayLabels: some View {
    VStack(alignment: .trailing, spacing: Design.cellGap) {
      ForEach(snapshot.rows) { row in
        Text(row.label)
          .font(.custom("Figtree-Regular", size: 11))
          .foregroundStyle(Design.textColor)
          .frame(width: Design.labelWidth, height: Design.cellHeight, alignment: .trailing)
      }
    }
  }

  private var gridAndAxis: some View {
    VStack(alignment: .leading, spacing: Design.axisTopSpacing) {
      VStack(alignment: .leading, spacing: Design.cellGap) {
        ForEach(snapshot.rows) { row in
          HStack(spacing: Design.cellGap) {
            ForEach(Array(row.cells.enumerated()), id: \.element.id) { index, cell in
              RoundedRectangle(cornerRadius: Design.cellCornerRadius, style: .continuous)
                .fill(cellFill(for: cell))
                .frame(width: cellWidth, height: Design.cellHeight)
                .help(cellHelp(row: row, cell: cell, slotIndex: index))
            }
          }
        }
      }
      .frame(width: gridWidth, alignment: .leading)

      VStack(alignment: .leading, spacing: Design.axisLabelSpacing) {
        Rectangle()
          .fill(Design.axisColor)
          .frame(width: gridWidth, height: 0.9)

        ZStack(alignment: .leading) {
          ForEach(snapshot.timeLabels) { label in
            Text(label.label)
              .font(.custom("Figtree-Regular", size: 10))
              .foregroundStyle(Color.black.opacity(0.78))
              .frame(width: Design.axisLabelWidth, alignment: axisAlignment(for: label))
              .offset(x: axisOffset(for: label))
          }
        }
        .frame(width: gridWidth, height: Design.axisLabelHeight, alignment: .leading)
      }
    }
  }

  private var footerPanel: some View {
    HStack(spacing: 8) {
      if snapshot.totals.isEmpty {
        Text(
          "Week total  No captured activity during \(clockText(snapshot.startMinute))-\(clockText(snapshot.endMinute))"
        )
        .font(.custom("Figtree-Regular", size: 12))
        .foregroundStyle(Design.mutedTextColor)
      } else {
        Text("Week total")
          .font(.custom("InstrumentSerif-Regular", size: 14))
          .foregroundStyle(Design.totalTitleColor)

        ForEach(snapshot.totals) { total in
          totalItem(total)
        }
      }
    }
    .padding(Design.footerPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .lineLimit(1)
    .minimumScaleFactor(0.7)
  }

  private func totalItem(_ total: WeeklyWorkflowTotalItem) -> some View {
    HStack(spacing: 2) {
      Text(total.name)
        .font(.custom("Figtree-Regular", size: 12))
        .foregroundStyle(Design.totalNameColor)

      Text(total.duration)
        .font(.custom("Figtree-SemiBold", size: 12))
        .foregroundStyle(Color(hex: total.colorHex))
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private func cellFill(for cell: WeeklyWorkflowCell) -> Color {
    guard let colorHex = cell.colorHex, cell.occupancy > 0 else {
      return Design.emptyCellColor
    }

    let occupancy = min(max(cell.occupancy, 0), 1)
    let alpha = 0.3 + (occupancy * 0.7)
    return Color(hex: colorHex).opacity(alpha)
  }

  private func axisOffset(for label: WeeklyWorkflowTimeLabel) -> CGFloat {
    guard snapshot.endMinute > snapshot.startMinute else { return 0 }

    let progress = CGFloat(
      (label.minute - snapshot.startMinute) / (snapshot.endMinute - snapshot.startMinute))
    let rawOffset = (progress * gridWidth) - (Design.axisLabelWidth / 2)

    if label.minute <= snapshot.startMinute {
      return 0
    }
    if label.minute >= snapshot.endMinute {
      return max(0, gridWidth - Design.axisLabelWidth)
    }
    return min(max(0, rawOffset), max(0, gridWidth - Design.axisLabelWidth))
  }

  private func axisAlignment(for label: WeeklyWorkflowTimeLabel) -> Alignment {
    if label.minute <= snapshot.startMinute {
      return .leading
    }
    if label.minute >= snapshot.endMinute {
      return .trailing
    }
    return .center
  }

  private func cellHelp(
    row: WeeklyWorkflowRow,
    cell: WeeklyWorkflowCell,
    slotIndex: Int
  ) -> String {
    guard let categoryName = cell.categoryName, cell.minutes > 0 else {
      return "\(row.label) \(slotRangeText(slotIndex)): No activity"
    }
    return
      "\(row.label) \(slotRangeText(slotIndex)): \(categoryName), \(durationText(cell.minutes))"
  }

  private func slotRangeText(_ slotIndex: Int) -> String {
    let start = snapshot.startMinute + (Double(slotIndex) * snapshot.slotMinutes)
    let end = min(snapshot.endMinute, start + snapshot.slotMinutes)
    return "\(clockText(start))-\(clockText(end))"
  }

  private func clockText(_ minute: Double) -> String {
    let totalMinutes = Int(minute)
    let hour24 = (totalMinutes / 60) % 24
    let minutePart = totalMinutes % 60
    let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
    let suffix = hour24 < 12 ? "am" : "pm"

    if minutePart == 0 {
      return "\(hour12)\(suffix)"
    }
    return String(format: "%d:%02d%@", hour12, minutePart, suffix)
  }

  private func durationText(_ minutes: Int) -> String {
    let hours = minutes / 60
    let remainingMinutes = minutes % 60

    if hours > 0, remainingMinutes > 0 {
      return "\(hours)h \(remainingMinutes)m"
    }
    if hours > 0 {
      return "\(hours)h"
    }
    return "\(remainingMinutes)m"
  }
}

extension WeeklyWorkflowSnapshot {
  static let figmaPreview = WeeklyWorkflowSnapshot(
    title: "Your workflow this week",
    startMinute: 9.0 * 60.0,
    endMinute: 22.0 * 60.0,
    slotMinutes: 15,
    timeLabels: [
      .init(id: "9", label: "9am", minute: 9.0 * 60.0),
      .init(id: "10", label: "10am", minute: 10.0 * 60.0),
      .init(id: "11", label: "11am", minute: 11.0 * 60.0),
      .init(id: "12", label: "12pm", minute: 12.0 * 60.0),
      .init(id: "13", label: "1pm", minute: 13.0 * 60.0),
      .init(id: "14", label: "2pm", minute: 14.0 * 60.0),
      .init(id: "15", label: "3pm", minute: 15.0 * 60.0),
      .init(id: "16", label: "4pm", minute: 16.0 * 60.0),
      .init(id: "17", label: "5pm", minute: 17.0 * 60.0),
      .init(id: "18", label: "6pm", minute: 18.0 * 60.0),
      .init(id: "19", label: "7pm", minute: 19.0 * 60.0),
      .init(id: "20", label: "8pm", minute: 20.0 * 60.0),
      .init(id: "21", label: "9pm", minute: 21.0 * 60.0),
      .init(id: "22", label: "10pm", minute: 22.0 * 60.0),
    ],
    rows: WeeklyWorkflowRow.previewRows,
    totals: [
      .init(id: "coding", name: "Coding", minutes: 704, duration: "11h 44m", colorHex: "6C8CFF"),
      .init(
        id: "communication", name: "Communication", minutes: 436, duration: "7h 16m",
        colorHex: "FFA189"),
      .init(id: "idle", name: "Idle", minutes: 388, duration: "6h 28m", colorHex: "A8B2C2"),
      .init(id: "research", name: "Research", minutes: 272, duration: "4h 32m", colorHex: "B984FF"),
      .init(
        id: "distraction", name: "Distraction", minutes: 165, duration: "2h 45m",
        colorHex: "FF5950"),
    ]
  )
}

extension WeeklyWorkflowRow {
  static let previewRows: [WeeklyWorkflowRow] = [
    .preview(
      id: "mon", label: "Mon",
      runs: [
        .init(0..<8, "F2EFED", 0),
        .init(8..<17, "FFA189", 0.85),
        .init(19..<29, "6C8CFF", 0.72),
        .init(30..<38, "A8B2C2", 0.6),
        .init(39..<48, "B984FF", 0.68),
      ]),
    .preview(
      id: "tue", label: "Tue",
      runs: [
        .init(5..<15, "6C8CFF", 0.76),
        .init(15..<22, "FFA189", 0.66),
        .init(26..<38, "B984FF", 0.74),
        .init(39..<47, "6C8CFF", 0.88),
      ]),
    .preview(
      id: "wed", label: "Wed",
      runs: [
        .init(2..<10, "A8B2C2", 0.5),
        .init(12..<24, "6C8CFF", 0.8),
        .init(27..<34, "7EE6F2", 0.62),
        .init(36..<45, "FF5950", 0.72),
      ]),
    .preview(
      id: "thu", label: "Thur",
      runs: [
        .init(6..<18, "B984FF", 0.74),
        .init(20..<30, "FFA189", 0.7),
        .init(31..<42, "6C8CFF", 0.84),
        .init(44..<50, "A8B2C2", 0.48),
      ]),
    .preview(
      id: "fri", label: "Fri",
      runs: [
        .init(4..<15, "6C8CFF", 0.82),
        .init(16..<25, "FFA189", 0.6),
        .init(27..<36, "FF5950", 0.7),
        .init(38..<45, "B984FF", 0.64),
      ]),
    .preview(
      id: "sat", label: "Sat",
      runs: [
        .init(13..<20, "7EE6F2", 0.55),
        .init(25..<30, "B984FF", 0.42),
      ]),
    .preview(
      id: "sun", label: "Sun",
      runs: [
        .init(16..<24, "A8B2C2", 0.46),
        .init(30..<36, "7EE6F2", 0.5),
      ]),
  ]

  private static func preview(
    id: String,
    label: String,
    runs: [WeeklyWorkflowPreviewRun]
  ) -> WeeklyWorkflowRow {
    var cells = (0..<52).map {
      WeeklyWorkflowCell(
        id: "slot-\($0)",
        categoryName: nil,
        colorHex: nil,
        minutes: 0,
        occupancy: 0
      )
    }

    for run in runs {
      for index in run.range where cells.indices.contains(index) {
        cells[index] = WeeklyWorkflowCell(
          id: "slot-\(index)",
          categoryName: "Preview",
          colorHex: run.colorHex,
          minutes: 15,
          occupancy: run.occupancy
        )
      }
    }

    return WeeklyWorkflowRow(id: id, label: label, cells: cells)
  }
}

private struct WeeklyWorkflowPreviewRun {
  let range: Range<Int>
  let colorHex: String
  let occupancy: Double

  init(_ range: Range<Int>, _ colorHex: String, _ occupancy: Double) {
    self.range = range
    self.colorHex = colorHex
    self.occupancy = occupancy
  }
}

#Preview("Weekly Workflow Section", traits: .fixedLayout(width: 958, height: 292)) {
  WeeklyWorkflowSection(snapshot: .figmaPreview)
    .padding(24)
    .background(Color(hex: "F7F3F0"))
}
