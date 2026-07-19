//
//  ProviderStatsView.swift
//  Dayflow
//
//  Dashboard surface that visualises which Dayflow provider + model produced
//  which activity cards, in the same GitHub-contribution-graph style the user
//  asked for. Read-only — all state is loaded on appear from
//  `StorageManager` and re-computed when the underlying `TimelineCard` list
//  changes.
//

import SwiftUI

@MainActor
final class ProviderStatsViewModel: ObservableObject {
  @Published private(set) var summary: ProviderStatsSummary = .empty
  @Published private(set) var isLoading: Bool = false

  func reload() {
    isLoading = true
    Task.detached(priority: .userInitiated) {
      let cards = await StorageManager.shared.fetchAllTimelineCards()
      let s = ProviderStatsCalculator.summary(from: cards)
      await MainActor.run {
        self.summary = s
        self.isLoading = false
      }
    }
  }
}

extension ProviderStatsSummary {
  static let empty = ProviderStatsSummary(
    totalCards: 0,
    byProvider: [:],
    byModel: [],
    daily: [],
    weekly: [],
    monthly: [],
    earliest: nil,
    latest: nil,
    heatmapDays: [],
    peakDay: nil
  )
}

struct ProviderStatsView: View {
  @StateObject private var viewModel = ProviderStatsViewModel()
  @State private var selectedRange: TimeRange = .year

