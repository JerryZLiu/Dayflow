import SwiftUI

/// Hero surface matching the highlighted Figma frame (Daily Journal pill + warm gradient entry).
struct JournalHeroView: View {
    var summary: JournalHeroSummary
    var onReflect: (() -> Void)?

    init(summary: JournalHeroSummary = .preview, onReflect: (() -> Void)? = nil) {
        self.summary = summary
        self.onReflect = onReflect
    }

    var body: some View {
        ZStack {
            backgroundLayer

            VStack(spacing: 32) {
                badgeHeader
                entryCard

                if let onReflect {
                    ReflectButton(title: summary.ctaTitle, action: onReflect)
                }
            }
            .frame(maxWidth: 920)
            .padding(.horizontal, 28)
            .padding(.vertical, 36)
        }
    }
}

// MARK: - Layers

private extension JournalHeroView {
    var backgroundLayer: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hex: "FF9B3A"),
                    Color(hex: "FFB764"),
                    Color(hex: "FFE6C5"),
                    Color(hex: "FFF6EB")
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [Color.white.opacity(0.9), Color.clear],
                center: .bottomLeading,
                startRadius: 90,
                endRadius: 520
            )
            .blendMode(.screen)
            .ignoresSafeArea()

            RadialGradient(
                colors: [Color(hex: "FFAE5E").opacity(0.45), Color.clear],
                center: .topLeading,
                startRadius: 140,
                endRadius: 520
            )
            .ignoresSafeArea()
        }
    }
}

// MARK: - Components

private extension JournalHeroView {
    var badgeHeader: some View {
        Text(summary.headline)
            .font(.custom("Nunito-SemiBold", size: 30))
            .kerning(-0.4)
            .foregroundStyle(.clear) // fill via gradient mask
            .overlay(
                JournalHeroTokens.badgeTextGradient
                    .mask(
                        Text(summary.headline)
                            .font(.custom("Nunito-SemiBold", size: 30))
                            .kerning(-0.4)
                    )
            )
            .padding(.horizontal, 30)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(JournalHeroTokens.badgeBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                            .stroke(JournalHeroTokens.badgeStroke, lineWidth: 1)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .stroke(JournalHeroTokens.badgeInnerHighlight, lineWidth: 0.6)
                    .blur(radius: 0.8)
            )
            .shadow(color: JournalHeroTokens.badgeShadow, radius: 18, y: 12)
    }

    var entryCard: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(JournalHeroTokens.entryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(JournalHeroTokens.entryStroke, lineWidth: 1)
                )
                .shadow(color: JournalHeroTokens.entryShadow, radius: 30, y: 18)

            Text(summary.entry)
                .lineSpacing(8)
                .kerning(-0.2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 26)
                .padding(.vertical, 24)
                .multilineTextAlignment(.leading)

            // Fade out toward the bottom to mirror the Figma glow
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(JournalHeroTokens.entryFade)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReflectButton: View {
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.custom("Nunito-SemiBold", size: 15))
        }
        .buttonStyle(JournalHeroPillButtonStyle())
    }
}

private struct JournalHeroPillButtonStyle: ButtonStyle {
    var horizontalPadding: CGFloat = 24
    var verticalPadding: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(red: 0.18, green: 0.11, blue: 0.06).opacity(0.8))
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(Color(red: 1, green: 0.96, blue: 0.92).opacity(configuration.isPressed ? 0.7 : 0.6))
            .cornerRadius(100)
            .overlay(
                RoundedRectangle(cornerRadius: 100)
                    .inset(by: 0.5)
                    .stroke(Color(red: 0.95, green: 0.86, blue: 0.84), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: configuration.isPressed)
    }
}

// MARK: - Models

struct JournalHeroSummary {
    var headline: String
    var entry: AttributedString
    var ctaTitle: String
}

extension JournalHeroSummary {
    static var preview: JournalHeroSummary {
        .init(
            headline: "Daily Journal",
            entry: .sampleEntry,
            ctaTitle: "Reflect with Dayflow"
        )
    }
}

private extension AttributedString {
    static var sampleEntry: AttributedString {
        var base = AttributeContainer()
        base.font = .custom("InstrumentSerif-Regular", size: 30)
        base.foregroundColor = JournalHeroTokens.entryPrimary

        var emphasized = AttributeContainer()
        emphasized.font = .custom("InstrumentSerif-Regular", size: 32)
        emphasized.foregroundColor = JournalHeroTokens.entryEmphasis

        var secondary = AttributeContainer()
        secondary.font = .custom("InstrumentSerif-Regular", size: 28)
        secondary.foregroundColor = JournalHeroTokens.entrySecondary

        var text = AttributedString("Started the morning deep in debugging mode around ", attributes: base)
        text += AttributedString("8:45 AM", attributes: emphasized)
        text += AttributedString(", wrestling with dashboard cards that refused to ", attributes: base)
        text += AttributedString("show up.", attributes: emphasized)
        text += AttributedString(" Classic case of “why isn’t this simple thing working?” Had to dig through using Claude and even fire up Beekeeper Studio to check logs.", attributes: secondary)
        return text
    }
}

// MARK: - Tokens

private enum JournalHeroTokens {
    static let badgeTextGradient = LinearGradient(
        colors: [Color(hex: "ED6B0C"), Color(hex: "F4C11C")],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let badgeBackground = LinearGradient(
        colors: [Color.white.opacity(0.96), Color(hex: "FFF2DB")],
        startPoint: .top,
        endPoint: .bottom
    )

    static let badgeStroke = Color.white.opacity(0.65)
    static let badgeInnerHighlight = Color.white.opacity(0.32)
    static let badgeShadow = Color(hex: "D88931").opacity(0.38)

    static let entryBackground = Color.white.opacity(0.36)
    static let entryStroke = Color.white.opacity(0.62)
    static let entryShadow = Color(hex: "C86E1A").opacity(0.14)
    static let entryPrimary = Color(hex: "7A4116")
    static let entrySecondary = Color(hex: "9C5A26").opacity(0.86)
    static let entryEmphasis = Color(hex: "5B2A06")
    static let entryFade = LinearGradient(
        colors: [Color.clear, Color(hex: "FFF6EB").opacity(0.94)],
        startPoint: .center,
        endPoint: .bottom
    )

    static let ctaBackground = LinearGradient(
        colors: [Color(hex: "FFE1B5"), Color(hex: "FFC169")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let ctaStroke = Color(hex: "FFD28A")
    static let ctaText = Color(hex: "7A3A00")
    static let ctaShadow = Color(hex: "E6A65A").opacity(0.30)
}

// MARK: - Preview

struct JournalHeroView_Previews: PreviewProvider {
    static var previews: some View {
        JournalHeroView()
            .frame(width: 1180, height: 820)
            .preferredColorScheme(.light)
    }
}
