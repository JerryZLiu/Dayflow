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
    @State private var hasSubmitted = false

    @Binding private var selectedReferral: ReferralOption?
    @Binding private var customReferral: String

    init(
        prompt: String,
        submitLabel: String = "Submit",
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
            _selectedReferral = selectedReferral
            _customReferral = customReferral
        } else {
            _selectedReferral = _internalSelectedReferral.projectedValue
            _customReferral = _internalCustomReferral.projectedValue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(prompt)
                .font(.custom("Nunito", size: 15).weight(.semibold))
                .foregroundColor(.black.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                ForEach(Array(referralRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 12) {
                        ForEach(row, id: \.id) { option in
                            referralOptionView(option)
                        }

                        if row.count == 1 {
                            Spacer(minLength: 0)
                        }
                    }
                }
            }

            detailField

            if showsThankYou && hasSubmitted {
                Label("Thanks for letting me know!", systemImage: "checkmark.circle.fill")
                    .font(.custom("Nunito", size: 14))
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
                                .font(.custom("Nunito", size: 16))
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
        [
            [.hackerNews, .x],
            [.friend, .youtube],
            [.newsletterBlog, .other]
        ]
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
                        .font(.custom("Nunito", size: 14))
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
                        .stroke(Color(red: 0.25, green: 0.17, blue: 0).opacity(isSelected ? 0.22 : 0.1), lineWidth: 1)
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
        TextField(currentDetailPlaceholder, text: $customReferral)
            .textFieldStyle(RoundedBorderTextFieldStyle())
            .font(.custom("Nunito", size: 13))
            .opacity(selectedReferral?.requiresDetail == true ? 1 : 0)
            .disabled(selectedReferral?.requiresDetail != true)
            .allowsHitTesting(selectedReferral?.requiresDetail == true)
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.top, 6)
    }

    private var currentDetailPlaceholder: String {
        selectedReferral?.detailPlaceholder ?? "Tell me more"
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
    case other

    var id: String { analyticsValue }

    var displayName: String {
        switch self {
        case .hackerNews: return "Hacker News"
        case .x: return "X / Twitter"
        case .friend: return "Friend or colleague"
        case .youtube: return "YouTube"
        case .newsletterBlog: return "Newsletter or blog (which one?)"
        case .other: return "Something else"
        }
    }

    var analyticsValue: String {
        switch self {
        case .hackerNews: return "hacker_news"
        case .x: return "x"
        case .friend: return "friend"
        case .youtube: return "youtube"
        case .newsletterBlog: return "newsletter_blog"
        case .other: return "other"
        }
    }

    var requiresDetail: Bool {
        switch self {
        case .youtube, .newsletterBlog, .other:
            return true
        default:
            return false
        }
    }

    var detailPlaceholder: String {
        switch self {
        case .newsletterBlog:
            return "Which newsletter or blog?"
        case .youtube:
            return "Which channel?"
        case .other:
            return "Tell me more"
        default:
            return ""
        }
    }
}
