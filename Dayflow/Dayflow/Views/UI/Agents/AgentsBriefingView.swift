//
//  AgentsBriefingView.swift
//  Dayflow
//
//  Stage 2 of the Agents flow: one workstream at a time — serif title,
//  accomplishment bullets, and "See details" / "Next" to either dive into the
//  thread cards or move on to the next workstream.
//

import SwiftUI

struct AgentsBriefingView: View {
  let recap: AgentsDayRecap
  let workstreamIndex: Int
  let onSeeDetails: () -> Void
  let onNext: () -> Void
  let onBack: () -> Void
  let onSelectThread: (Int, Int) -> Void

  private var workstream: AgentWorkstream {
    recap.workstreams[workstreamIndex]
  }

  private var isLastWorkstream: Bool {
    workstreamIndex == recap.workstreams.count - 1
  }

  var body: some View {
    VStack(spacing: 0) {
      topBar

      Spacer()

      VStack(spacing: 22) {
        Text(workstream.name)
          .font(.custom("InstrumentSerif-Regular", size: 38))
          .foregroundColor(.black.opacity(0.85))

        bullets
      }

      Spacer()

      HStack(spacing: 12) {
        seeDetailsButton
        nextButton
      }
      .padding(.bottom, 60)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var topBar: some View {
    ZStack {
      AgentsScrubberView(
        workstreams: recap.workstreams,
        selectedWorkstream: workstreamIndex,
        selectedThread: nil,
        onSelectThread: onSelectThread
      )
      .frame(maxWidth: .infinity)

      HStack {
        backButton
        Spacer()
      }
      .padding(.horizontal, 24)
    }
    .padding(.top, 26)
  }

  private var backButton: some View {
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
    .accessibilityLabel(Text("Back to overview"))
  }

  private var bullets: some View {
    let lines = workstream.bullets.isEmpty ? [workstream.summary] : workstream.bullets

    return VStack(alignment: .leading, spacing: 12) {
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        HStack(alignment: .top, spacing: 9) {
          Image(systemName: "sparkle")
            .font(.system(size: 10))
            .foregroundColor(.black.opacity(0.4))
            .padding(.top, 3)
          Text(line)
            .font(.custom("Figtree", size: 13.5))
            .foregroundColor(.black.opacity(0.72))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .frame(maxWidth: 520, alignment: .leading)
  }

  private var seeDetailsButton: some View {
    DayflowSurfaceButton(
      action: onSeeDetails,
      content: {
        Text("See details")
          .font(.custom("Figtree", size: 13))
          .fontWeight(.semibold)
      },
      background: Color(hex: "F96E00"),
      foreground: .white,
      borderColor: .clear,
      cornerRadius: 9,
      horizontalPadding: 20,
      verticalPadding: 10,
      showOverlayStroke: true
    )
  }

  private var nextButton: some View {
    DayflowSurfaceButton(
      action: onNext,
      content: {
        Text(isLastWorkstream ? "Done" : "Next")
          .font(.custom("Figtree", size: 13))
          .fontWeight(.semibold)
      },
      background: Color(hex: "FFF1E5"),
      foreground: Color(hex: "F96E00"),
      borderColor: Color(hex: "F9D9BD"),
      cornerRadius: 9,
      horizontalPadding: 20,
      verticalPadding: 10,
      showOverlayStroke: false
    )
  }
}
