//
//  AgentsScrubberView.swift
//  Dayflow
//
//  The tick-mark timeline from the Figma exploration: one tick per condensed
//  turn, grouped by thread (tighter spacing) and workstream (wider spacing,
//  labeled). Clicking a thread's tick group jumps to that thread's card.
//

import SwiftUI

struct AgentsScrubberView: View {
  let workstreams: [AgentWorkstream]
  let selectedWorkstream: Int
  /// nil while in the briefing stage (whole workstream highlighted, no thread)
  let selectedThread: Int?
  let onSelectThread: (Int, Int) -> Void

  var body: some View {
    // Horizontal scroll for heavy days; the inner max-width frame keeps the
    // ticks centered whenever they fit.
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(alignment: .top, spacing: 26) {
        ForEach(Array(workstreams.enumerated()), id: \.element.id) { wsIndex, workstream in
          workstreamGroup(workstream, wsIndex: wsIndex)
        }
      }
      .padding(.horizontal, 60)
      .frame(maxWidth: .infinity)
    }
  }

  private func workstreamGroup(_ workstream: AgentWorkstream, wsIndex: Int) -> some View {
    let isCurrentWorkstream = wsIndex == selectedWorkstream

    return VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .bottom, spacing: 4) {
        ForEach(Array(workstream.threads.enumerated()), id: \.element.id) { threadIndex, thread in
          threadTicks(
            thread,
            isSelected: isCurrentWorkstream && selectedThread == threadIndex
          )
          .contentShape(Rectangle())
          .onTapGesture { onSelectThread(wsIndex, threadIndex) }
          .pointingHandCursor()
        }
      }
      .frame(height: 16, alignment: .bottom)

      Text(workstream.name)
        .font(.custom("Figtree", size: 11))
        .fontWeight(isCurrentWorkstream ? .semibold : .regular)
        .foregroundColor(.black.opacity(isCurrentWorkstream ? 0.8 : 0.4))
    }
  }

  private func threadTicks(_ thread: AgentThread, isSelected: Bool) -> some View {
    HStack(alignment: .bottom, spacing: 2) {
      ForEach(0..<max(thread.turns.count, 1), id: \.self) { _ in
        RoundedRectangle(cornerRadius: 0.75)
          .fill(Color.black.opacity(isSelected ? 0.75 : 0.3))
          .frame(width: 1.5, height: isSelected ? 15 : 10)
      }
    }
  }
}
