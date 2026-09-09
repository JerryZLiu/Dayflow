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

struct FeedbackModalContent {
  let accessibilityLabel: String
  let accessibilityHint: String
  let formTitle: String
  let formSubtitle: String
  let placeholder: String
  let shareLogsLabel: String
  let submitButtonTitle: String
  let thanksTitle: String
  let thanksBody: String?
  let illustrationImageName: String?
  let illustrationAccessibilityLabel: String?

  static let timeline = FeedbackModalContent(
    accessibilityLabel: "Timeline feedback form",
    accessibilityHint: "Share more context after rating this summary.",
    formTitle: "Thank you!",
    formSubtitle: "Tell us more about your feedback",
    placeholder:
      "I don't have access to your timeline (privacy first!), so your feedback here helps improve the quality of Dayflow for everyone.",
    shareLogsLabel: "I'd like to share this log to the developer to help improve the product.",
    submitButtonTitle: "Submit",
    thanksTitle: "Thank you for your feedback!",
    thanksBody:
      "If you find that your activities are summarized inaccurately, try editing the descriptions of your categories to improve Dayflow's accuracy.",
    illustrationImageName: "CategoryEditUI",
    illustrationAccessibilityLabel: "Illustration showing how to edit categories"
  )

  static let chat = FeedbackModalContent(
    accessibilityLabel: "Chat feedback form",
    accessibilityHint: "Share more context after rating this chat answer.",
    formTitle: "Thanks for the report",
    formSubtitle: "Tell us what went wrong",
    placeholder:
      "What was wrong with this answer? If you're comfortable, include what you expected instead.",
    shareLogsLabel:
      "I'd like to share this answer and related logs with the developer to help improve the product.",
    submitButtonTitle: "Submit",
    thanksTitle: "Thank you for your feedback!",
    thanksBody: "Your note will help improve future Dashboard answers.",
    illustrationImageName: nil,
    illustrationAccessibilityLabel: nil
  )
}

struct TimelineFeedbackModal: View {
  @Binding var message: String
  @Binding var shareLogs: Bool
  let direction: TimelineRatingDirection
  let mode: TimelineFeedbackMode
  let content: FeedbackModalContent
  let onSubmit: () -> Void
  let onClose: () -> Void

  @FocusState private var isEditorFocused: Bool
  @Environment(\.dayflowTheme) private var theme

