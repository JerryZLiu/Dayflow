import Combine
import SwiftUI

// MARK: - Main View

struct JournalDayView: View {
  var onSetReminders: (() -> Void)?

  @StateObject private var manager = JournalDayManager()
  @State private var selectedPeriod: JournalDayViewPeriod = .day

  @Namespace private var layoutNamespace
  @State private var transitionDirection: AnyTransition = .identity
  @State private var pageId = UUID()

  init(onSetReminders: (() -> Void)? = nil) {
    self.onSetReminders = onSetReminders
  }

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      VStack(spacing: 10) {
        toolbar

        Text(manager.headline)
          .font(.custom("InstrumentSerif-Regular", size: 36))
          .foregroundStyle(JournalDayTokens.primaryText)
          .transaction { transaction in
            transaction.animation = nil
          }

        contentForFlowState
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .id(pageId)
          .transition(transitionDirection)

        Spacer(minLength: 0)
      }
      .padding(.top, 10)
      .padding(.horizontal, 20)
      .padding(.bottom, 10)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

    }
    .onAppear {
      manager.loadCurrentDay()
    }
  }
}

// MARK: - Content Switcher

extension JournalDayView {
  @ViewBuilder
  var contentForFlowState: some View {
    switch manager.flowState {
    case .intro:
      IntroView(ctaTitle: manager.ctaTitle, isEnabled: manager.isToday) {
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
          manager.startEditingIntentions()
        }
      }
    case .summary:
      SummaryView(copy: manager.recentSummary?.summary ?? "") {
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
          manager.startEditingIntentions()
        }
      }
    case .intentionsEdit:
      IntentionsEditForm(
        intentions: $manager.formIntentions,
        notes: $manager.formNotes,
        goals: $manager.formGoals,
        onBack: { manager.cancelEditingIntentions() },
        onSave: {
          withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) {
            manager.saveIntentions()
          }
        },
        namespace: layoutNamespace
      )
      .zIndex(10)

    case .reflectionPrompt:
      JournalBoardLayout(
        intentions: manager.intentionsList,
        notes: manager.formNotes,
        goals: manager.goalsList,
        onTapLeft: manager.isToday
          ? {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
              manager.startEditingIntentions()
            }
          } : nil,
        isUnfolding: true,
        namespace: layoutNamespace
      ) {
        ReflectionPromptCard(isEnabled: manager.isToday) {
          withAnimation { manager.startReflecting() }
        }
      }
      .zIndex(1)

    case .reflectionEdit:
      JournalBoardLayout(
        intentions: manager.intentionsList,
        notes: manager.formNotes,
        goals: manager.goalsList,
        onTapLeft: nil
      ) {
        ReflectionEditorCard(
          text: $manager.formReflections,
          onSave: { manager.saveReflections() },
          onSkip: { manager.skipReflections() }
        )
      }
    case .reflectionSaved:
      JournalBoardLayout(
        intentions: manager.intentionsList,
        notes: manager.formNotes,
        goals: manager.goalsList,
        onTapLeft: manager.isToday ? { manager.startEditingIntentions() } : nil
      ) {
        ReflectionSavedCard(
          reflections: manager.formReflections,
          canSummarize: manager.canSummarize,
          isLoading: manager.isLoading,
          errorMessage: manager.errorMessage,
          onSummarize: {
            Task { await manager.generateSummary() }
          },
          onDismissError: { manager.errorMessage = nil }
        )
      }
    case .boardComplete:
      JournalBoardLayout(
        intentions: manager.intentionsList,
        notes: manager.formNotes,
        goals: manager.goalsList,
        onTapLeft: manager.isToday ? { manager.startEditingIntentions() } : nil
      ) {
        SummaryCard(
          summary: manager.formSummary.isEmpty ? nil : manager.formSummary,
          reflections: manager.formReflections.isEmpty ? nil : manager.formReflections,
          onRegenerate: {
            Task { await manager.generateSummary() }
          }
        )
      }
    }
  }

  private var toolbar: some View {
    ZStack {
      HStack(spacing: 10) {
        JournalDayCircleButton(direction: .left) {
          transitionDirection = .bookFlipPrev
          withAnimation(.easeInOut(duration: 0.6)) {
            manager.navigateToPreviousDay()
            pageId = UUID()
          }
        }

        JournalDaySegmentedControl(selection: $selectedPeriod)
          .fixedSize()

        JournalDayCircleButton(direction: .right, isDisabled: !manager.canNavigateForward) {
          transitionDirection = .bookFlipNext
          withAnimation(.easeInOut(duration: 0.6)) {
            manager.navigateToNextDay()
            pageId = UUID()
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .center)

      HStack {
        Spacer()
        Button(action: {
          AnalyticsService.shared.capture("journal_reminders_opened")
          onSetReminders?()
        }) {
          HStack(alignment: .center, spacing: 4) {
            Image("JournalReminderIcon")
              .resizable()
              .renderingMode(.template)
              .foregroundStyle(JournalDayTokens.reminderText)
              .frame(width: 16, height: 16)

            Text("Set reminders")
              .font(.custom("Figtree-SemiBold", size: 12))
              .foregroundStyle(JournalDayTokens.reminderText)
          }
        }
        .buttonStyle(
          JournalPillButtonStyle(
            horizontalPadding: 12, verticalPadding: 6, font: .custom("Figtree-SemiBold", size: 12))
        )
        .padding(.trailing, 20)
      }
    }
  }
}

// MARK: - Intentions Edit Form

private struct IntentionsEditForm: View {
  @Binding var intentions: String
  @Binding var notes: String
  @Binding var goals: String
  var onBack: () -> Void
  var onSave: () -> Void
  var namespace: Namespace.ID

  private let titleLeading: CGFloat = 5

  var body: some View {
    VStack(spacing: 10) {
      HStack {
        Button(action: onBack) {
          Image(systemName: "arrow.left")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(JournalDayTokens.bodyText.opacity(0.5))
            .frame(width: 32, height: 32)
            .background(Color.white.opacity(0.6))
            .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        Spacer()
      }
      .padding(.horizontal, 12)

      editCard
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .matchedGeometryEffect(id: "card_bg", in: namespace)

      HStack(spacing: 12) {
        Button("Save", action: onSave)
          .buttonStyle(JournalPillButtonStyle(horizontalPadding: 22, verticalPadding: 9))
      }
      .frame(height: 46)
      .padding(.horizontal, 8)
      .padding(.bottom, 10)
    }
    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
  }

  private var editCard: some View {
    ScrollView(.vertical, showsIndicators: false) {
      VStack(alignment: .leading, spacing: 5) {
        sectionIntentions
        sectionNotes
        sectionGoals
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 24)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .background(
      LinearGradient(
        stops: [
          .init(color: Color.white.opacity(0.3), location: 0.00),
          .init(color: Color.white.opacity(0.8), location: 0.50),
          .init(color: Color.white.opacity(0.3), location: 1.00),
        ],
        startPoint: UnitPoint(x: 1, y: 0.14),
        endPoint: UnitPoint(x: 0, y: 0.78)
      )
    )
    .cornerRadius(8)
    .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 0)
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .inset(by: 0.5)
        .stroke(Color.white, lineWidth: 1)
    )
  }

  private static let intentionsPlaceholders = [
    "What does a good day look like?",
    "If today goes well, what will you have done?",
  ]

  @State private var intentionsPlaceholder: String = intentionsPlaceholders.randomElement()!

  private var sectionIntentions: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Today's intentions")
        .font(.custom("InstrumentSerif-Regular", size: 22))
        .foregroundStyle(JournalDayTokens.sectionHeader)
        .padding(.leading, titleLeading)

      JournalTextEditor(
        text: $intentions,
        placeholder: intentionsPlaceholder,
        minLines: 3,
        autoFocus: true
      )
    }
  }

  private var sectionNotes: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        Text("Notes for today")
          .font(.custom("InstrumentSerif-Regular", size: 22))
          .foregroundStyle(JournalDayTokens.sectionHeader)
          .padding(.leading, titleLeading)
      }

      JournalTextEditor(
        text: $notes,
        placeholder: "What mindset do you want to carry today?",
        minLines: 3
      )
    }
  }

  private var sectionGoals: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        Text("Long term goals")
          .font(.custom("InstrumentSerif-Regular", size: 22))
          .foregroundStyle(JournalDayTokens.sectionHeader)
          .padding(.leading, titleLeading)
      }

      JournalTextEditor(
        text: $goals,
        placeholder: "What are you working towards?",
        minLines: 3
      )
    }
  }
}

