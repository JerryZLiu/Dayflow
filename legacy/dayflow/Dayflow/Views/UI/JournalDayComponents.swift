//
//  JournalDayComponents.swift
//  Dayflow
//
//  Shared building blocks for the journal: motion modifiers, design tokens,
//  and small controls used across the journal screens.
//

import SwiftUI

// MARK: - Motion Modifiers & Transitions

struct BookFlipModifier: ViewModifier {
  let angle: Double
  let anchor: UnitPoint

  func body(content: Content) -> some View {
    content
      .rotation3DEffect(
        .degrees(angle),
        axis: (x: 0, y: 1, z: 0),
        anchor: anchor,
        anchorZ: 0,
        perspective: 0.5
      )
      .opacity(abs(angle) > 89 ? 0 : 1)
      .overlay(
        Color.black
          .opacity(calculateShadowOpacity(angle: angle))
          .allowsHitTesting(false)
      )
  }

  private func calculateShadowOpacity(angle: Double) -> Double {
    let progress = abs(angle) / 90.0
    return progress * 0.15
  }
}

extension AnyTransition {
  static var bookFlipNext: AnyTransition {
    .asymmetric(
      insertion: .modifier(
        active: BookFlipModifier(angle: 90, anchor: .leading),
        identity: BookFlipModifier(angle: 0, anchor: .leading)
      ),
      removal: .modifier(
        active: BookFlipModifier(angle: -90, anchor: .trailing),
        identity: BookFlipModifier(angle: 0, anchor: .trailing)
      )
    )
  }

  static var bookFlipPrev: AnyTransition {
    .asymmetric(
      insertion: .modifier(
        active: BookFlipModifier(angle: -90, anchor: .trailing),
        identity: BookFlipModifier(angle: 0, anchor: .trailing)
      ),
      removal: .modifier(
        active: BookFlipModifier(angle: 90, anchor: .leading),
        identity: BookFlipModifier(angle: 0, anchor: .leading)
      )
    )
  }
}

struct WetInkText: View {
  let text: String
  var font: Font = .custom("Figtree-Regular", size: 15)
  var color: Color = Color(red: 0.18, green: 0.11, blue: 0.06)
  var lineHeight: CGFloat = 5

  @State private var displayedText: String = ""
  @State private var isComplete: Bool = false

  var body: some View {
    Text(displayedText)
      .font(font)
      .foregroundStyle(color.opacity(isComplete ? 1.0 : 0.8))
      .lineSpacing(lineHeight)
      .blur(radius: isComplete ? 0 : 0.2)
      .animation(.easeOut(duration: 0.5), value: isComplete)
      .onAppear {
        typewriterEffect()
      }
      .onChange(of: text) {
        typewriterEffect()
      }
  }

  private func typewriterEffect() {
    displayedText = ""
    isComplete = false

    let chars = Array(text)
    var currentIndex = 0

    func nextChar() {
      guard currentIndex < chars.count else {
        isComplete = true
        return
      }

      displayedText.append(chars[currentIndex])
      currentIndex += 1

      let char = chars[currentIndex - 1]
      var delay: Double = Double.random(in: 0.01...0.03)

      if char == "." || char == "," || char == "\n" {
        delay += 0.15
      }

      DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        nextChar()
      }
    }

    nextChar()
  }
}

struct JournalPillButtonStyle: ButtonStyle {
  var horizontalPadding: CGFloat = 18
  var verticalPadding: CGFloat = 9
  var font: Font = .custom("Figtree-SemiBold", size: 16)

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(font)
      .foregroundStyle(JournalDayTokens.primaryText.opacity(0.8))
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, verticalPadding)
      .background(Color(red: 1, green: 0.96, blue: 0.92).opacity(0.6))
      .cornerRadius(100)
      .overlay(
        RoundedRectangle(cornerRadius: 100)
          .inset(by: 0.5)
          .stroke(Color(red: 0.95, green: 0.86, blue: 0.84), lineWidth: 1)
      )
      .dayflowPressScale(
        configuration.isPressed,
        pressedScale: 0.96,
        animation: .spring(response: 0.3, dampingFraction: 0.6)
      )
      .pointingHandCursor()
  }
}

struct PaperHoverEffect: ViewModifier {
  @State private var isHovered = false
  var isEnabled: Bool

  func body(content: Content) -> some View {
    content
      .scaleEffect(isHovered && isEnabled ? 1.01 : 1.0)
      .shadow(
        color: Color.black.opacity(isHovered && isEnabled ? 0.12 : 0.0),
        radius: isHovered && isEnabled ? 12 : 0,
        x: 0,
        y: isHovered && isEnabled ? 4 : 0
      )
      .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
      .onHover { hovering in
        isHovered = hovering
      }
  }
}

