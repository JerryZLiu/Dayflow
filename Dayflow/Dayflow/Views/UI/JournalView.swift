import SwiftUI

struct JournalView: View {
    // MARK: - Storage & State
    @AppStorage("isJournalUnlocked") private var isUnlocked: Bool = false
    @State private var accessCode: String = ""
    @State private var attempts: Int = 0
    
    // Hardcoded Beta Code
    private let requiredCode = "ACCESS123"
    private let betaNoticeCopy = "Journal is now in closed beta. We'll slowly grant more people access as it gets refined. If you want early access, you acknowledge that the product will change frequently and may have bugs. You also agree to provide feedback frequently."
    
    var body: some View {
        ZStack {
            // MARK: - 1. Background Layer
            GeometryReader { geo in
                Image("JournalPreview") // Make sure this exists in Assets
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                    .clipped()
                    // Blur when locked
                    .blur(radius: isUnlocked ? 0 : 6)
                    .overlay(
                        Color.black.opacity(isUnlocked ? 0 : 0.4)
                    )
                    .animation(.easeInOut(duration: 0.8), value: isUnlocked)
            }
            .padding(.all, -1)
            
            // MARK: - 2. Content Layer
            if isUnlocked {
                unlockedContent
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else {
                lockScreen
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: "F7F2EC").opacity(0.35))
    }
    
    // MARK: - Lock Screen View
    var lockScreen: some View {
        VStack(spacing: 30) {
            Spacer()
            
            // Header
            VStack(spacing: 12) {
                Text("PRIVATE BETA")
                    .font(.custom("Nunito-SemiBold", size: 12))
                    .tracking(2.5)
                    .foregroundColor(.white.opacity(0.7))
                
                Text("Enter Access Code")
                    .font(.custom("InstrumentSerif-Regular", size: 34))
                    .foregroundColor(.white)
            }
            
            // Input Pill
            HStack(spacing: 15) {
                Image(systemName: "key.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.white.opacity(0.5))
                
                SecureField("", text: $accessCode)
                    .placeholder(when: accessCode.isEmpty) {
                        Text("Tap to enter").foregroundColor(.white.opacity(0.3))
                    }
                    .textFieldStyle(.plain)
                    .accentColor(.white) // Forces cursor to be white
                    .foregroundColor(.white)
                    .font(.custom("Nunito-Medium", size: 18))
                    .submitLabel(.go)
                    .onSubmit { validateCode() }
                
                // Submit Button
                if !accessCode.isEmpty {
                    Button(action: validateCode) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.black)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.white))
                    }
                    .buttonStyle(.plain) // Removes the default button border/highlight
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 24)
            .frame(height: 64) // Fixed height prevents layout jumping
            .frame(maxWidth: 340)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.5))
                    .overlay(
                        Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
            )
            // Shake on Error
            .modifier(Shake(animatableData: CGFloat(attempts)))
            
            Spacer()
            
            // Footer
            Text(betaNoticeCopy)
                .font(.custom("Nunito-Regular", size: 12))
                .foregroundColor(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .padding(.bottom, 32)
        }
        .padding()
    }
    
    // MARK: - Unlocked Content
    var unlockedContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            ZStack {
                // Static Content Overlay
                VStack(spacing: 10) {
                    Text("Daily Journal is in development. Reach out via the feedback tab if you want early access!")
                        .font(.custom("Nunito-SemiBold", size: 12))
                        .foregroundColor(.black)
                        .multilineTextAlignment(.center)

                    Text("Get an automatic write-up of focus blocks, key apps, context switches, and distractions.")
                        .font(.custom("Nunito-Regular", size: 13))
                        .foregroundColor(Color.black.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                    
                    // Debug Lock Button
                    Button("Lock (Debug)") {
                        withAnimation {
                            isUnlocked = false
                            accessCode = ""
                        }
                    }
                    .font(.custom("Nunito-Regular", size: 11))
                    .padding(.top, 5)
                    .foregroundColor(.gray)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(Color.white.opacity(0.96))
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                .shadow(color: Color.black.opacity(0.10), radius: 10, x: 0, y: 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(betaNoticeCopy)
                .font(.custom("Nunito-Regular", size: 12))
                .foregroundColor(Color.black.opacity(0.65))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 30)
    }
    
    // MARK: - Logic
    func validateCode() {
        if accessCode == requiredCode {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                isUnlocked = true
            }
        } else {
            withAnimation(.default) {
                attempts += 1
                accessCode = ""
            }
        }
    }
}

// MARK: - Helpers

// Shake Effect
struct Shake: GeometryEffect {
    var amount: CGFloat = 10
    var shakesPerUnit: CGFloat = 3
    var animatableData: CGFloat
    
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX:
            amount * sin(animatableData * .pi * shakesPerUnit),
            y: 0))
    }
}

// Placeholder Helper
extension View {
    func placeholder<Content: View>(
        when shouldShow: Bool,
        alignment: Alignment = .leading,
        @ViewBuilder placeholder: () -> Content) -> some View {
        
        ZStack(alignment: alignment) {
            placeholder().opacity(shouldShow ? 1 : 0)
            self
        }
    }
}

#Preview {
    JournalView()
}
