//
//  OnboardingPrototypePreferencesStep.swift
//  Dayflow
//

import SwiftUI

// MARK: - Preferences Step

struct OnboardingPrototypePreferencesStep: View {
  let onContinue: (Bool) -> Void

  var body: some View {
    VStack(spacing: 0) {
      Spacer()

      VStack(spacing: 24) {
        Text("Do you have a paid ChatGPT or Claude account?")
          .font(.custom("Figtree", size: 20))
          .foregroundColor(Color(hex: "89380E"))
          .multilineTextAlignment(.center)

        HStack(spacing: 8) {
          ForEach(["Yes", "No"], id: \.self) { option in
            Button {
              onContinue(option == "Yes")
            } label: {
              Text(option)
                .font(.custom("Figtree", size: 16))
                .foregroundColor(Color(hex: "492304"))
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.4))
                .clipShape(Capsule())
                .overlay(
                  Capsule()
                    .stroke(Color(hex: "E4D3C2"), lineWidth: 1)
                )
                .shadow(
                  color: Color(hex: "AF7246").opacity(0.15),
                  radius: 2, x: 0, y: 0
                )
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
          }
        }
      }

      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
