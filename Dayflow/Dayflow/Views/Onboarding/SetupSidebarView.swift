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
    .background(
      ZStack {
        // Subtle base color
        Color.white.opacity(0.03)

        // Angular gradient overlay
        RoundedRectangle(cornerRadius: 8)
          .stroke(
            AngularGradient(
              stops: [
                // Loop closed - same color at 0.0 and 1.0
                .init(color: Color(hex: "FFF1D3").opacity(0.15), location: 0.00),

                .init(color: Color(hex: "FF8904").opacity(0.15), location: 0.03),
                .init(color: Color(hex: "FF8904").opacity(0.10), location: 0.09),
                .init(color: .white.opacity(0.05), location: 0.17),
                .init(color: .white.opacity(0.03), location: 0.23),
                .init(color: .white.opacity(0.02), location: 0.25),
                .init(color: .white.opacity(0.02), location: 0.30),
                .init(color: Color(hex: "FF8904").opacity(0.10), location: 0.52),
                .init(color: Color(hex: "FFE0A5").opacity(0.20), location: 0.58),
                .init(color: .white.opacity(0.05), location: 0.80),
                .init(color: Color(hex: "FFF1D3").opacity(0.15), location: 0.91),

                // Mirror the first stop so 1.0 == 0.0
                .init(color: Color(hex: "FFF1D3").opacity(0.15), location: 1.00),
              ],
              center: .center,
              startAngle: .degrees(0),
              endAngle: .degrees(360)
            ),
            lineWidth: 1
          )
          .padding(1)
          .opacity(0.5)  // Make it subtle for the background
      }
    )
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

  var body: some View {
    Button(action: onTap) {
      HStack(alignment: .center, spacing: 12) {
        // Step indicator - fixed width for consistent alignment
        Group {
          if isCompleted && !isSelected {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 14))
              .foregroundColor(Color(red: 0.34, green: 1, blue: 0.45))
          } else if isSelected {
            Image(systemName: "chevron.right")
              .font(.system(size: 12, weight: .semibold))
              .foregroundColor(Color(hex: "492304"))
          } else {
            Color.clear  // Placeholder for unselected items
          }
        }
        .frame(width: 20, height: 20)  // Fixed frame for consistent centering

        Text(title)
          .font(.custom("Nunito", size: 15))
          .fontWeight(isSelected ? .semibold : .medium)
          .foregroundColor(textColor)

        Spacer()  // Push content to fill the button area
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())  // Make entire area clickable
      .background(backgroundView)
      .cornerRadius(4)
      .overlay(overlayView)
      .shadow(color: shadowColor(at: 0), radius: 3.08534, x: -1.23414, y: 2.46827)
      .shadow(color: shadowColor(at: 1), radius: 5.55362, x: -4.31948, y: 10.49016)
      .shadow(color: shadowColor(at: 2), radius: 7.40482, x: -9.25603, y: 22.83153)
      .shadow(color: shadowColor(at: 3), radius: 8.94749, x: -16.66084, y: 40.72652)
      .shadow(color: shadowColor(at: 4), radius: 9.56456, x: -25.91687, y: 63.55804)
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
    .scaleEffect(isHovered && !isSelected ? 1.02 : 1.0)
    .animation(.spring(response: 0.3, dampingFraction: 0.9), value: isSelected)
    .animation(.easeOut(duration: 0.2), value: isHovered)
    .onHover { hovering in
      isHovered = hovering
    }
  }

  @ViewBuilder
  private var backgroundView: some View {
    if isSelected {
      ZStack {
        // Layer 1: Orange gradient
        LinearGradient(
          stops: [
            Gradient.Stop(color: Color(red: 1, green: 0.77, blue: 0.34), location: 0.00),
            Gradient.Stop(color: Color(red: 1, green: 0.98, blue: 0.95).opacity(0), location: 1.00),
          ],
          startPoint: UnitPoint(x: 1.15, y: 3.61),
          endPoint: UnitPoint(x: 0.02, y: 0)
        )

        // Layer 2: White opacity overlay
        Color.white.opacity(0.69)
      }
      .blur(radius: 4.62801)
      .matchedGeometryEffect(id: "selection", in: namespace)
    } else {
      Color.clear
    }
  }

  @ViewBuilder
  private var overlayView: some View {
    if isSelected {
      RoundedRectangle(cornerRadius: 4)
        .inset(by: 0.5)
        .stroke(Color(red: 1, green: 0.54, blue: 0.02).opacity(0.5), lineWidth: 1)
    }
  }

  private var textColor: Color {
    if isSelected {
      return Color(hex: "492304")  // Dark brown for selected
    } else if isCompleted {
      return Color(hex: "492304").opacity(0.7)  // Slightly muted for completed
    } else {
      return Color(hex: "492304").opacity(0.4)  // More muted for inactive
    }
  }

  private func shadowColor(at index: Int) -> Color {
    guard isSelected else { return .clear }

    let baseColor = Color(red: 0.57, green: 0.57, blue: 0.57)
    let opacities = [0.05, 0.04, 0.03, 0.01, 0]

    return baseColor.opacity(opacities[min(index, opacities.count - 1)])
  }
}
