//
//  SetupContinueButton.swift
//  Dayflow
//
//  Continue button for setup flow with exact Figma styling
//

import SwiftUI

struct SetupContinueButton: View {
  let title: String
  let isEnabled: Bool
  let action: () -> Void

  @Environment(\.dayflowTheme) private var theme
  @State private var isPressed = false
  @State private var isHovered = false

  init(title: String = "Continue", isEnabled: Bool = true, action: @escaping () -> Void) {
    self.title = title
    self.isEnabled = isEnabled
    self.action = action
  }

  var body: some View {
    Button(action: isEnabled ? action : {}) {
      HStack(alignment: .center, spacing: 6) {
        Text(title)
          .font(.custom("Figtree", size: 14))
          .fontWeight(.regular)
        Image(systemName: "chevron.right")
          .font(.system(size: 12, weight: .medium))
      }
      .foregroundColor(.white)
      .padding(.leading, 36)
      .padding(.trailing, 32)
      .frame(height: 44)
      .background(theme.primaryButtonFill)
      .cornerRadius(200)
      .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
      .overlay(
        Capsule()
          .inset(by: 0.25)
          .stroke(theme.primaryButtonBorder, lineWidth: 0.5)
      )
      .overlay(
        InnerGlow(shape: Capsule(), color: theme.primaryButtonInnerGlow, radius: 3)
      )
      .opacity(isEnabled ? 1.0 : 0.4)
    }
    .buttonStyle(.plain)
    .scaleEffect(isPressed ? 0.96 : (isHovered && isEnabled ? 1.02 : 1.0))
    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isPressed)
    .animation(.easeOut(duration: 0.2), value: isHovered)
    .onHover { hovering in
      if isEnabled {
        isHovered = hovering
      }
    }
    .simultaneousGesture(
      DragGesture(minimumDistance: 0)
        .onChanged { _ in
          if isEnabled {
            isPressed = true
          }
        }
        .onEnded { _ in
          isPressed = false
        }
    )
    .disabled(!isEnabled)
    .pointingHandCursor(enabled: isEnabled)
  }
}