  var body: some View {
    ZStack(alignment: .topTrailing) {
      modalCard

      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 12.5, weight: .semibold))
          .foregroundColor(theme.isDark ? Color(hex: "C9CBD6") : Color(hex: "FF8046").opacity(0.7))
          .frame(width: 22, height: 22)
          .background(theme.isDark ? Color.clear : Color.white.opacity(0.9))
          .clipShape(Circle())
      }
      .buttonStyle(.plain)
      .pointingHandCursor()
      .offset(x: -8, y: 6)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(content.accessibilityLabel))
    .accessibilityHint(Text(content.accessibilityHint))
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
        .fill(cardFill)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(theme.isDark ? Color(hex: "585858") : Color(hex: "ECECEC"), lineWidth: 1)
    )
    .shadow(
      color: Color.black.opacity(theme.isDark ? 0.35 : 0.07), radius: 12, x: 0, y: 6)
  }

  private var cardFill: AnyShapeStyle {
    if theme.isDark {
      return AnyShapeStyle(
        LinearGradient(
          gradient: Gradient(stops: [
            .init(color: Color(hex: "272F43"), location: 0),
            .init(color: Color(hex: "272F43"), location: 0.3),
            .init(color: Color(hex: "3F3D52"), location: 0.85),
          ]),
          startPoint: .bottom,
          endPoint: .top
        )
      )
    }
    return AnyShapeStyle(
      LinearGradient(
        gradient: Gradient(stops: [
          .init(color: Color(hex: "FFF4E9"), location: 0),
          .init(color: Color.white, location: 0.85),
        ]),
        startPoint: .bottom,
        endPoint: .top
      )
    )
  }

  private var primaryText: Color {
    theme.isDark ? .white : Color(hex: "333333")
  }

  private var formContent: some View {
    VStack(spacing: 16) {
      VStack(spacing: 12) {
        Text(content.formTitle)
          .font(Font.custom("InstrumentSerif-Regular", size: 18))
          .foregroundColor(primaryText)
          .multilineTextAlignment(.center)

        Text(content.formSubtitle)
          .font(Font.custom("Figtree", size: 14))
          .foregroundColor(primaryText)
          .multilineTextAlignment(.center)
      }

      VStack(spacing: 8) {
        ZStack(alignment: .topLeading) {
          TextEditor(text: $message)
            .font(Font.custom("Figtree", size: 12))
            .foregroundColor(primaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .background(theme.isDark ? Color.white.opacity(0.06) : Color.white)
            .frame(height: 90)
            .cornerRadius(4)
            .overlay(
              RoundedRectangle(cornerRadius: 4)
                .stroke(theme.isDark ? Color(hex: "5C5F70") : Color(hex: "D9D9D9"), lineWidth: 1)
            )
            .background(ThinScrollerInstaller())
            .focused($isEditorFocused)
            .onAppear {
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isEditorFocused = true
              }
            }
            .scrollContentBackground(.hidden)

          if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(content.placeholder)
              .font(Font.custom("Figtree", size: 12))
              .foregroundColor(theme.isDark ? Color(hex: "9BA0B0") : Color(hex: "AAAAAA"))
              .padding(.horizontal, 12)
              .padding(.vertical, 12)
          }
        }

        Button {
          shareLogs.toggle()
        } label: {
          HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
              .stroke(Color(hex: "AAAAAA"), lineWidth: shareLogs ? 0 : 1)
              .frame(width: 14, height: 14)
              .overlay(
                Image(systemName: "checkmark")
                  .font(.system(size: 8, weight: .bold))
                  .foregroundColor(.white)
                  .opacity(shareLogs ? 1 : 0)
              )
              .background(
                RoundedRectangle(cornerRadius: 2)
                  .fill(
                    shareLogs
                      ? (theme.isDark ? Color(hex: "D1653E") : Color(hex: "FF8046"))
                      : Color.clear)
              )

            Text(content.shareLogsLabel)
              .font(Font.custom("Figtree", size: 12))
              .foregroundColor(theme.isDark ? Color.white : Color.black)
              .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
      }

      Button(action: onSubmit) {
        // Matches the paused pill's "Resume" button chrome.
        Text(content.submitButtonTitle)
          .font(Font.custom("Figtree", size: 12))
          .foregroundColor(theme.primaryButtonText)
          .frame(maxWidth: .infinity)
          .frame(height: 32)
          .background(theme.primaryButtonFill)
          .overlay(InnerGlow(shape: Capsule(), color: theme.primaryButtonInnerGlow, radius: 3))
          .overlay(Capsule().strokeBorder(theme.primaryButtonBorder, lineWidth: 1))
          .clipShape(Capsule())
      }
      .buttonStyle(.plain)
      .pointingHandCursor()
    }
  }

  private var thanksContent: some View {
    VStack(spacing: 20) {
      Text(content.thanksTitle)
        .font(Font.custom("InstrumentSerif-Regular", size: 18))
        .foregroundColor(primaryText)
        .multilineTextAlignment(.center)
        .padding(.bottom, 4)

      VStack(alignment: .leading, spacing: 12) {
        if let thanksBody = content.thanksBody {
          Text(thanksBody)
            .font(Font.custom("Figtree", size: 12))
            .foregroundColor(primaryText)
            .multilineTextAlignment(.leading)
        }

        if let illustrationImageName = content.illustrationImageName {
          feedbackIllustration(
            imageName: illustrationImageName,
            accessibilityLabel: content.illustrationAccessibilityLabel
          )
        }
      }
    }
  }
}

extension TimelineFeedbackModal {
  private func feedbackIllustration(imageName: String, accessibilityLabel: String?) -> some View {
    Image(imageName)
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
      .accessibilityLabel(Text(accessibilityLabel ?? "Feedback illustration"))
  }
}

// MARK: - Thin scroll bar for the feedback text editor

/// Draws the vertical scroller knob at half the standard width.
private final class ThinFeedbackScroller: NSScroller {
  override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

  override func drawKnob() {
    let knob = rect(for: .knob)
    guard knob.width > 0, knob.height > 0 else { return }
    let width = knob.width * 0.5
    let knobRect = NSRect(x: knob.midX - width / 2, y: knob.minY, width: width, height: knob.height)
    let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    (isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.4).setFill()
    NSBezierPath(roundedRect: knobRect, xRadius: width / 2, yRadius: width / 2).fill()
  }
}

/// Finds the `TextEditor`'s enclosing scroll view and swaps in the thin scroller.
private struct ThinScrollerInstaller: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async { install(near: view) }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async { install(near: nsView) }
  }

  private func install(near view: NSView) {
    var ancestor = view.superview
    var hops = 0
    while let current = ancestor, hops < 6 {
      if let scrollView = textEditorScrollView(in: current) {
        if !(scrollView.verticalScroller is ThinFeedbackScroller) {
          scrollView.verticalScroller = ThinFeedbackScroller()
        }
        return
      }
      ancestor = current.superview
      hops += 1
    }
  }

  private func textEditorScrollView(in view: NSView) -> NSScrollView? {
    if let scrollView = view as? NSScrollView, scrollView.documentView is NSTextView {
      return scrollView
    }
    for subview in view.subviews {
      if let found = textEditorScrollView(in: subview) { return found }
    }
    return nil
  }
}

#Preview {
  TimelineFeedbackModal(
    message: .constant(""),
    shareLogs: .constant(true),
    direction: .up,
    mode: .form,
    content: .timeline,
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
    content: .timeline,
    onSubmit: {},
    onClose: {}
  )
  .padding()
  .background(Color.gray.opacity(0.1))
}