  enum TimeRange: String, CaseIterable, Identifiable {
    case week = "Week"
    case month = "Month"
    case quarter = "Quarter"
    case year = "Year"
    var id: String { rawValue }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        header
        summaryStats
        providerBreakdown
        modelBreakdown
        heatmapSection
        timeSeriesSection
      }
      .padding(20)
    }
    .background(Color(NSColor.windowBackgroundColor))
    .onAppear { viewModel.reload() }
  }

  // MARK: - Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Usage statistics")
          .font(.custom("Figtree", size: 22))
          .fontWeight(.semibold)
        Spacer()
        if viewModel.isLoading {
          ProgressView().scaleEffect(0.6)
        } else {
          Button {
            viewModel.reload()
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .buttonStyle(.borderless)
          .help("Recompute statistics from local storage")
        }
      }
      Text(
        viewModel.summary.totalCards == 0
          ? "No activity cards yet. Once Dayflow processes a recording, you'll see your provider and model usage here."
          : "Tracks which Dayflow provider and model produced each activity card. All data stays on your Mac."
      )
      .font(.custom("Figtree", size: 12))
      .foregroundColor(.secondary)
    }
  }

  // MARK: - Summary cards

  private var summaryStats: some View {
    let s = viewModel.summary
    return HStack(spacing: 12) {
      statTile(
        title: "Total cards",
        value: "\(s.totalCards)",
        icon: "rectangle.stack"
      )
      statTile(
        title: "Active providers",
        value: "\(s.byProvider.values.filter { $0 > 0 }.count)",
        icon: "cpu"
      )
      statTile(
        title: "Peak day",
        value: s.peakDay.map { "\($0.count) on " + dateLabel($0.date) } ?? "—",
        icon: "flame"
      )
      statTile(
        title: "Tracking from",
        value: s.earliest.map { dateLabel($0) } ?? "—",
        icon: "calendar"
      )
    }
  }

  private func statTile(title: String, value: String, icon: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: icon)
        .font(.custom("Figtree", size: 11))
        .foregroundColor(.secondary)
      Text(value)
        .font(.custom("Figtree", size: 18).weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color(NSColor.controlBackgroundColor))
    )
  }

  // MARK: - Provider breakdown

  private var providerBreakdown: some View {
    let s = viewModel.summary
    let total = max(1, s.totalCards)
    let entries = ProviderStatsCalculator.knownProviders.compactMap { id -> (String, Int)? in
      let count = s.byProvider[id] ?? 0
      return count > 0 ? (displayName(for: id), count) : nil
    }
    let maxValue = max(1, entries.map(\.1).max() ?? 1)
    return sectionCard(title: "Provider breakdown", subtitle: "Cards produced by each provider") {
      if entries.isEmpty {
        Text("No provider activity yet.")
          .font(.custom("Figtree", size: 12))
          .foregroundColor(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(0..<entries.count, id: \.self) { i in
            providerBar(
              entry: entries[i],
              total: total,
              maxValue: maxValue
            )
          }
        }
      }
    }
  }

  // MARK: - Model breakdown

  private var modelBreakdown: some View {
    let entries = viewModel.summary.byModel
    return sectionCard(
      title: "Model breakdown",
      subtitle: "Per-(provider · model) usage"
    ) {
      if entries.isEmpty {
        Text("No model-level data yet — older cards don't carry the model id.")
          .font(.custom("Figtree", size: 12))
          .foregroundColor(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            HStack(spacing: 8) {
              Circle()
                .fill(colorFor(providerID: entry.providerID))
                .frame(width: 8, height: 8)
              Text(displayName(for: entry.providerID))
                .font(.custom("Figtree", size: 11))
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
              Text(entry.modelID)
                .font(.custom("Figtree", size: 12).monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
              Spacer()
              Text("\(entry.count) cards")
                .font(.custom("Figtree", size: 12))
                .foregroundColor(.secondary)
            }
          }
        }
      }
    }
  }

  // MARK: - Heatmap

  private var heatmapSection: some View {
    sectionCard(
      title: "Activity heatmap",
      subtitle: "GitHub-style: each cell is one day, brighter = more cards produced."
    ) {
      HeatmapView(days: viewModel.summary.heatmapDays)
    }
  }

  // MARK: - Time series

  private var timeSeriesSection: some View {
    let s = viewModel.summary
    return sectionCard(
      title: "Timeline",
      subtitle: "Card counts per week and per month"
    ) {
      VStack(alignment: .leading, spacing: 16) {
        Picker("Range", selection: $selectedRange) {
          ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 280)

        switch selectedRange {
        case .week:
          timeSeriesBarChart(
            entries: Array(s.daily.suffix(7).map { ($0.date, $0.count) }),
            color: .blue
          )
        case .month:
          timeSeriesBarChart(
            entries: Array(s.daily.suffix(30).map { ($0.date, $0.count) }),
            color: .purple
          )
        case .quarter:
          timeSeriesBarChart(
            entries: s.weekly.suffix(13).map { ($0.weekStart, $0.count) },
            color: .orange
          )
        case .year:
          timeSeriesBarChart(
            entries: s.monthly.map { ($0.monthStart, $0.count) },
            color: .green
          )
        }
      }
    }
  }

  @ViewBuilder
  private func timeSeriesBarChart(entries: [(Date, Int)], color: Color) -> some View {
    let maxValue = max(1, entries.map(\.1).max() ?? 1)
    if entries.isEmpty {
      Text("No data for this range yet.")
        .font(.custom("Figtree", size: 12))
        .foregroundColor(.secondary)
    } else {
      HStack(alignment: .bottom, spacing: 2) {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
          VStack(spacing: 4) {
            Text("\(entry.1)")
              .font(.custom("Figtree", size: 8))
              .foregroundColor(.secondary)
            Rectangle()
              .fill(color.opacity(0.6 + 0.4 * Double(entry.1) / Double(maxValue)))
              .frame(height: max(2, CGFloat(entry.1) / CGFloat(maxValue) * 60))
            Text(dateLabel(entry.0, short: true))
              .font(.custom("Figtree", size: 8))
              .foregroundColor(.secondary)
          }
          .frame(maxWidth: .infinity)
        }
      }
      .frame(height: 110)
    }
  }

  // MARK: - Helpers

  private func sectionCard<Content: View>(
    title: String, subtitle: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.custom("Figtree", size: 14).weight(.semibold))
        Text(subtitle)
          .font(.custom("Figtree", size: 11))
          .foregroundColor(.secondary)
      }
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(Color(NSColor.controlBackgroundColor))
    )
  }

  @ViewBuilder
  private func providerBar(entry: (String, Int), total: Int, maxValue: Int) -> some View {
    HStack(spacing: 8) {
      Text(entry.0)
        .frame(width: 110, alignment: .leading)
        .font(.custom("Figtree", size: 12))
      GeometryReader { proxy in
        let width = proxy.size.width * CGFloat(entry.1) / CGFloat(maxValue)
        RoundedRectangle(cornerRadius: 3)
          .fill(colorFor(providerID: entry.0))
          .frame(width: max(4, width), height: 14)
      }
      .frame(height: 14)
      Text("\(entry.1)")
        .font(.custom("Figtree", size: 12).monospacedDigit())
        .foregroundColor(.secondary)
        .frame(width: 40, alignment: .trailing)
      Text("\(Int(round(Double(entry.1) / Double(total) * 100)))%")
        .font(.custom("Figtree", size: 10))
        .foregroundColor(SettingsStyle.meta)
        .frame(width: 40, alignment: .trailing)
    }
  }

  private func displayName(for providerID: String) -> String {
    switch providerID {
    case "gemini": return "Gemini"
    case "minimax": return "MiniMax"
    case "ollama": return "Local AI"
    case "chatgpt_claude": return "ChatGPT / Claude"
    case "dayflow": return "Dayflow Pro"
    default: return providerID
    }
  }

  private func colorFor(providerID: String) -> Color {
    switch providerID {
    case "gemini": return .blue
    case "minimax": return .purple
    case "ollama": return .green
    case "chatgpt_claude": return .orange
    case "dayflow": return .pink
    default: return .gray
    }
  }

  private func dateLabel(_ d: Date, short: Bool = false) -> String {
    let f = DateFormatter()
    f.dateFormat = short ? "MMM d" : "MMM d, yyyy"
    return f.string(from: d)
  }
}