// MARK: - Reflection Prompt & Edit Components

private struct ReflectionPromptCard: View {
  var isEnabled: Bool = true
  var onReflect: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Today's reflections")
        .font(.custom("InstrumentSerif-Regular", size: 22))
        .foregroundStyle(JournalDayTokens.sectionHeader.opacity(0.4))

      Text(
        "Return near the end of your day to reflect on your intentions. Let Dayflow generate a narrative summary based on the activities on your Timeline."
      )
      .font(.custom("Figtree-Regular", size: 15))
      .foregroundStyle(JournalDayTokens.bodyText.opacity(0.65))
      .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 0)

      if isEnabled {
        HStack {
          Spacer()
          Button("Reflect on your day", action: onReflect)
            .buttonStyle(JournalPillButtonStyle(horizontalPadding: 20, verticalPadding: 10))
        }
      }
    }
  }
}

private struct ReflectionEditorCard: View {
  @Binding var text: String
  var onSave: () -> Void
  var onSkip: () -> Void
  private var isSaveDisabled: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Your reflections")
        .font(.custom("InstrumentSerif-Regular", size: 22))
        .foregroundStyle(JournalDayTokens.sectionHeader)

      JournalTextEditor(
        text: $text,
        placeholder: "How was your day? What did you do? How do you feel?",
        minLines: 6
      )
      .padding(.leading, -4)
      .frame(maxWidth: .infinity, alignment: .topLeading)

