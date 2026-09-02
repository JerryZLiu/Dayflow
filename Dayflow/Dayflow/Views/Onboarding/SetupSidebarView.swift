//
//  SetupSidebarView.swift
//  Dayflow
//
//  Sidebar navigation for LLM provider setup flow
//

import SwiftUI

struct SetupSidebarView: View {
  let steps: [SetupStep]
  let currentStepId: String
  let onStepSelected: (String) -> Void

  @Namespace private var selectionNamespace

  var body: some View {
    // Just the steps list - no extra VStack or ScrollView
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
        SetupSidebarItem(
          title: step.title,
          isSelected: step.id == currentStepId,
          isCompleted: isStepCompleted(step: step, currentId: currentStepId, in: steps),
          namespace: selectionNamespace,
          onTap: {
            onStepSelected(step.id)
          }
        )
      }
    }
    .padding(.horizontal, 20)
    .frame(maxWidth: .infinity)
  }

  private func isStepCompleted(step: SetupStep, currentId: String, in steps: [SetupStep]) -> Bool {
    guard let currentIndex = steps.firstIndex(where: { $0.id == currentId }),
      let stepIndex = steps.firstIndex(where: { $0.id == step.id })
    else {
      return false
    }
    return stepIndex < currentIndex || step.isCompleted
  }
}

struct SetupSidebarItem: View {
  let title: String
  let isSelected: Bool
  let isCompleted: Bool
  let namespace: Namespace.ID
  let onTap: () -> Void

  @State private var isHovered = false

  private let textColor = Color(hex: "634342")

  var body: some View {
    Button(action: onTap) {
      HStack(alignment: .center, spacing: 8) {
        Group {
          if isCompleted && !isSelected {
            Image(systemName: "checkmark.circle")
              .font(.system(size: 14, weight: .medium))
              .foregroundColor(textColor)
          } else if isSelected {
            Image(systemName: "chevron.right")
              .font(.system(size: 14, weight: .medium))
              .foregroundColor(textColor)
          } else {
            Color.clear
          }
        }
        .frame(width: 20, height: 20)

        Text(title)
          .font(.custom("Figtree", size: 16))
          .fontWeight(.medium)
          .foregroundColor(textColor)
          .opacity(isSelected || isCompleted ? 1 : 0.5)

        Spacer()
      }
      .padding(.leading, 10)
      .padding(.trailing, 16)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .background(selectedBackground)
    }
    .buttonStyle(DayflowPressScaleButtonStyle(pressedScale: 0.97))
    .pointingHandCursor()
    .scaleEffect(isHovered && !isSelected ? 1.02 : 1.0)
    .animation(.spring(response: 0.3, dampingFraction: 0.9), value: isSelected)
    .animation(.easeOut(duration: 0.2), value: isHovered)
    .onHover { hovering in
      isHovered = hovering
    }
  }

  @ViewBuilder
  private var selectedBackground: some View {
    if isSelected {
      let shape = RoundedRectangle(cornerRadius: 10)
      shape
        .fill(Color(hex: "FFFAF8"))
        .overlay(InnerGlow(shape: shape, color: .white, radius: 4))
        .overlay(shape.strokeBorder(Color(hex: "FFB693"), lineWidth: 1))
        .shadow(color: Color(hex: "D5D3D9"), radius: 2, x: 0, y: 1)
        .matchedGeometryEffect(id: "selection", in: namespace)
    }
  }
}
