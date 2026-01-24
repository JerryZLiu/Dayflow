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
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Icon
            Image(iconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 40, height: 40)
            
            // Text content
            VStack(alignment: .leading, spacing: 4) {
                // Heading
                Text(title)
                    .font(.custom("Nunito", size: 16))
                    .fontWeight(.semibold)
                    .foregroundColor(.black.opacity(0.85))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                
                // Body
                Text(description)
                    .font(.custom("Nunito", size: 14))
                    .fontWeight(.regular)
                    .foregroundColor(.black.opacity(0.6))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(nil)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 580, alignment: .topLeading)
        .background(.white.opacity(0.3))
        .cornerRadius(5)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .inset(by: 0.5)
                .stroke(.black.opacity(0.06), lineWidth: 1)
        )
    }
}

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
