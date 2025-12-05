//
//  ProviderCardComponents.swift
//  Dayflow
//
//  Shared UI components for provider selection cards
//  Used in both OnboardingLLMSelectionView and SettingsView
//

import SwiftUI


enum ProviderCardButtonMode {
    case onboarding(onProceed: () -> Void)
    case settings(onSwitch: () -> Void)
}


struct FlexibleProviderCard: View {
    let id: String
    let title: String
    let badgeText: String
    let badgeType: BadgeType
    let icon: String
    let features: [(text: String, isAvailable: Bool)]
    let isSelected: Bool
    let buttonMode: ProviderCardButtonMode
    let showCurrentlySelected: Bool
    let customStatusText: String?
    let onSelect: (() -> Void)?

    private let isComingSoon: Bool

    init(
        id: String,
        title: String,
        badgeText: String,
        badgeType: BadgeType,
        icon: String,
        features: [(text: String, isAvailable: Bool)],
        isSelected: Bool,
        buttonMode: ProviderCardButtonMode,
        showCurrentlySelected: Bool = false,
        customStatusText: String? = nil,
        onSelect: (() -> Void)? = nil
    ) {
        self.id = id
        self.title = title
        self.badgeText = badgeText
        self.badgeType = badgeType
        self.icon = icon
        self.features = features
        self.isSelected = isSelected
        self.buttonMode = buttonMode
        self.showCurrentlySelected = showCurrentlySelected
        self.customStatusText = customStatusText
        self.onSelect = onSelect
        self.isComingSoon = id == "dayflow"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header content
            VStack(alignment: .leading, spacing: 0) {
                iconSection
                titleSection
                badgeSection
                if showCurrentlySelected {
                    statusIndicator
                }
                featuresScroll
            }
            
            // Button at bottom
            actionButton
        }
        .frame(maxWidth: .infinity)
        .background(cardBackground)
        .cornerRadius(4)
        .overlay(cardOverlay)
        .modifier(CardShadowModifier(isSelected: isSelected))
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: isSelected)
        .contentShape(RoundedRectangle(cornerRadius: 4))
        .allowsHitTesting(shouldAllowHitTesting)
        .pointingHandCursor(enabled: shouldShowPointer)
        .onTapGesture { handleCardTap() }
    }
    
    private var shouldAllowHitTesting: Bool {
        switch buttonMode {
        case .onboarding:
            return !isComingSoon
        case .settings:
            return true
        }
    }
    
    private var shouldShowPointer: Bool {
        switch buttonMode {
        case .onboarding:
            // Show pointer cursor for selectable cards
            return !isComingSoon && !isSelected
        case .settings:
            return false
        }
    }
    
    private func handleCardTap() {
        switch buttonMode {
        case .onboarding:
            // In onboarding, clicking the card selects it
            if !isComingSoon && !isSelected {
                onSelect?()
            }
        case .settings:
            break // No tap action in settings mode
        }
    }
    
    private var iconSection: some View {
        HStack {
            Spacer()
            ProviderIconView(icon: icon)
            Spacer()
        }
        .padding(.top, 24)
        .padding(.bottom, 16)
    }
    
    private var titleSection: some View {
        HStack {
            Spacer()
            Text(title)
                .font(.custom("Nunito", size: 18))
                .fontWeight(.semibold)
                .foregroundColor(.black.opacity(0.9))
                .lineLimit(2)
                .truncationMode(.tail)
            Spacer()
        }
        .padding(.bottom, 8)
    }
    
    private var badgeSection: some View {
        HStack {
            Spacer()
            BadgeView(text: badgeText, type: badgeType)
            Spacer()
        }
        .padding(.bottom, showCurrentlySelected ? 12 : 24)
    }
    
    private var statusIndicator: some View {
        HStack {
            Spacer()
            if isSelected {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.green)
                    Text(customStatusText ?? "Currently selected")
                        .font(.custom("Nunito", size: 12))
                        .fontWeight(.medium)
                        .foregroundColor(.black.opacity(0.6))
                }
            }
            Spacer()
        }
        .frame(height: 20)
        .padding(.bottom, 8)
    }
    
    private var featuresScroll: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(features.enumerated()), id: \.offset) { _, feature in
                    FeatureRowView(feature: feature)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var actionButton: some View {
        DayflowSurfaceButton(
            action: buttonAction,
            content: {
                Text(buttonTitle)
                    .font(.custom("Nunito", size: 14))
                    .fontWeight(.semibold)
                    .foregroundColor(buttonForegroundColor)
                    .frame(maxWidth: .infinity)
            },
            background: buttonBackgroundColor,
            foreground: buttonForegroundColor,
            borderColor: .clear,
            cornerRadius: 8,
            horizontalPadding: 24,
            verticalPadding: 12,
            minWidth: nil,
            showOverlayStroke: true
        )
        .disabled(isButtonDisabled)
        .opacity(isComingSoon ? 0.4 : 1.0)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .frame(height: 60, alignment: .center)
    }
    
    private var buttonAction: () -> Void {
        switch buttonMode {
        case .onboarding(let onProceed):
            return { if !isComingSoon { onProceed() } }
        case .settings(let onSwitch):
            return { if !isComingSoon { onSwitch() } }  // Removed !isSelected check - allow editing
        }
    }
    
    private var buttonTitle: String {
        if isComingSoon {
            return "Coming Soon"
        }

        switch buttonMode {
        case .onboarding:
            return "Proceed"
        case .settings:
            return isSelected ? "Edit Configuration" : "Switch"
        }
    }
    
    private var isButtonDisabled: Bool {
        if isComingSoon {
            return true
        }

        switch buttonMode {
        case .onboarding:
            return false
        case .settings:
            return false  // Always enabled - allows editing when selected
        }
    }
    
    private var buttonForegroundColor: Color {
        return .white
    }
    
    private var buttonBackgroundColor: Color {
        return Color(red: 0.25, green: 0.17, blue: 0)
    }
    
    @ViewBuilder
    private var cardBackground: some View {
        if isSelected {
            SelectedCardBackground()
        } else {
            Color.white.opacity(0.3)
        }
    }
    
    @ViewBuilder
    private var cardOverlay: some View {
        if isSelected {
            SelectedCardOverlay()
        } else {
            RoundedRectangle(cornerRadius: 4)
                .inset(by: 0.5)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        }
    }
}


