//
//  AgentsCardsView.swift
//  Dayflow
//
//  Stage 3 of the Agents flow: focused per-thread review. One card at a time,
//  navigable via chevrons or the scrubber, with a runtime toggle between the
//  four rendering styles from the Figma exploration.
//

import SwiftUI

struct AgentsCardsView: View {
  let recap: AgentsDayRecap
  let workstreamIndex: Int
  let threadIndex: Int
  let onNavigate: (Int, Int) -> Void
  let onBack: () -> Void

  @AppStorage("agentsCardStyle") private var cardStyleRaw = AgentCardStyle.messenger.rawValue
  @State private var keptThreadIDs: Set<String> = []
  @State private var collapsedThreadIDs: Set<String> = []

  private var cardStyle: AgentCardStyle {
    AgentCardStyle(rawValue: cardStyleRaw) ?? .messenger
  }

  /// Every (workstream, thread) position in reading order, so chevrons can
  /// walk across workstream boundaries.
  private var positions: [(workstream: Int, thread: Int)] {
    recap.workstreams.enumerated().flatMap { wsIndex, workstream in
      workstream.threads.indices.map { (wsIndex, $0) }
    }
  }

  private var currentPositionIndex: Int {
    positions.firstIndex { $0.workstream == workstreamIndex && $0.thread == threadIndex } ?? 0
  }

  private var currentThread: AgentThread {
    recap.workstreams[workstreamIndex].threads[threadIndex]
  }

  var body: some View {
    VStack(spacing: 0) {
      topBar

      Spacer(minLength: 16)

      HStack(spacing: 18) {
        navChevron(systemName: "chevron.left", enabled: currentPositionIndex > 0) {
          step(by: -1)
        }

        card

        navChevron(
          systemName: "chevron.right", enabled: currentPositionIndex < positions.count - 1
        ) {
          step(by: 1)
        }
      }

      positionCaption
        .padding(.top, 12)

      Spacer(minLength: 12)

      stylePicker
        .padding(.bottom, 24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Navigation

  private func step(by delta: Int) {
    let target = currentPositionIndex + delta
    guard positions.indices.contains(target) else { return }
    let position = positions[target]
    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
      onNavigate(position.workstream, position.thread)
    }
  }

  private var topBar: some View {
    ZStack {
      AgentsScrubberView(
        workstreams: recap.workstreams,
        selectedWorkstream: workstreamIndex,
        selectedThread: threadIndex,
        onSelectThread: { wsIndex, thrIndex in
          withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            onNavigate(wsIndex, thrIndex)
          }
        }
      )
      .frame(maxWidth: .infinity)

      HStack {
        Button(action: onBack) {
          Image(systemName: "chevron.left")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.black.opacity(0.5))
            .frame(width: 28, height: 28)
            .background(Color.white.opacity(0.8))
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.black.opacity(0.06), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .hoverScaleEffect(scale: 1.05)
        .pointingHandCursor()
        .accessibilityLabel(Text("Back to briefing"))

        Spacer()
      }
      .padding(.horizontal, 24)
    }
    .padding(.top, 26)
  }

  private func navChevron(systemName: String, enabled: Bool, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(.black.opacity(enabled ? 0.55 : 0.18))
        .frame(width: 32, height: 32)
        .background(Color.white.opacity(0.85))
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.black.opacity(0.06), lineWidth: 1))
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .hoverScaleEffect(enabled: enabled, scale: 1.06)
    .pointingHandCursorOnHover(enabled: enabled, reassertOnPressEnd: true)
  }

  // MARK: - Card

  private var card: some View {
    let thread = currentThread

    return AgentThreadCardView(
      thread: thread,
      style: cardStyle,
      isExpanded: !collapsedThreadIDs.contains(thread.id),
      isKept: keptThreadIDs.contains(thread.id),
      onToggleExpanded: {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
          if collapsedThreadIDs.contains(thread.id) {
            collapsedThreadIDs.remove(thread.id)
          } else {
            collapsedThreadIDs.insert(thread.id)
          }
        }
      },
      onToggleKept: {
        if keptThreadIDs.contains(thread.id) {
          keptThreadIDs.remove(thread.id)
        } else {
          keptThreadIDs.insert(thread.id)
        }
      }
    )
    .frame(width: 470)
    .id(thread.id)
    .transition(.opacity.combined(with: .scale(scale: 0.98)))
  }

  private var positionCaption: some View {
    Text(
      "Thread \(currentPositionIndex + 1) of \(positions.count) · \(recap.workstreams[workstreamIndex].name)"
    )
    .font(.custom("Figtree", size: 11))
    .foregroundColor(.black.opacity(0.35))
  }

  // MARK: - Style picker

  private var stylePicker: some View {
    HStack(spacing: 6) {
      ForEach(AgentCardStyle.allCases) { style in
        stylePill(style)
      }
    }
  }

  private func stylePill(_ style: AgentCardStyle) -> some View {
    let isSelected = style == cardStyle

    return Button {
      cardStyleRaw = style.rawValue
      AnalyticsService.shared.capture("agents_card_style_changed", ["style": style.rawValue])
    } label: {
      Text(style.displayName)
        .font(.custom("Figtree", size: 12))
        .fontWeight(.medium)
        .foregroundColor(isSelected ? .white : .black.opacity(0.5))
        .padding(.horizontal, 13)
        .padding(.vertical, 6)
        .background(isSelected ? Color(hex: "F96E00") : Color.white.opacity(0.85))
        .clipShape(Capsule())
        .overlay(
          Capsule().stroke(
            isSelected ? Color.clear : Color.black.opacity(0.08), lineWidth: 1)
        )
    }
    .buttonStyle(.plain)
    .hoverScaleEffect(scale: 1.03)
    .pointingHandCursor()
  }
}
