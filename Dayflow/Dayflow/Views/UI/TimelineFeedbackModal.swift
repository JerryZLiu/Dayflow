//
//  TimelineFeedbackModal.swift
//  Dayflow
//
//  Feedback card shown after rating a timeline summary.
//

import SwiftUI

enum TimelineFeedbackMode {
    case form
    case thanks
}

struct TimelineFeedbackModal: View {
    @Binding var message: String
    @Binding var shareLogs: Bool
    let direction: TimelineRatingDirection
    let mode: TimelineFeedbackMode
    let onSubmit: () -> Void
    let onClose: () -> Void

    @FocusState private var isEditorFocused: Bool

    private let placeholder = "I don’t have access to your timeline (privacy first!), so your feedback here helps improve the quality of Dayflow for everyone."

    var body: some View {
        ZStack(alignment: .topTrailing) {
            modalCard

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Color(hex: "FF8046").opacity(0.7))
                    .frame(width: 22, height: 22)
                    .background(Color.white.opacity(0.9))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .offset(x: -8, y: 6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline feedback form")
        .accessibilityHint("Share more context after rating this summary.")
    }

    @ViewBuilder
    private var modalCard: some View {
        VStack(spacing: mode == .form ? 20 : 24) {
            switch mode {
            case .form:
                formContent
            case .thanks:
                thanksContent
            }
        }
        .padding(24)
        .frame(width: 286)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color(hex: "FFF4E9"), location: 0),
                            .init(color: Color.white, location: 0.85)
                        ]),
                        startPoint: .bottom,
                        endPoint: .top
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(hex: "ECECEC"), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.07), radius: 12, x: 0, y: 6)
    }

    private var formContent: some View {
        VStack(spacing: 16) {
            VStack(spacing: 12) {
                Text("Thank you!")
                    .font(Font.custom("InstrumentSerif-Regular", size: 18))
                    .foregroundColor(Color(hex: "333333"))
                    .multilineTextAlignment(.center)

                Text("Tell us more about your feedback")
                    .font(Font.custom("Nunito", size: 13).weight(.medium))
                    .foregroundColor(Color(hex: "333333"))
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 8) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $message)
                        .font(Font.custom("Nunito", size: 12).weight(.medium))
                        .foregroundColor(Color(hex: "333333"))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                        .background(Color.white)
                        .frame(height: 90)
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(hex: "D9D9D9"), lineWidth: 1)
                        )
                        .focused($isEditorFocused)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                isEditorFocused = true
                            }
                        }
                        .scrollContentBackground(.hidden)

                    if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(placeholder)
                            .font(Font.custom("Nunito", size: 12).weight(.medium))
                            .foregroundColor(Color(hex: "AAAAAA"))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                    }
                }

                Button {
                    shareLogs.toggle()
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(Color(hex: "FF8046"), lineWidth: shareLogs ? 0 : 1)
                            .frame(width: 14, height: 14)
                            .overlay(
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.white)
                                    .opacity(shareLogs ? 1 : 0)
                            )
                            .background(
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(shareLogs ? Color(hex: "FF8046") : Color.clear)
                            )

                        Text("I’d like to share this log to the developer to help improve the product.")
                            .font(Font.custom("Nunito", size: 10).weight(.medium))
                            .foregroundColor(Color.black)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            Button(action: onSubmit) {
                Text("Submit")
                    .font(Font.custom("Nunito", size: 12).weight(.medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(Color(hex: "FF8046"))
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
    }

    private var thanksContent: some View {
        VStack(spacing: 20) {
            Text("Thank you for your feedback!")
                .font(Font.custom("InstrumentSerif-Regular", size: 18))
                .foregroundColor(Color(hex: "333333"))
                .multilineTextAlignment(.center)
                .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 12) {
                Text("If you find that your activities are summarized inaccurately, try editing the descriptions of your categories to improve Dayflow’s accuracy.")
                    .font(Font.custom("Nunito", size: 12).weight(.medium))
                    .foregroundColor(Color(hex: "333333"))
                    .multilineTextAlignment(.leading)

                categoryTipsIllustration
            }
        }
    }
}

extension TimelineFeedbackModal {
    private var categoryTipsIllustration: some View {
        Image("CategoryEditUI")
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.7), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 6)
            .accessibilityLabel("Illustration showing how to edit categories")
    }
}

#Preview {
    TimelineFeedbackModal(
        message: .constant(""),
        shareLogs: .constant(true),
        direction: .up,
        mode: .form,
        onSubmit: {},
        onClose: {}
    )
    .padding()
    .background(Color.gray.opacity(0.1))

    TimelineFeedbackModal(
        message: .constant(""),
        shareLogs: .constant(true),
        direction: .up,
        mode: .thanks,
        onSubmit: {},
        onClose: {}
    )
    .padding()
    .background(Color.gray.opacity(0.1))
}
