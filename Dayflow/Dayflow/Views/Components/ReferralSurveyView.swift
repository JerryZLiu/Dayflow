import SwiftUI

/// Reusable "Where did you find Dayflow?" survey component.
struct ReferralSurveyView: View {
  let prompt: String
  let submitLabel: String
  let showsThankYou: Bool
  let showSubmitButton: Bool
  let onSubmit: (_ option: ReferralOption, _ detail: String?) -> Void

  @State private var internalSelectedReferral: ReferralOption? = nil
  @State private var internalCustomReferral: String = ""
  @State private var randomizedOptions = ReferralOption.randomizedConcreteOptions()
  @State private var hasSubmitted = false

  private let externalSelectedReferral: Binding<ReferralOption?>?
  private let externalCustomReferral: Binding<String>?

  private var selectedReferralBinding: Binding<ReferralOption?> {
    externalSelectedReferral ?? $internalSelectedReferral
  }

  private var customReferralBinding: Binding<String> {
    externalCustomReferral ?? $internalCustomReferral
  }

  private var selectedReferral: ReferralOption? {
    get { selectedReferralBinding.wrappedValue }
    nonmutating set { selectedReferralBinding.wrappedValue = newValue }
  }

  private var customReferral: String {
    get { customReferralBinding.wrappedValue }
    nonmutating set { customReferralBinding.wrappedValue = newValue }
  }

  init(
    prompt: String,
    submitLabel: String = String(localized: "Submit"),
    showsThankYou: Bool = false,
    showSubmitButton: Bool = true,
    selectedReferral: Binding<ReferralOption?>? = nil,
    customReferral: Binding<String>? = nil,
    onSubmit: @escaping (_ option: ReferralOption, _ detail: String?) -> Void = { _, _ in }
  ) {
    self.prompt = prompt
    self.submitLabel = submitLabel
    self.showsThankYou = showsThankYou
    self.showSubmitButton = showSubmitButton
    self.onSubmit = onSubmit

    if let selectedReferral = selectedReferral, let customReferral = customReferral {
      externalSelectedReferral = selectedReferral
      externalCustomReferral = customReferral
    } else {
      externalSelectedReferral = nil
      externalCustomReferral = nil
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(prompt)
        .font(.custom("Figtree", size: 15).weight(.semibold))
        .foregroundColor(.black.opacity(0.85))
        .fixedSize(horizontal: false, vertical: true)

      VStack(spacing: 10) {
        ForEach(Array(referralRows.enumerated()), id: \.offset) { _, row in
          HStack(spacing: 12) {
            ForEach(row, id: \.id) { option in
              referralOptionView(option)
            }
          }
        }
      }

      detailField

      if showsThankYou && hasSubmitted {
        Label("Thanks for letting me know!", systemImage: "checkmark.circle.fill")
          .font(.custom("Figtree", size: 14))
          .foregroundColor(Color(red: 0.25, green: 0.17, blue: 0))
          .padding(.top, 4)
      }

      if showSubmitButton {
        HStack {
          Spacer()
          DayflowSurfaceButton(
            action: handleSubmit,
            content: {
              Text(submitLabel)
                .font(.custom("Figtree", size: 16))
                .fontWeight(.semibold)
            },
            background: submitBackground,
            foreground: Color.white.opacity(canSubmit ? 1 : 0.85),
            borderColor: .clear,
            cornerRadius: 8,
            horizontalPadding: 40,
            verticalPadding: 14,
            minWidth: 200,
            showOverlayStroke: true
          )
          .disabled(!canSubmit)
          .opacity(canSubmit ? 1 : 0.85)
          .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 8)
      }
    }
    .onChange(of: customReferral) {
      hasSubmitted = false
    }
  }

  private var referralRows: [[ReferralOption]] {
    (randomizedOptions + [.other]).chunked(into: 2)
  }

