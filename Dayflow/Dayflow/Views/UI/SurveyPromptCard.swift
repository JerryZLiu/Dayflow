//
//  SurveyPromptCard.swift
//  Dayflow
//
//  The bottom-right card that asks one in-app survey, one question at a time.
//  Pick-one and rating answers submit on tap; pick-several and written
//  answers have a button. SurveyCenter records everything.
//

import SwiftUI

struct SurveyPromptCard: View {
  @Environment(\.dayflowTheme) private var theme

  let survey: Survey
  @ObservedObject var center: SurveyCenter

  @State private var questionIndex = 0
  @State private var pickedChoices: Set<String> = []
  @State private var writtenAnswer = ""
  @State private var isFinished = false

  private static let maxWrittenCharacters = 2_000

  private var question: SurveyQuestion {
    survey.questions[min(questionIndex, survey.questions.count - 1)]
  }

  private var trimmedWrittenAnswer: String {
    writtenAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if isFinished {
        thanks
      } else {
        header

        Text(question.prompt)
          .font(.custom("Figtree", size: 15).weight(.semibold))
          .foregroundStyle(theme.textPrimary)
          .fixedSize(horizontal: false, vertical: true)

        answerArea

        Text("Your answer goes straight to the Dayflow team.")
          .font(.custom("Figtree", size: 11))
          .foregroundStyle(theme.textTertiary)
      }
    }
    .promptCardStyle(width: 360)
    .animation(.easeInOut(duration: 0.2), value: questionIndex)
    .animation(.easeInOut(duration: 0.2), value: isFinished)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Dayflow survey")
  }

  // MARK: - Pieces

  private var header: some View {
    HStack {
      Text(
        survey.questions.count > 1
          ? String(localized: "Quick question · \(questionIndex + 1) of \(survey.questions.count)")
          : String(localized: "Quick question")
      )
      .font(.custom("Figtree", size: 12).weight(.medium))
      .foregroundStyle(theme.textSecondary)

      Spacer()

      Button {
        center.dismiss(survey, on: question)
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(theme.textSecondary)
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .pointingHandCursor()
      .accessibilityLabel("Close survey")
    }
  }

  @ViewBuilder
  private var answerArea: some View {
    switch question.type {
    case .single:
      VStack(spacing: 8) {
        ForEach(question.choices ?? [], id: \.self) { choice in
          choiceButton(choice, isPicked: false) {
            submit(.choice(choice))
          }
        }
      }

    case .multi:
      VStack(spacing: 8) {
        ForEach(question.choices ?? [], id: \.self) { choice in
          choiceButton(choice, isPicked: pickedChoices.contains(choice)) {
            togglePicked(choice)
          }
        }
        primaryButton(String(localized: "Continue"), isEnabled: !pickedChoices.isEmpty) {
          let inOrder = (question.choices ?? []).filter { pickedChoices.contains($0) }
          submit(.choices(inOrder))
        }
      }

    case .rating:
      VStack(spacing: 6) {
        HStack(spacing: 8) {
          ForEach(1...5, id: \.self) { value in
            ratingButton(value)
          }
        }
        HStack {
          Text("Not at all")
          Spacer()
          Text("Love it")
        }
        .font(.custom("Figtree", size: 11))
        .foregroundStyle(theme.textTertiary)
      }

    case .open:
      VStack(spacing: 10) {
        writtenAnswerEditor
        HStack(spacing: 8) {
          if question.isOptional {
            secondaryButton(String(localized: "Skip")) {
              advance()
            }
          }
          primaryButton(String(localized: "Send"), isEnabled: !trimmedWrittenAnswer.isEmpty) {
            submit(.text(trimmedWrittenAnswer))
          }
        }
      }

    case .unsupported:
      EmptyView()
    }
  }

  private var writtenAnswerEditor: some View {
    ZStack(alignment: .topLeading) {
      TextEditor(text: $writtenAnswer)
        .font(.custom("Figtree", size: 14))
        .foregroundStyle(theme.textPrimary)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .onChange(of: writtenAnswer) { _, newValue in
          if newValue.count > Self.maxWrittenCharacters {
            writtenAnswer = String(newValue.prefix(Self.maxWrittenCharacters))
          }
        }

      if writtenAnswer.isEmpty {
        Text("Type your answer…")
          .font(.custom("Figtree", size: 14))
          .foregroundStyle(theme.textTertiary)
          .padding(.horizontal, 11)
          .padding(.vertical, 8)
          .allowsHitTesting(false)
      }
    }
    .frame(height: 90)
    .background(RoundedRectangle(cornerRadius: 8).fill(theme.controlFill))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.controlBorder, lineWidth: 1))
  }

  private var thanks: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Thank you!")
        .font(.custom("Figtree", size: 15).weight(.semibold))
        .foregroundStyle(theme.textPrimary)
      Text("Jerry reads every answer.")
        .font(.custom("Figtree", size: 13))
        .foregroundStyle(theme.textSecondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func choiceButton(_ choice: String, isPicked: Bool, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      HStack(spacing: 8) {
        if question.type == .multi {
          Image(systemName: isPicked ? "checkmark.square.fill" : "square")
            .font(.system(size: 13))
            .foregroundStyle(isPicked ? theme.accent : theme.textSecondary)
        }
        Text(choice)
          .font(.custom("Figtree", size: 14))
          .foregroundStyle(theme.chipText)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 8).fill(theme.chipFill))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(isPicked ? theme.accent : theme.chipBorder, lineWidth: 1)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }

  private func ratingButton(_ value: Int) -> some View {
    Button {
      submit(.rating(value))
    } label: {
      Text("\(value)")
        .font(.custom("Figtree", size: 15).weight(.medium))
        .foregroundStyle(theme.chipText)
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.chipFill))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.chipBorder, lineWidth: 1))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
    .accessibilityLabel("\(value) out of 5")
  }

  private func primaryButton(_ title: String, isEnabled: Bool, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Text(title)
        .font(.custom("Figtree", size: 14).weight(.medium))
        .foregroundStyle(theme.primaryButtonText)
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .background(Capsule().fill(theme.primaryButtonFill))
        .overlay(InnerGlow(shape: Capsule(), color: theme.primaryButtonInnerGlow, radius: 3))
        .overlay(
          Capsule().strokeBorder(theme.primaryButtonBorder, lineWidth: theme.isDark ? 0.5 : 0.75))
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
    .opacity(isEnabled ? 1 : 0.4)
    .allowsHitTesting(isEnabled)
  }

  private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.custom("Figtree", size: 14).weight(theme.isDark ? .medium : .regular))
        .foregroundStyle(theme.secondaryButtonText)
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 18).fill(theme.secondaryButtonFill))
        .overlay(
          RoundedRectangle(cornerRadius: 18)
            .strokeBorder(theme.secondaryButtonBorder, lineWidth: theme.isDark ? 1 : 0.75)
        )
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }

  // MARK: - Flow

  private func togglePicked(_ choice: String) {
    if pickedChoices.contains(choice) {
      pickedChoices.remove(choice)
    } else {
      pickedChoices.insert(choice)
    }
  }

  private func submit(_ answer: SurveyAnswer) {
    center.recordAnswer(answer, to: question, in: survey)
    advance()
  }

  /// Next question, or the thank-you after the last one.
  private func advance() {
    if questionIndex + 1 < survey.questions.count {
      questionIndex += 1
      pickedChoices = []
      writtenAnswer = ""
      return
    }

    center.recordCompleted(survey)
    isFinished = true
    Task {
      try? await Task.sleep(for: .seconds(2))
      center.close()
    }
  }
}
