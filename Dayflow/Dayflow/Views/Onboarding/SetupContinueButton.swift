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

  @State private var isPressed = false
  @State private var isHovered = false

  init(title: String = "Continue", isEnabled: Bool = true, action: @escaping () -> Void) {
    self.title = title
    self.isEnabled = isEnabled
    self.action = action
  }

  var body: some View {
    Button(action: isEnabled ? action : {}) {
      HStack(alignment: .center, spacing: 8) {
        Text(title)
          .font(.custom("Nunito", size: 16))
          .fontWeight(.semibold)
          .foregroundColor(.white)
      }
      .padding(.horizontal, 59)
      .padding(.vertical, 18)
      .frame(width: 160, alignment: .center)
      .background(
        Color(red: 0.25, green: 0.17, blue: 0)
      )
      .cornerRadius(12)
      .shadow(color: .black.opacity(0.25), radius: 0.25, x: 0, y: 0.5)
      .shadow(color: .black.opacity(0.16), radius: 0.5, x: 0, y: 1)
      .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 2)
      .overlay(
        RoundedRectangle(cornerRadius: 12)
          .inset(by: 0.75)
          .stroke(.white.opacity(0.17), lineWidth: 1.5)
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