  var canSubmit: Bool {
    guard let option = selectedReferral else { return false }
    if option.requiresDetail {
      return !customReferral.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    return true
  }

  private var submitBackground: Color {
    canSubmit
      ? Color(red: 0.25, green: 0.17, blue: 0)
      : Color(red: 0.88, green: 0.84, blue: 0.78)
  }

  @ViewBuilder
  private func referralOptionView(_ option: ReferralOption) -> some View {
    let isSelected = selectedReferral == option

    VStack(alignment: .leading, spacing: 0) {
      Button(action: { select(option) }) {
        HStack(spacing: 8) {
          Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
            .foregroundColor(Color(red: 0.25, green: 0.17, blue: 0))

          Text(option.displayName)
            .font(.custom("Figtree", size: 14))
            .foregroundColor(.black.opacity(0.78))

          Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isSelected ? Color(red: 1.0, green: 0.95, blue: 0.9) : Color.white)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(
              Color(red: 0.25, green: 0.17, blue: 0).opacity(isSelected ? 0.22 : 0.1), lineWidth: 1)
        )
      }
      .buttonStyle(PlainButtonStyle())
      .pointingHandCursor()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func select(_ option: ReferralOption) {
    selectedReferral = option
    hasSubmitted = false

    if !option.requiresDetail {
      customReferral = ""
    }
  }

  private var detailField: some View {
    TextField(currentDetailPlaceholder, text: customReferralBinding)
      .textFieldStyle(.plain)
      .font(.custom("Figtree", size: 13))
      .foregroundColor(Color(hex: "634D42"))
      .padding(.horizontal, 12)
      .frame(height: 34)
      .frame(maxWidth: .infinity)
      .background(Color.white.opacity(0.4))
      .cornerRadius(5)
      .overlay(
        RoundedRectangle(cornerRadius: 5)
          .stroke(Color(hex: "E4D3C2"), lineWidth: 1)
      )
      .shadow(
        color: Color(hex: "AF7246").opacity(0.15),
        radius: 2, x: 0, y: 0
      )
      .opacity(selectedReferral?.requiresDetail == true ? 1 : 0)
      .disabled(selectedReferral?.requiresDetail != true)
      .allowsHitTesting(selectedReferral?.requiresDetail == true)
      .padding(.top, 6)
  }

  private var currentDetailPlaceholder: String {
    selectedReferral?.detailPlaceholder ?? String(localized: "Tell me more")
  }

  private func handleSubmit() {
    guard canSubmit, let option = selectedReferral else { return }
    let trimmedDetail = customReferral.trimmingCharacters(in: .whitespacesAndNewlines)
    let detailToSend = option.requiresDetail ? trimmedDetail : nil

    onSubmit(option, detailToSend?.isEmpty == false ? detailToSend : nil)
    hasSubmitted = true
  }
}

enum ReferralOption: CaseIterable, Identifiable, Hashable {
  case hackerNews
  case x
  case friend
  case youtube
  case newsletterBlog
  case chatGPTClaudeAI
  case other

  var id: String { analyticsValue }

  static func randomizedConcreteOptions() -> [ReferralOption] {
    allCases.filter { $0 != .other }.shuffled()
  }

  var displayName: String {
    switch self {
    case .hackerNews: return String(localized: "Hacker News")
    case .x: return String(localized: "X / Twitter")
    case .friend: return String(localized: "Friend or colleague")
    case .youtube: return String(localized: "YouTube")
    case .newsletterBlog: return String(localized: "Newsletter or blog (which one?)")
    case .chatGPTClaudeAI: return String(localized: "ChatGPT / Claude / AI")
    case .other: return String(localized: "Other (please specify)")
    }
  }

  var analyticsValue: String {
    switch self {
    case .hackerNews: return "hacker_news"
    case .x: return "x"
    case .friend: return "friend"
    case .youtube: return "youtube"
    case .newsletterBlog: return "newsletter_blog"
    case .chatGPTClaudeAI: return "chatgpt_claude_ai"
    case .other: return "other"
    }
  }

  var requiresDetail: Bool {
    switch self {
    case .youtube, .newsletterBlog, .chatGPTClaudeAI, .other:
      return true
    default:
      return false
    }
  }

  var detailPlaceholder: String {
    switch self {
    case .newsletterBlog:
      return String(localized: "Which newsletter or blog?")
    case .youtube:
      return String(localized: "Which channel?")
    case .chatGPTClaudeAI:
      return String(localized: "What did you ask ChatGPT or Claude that led you to Dayflow?")
    case .other:
      return String(localized: "Where did you hear about Dayflow?")
    default:
      return ""
    }
  }
}

extension Array {
  fileprivate func chunked(into size: Int) -> [[Element]] {
    stride(from: 0, to: count, by: size).map { startIndex in
      Array(self[startIndex..<Swift.min(startIndex + size, count)])
    }
  }
}
