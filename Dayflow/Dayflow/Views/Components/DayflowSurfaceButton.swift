//
//  DayflowSurfaceButton.swift
//  Dayflow
//
//  Generic content button with unified Emil‑style hover/press interactions
//

import SwiftUI

struct DayflowSurfaceButton<Content: View>: View {
  let action: () -> Void
  @ViewBuilder let content: () -> Content

  var background: Color = .white
  var foreground: Color = .black
  var borderColor: Color = .black.opacity(0.15)
  var cornerRadius: CGFloat = 0
  var horizontalPadding: CGFloat = 18
  var verticalPadding: CGFloat = 12
  var minWidth: CGFloat? = nil
  var showShadow: Bool = true
  var showOverlayStroke: Bool = false  // New parameter for white overlay stroke
  var isSecondaryStyle: Bool = false  // New parameter for white/secondary buttons

  @State private var isHovered = false
  @State private var isPressed = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private let hoverAnim = Animation.spring(response: 0.22, dampingFraction: 0.85)
  private let pressAnim = Animation.spring(response: 0.26, dampingFraction: 0.75)

  var body: some View {
    Button(action: {
      withAnimation(pressAnim) { isPressed = true }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
        withAnimation(pressAnim) { isPressed = false }
        action()
      }
    }) {
      HStack(spacing: 10) {
        content()
          .foregroundColor(foreground.opacity(0.85))
      }
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, verticalPadding)
      .frame(minWidth: minWidth)
      .background(background)
      .overlay(
        Group {
          if isSecondaryStyle {
            RoundedRectangle(cornerRadius: cornerRadius)
              .inset(by: 0.75)
              .stroke(Color(red: 0.25, green: 0.17, blue: 0), lineWidth: 1.5)
          } else if showOverlayStroke {
            RoundedRectangle(cornerRadius: cornerRadius)
              .inset(by: 0.75)
              .stroke(.white.opacity(0.17), lineWidth: 1.5)
          } else {
            RoundedRectangle(cornerRadius: cornerRadius)
              .inset(by: 0.5)
              .stroke(isHovered ? borderColor.opacity(1.0) : borderColor, lineWidth: 1)
          }
        }
      )
      .cornerRadius(cornerRadius)
      .if(isSecondaryStyle) { view in
        view
          .shadow(color: .black.opacity(0.25), radius: 0.25, x: 0, y: 0.5)
          .shadow(color: .black.opacity(0.16), radius: 0.5, x: 0, y: 1)
          .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 2)
      }
      .if(!isSecondaryStyle) { view in
        view
          .shadow(
            color: .black.opacity(showShadow ? (isHovered ? 0.10 : 0.06) : 0),
            radius: isHovered ? 8 : 4, x: 0, y: isHovered ? 4 : 2
          )
          .shadow(
            color: .black.opacity(showShadow ? (isHovered ? 0.06 : 0.04) : 0),
            radius: isHovered ? 2 : 1, x: 0, y: 1)
      }
      .brightness(isPressed ? -0.04 : (isHovered ? 0.02 : 0))
      .scaleEffect(reduceMotion ? 1.0 : (isPressed ? 0.985 : (isHovered ? 1.02 : 1.0)))
      .offset(y: reduceMotion ? 0 : (isHovered ? -1 : 0))
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      withAnimation(hoverAnim) { isHovered = hovering }
    }
    .pointingHandCursor()
  }
}
