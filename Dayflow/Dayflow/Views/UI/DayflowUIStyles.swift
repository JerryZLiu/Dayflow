//
//  DayflowUIStyles.swift
//  Dayflow
//
//  Reusable styling components for the new UI
//

import SwiftUI

// MARK: - Color Extension
extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex & 0xFF0000) >> 16) / 255
        let g = Double((hex & 0x00FF00) >>  8) / 255
        let b = Double( hex & 0x0000FF       ) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

// MARK: - Reusable Gradient
struct DayflowAngularGradient {
    static let gradient = AngularGradient(
        gradient: Gradient(stops: [
            .init(color: Color(hex: 0xFF8904, alpha: 0.50), location: 0.03),
            .init(color: Color(hex: 0xFF8904, alpha: 0.35), location: 0.09),
            .init(color: .white, location: 0.17),
            .init(color: .white.opacity(0.50), location: 0.30),
            .init(color: Color(hex: 0xFF8904, alpha: 0.35), location: 0.52),
            .init(color: Color(hex: 0xFFE0A5), location: 0.58),
            .init(color: .white, location: 0.80),
            .init(color: Color(hex: 0xFFF1D3, alpha: 0.50), location: 0.91)
        ]),
        center: .center,
        startAngle: .degrees(0),
        endAngle: .degrees(360)
    )
}

// MARK: - Shadow Modifier
struct DayflowShadowModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .shadow(color: Color(red: 0.57, green: 0.57, blue: 0.57).opacity(0.05), radius: 3.08853, x: -1.23541, y: 2.47082)
            .shadow(color: Color(red: 0.57, green: 0.57, blue: 0.57).opacity(0.04), radius: 5.55935, x: -4.32394, y: 10.501)
            .shadow(color: Color(red: 0.57, green: 0.57, blue: 0.57).opacity(0.03), radius: 7.41247, x: -9.26558, y: 22.85511)
            .shadow(color: Color(red: 0.57, green: 0.57, blue: 0.57).opacity(0.01), radius: 8.95673, x: -16.67805, y: 40.76858)
            .shadow(color: Color(red: 0.57, green: 0.57, blue: 0.57).opacity(0), radius: 9.57444, x: -25.94364, y: 63.62368)
    }
}

// MARK: - View Extensions
extension View {
    /// Applies Dayflow's signature shadow stack
    func dayflowShadow() -> some View {
        modifier(DayflowShadowModifier())
    }
    
    /// Applies complete Dayflow style with rounded rectangle shape
    func dayflowStyle(cornerRadius: CGFloat = 735.4068, strokeWidth: CGFloat = 0.61771, backgroundOpacity: CGFloat = 0.3) -> some View {
        self
            .background(.white.opacity(backgroundOpacity))
            .cornerRadius(cornerRadius)
            .dayflowShadow()
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .inset(by: 0.31)
                    .stroke(DayflowAngularGradient.gradient, lineWidth: strokeWidth)
            )
    }
    
    /// Applies complete Dayflow style with circle shape
    func dayflowCircleStyle(strokeWidth: CGFloat = 0.61771, backgroundOpacity: CGFloat = 0.3) -> some View {
        self
            .background(.white.opacity(backgroundOpacity))
            .clipShape(Circle())
            .dayflowShadow()
            .overlay(
                Circle()
                    .inset(by: 0.31)
                    .stroke(DayflowAngularGradient.gradient, lineWidth: strokeWidth)
            )
    }
}

// MARK: - Convenience Styled Components
struct DayflowCircleButton: View {
    let action: () -> Void
    let content: () -> AnyView
    let size: CGSize
    
    init(width: CGFloat = 31.40301, height: CGFloat = 30.4514, action: @escaping () -> Void, @ViewBuilder content: @escaping () -> some View) {
        self.size = CGSize(width: width, height: height)
        self.action = action
        self.content = { AnyView(content()) }
    }
    
    var body: some View {
        Button(action: action) {
            content()
        }
        .buttonStyle(PlainButtonStyle())
        .frame(width: size.width, height: size.height)
        .dayflowCircleStyle()
    }
}

struct DayflowPillButton: View {
    let text: String
    let font: Font
    let foregroundColor: Color
    let horizontalPadding: CGFloat
    let height: CGFloat
    
    init(
        text: String,
        font: Font = .custom("InstrumentSerif-Regular", size: 18),
        foregroundColor: Color = Color(red: 0.2, green: 0.2, blue: 0.2),
        horizontalPadding: CGFloat = 11.77829,
        height: CGFloat = 30.4514
    ) {
        self.text = text
        self.font = font
        self.foregroundColor = foregroundColor
        self.horizontalPadding = horizontalPadding
        self.height = height
    }
    
    var body: some View {
        Text(text)
            .font(font)
            .foregroundColor(foregroundColor)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .dayflowStyle()
    }
}