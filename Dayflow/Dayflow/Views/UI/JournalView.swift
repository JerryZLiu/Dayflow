import SwiftUI

struct JournalView: View {
    // MARK: - Storage & State
    @AppStorage("isJournalUnlocked") private var isUnlocked: Bool = false
    @State private var accessCode: String = ""
    @State private var attempts: Int = 0
    @State private var showRemindersSheet: Bool = false
    
    // Hardcoded Beta Code
    private let requiredCode = "ACCESS123"
    private let betaNoticeCopy = "Journal is now in closed beta. We'll slowly grant more people access as it gets refined. If you want early access, you acknowledge that the product will change frequently and may have bugs. You also agree to provide feedback frequently."
    
    var body: some View {
        ZStack {
            if isUnlocked {
                unlockedContent
                    .transition(.opacity)
            } else {
                lockScreen
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .sheet(isPresented: $showRemindersSheet) {
            JournalRemindersView()
        }
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
        ZStack {
            JournalDayView(
                onSetReminders: { showRemindersSheet = true }
            )
            .frame(maxWidth: 980, alignment: .center)
            .padding(.horizontal, 12)
        }
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