enum BadgeType {
    case green, orange, blue
}


struct BadgeView: View {
    let text: String
    let type: BadgeType
    
    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(Font.custom("Nunito", size: 10).weight(textWeight))
                .kerning(kerningValue)
                .foregroundColor(textColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(badgeBackground)
        .cornerRadius(2)
        .modifier(BadgeShadowModifier(shadowColor: shadowColor))
        .overlay(badgeOverlay)
    }
    
    private var textWeight: Font.Weight {
        switch type {
        case .green:
            return .semibold
        case .orange, .blue:
            return .bold
        }
    }
    
    private var kerningValue: CGFloat {
        switch type {
        case .green:
            return 0.5
        case .orange, .blue:
            return 0.7
        }
    }
    
    private var textColor: Color {
        switch type {
        case .green:
            return Color(red: 0.13, green: 0.7, blue: 0.23)
        case .orange:
            return Color(red: 0.91, green: 0.34, blue: 0.16)
        case .blue:
            return Color(red: 0.19, green: 0.39, blue: 0.8)
        }
    }
    
    private var badgeBackground: some View {
        ZStack {
            Color.white.opacity(0.69)
            
            LinearGradient(
                stops: gradientColors,
                startPoint: UnitPoint(x: 1.15, y: 3.61),
                endPoint: UnitPoint(x: 0.02, y: 0)
            )
        }
    }
    
    private var badgeOverlay: some View {
        RoundedRectangle(cornerRadius: 2)
            .inset(by: 0.25)
            .stroke(strokeColor, lineWidth: 0.5)
    }
    
    private var gradientColors: [Gradient.Stop] {
        switch type {
        case .green:
            return [
                Gradient.Stop(color: Color(red: 0.34, green: 1, blue: 0.45), location: 0.00),
                Gradient.Stop(color: Color(red: 1, green: 0.98, blue: 0.95).opacity(0), location: 1.00)
            ]
        case .orange:
            return [
                Gradient.Stop(color: Color(red: 1, green: 0.49, blue: 0.34), location: 0.00),
                Gradient.Stop(color: Color(red: 1, green: 0.98, blue: 0.95).opacity(0), location: 1.00)
            ]
        case .blue:
            return [
                Gradient.Stop(color: Color(red: 0.34, green: 0.56, blue: 1), location: 0.00),
                Gradient.Stop(color: Color(red: 1, green: 0.98, blue: 0.95).opacity(0), location: 1.00)
            ]
        }
    }
    
    private var shadowColor: Color {
        switch type {
        case .green:
            return Color(red: 0.34, green: 1, blue: 0.45)
        case .orange:
            return Color(red: 1, green: 0.53, blue: 0)
        case .blue:
            return Color(red: 0.34, green: 0.56, blue: 1)
        }
    }
    
    private var strokeColor: Color {
        switch type {
        case .green:
            return Color(red: 0.34, green: 1, blue: 0.45).opacity(0.3)
        case .orange:
            return Color(red: 1, green: 0.25, blue: 0.02).opacity(0.3)
        case .blue:
            return Color(red: 0.34, green: 0.56, blue: 1).opacity(0.3)
        }
    }
}


struct BadgeShadowModifier: ViewModifier {
    let shadowColor: Color
    
    func body(content: Content) -> some View {
        content
            .shadow(color: shadowColor.opacity(0.14), radius: 1.5, x: 0, y: 1)
            .shadow(color: shadowColor.opacity(0.12), radius: 2.5, x: 2, y: 4)
            .shadow(color: shadowColor.opacity(0.07), radius: 3, x: 4, y: 10)
            .shadow(color: shadowColor.opacity(0.02), radius: 3.5, x: 7, y: 17)
            .shadow(color: shadowColor.opacity(0), radius: 4, x: 10, y: 27)
    }
}


