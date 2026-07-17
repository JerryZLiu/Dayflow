//
//  AgentsView.swift
//  Dayflow
//
//  Root of the Agents tab. Three stages mirror the Figma flow:
//  overview (status blobs) → briefing (one workstream at a time) → cards
//  (per-thread review). Falls back to generate/progress/error states when
//  there is no recap for today yet.
//

import SwiftUI

enum AgentsStage: Equatable {
  case overview
  case briefing(workstream: Int)
  case cards(workstream: Int, thread: Int)
}

struct AgentsView: View {
  @ObservedObject var store = AgentsRecapStore.shared
  @State private var stage: AgentsStage = .overview

  var body: some View {
    ZStack {
      background

      if let recap = store.recap {
        stageContent(recap)
      } else {
        statusContent
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear { store.loadCachedRecapIfNeeded() }
  }

  private var background: some View {
    ZStack {
      LinearGradient(
        colors: [Color(hex: "FFFDFB"), Color(hex: "FFF6EC")],
        startPoint: .top,
        endPoint: .bottom
      )
      RadialGradient(
        colors: [Color(hex: "FFD9B0").opacity(0.45), Color.clear],
        center: .bottomLeading,
        startRadius: 0,
        endRadius: 700
      )
    }
    .ignoresSafeArea()
  }

  @ViewBuilder
  private func stageContent(_ recap: AgentsDayRecap) -> some View {
    switch stage {
    case .overview:
      AgentsOverviewView(
        recap: recap,
        isRefreshing: store.isRunning,
        refreshError: refreshErrorMessage,
        previousDay: store.previousAvailableDay,
        nextDay: store.nextAvailableDay,
        onSelectDay: { store.selectDay($0) },
        onRefresh: { store.generate() },
        onSelectWorkstream: { index in
          withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            stage = .briefing(workstream: index)
          }
        },
        onStartReview: {
          guard !recap.workstreams.isEmpty else { return }
          withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            stage = .briefing(workstream: 0)
          }
        }
      )
      .transition(.opacity)

    case .briefing(let index):
      if let workstreamIndex = clampedWorkstreamIndex(index, in: recap) {
        AgentsBriefingView(
          recap: recap,
          workstreamIndex: workstreamIndex,
          onSeeDetails: {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
              stage = .cards(workstream: workstreamIndex, thread: 0)
            }
          },
          onNext: {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
              let next = workstreamIndex + 1
              stage = next < recap.workstreams.count ? .briefing(workstream: next) : .overview
            }
          },
          onBack: {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
              stage = .overview
            }
          },
          onSelectThread: { wsIndex, threadIndex in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
              stage = .cards(workstream: wsIndex, thread: threadIndex)
            }
          }
        )
        .transition(.opacity.combined(with: .move(edge: .trailing)))
      } else {
        recoverToOverview
      }

    case .cards(let wsIndex, let threadIndex):
      if let workstreamIndex = clampedWorkstreamIndex(wsIndex, in: recap),
        !recap.workstreams[workstreamIndex].threads.isEmpty
      {
        AgentsCardsView(
          recap: recap,
          workstreamIndex: workstreamIndex,
          threadIndex: min(threadIndex, recap.workstreams[workstreamIndex].threads.count - 1),
          onNavigate: { wsIdx, threadIdx in
            stage = .cards(workstream: wsIdx, thread: threadIdx)
          },
          onBack: {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
              stage = .briefing(workstream: workstreamIndex)
            }
          }
        )
        .transition(.opacity.combined(with: .move(edge: .trailing)))
      } else {
        recoverToOverview
      }
    }
  }

  private func clampedWorkstreamIndex(_ index: Int, in recap: AgentsDayRecap) -> Int? {
    guard !recap.workstreams.isEmpty else { return nil }
    return min(max(index, 0), recap.workstreams.count - 1)
  }

  private var refreshErrorMessage: String? {
    if case .failed(let message) = store.runState { return message }
    return nil
  }

  /// Shown for one frame if a refreshed recap invalidated the current stage's
  /// indices; immediately resets to the overview.
  private var recoverToOverview: some View {
    Color.clear.onAppear { stage = .overview }
  }

  // MARK: - No-recap states

  @ViewBuilder
  private var statusContent: some View {
    switch store.runState {
    case .running(let startedAt):
      runningState(startedAt: startedAt)
    case .failed(let message):
      failedState(message: message)
    case .idle:
      emptyState
    }
  }

  private var emptyState: some View {
    VStack(spacing: 14) {
      Text("Agents")
        .font(.custom("InstrumentSerif-Regular", size: 40))
        .foregroundColor(.black.opacity(0.85))

      Text(
        "Fable reads today's Claude Code and Codex sessions and builds a review of everything your agents did — grouped by workstream, thread by thread."
      )
      .font(.custom("Figtree", size: 13))
      .foregroundColor(.black.opacity(0.55))
      .multilineTextAlignment(.center)
      .frame(maxWidth: 420)

      generateButton(title: "Generate today's recap")
        .padding(.top, 10)

      Text("Runs only when you ask — nothing happens automatically.")
        .font(.custom("Figtree", size: 11))
        .foregroundColor(.black.opacity(0.35))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func runningState(startedAt: Date) -> some View {
    VStack(spacing: 14) {
      ProgressView()
        .controlSize(.small)

      Text("Fable is reading today's sessions…")
        .font(.custom("InstrumentSerif-Regular", size: 26))
        .foregroundColor(.black.opacity(0.8))

      TimelineView(.periodic(from: startedAt, by: 1)) { context in
        let elapsed = Int(context.date.timeIntervalSince(startedAt))
        Text("Running for \(elapsed / 60)m \(elapsed % 60)s — a full day can take several minutes.")
          .font(.custom("Figtree", size: 12))
          .foregroundColor(.black.opacity(0.45))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func failedState(message: String) -> some View {
    VStack(spacing: 14) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 22))
        .foregroundColor(Color(hex: "C04A00"))

      Text("The recap run didn't finish")
        .font(.custom("InstrumentSerif-Regular", size: 26))
        .foregroundColor(.black.opacity(0.8))

      ScrollView {
        Text(message)
          .font(.custom("Figtree", size: 12))
          .foregroundColor(.black.opacity(0.55))
          .multilineTextAlignment(.center)
          .textSelection(.enabled)
      }
      .frame(maxWidth: 460, maxHeight: 120)

      generateButton(title: "Try again")
        .padding(.top, 4)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func generateButton(title: String) -> some View {
    DayflowSurfaceButton(
      action: { store.generate() },
      content: {
        HStack(spacing: 7) {
          Image(systemName: "sparkles")
            .font(.system(size: 12, weight: .semibold))
          Text(title)
            .font(.custom("Figtree", size: 13))
            .fontWeight(.semibold)
        }
      },
      background: Color(hex: "F96E00"),
      foreground: .white,
      borderColor: .clear,
      cornerRadius: 9,
      horizontalPadding: 18,
      verticalPadding: 10,
      showOverlayStroke: true
    )
  }
}