extension View {
  @ViewBuilder func applyIf<Content: View>(_ condition: Bool, transform: (Self) -> Content)
    -> some View
  {
    if condition {
      transform(self)
    } else {
      self
    }
  }
}

// MARK: - Small Controls

struct JournalDayBulletList: View {
  let items: [String]
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(items, id: \.self) { item in
        HStack(alignment: .top, spacing: 8) {
          Circle().fill(JournalDayTokens.bullet).frame(width: 6, height: 6).padding(.top, 6)
          Text(item).font(.custom("Figtree-Regular", size: 15)).foregroundStyle(
            JournalDayTokens.bodyText
          ).fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}

struct JournalDayCircleButton: View {
  enum Direction { case left, right }
  var direction: Direction
  var isDisabled: Bool = false
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      ZStack {
        Circle().fill(JournalDayTokens.navCircleFill)
        Circle().stroke(JournalDayTokens.navCircleStroke, lineWidth: 1)
        Image("JournalArrow")
          .renderingMode(.template).resizable().aspectRatio(contentMode: .fit)
          .frame(width: 9, height: 9)
          .foregroundStyle(JournalDayTokens.navArrow.opacity(isDisabled ? 0.35 : 1))
          .scaleEffect(x: direction == .right ? -1 : 1, y: 1)
      }
      .frame(width: 26, height: 26)
      .shadow(color: JournalDayTokens.navCircleShadow, radius: 2, x: 0, y: 0)
      .opacity(isDisabled ? 0.55 : 1)
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .pointingHandCursor(enabled: !isDisabled)
  }
}

struct JournalDaySegmentedControl: View {
  @Binding var selection: JournalDayViewPeriod
  var body: some View {
    HStack(alignment: .center, spacing: 2) {
      ForEach(JournalDayViewPeriod.allCases) { option in
        Button(action: { selection = option }) {
          Text(option.rawValue)
            .font(.custom("Figtree-Regular", size: 12))
            .tracking(-0.12)
            .foregroundStyle(
              selection == option ? Color.white : JournalDayTokens.segmentInactiveText
            )
            .padding(.horizontal, 14).padding(.vertical, 4)
            .frame(width: 64, alignment: .center)
            .background(
              selection == option
                ? JournalDayTokens.segmentActiveFill : JournalDayTokens.segmentInactiveFill
            )
            .cornerRadius(200)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
      }
    }
    .padding(2)
    .background(
      Capsule().fill(JournalDayTokens.segmentContainerFill).overlay(
        Capsule().inset(by: 0.5).stroke(Color.white.opacity(0.6), lineWidth: 1))
    )
    .shadow(color: Color.black.opacity(0.10), radius: 2, x: 0, y: 1)
  }
}

// MARK: - Flow Types & Tokens

enum JournalFlowState: CaseIterable {
  case intro, summary, intentionsEdit, reflectionPrompt, reflectionEdit, reflectionSaved,
    boardComplete
  var label: String { "" }
}

enum JournalDayViewPeriod: String, CaseIterable, Identifiable {
  case day = "Day"
  case week = "Week"
  var id: String { rawValue }
}

enum JournalDayTokens {
  static let primaryText = Color(red: 0.18, green: 0.09, blue: 0.03)
  static let reminderText = Color(red: 0.35, green: 0.20, blue: 0.05)
  static let bodyText = Color(red: 0.18, green: 0.11, blue: 0.06)
  static let bullet = Color(red: 0.96, green: 0.57, blue: 0.24)
  static let sectionHeader = Color(red: 0.85, green: 0.44, blue: 0.04)
  static let divider = Color(red: 0.90, green: 0.85, blue: 0.80)
  static let navCircleFill = Color(red: 0.996, green: 0.976, blue: 0.953)
  static let navCircleStroke = Color.white
  static let navCircleShadow = Color.black.opacity(0.04)
  static let navArrow = Color(red: 1.0, green: 0.74, blue: 0.35)
  static let segmentActiveFill = Color(red: 1, green: 0.72, blue: 0.35)
  static let segmentInactiveFill = Color(red: 0.95, green: 0.94, blue: 0.93)
  static let segmentInactiveText = Color(red: 0.80, green: 0.78, blue: 0.77)
  static let segmentContainerFill = Color(red: 1.0, green: 0.976, blue: 0.953)
}
