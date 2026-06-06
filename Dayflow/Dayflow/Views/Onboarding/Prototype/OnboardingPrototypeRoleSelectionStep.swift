//
//  OnboardingPrototypeRoleSelectionStep.swift
//  Dayflow
//

import SwiftUI

struct OnboardingPrototypeRoleSelectionStep: View {
  let onContinue: (String) -> Void

  private let roles = [
    "Software Engineer", "Founder / Executive", "Designer", "Student", "Product Manager",
    "Data Scientist", "Other",
  ]
  @State private var selectedRole: String?
  @State private var otherText = ""

  private var resolvedRole: String? {
    guard let selectedRole else { return nil }
    if selectedRole == "Other" {
      return otherText.trimmingCharacters(in: .whitespaces).isEmpty
        ? nil : otherText.trimmingCharacters(in: .whitespaces)
    }
    return selectedRole
  }

  var body: some View {
    VStack(spacing: 0) {
      Spacer()
        .frame(height: 39)

      Text("Help Dayflow understand your work patterns better.")
        .font(.custom("InstrumentSerif-Regular", size: 40))
        .tracking(-1.2)
        .multilineTextAlignment(.center)
        .foregroundColor(Color(hex: "492304"))
        .lineSpacing(40 * 0.2)
        .frame(maxWidth: 708)
        .fixedSize(horizontal: false, vertical: true)

      Spacer()
        .frame(height: 60)

      VStack(spacing: 24) {
        VStack(spacing: 4) {
          Text("What do you do for work?")
            .font(.custom("Figtree", size: 20))
            .foregroundColor(Color(hex: "89380E"))

          Text("This will help Dayflow generate categories that are most helpful to you.")
            .font(.custom("Figtree", size: 20))
            .foregroundColor(Color(hex: "89380E"))
        }
        .multilineTextAlignment(.center)

        VStack(spacing: 8) {
          HStack(spacing: 8) {
            ForEach(roles.prefix(4), id: \.self) { role in
              roleChip(role)
            }
          }
          HStack(spacing: 8) {
            ForEach(roles.dropFirst(4), id: \.self) { role in
              roleChip(role)
            }
          }
        }
      }

      if selectedRole == "Other" {
        VStack(spacing: 16) {
          Text("Please specify")
            .font(.custom("Figtree", size: 20))
            .foregroundColor(Color(hex: "89380E"))

          TextField("", text: $otherText)
            .font(.custom("Figtree", size: 16))
            .foregroundColor(Color(hex: "492304"))
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .frame(width: 353, height: 34)
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
        }
        .padding(.top, 32)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }

      Spacer()

      DayflowSurfaceButton(
        action: {
          if let role = resolvedRole {
            onContinue(role)
          }
        },
        content: {
          Text("Continue")
            .font(.custom("Figtree", size: 14))
            .fontWeight(.semibold)
        },
        background: Color(hex: "402C00"),
        foreground: .white,
        borderColor: .clear,
        cornerRadius: 8,
        horizontalPadding: 59,
        verticalPadding: 12,
        minWidth: 234,
        showOverlayStroke: true
      )
      .opacity(resolvedRole == nil ? 0.4 : 1.0)
      .allowsHitTesting(resolvedRole != nil)
      .animation(.easeInOut(duration: 0.2), value: resolvedRole)

      Spacer()
        .frame(height: 60)
    }
    .animation(.easeInOut(duration: 0.25), value: selectedRole == "Other")
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func roleChip(_ role: String) -> some View {
    let isSelected = selectedRole == role
    return Button {
      selectedRole = role
    } label: {
      Text(role)
        .font(.custom("Figtree", size: 16))
        .foregroundColor(Color(hex: "492304"))
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(
          isSelected
            ? Color(red: 1, green: 0.898, blue: 0.812).opacity(0.4)
            : Color.white.opacity(0.4)
        )
        .clipShape(Capsule())
        .overlay(
          Capsule()
            .stroke(
              isSelected ? Color(hex: "FFCCA7") : Color(hex: "E4D3C2"),
              lineWidth: 1
            )
        )
        .shadow(
          color: isSelected
            ? Color(red: 1, green: 0.416, blue: 0).opacity(0.5)
            : Color(hex: "AF7246").opacity(0.15),
          radius: isSelected ? 3 : 2, x: 0, y: 0
        )
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }
}