struct ProviderIconView: View {
    let icon: String
    
    var body: some View {
        iconContent
            .frame(width: containerWidth, height: 40)
    }

    private var containerWidth: CGFloat {
        icon == "chatgpt_claude_asset" ? 104 : 40
    }

    @ViewBuilder
    private var iconContent: some View {
        switch icon {
        case "gemini_asset":
            logoBox(name: "GeminiLogo")
        case "chatgpt_claude_asset":
            HStack(spacing: 8) {
                logoBox(name: "ChatGPTLogo")
                logoBox(name: "ClaudeLogo")
            }
        default:
            logoBox(systemName: icon)
        }
    }

    @ViewBuilder
    private func logoBox(name: String) -> some View {
        Image(name)
            .resizable()
            .renderingMode(.original)
            .interpolation(.high)
            .antialiased(true)
            .scaledToFit()
            .frame(width: 28, height: 28)
            .padding(6)
            .background(.white.opacity(0.9))
            .cornerRadius(6)
            .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 2)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.black.opacity(0.05), lineWidth: 0.5)
            )
    }

    @ViewBuilder
    private func logoBox(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 20, weight: .medium))
            .foregroundColor(.black.opacity(0.7))
            .frame(width: 40, height: 40)
            .background(.white.opacity(0.6))
            .cornerRadius(3)
            .shadow(color: Color(red: 0.92, green: 0.91, blue: 0.91), radius: 1, x: -1, y: 2)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .inset(by: 0.23)
                    .stroke(.white.opacity(0.87), lineWidth: 0.46508)
            )
    }
}


struct FeatureRowView: View {
    let feature: (text: String, isAvailable: Bool)
    
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: feature.isAvailable ? "checkmark" : "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(feature.isAvailable ? Color(red: 0.34, green: 1, blue: 0.45) : Color(hex: "E91515"))
                .frame(width: 16)
            
            Text(feature.text)
                .font(.custom("Nunito", size: 14))
                .foregroundColor(.black.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}


struct SelectedCardBackground: View {
    var body: some View {
        ZStack {
            Color(hex: "FCF2E3")
            Color.white.opacity(0.69)
            LinearGradient(
                stops: [
                    Gradient.Stop(color: Color.clear, location: 0.25),
                    Gradient.Stop(color: Color(hex: "FF7506").opacity(0.05), location: 0.7),
                    Gradient.Stop(color: Color(hex: "FF7506").opacity(0.15), location: 1.0)
                ],
                startPoint: UnitPoint(x: 0, y: 0.5),
                endPoint: UnitPoint(x: 1, y: 0.5)
            )
        }
    }
}


struct SelectedCardOverlay: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .inset(by: 0.5)
                .stroke(Color(hex: "EBE9E6"), lineWidth: 1)
            
            RoundedRectangle(cornerRadius: 4)
                .inset(by: 0.5)
                .stroke(Color(hex: "FFEBC9"), lineWidth: 1)
            
            RoundedRectangle(cornerRadius: 4)
                .inset(by: 0.5)
                .stroke(
                    AngularGradient(
                        stops: [
                            .init(color: Color(hex: "FFF1D3").opacity(0.50), location: 0.00),
                            .init(color: Color(hex: "FF8904").opacity(0.50), location: 0.03),
                            .init(color: Color(hex: "FF8904").opacity(0.35), location: 0.09),
                            .init(color: .white, location: 0.17),
                            .init(color: .white.opacity(0.75), location: 0.23),
                            .init(color: .white.opacity(0.50), location: 0.25),
                            .init(color: .white.opacity(0.50), location: 0.30),
                            .init(color: Color(hex: "FF8904").opacity(0.35), location: 0.52),
                            .init(color: Color(hex: "FFE0A5"), location: 0.58),
                            .init(color: .white, location: 0.80),
                            .init(color: Color(hex: "FFF1D3").opacity(0.50), location: 0.91),
                            .init(color: Color(hex: "FFF1D3").opacity(0.50), location: 1.00)
                        ],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360)
                    ),
                    lineWidth: 1
                )
        }
    }
}


struct CardShadowModifier: ViewModifier {
    let isSelected: Bool
    
    func body(content: Content) -> some View {
        content
            .shadow(
                color: isSelected ? Color(red: 0.47, green: 0.27, blue: 0.09).opacity(0.21) : Color.clear,
                radius: 5,
                x: 4,
                y: 3
            )
            .shadow(
                color: isSelected ? Color(red: 0.47, green: 0.27, blue: 0.09).opacity(0.18) : Color.clear,
                radius: 9.5,
                x: 14,
                y: 12
            )
            .shadow(
                color: isSelected ? Color(red: 0.48, green: 0.27, blue: 0.1).opacity(0.11) : Color.clear,
                radius: 12.5,
                x: 32,
                y: 27
            )
    }
}


extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
