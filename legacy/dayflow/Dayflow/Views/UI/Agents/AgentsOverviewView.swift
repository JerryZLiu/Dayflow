//
//  AgentsOverviewView.swift
//  Dayflow
//
//  Stage 1 of the Agents flow: "Today, July 6" — one soft blob per
//  workstream carrying live status chips, plus a totals legend and the
//  user-initiated generate/refresh control.
//

import SwiftUI

struct AgentsOverviewView: View {
  let recap: AgentsDayRecap
  let isRefreshing: Bool
  let refreshError: String?
  /// Nearest days with a recap on disk, for the ‹ › toggles (nil disables).
  let previousDay: String?
  let nextDay: String?
  let onSelectDay: (String) -> Void
  let onRefresh: () -> Void
  let onSelectWorkstream: (Int) -> Void
  let onStartReview: () -> Void

  // Loose scatter echoing the Figma layout; fractions of the available area.
  private static let blobAnchors: [CGPoint] = [
    CGPoint(x: 0.30, y: 0.30),
    CGPoint(x: 0.62, y: 0.22),
    CGPoint(x: 0.82, y: 0.44),
    CGPoint(x: 0.30, y: 0.68),
    CGPoint(x: 0.58, y: 0.72),
    CGPoint(x: 0.82, y: 0.80),
    CGPoint(x: 0.14, y: 0.50),
  ]

  var body: some View {
    ZStack(alignment: .topLeading) {
      GeometryReader { geo in
        ForEach(Array(recap.workstreams.enumerated()), id: \.element.id) { index, workstream in
          blob(for: workstream, index: index)
            .position(blobPosition(index: index, in: geo.size))
        }
      }
      .padding(.top, 70)
      .padding(.bottom, 60)

      header
        .padding(.top, 28)
        .padding(.horizontal, 32)

      legend
        .padding(.top, 92)
        .padding(.leading, 32)
    }
    .overlay(alignment: .bottom) {
      startReviewButton
        .padding(.bottom, 26)
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .top) {
      HStack(spacing: 10) {
        dayToggle(systemName: "chevron.left", day: previousDay)
        Text(dayHeading)
          .font(.custom("InstrumentSerif-Regular", size: 32))
          .foregroundColor(.black.opacity(0.85))
        dayToggle(systemName: "chevron.right", day: nextDay)
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 5) {
        refreshButton
        if refreshError != nil {
          Text("Last refresh failed — try again")
            .font(.custom("Figtree", size: 11))
            .foregroundColor(Color(hex: "C04A00"))
        } else if let generatedText = generatedAtText {
          Text(generatedText)
            .font(.custom("Figtree", size: 11))
            .foregroundColor(.black.opacity(0.35))
        }
      }
    }
  }