      Spacer(minLength: 0)

      HStack(spacing: 10) {
        Button("Save", action: onSave)
          .buttonStyle(JournalPillButtonStyle(horizontalPadding: 18, verticalPadding: 8))
          .disabled(isSaveDisabled)
          .opacity(isSaveDisabled ? 0.55 : 1)
          .animation(.easeInOut(duration: 0.2), value: isSaveDisabled)

        Button("Skip", action: onSkip)
          .buttonStyle(.plain)
          .foregroundStyle(JournalDayTokens.bodyText.opacity(0.6))
          .pointingHandCursor()
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
  }
}

private struct ReflectionSavedCard: View {
  var reflections: String
  var canSummarize: Bool = true
  var isLoading: Bool = false
  var errorMessage: String? = nil
  var onSummarize: () -> Void
  var onDismissError: (() -> Void)? = nil
  private var hasReflections: Bool {
    !reflections.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Your reflections")
        .font(.custom("InstrumentSerif-Regular", size: 22))
        .foregroundStyle(JournalDayTokens.sectionHeader)

      if hasReflections {
        ScrollView {
          Text(reflections)
            .font(.custom("Figtree-Regular", size: 15))
            .foregroundStyle(JournalDayTokens.bodyText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
            .padding(.horizontal, 2)
        }
      } else {
        Text("Return near the end of your day to reflect on your intentions.")
          .font(.custom("Figtree-Regular", size: 15))
          .foregroundStyle(JournalDayTokens.bodyText.opacity(0.65))
      }

      Spacer(minLength: 0)

      HStack {
        Spacer()
        if isLoading {
          HStack(spacing: 8) {
            ProgressView().scaleEffect(0.8)
            Text("Generating summary...").font(.custom("Figtree-Regular", size: 14))
              .foregroundStyle(
                JournalDayTokens.bodyText.opacity(0.7))
          }
        } else if let error = errorMessage {
          VStack(alignment: .trailing, spacing: 8) {
            Text(error).font(.custom("Figtree-Regular", size: 13)).foregroundStyle(
              Color.red.opacity(0.8)
            ).multilineTextAlignment(.trailing)
            HStack(spacing: 12) {
              Button("Dismiss") { onDismissError?() }
                .buttonStyle(.plain).font(.custom("Figtree-Regular", size: 13)).foregroundStyle(
                  JournalDayTokens.bodyText.opacity(0.6)
                )
                .pointingHandCursor()
              Button("Try again", action: onSummarize)
                .buttonStyle(JournalPillButtonStyle(horizontalPadding: 18, verticalPadding: 8))
            }
          }
        } else if canSummarize {
          Button("Summarize with Dayflow", action: onSummarize)
            .buttonStyle(JournalPillButtonStyle(horizontalPadding: 24, verticalPadding: 11))
        } else {
          Text("Need at least 1 hour of timeline activity to summarize")
            .font(.custom("Figtree-Regular", size: 13))
            .foregroundStyle(JournalDayTokens.bodyText.opacity(0.5))
        }
      }
    }
  }
}

