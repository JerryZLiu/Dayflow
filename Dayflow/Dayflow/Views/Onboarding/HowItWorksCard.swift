//
//  HowItWorksCard.swift
//  Dayflow
//
//  Card component for How It Works section
//

import SwiftUI

struct HowItWorksCard: View {
    let iconImage: String  // Asset image name
    let title: String
    let description: String
    
    @State private var isHovered = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Icon container
            HStack(alignment: .center, spacing: 5.37353) {
                Image(iconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
            }
            .padding(6.44824)
            .frame(width: 40.84961, height: 40.84961, alignment: .center)
            .background(.white.opacity(0.6))
            .cornerRadius(5.83566)
            .shadow(color: Color(red: 1, green: 0.42, blue: 0.02).opacity(0.3), radius: 0.53735, x: -0.53735, y: 1.07471)
            .overlay(
                RoundedRectangle(cornerRadius: 5.83566)
                    .inset(by: 0.12)
                    .stroke(.white.opacity(0.87), lineWidth: 0.24991)
            )
            
            // Text content
            VStack(alignment: .leading, spacing: 4) {
                // Heading
                Text(title)
                    .font(.custom("Nunito", size: 20))
                    .fontWeight(.semibold)
                    .foregroundColor(Color(red: 0.54, green: 0.22, blue: 0.05))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                
                // Body
                Text(description)
                    .font(.custom("Nunito", size: 14))
                    .fontWeight(.medium)
                    .foregroundColor(Color(red: 0.18, green: 0.18, blue: 0.18))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(16)
        .frame(maxWidth: 600, minHeight: 100)
        .background(.white.opacity(isHovered ? 0.75 : 0.66))
        .cornerRadius(16)
        .shadow(color: Color(red: 1, green: 0.42, blue: 0.02).opacity(isHovered ? 0.16 : 0.11), radius: isHovered ? 6 : 4.5, x: -3, y: 4)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .inset(by: 1)
                .stroke(Color(red: 1, green: 0.54, blue: 0.02).opacity(isHovered ? 0.7 : 0.5), lineWidth: 2)
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Preview
struct HowItWorksCard_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            HowItWorksCard(
                iconImage: "OnboardingHow",
                title: "Install and Forget",
                description: "Dayflow takes periodic screen captures to understand what you're working on - all stored privately on your device."
            )
            
            HowItWorksCard(
                iconImage: "OnboardingSecurity",
                title: "AI-Powered Insights",
                description: "Local AI analyzes your activities to create a timeline of your day without sending data to the cloud."
            )
            
            HowItWorksCard(
                iconImage: "OnboardingUnderstanding",
                title: "Review Your Day",
                description: "See where your time went with beautiful visualizations and actionable insights about your productivity."
            )
        }
        .padding(40)
        .background(Color.gray.opacity(0.1))
    }
}