// MARK: - Heatmap view

struct HeatmapView: View {
  let days: [HeatmapDay]

  private static let cellSize: CGFloat = 11
  private static let cellSpacing: CGFloat = 2

  /// Group `days` into calendar weeks, anchored to the most recent Sunday.
  private var grid: [[HeatmapDay?]] {
    guard !days.isEmpty else { return [] }
    let calendar = Calendar.current
    let firstDay = days.first?.date ?? Date()
    let lastDay = days.last?.date ?? Date()
    let weekdayOfLast = calendar.component(.weekday, from: lastDay)
    let trailingPad = (7 - weekdayOfLast) % 7

    // Map date -> HeatmapDay for quick lookup
    var byDate: [Date: HeatmapDay] = [:]
    for d in days { byDate[calendar.startOfDay(for: d.date)] = d }

    var weeks: [[HeatmapDay?]] = []
    var current = Array<HeatmapDay?>(repeating: nil, count: 7)
    var cursor = calendar.startOfDay(for: firstDay)
    let endDay = calendar.date(byAdding: .day, value: trailingPad, to: lastDay) ?? lastDay
    while cursor <= endDay {
      let weekday = calendar.component(.weekday, from: cursor)  // 1...7 (Sun...Sat)
      current[weekday - 1] = byDate[cursor]
      if weekday == 7 {
        weeks.append(current)
        current = Array<HeatmapDay?>(repeating: nil, count: 7)
      }
      cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86400)
    }
    if current.contains(where: { $0 != nil }) {
      weeks.append(current)
    }
    return weeks
  }

  private let monthFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMM"
    return f
  }()

  var body: some View {
    if days.isEmpty {
      Text("No activity in the last year yet.")
        .font(.custom("Figtree", size: 12))
        .foregroundColor(.secondary)
    } else {
      ScrollView(.horizontal, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .top, spacing: 2) {
            Color.clear.frame(width: 22)
            ForEach(Array(grid.enumerated()), id: \.offset) { weekIndex, week in
              let firstDate = week.compactMap { $0?.date }.first
              if let firstDate, weekIndex == 0 || calendar.component(.weekday, from: firstDate) == 1
              {
                Text(monthFormatter.string(from: firstDate))
                  .font(.custom("Figtree", size: 9))
                  .foregroundColor(.secondary)
                  .frame(width: Self.cellSize + Self.cellSpacing, alignment: .leading)
              } else {
                Color.clear.frame(width: Self.cellSize + Self.cellSpacing, height: 10)
              }
            }
          }
          HStack(alignment: .top, spacing: 2) {
            VStack(alignment: .leading, spacing: 0) {
              Text("M")
              Text("W")
              Text("F")
            }
            .font(.custom("Figtree", size: 8))
            .foregroundColor(.secondary)
            .frame(width: 22, alignment: .leading)
            ForEach(Array(grid.enumerated()), id: \.offset) { _, week in
              VStack(spacing: Self.cellSpacing) {
                ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                  Rectangle()
                    .fill(colorFor(intensity: day?.intensity ?? 0))
                    .frame(width: Self.cellSize, height: Self.cellSize)
                    .overlay(
                      RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.black.opacity(0.06), lineWidth: 0.5)
                    )
                    .help(heatmapTooltip(for: day))
                }
              }
            }
          }
          HStack(spacing: 6) {
            Text("Less")
              .font(.custom("Figtree", size: 9))
              .foregroundColor(.secondary)
            ForEach(0..<5) { i in
              Rectangle()
                .fill(colorFor(intensity: Double(i) / 4.0))
                .frame(width: Self.cellSize, height: Self.cellSize)
            }
            Text("More")
              .font(.custom("Figtree", size: 9))
              .foregroundColor(.secondary)
          }
          .padding(.top, 6)
        }
      }
    }
  }

  private let calendar = Calendar.current

  private func colorFor(intensity: Double) -> Color {
    switch intensity {
    case 0: return Color(NSColor.controlBackgroundColor).opacity(0.5)
    case 0..<0.25: return Color.green.opacity(0.25)
    case 0.25..<0.5: return Color.green.opacity(0.45)
    case 0.5..<0.75: return Color.green.opacity(0.65)
    default: return Color.green.opacity(0.85)
    }
  }

  private func heatmapTooltip(for day: HeatmapDay?) -> String {
    guard let day else { return "" }
    let f = DateFormatter()
    f.dateStyle = .medium
    return "\(f.string(from: day.date)): \(day.count) card\(day.count == 1 ? "" : "s")"
  }
}