private struct SummaryCard: View {
  var summary: String?
  var reflections: String?
  var onRegenerate: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Dayflow summary")
          .font(.custom("InstrumentSerif-Regular", size: 22))
          .foregroundStyle(JournalDayTokens.sectionHeader)

        if let summary {
          WetInkText(text: summary, font: .custom("Figtree-Regular", size: 17))
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Text("Summarizing your day recorded on your timeline…")
            .font(.custom("Figtree-Regular", size: 15))
            .foregroundStyle(JournalDayTokens.bodyText.opacity(0.65))
        }
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Your reflections")
          .font(.custom("InstrumentSerif-Regular", size: 22))
          .foregroundStyle(JournalDayTokens.sectionHeader)

        if let reflections, !reflections.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text(reflections)
            .font(.custom("Figtree-Regular", size: 15))
            .foregroundStyle(JournalDayTokens.bodyText)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Text("Return near the end of your day to reflect on your intentions.")
            .font(.custom("Figtree-Regular", size: 15))
            .foregroundStyle(JournalDayTokens.bodyText.opacity(0.65))
        }
      }

      if let onRegenerate {
        Button(action: onRegenerate) {
          Text("Regenerate summary")
            .font(.custom("Figtree-Regular", size: 13))
            .foregroundStyle(JournalDayTokens.sectionHeader)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
      }
      Spacer(minLength: 0)
    }
  }
}

// MARK: - Intro & Summary Views (Simple)

private struct IntroView: View {
  var ctaTitle: String
  var isEnabled: Bool = true
  var onTapCTA: () -> Void

  var body: some View {
    VStack(spacing: 20) {
      Text("Set daily intentions and track your progress")
        .font(.custom("InstrumentSerif-Regular", size: 34))
        .foregroundStyle(JournalDayTokens.sectionHeader)
        .multilineTextAlignment(.center)
      Text(
        "Dayflow helps you track your daily and longer term pursuits, gives you the space to reflect, and generates a summary of each day."
      )
      .font(.custom("Figtree-Regular", size: 16))
      .foregroundStyle(JournalDayTokens.bodyText)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 540)

      if isEnabled {
        Button(action: onTapCTA) {
          Text(ctaTitle).font(.custom("Figtree-SemiBold", size: 17))
        }
        .buttonStyle(JournalPillButtonStyle(horizontalPadding: 28, verticalPadding: 10))
        .padding(.top, 16)
      } else {
        Text("No journal entry for this day")
          .font(.custom("Figtree-Regular", size: 14))
          .foregroundStyle(JournalDayTokens.bodyText.opacity(0.5))
          .padding(.top, 16)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct SummaryView: View {
  var copy: String
  var onTapCTA: () -> Void

  var body: some View {
    VStack(spacing: 20) {
      Text("Summary from yesterday")
        .font(.custom("InstrumentSerif-Regular", size: 30))
        .foregroundStyle(JournalDayTokens.sectionHeader)

      ScrollView(.vertical, showsIndicators: false) {
        WetInkText(text: copy, font: .custom("Figtree-Regular", size: 17))
          .multilineTextAlignment(.leading)
          .frame(maxWidth: 640, alignment: .leading)
      }
      .frame(maxHeight: 300)

      Button(action: onTapCTA) {
        Text("Set today's intentions")
          .font(.custom("Figtree-SemiBold", size: 17))
      }
      .buttonStyle(JournalPillButtonStyle(horizontalPadding: 28, verticalPadding: 10))
      .padding(.top, 16)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct JournalDayView_Previews: PreviewProvider {
  static var previews: some View {
    JournalDayView()
      .background(Color(red: 0.96, green: 0.94, blue: 0.92))
      .previewLayout(.sizeThatFits)
      .preferredColorScheme(.light)
      .frame(width: 800, height: 600)
  }
}