  private func dayToggle(systemName: String, day: String?) -> some View {
    Button(action: { if let day { onSelectDay(day) } }) {
      Image(systemName: systemName)
        .font(.system(size: 15, weight: .semibold))
        .foregroundColor(.black.opacity(day == nil ? 0.12 : 0.45))
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(day == nil)
    .pointingHandCursor()
  }

  private var dayHeading: String {
    guard let date = DateFormatter.yyyyMMdd.date(from: recap.day) else { return "Today" }
    let formatter = DateFormatter()
    formatter.dateFormat = "MMMM d"
    let prefix = Calendar.current.isDateInToday(date) ? "Today, " : ""
    return prefix + formatter.string(from: date)
  }

  private var isViewingToday: Bool {
    guard let date = DateFormatter.yyyyMMdd.date(from: recap.day) else { return true }
    return Calendar.current.isDateInToday(date)
  }

  private var generatedAtText: String? {
    let iso = ISO8601DateFormatter()
    guard let date = iso.date(from: recap.generatedAt) else { return nil }
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    formatter.dateStyle = .none
    return "Generated \(formatter.string(from: date))"
  }

  private var refreshButton: some View {
    DayflowSurfaceButton(
      action: onRefresh,
      content: {
        HStack(spacing: 6) {
          if isRefreshing {
            ProgressView()
              .controlSize(.mini)
          } else {
            Image(systemName: "sparkles")
              .font(.system(size: 11, weight: .semibold))
          }
          Text(refreshButtonTitle)
            .font(.custom("Figtree", size: 12))
            .fontWeight(.semibold)
        }
      },
      background: Color(hex: "FFF1E5"),
      foreground: Color(hex: "F96E00"),
      borderColor: Color(hex: "F9D9BD"),
      cornerRadius: 8,
      horizontalPadding: 12,
      verticalPadding: 7,
      showOverlayStroke: false
    )
    .disabled(isRefreshing)
  }

  /// A refresh always regenerates *today's* recap, so make that explicit
  /// whenever a past day is on screen.
  private var refreshButtonTitle: String {
    if isRefreshing { return "Refreshing…" }
    return isViewingToday ? "Refresh recap" : "Generate today's recap"
  }

  private func blobPosition(index: Int, in size: CGSize) -> CGPoint {
    let anchor = Self.blobAnchors[index % Self.blobAnchors.count]
    return CGPoint(x: size.width * anchor.x, y: size.height * anchor.y)
  }

  // MARK: - Legend

  private var legend: some View {
    let counts = recap.totalCounts

    return VStack(alignment: .leading, spacing: 6) {
      Text("Total")
        .font(.custom("Figtree", size: 11))
        .fontWeight(.semibold)
        .foregroundColor(.black.opacity(0.55))

      ForEach(AgentThreadStatus.allCases, id: \.self) { status in
        legendRow(status: status, count: counts.count(for: status))
      }
    }
    .padding(12)
    .background(Color.white.opacity(0.85))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.black.opacity(0.05), lineWidth: 1)
    )
  }

  private func legendRow(status: AgentThreadStatus, count: Int) -> some View {
    HStack(spacing: 6) {
      Circle()
        .fill(AgentsPalette.legendDot(for: status))
        .overlay(Circle().stroke(Color.black.opacity(0.08), lineWidth: 0.5))
        .frame(width: 8, height: 8)
      Text("\(count) \(status.displayName)")
        .font(.custom("Figtree", size: 11))
        .foregroundColor(.black.opacity(0.6))
    }
  }

  // MARK: - Blobs

  private func blob(for workstream: AgentWorkstream, index: Int) -> some View {
    let size = blobSize(for: workstream)
    let counts = workstream.counts
    let topChips = chipStatuses(counts).prefix(1)
    let bottomChips = chipStatuses(counts).dropFirst()

    return ZStack {
      Ellipse()
        .fill(AgentsPalette.blobColor(at: index).opacity(0.65))
        .frame(width: size * 1.5, height: size)
        .blur(radius: 34)

      VStack(spacing: 8) {
        chipRow(Array(topChips), counts: counts)

        Text(workstream.name)
          .font(.custom("Figtree", size: 16))
          .fontWeight(.medium)
          .foregroundColor(.black.opacity(0.8))

        if !workstream.summary.isEmpty {
          Text(workstream.summary)
            .font(.custom("Figtree", size: 11.5))
            .foregroundColor(.black.opacity(0.55))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: size * 1.15)
        }

        chipRow(Array(bottomChips), counts: counts)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { onSelectWorkstream(index) }
    .hoverScaleEffect(scale: 1.03)
    .pointingHandCursor()
  }

  private func blobSize(for workstream: AgentWorkstream) -> CGFloat {
    150 + CGFloat(min(workstream.threads.count, 8)) * 12
  }

  private func chipStatuses(_ counts: AgentStatusCounts) -> [AgentThreadStatus] {
    AgentThreadStatus.allCases.filter { counts.count(for: $0) > 0 }
  }

  @ViewBuilder
  private func chipRow(_ statuses: [AgentThreadStatus], counts: AgentStatusCounts) -> some View {
    if statuses.isEmpty {
      EmptyView()
    } else {
      HStack(spacing: 6) {
        ForEach(statuses, id: \.self) { status in
          statusChip(status, count: counts.count(for: status))
        }
      }
    }
  }

  private func statusChip(_ status: AgentThreadStatus, count: Int) -> some View {
    Text("\(count) \(status.displayName)")
      .font(.custom("Figtree", size: 10.5))
      .fontWeight(.medium)
      .foregroundColor(AgentsPalette.chipForeground(for: status))
      .padding(.horizontal, 9)
      .padding(.vertical, 4)
      .background(AgentsPalette.chipBackground(for: status))
      .clipShape(Capsule())
      .overlay(Capsule().stroke(Color.black.opacity(0.05), lineWidth: 0.5))
      .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 1)
  }

  // MARK: - Start review

  private var startReviewButton: some View {
    DayflowSurfaceButton(
      action: onStartReview,
      content: {
        HStack(spacing: 6) {
          Text("Start review")
            .font(.custom("Figtree", size: 13))
            .fontWeight(.semibold)
          Image(systemName: "arrow.right")
            .font(.system(size: 11, weight: .semibold))
        }
      },
      background: Color(hex: "F96E00"),
      foreground: .white,
      borderColor: .clear,
      cornerRadius: 9,
      horizontalPadding: 16,
      verticalPadding: 9,
      showOverlayStroke: true
    )
  }
}
