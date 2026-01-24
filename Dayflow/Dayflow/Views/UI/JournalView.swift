import SwiftUI
import CryptoKit
import AVKit
import AVFoundation

// MARK: - Journal Coordinator

/// Coordinates journal-level UI state that needs to be shared across the view hierarchy
@MainActor
final class JournalCoordinator: ObservableObject {
    @Published var showOnboardingVideo = false
    @Published var showRemindersAfterOnboarding = false
}

struct JournalView: View {
    // MARK: - Storage & State
    @AppStorage("isJournalUnlocked") private var isUnlocked: Bool = false
    @AppStorage("hasCompletedJournalOnboarding") private var hasCompletedOnboarding: Bool = false
    @EnvironmentObject private var coordinator: JournalCoordinator
    @State private var accessCode: String = ""
    @State private var attempts: Int = 0
    @State private var showRemindersSheet: Bool = false

    // SHA256 hashed—nice try! But you're already in the source code...
    // so yes you can delete this function and build from source if you so desire.
    private let requiredCodeHash = "909ca0096d519dcf94aba6069fa664842bdf9de264725a6c543c4926abe6bdfa"
    private let betaNoticeCopy = "We're slowly letting people into the beta as we iterate and improve the experience. If you choose to participate in the beta, you acknowledge that you may encounter bugs and agree to provide feedback."

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
            JournalRemindersView(
                onSave: {
                    showRemindersSheet = false
                    coordinator.showRemindersAfterOnboarding = false
                },
                onCancel: {
                    showRemindersSheet = false
                    coordinator.showRemindersAfterOnboarding = false
                }
            )
        }
        .onChange(of: coordinator.showRemindersAfterOnboarding) { _, shouldShow in
            if shouldShow {
                showRemindersSheet = true
            }
        }
    }

    // MARK: - Lock Screen View
    var lockScreen: some View {
        VStack(spacing: 24) {
            Spacer()

            // Header: "Dayflow Journal" with BETA badge
            HStack(alignment: .top, spacing: 4) {
                Text("Dayflow Journal")
                    .font(.custom("InstrumentSerif-Italic", size: 38))
                    .foregroundColor(Color(red: 0.35, green: 0.22, blue: 0.12))

                // BETA badge
                Text("BETA")
                    .font(.custom("Nunito-Bold", size: 11))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(red: 0.98, green: 0.55, blue: 0.20))
                    )
                    .rotationEffect(.degrees(-12))
                    .offset(x: -4, y: -4)
            }

            // Subtitle
            Text(betaNoticeCopy)
                .font(.custom("Nunito-Regular", size: 15))
                .foregroundColor(Color(red: 0.35, green: 0.22, blue: 0.12).opacity(0.8))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .padding(.horizontal, 24)

            Spacer().frame(height: 20)

            // Access code card
            accessCodeCard
                .modifier(Shake(animatableData: CGFloat(attempts)))

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(
            GeometryReader { geo in
                Image("JournalPreview")
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .allowsHitTesting(false)
            }
        )
    }

    // MARK: - Access Code Card
    // JournalLock is the entire card image (gradient bg + lock icon baked in)
    private var accessCodeCard: some View {
        ZStack(alignment: .bottom) {
            // Card background image (contains gradient + lock icon)
            Image("JournalLock")
                .resizable()
                .aspectRatio(contentMode: .fit)

            // Overlay content: title, text field, button (anchored to bottom)
            VStack(spacing: 16) {
                // Title
                Text("Enter access code")
                    .font(.custom("Nunito-SemiBold", size: 20))
                    .foregroundColor(Color(red: 0.85, green: 0.45, blue: 0.25))

                // Text field
                TextField("", text: $accessCode)
                    .textFieldStyle(.plain)
                    .font(.custom("Nunito-Medium", size: 15))
                    .foregroundColor(Color(red: 0.25, green: 0.15, blue: 0.10))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white)
                    )
                    .padding(.horizontal, 80)
                    .submitLabel(.go)
                    .onSubmit { validateCode() }

                // Submit button
                Button(action: validateCode) {
                    Text("Get early access")
                        .font(.custom("Nunito-SemiBold", size: 15))
                        .foregroundColor(Color(red: 0.35, green: 0.22, blue: 0.12))
                        .padding(.horizontal, 28)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 1.0, green: 0.92, blue: 0.82),
                                            Color(red: 1.0, green: 0.85, blue: 0.70)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(Color(red: 0.90, green: 0.75, blue: 0.55), lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 28)
        }
        .frame(width: 380)
        .shadow(color: Color.black.opacity(0.08), radius: 16, x: 0, y: 6)
    }
    
    // MARK: - Unlocked Content
    @ViewBuilder
    var unlockedContent: some View {
        if hasCompletedOnboarding {
            // Main journal view
            JournalDayView(
                onSetReminders: { showRemindersSheet = true }
            )
            .frame(maxWidth: 980, alignment: .center)
            .padding(.horizontal, 12)
        } else {
            // Journal onboarding screen
            JournalOnboardingView(onStartOnboarding: {
                AnalyticsService.shared.capture("journal_onboarding_started")
                coordinator.showOnboardingVideo = true
            })
        }
    }
    
    // MARK: - Logic
    func validateCode() {
        // Lowercase input and compute SHA256 hash
        let inputLowercased = accessCode.lowercased()
        let inputData = Data(inputLowercased.utf8)
        let inputHash = SHA256.hash(data: inputData)
        let inputHashString = inputHash.compactMap { String(format: "%02x", $0) }.joined()

        if inputHashString == requiredCodeHash {
            AnalyticsService.shared.capture("journal_unlocked")
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

// MARK: - Journal Onboarding View

private struct JournalOnboardingView: View {
    var onStartOnboarding: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Title
            Text("Set your intentions today")
                .font(.custom("InstrumentSerif-Regular", size: 42))
                .foregroundColor(Color(red: 0.85, green: 0.45, blue: 0.15))
                .multilineTextAlignment(.center)

            // Description
            Text("Dayflow helps you track your daily and longer term goals, gives you the space to reflect, and generates a summary of each day.")
                .font(.custom("Nunito-Regular", size: 16))
                .foregroundColor(Color(red: 0.25, green: 0.15, blue: 0.10).opacity(0.8))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 640)
                .padding(.horizontal, 24)

            Spacer()

            // Start onboarding button
            Button(action: onStartOnboarding) {
                Text("Start onboarding")
                    .font(.custom("Nunito-SemiBold", size: 16))
                    .foregroundColor(Color(red: 0.35, green: 0.22, blue: 0.12))
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 1.0, green: 0.96, blue: 0.92),
                                        Color(red: 1.0, green: 0.90, blue: 0.82)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .overlay(
                                Capsule()
                                    .stroke(Color(red: 0.92, green: 0.85, blue: 0.78), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Journal Onboarding Video View

struct JournalOnboardingVideoView: View {
    var onComplete: () -> Void

    @State private var player: AVPlayer?
    @State private var hasCompleted = false
    @State private var playbackTimer: Timer?
    @State private var timeObserverToken: Any?
    @State private var endObserverToken: NSObjectProtocol?
    @State private var statusObservation: NSKeyValueObservation?

    var body: some View {
        ZStack {
            // Black background in case video doesn't load
            Color.black.ignoresSafeArea()

            if let player = player {
                JournalVideoPlayerView(player: player)
                    .ignoresSafeArea()
            }
        }
        .onAppear {
            setupVideo()
        }
        .onDisappear {
            cleanup()
        }
    }

    private func setupVideo() {
        // Try root, then Videos subfolder, then mov fallback
        guard let videoURL = Bundle.main.url(forResource: "JournalOnboardingVideo", withExtension: "mp4")
                ?? Bundle.main.url(forResource: "JournalOnboardingVideo", withExtension: "mp4", subdirectory: "Videos")
                ?? Bundle.main.url(forResource: "JournalOnboardingVideo", withExtension: "mov")
                ?? Bundle.main.url(forResource: "JournalOnboardingVideo", withExtension: "mov", subdirectory: "Videos") else {
            print("⚠️ [JournalOnboardingVideoView] Video not found in bundle, completing immediately")
            completeVideo()
            return
        }

        let playerItem = AVPlayerItem(url: videoURL)
        player = AVPlayer(playerItem: playerItem)

        // Mute to prevent interrupting user's music
        player?.isMuted = true
        player?.volume = 0

        // Prevent system-level pause/interruptions
        player?.automaticallyWaitsToMinimizeStalling = false
        player?.actionAtItemEnd = .none

        // Monitor when near the end to start transition early
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            guard let duration = self.player?.currentItem?.duration,
                  duration.isValid && duration.isNumeric else { return }

            let currentSeconds = time.seconds
            let totalSeconds = duration.seconds

            // Start transition 0.3 seconds before the end
            if currentSeconds >= totalSeconds - 0.3 && currentSeconds < totalSeconds {
                self.completeVideo()
            }
        }

        // Fallback: monitor actual completion
        endObserverToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { _ in
            completeVideo()
        }

        // Monitor for errors
        statusObservation = playerItem.observe(\.status) { item, _ in
            if item.status == .failed {
                print("❌ [JournalOnboardingVideoView] Video failed: \(item.error?.localizedDescription ?? "Unknown")")
                DispatchQueue.main.async {
                    self.completeVideo()
                }
            }
        }

        // Start playing
        player?.play()

        // Timer to force resume if paused
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if self.player?.rate == 0 && !self.hasCompleted {
                self.player?.play()
            }
        }
    }

    private func completeVideo() {
        guard !hasCompleted else { return }
        hasCompleted = true

        playbackTimer?.invalidate()
        playbackTimer = nil

        player?.pause()
        AnalyticsService.shared.capture("journal_onboarding_completed")
        onComplete()
    }

    private func cleanup() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let token = endObserverToken {
            NotificationCenter.default.removeObserver(token)
            endObserverToken = nil
        }
        statusObservation = nil
        player?.pause()
        player = nil
    }
}

// MARK: - Non-Interactive Video Player

private struct JournalVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> JournalNonInteractivePlayerView {
        let view = JournalNonInteractivePlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspectFill
        view.showsFullScreenToggleButton = false
        view.allowsPictureInPicturePlayback = false
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: JournalNonInteractivePlayerView, context: Context) {}
}

private class JournalNonInteractivePlayerView: AVPlayerView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Prevent all mouse interactions
        return nil
    }

    override func keyDown(with event: NSEvent) {
        // Ignore all keyboard events (including spacebar)
    }

    override func mouseDown(with event: NSEvent) {
        // Ignore mouse clicks
    }

    override func rightMouseDown(with event: NSEvent) {
        // Ignore right clicks
    }

    override var acceptsFirstResponder: Bool {
        return false
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

#Preview {
    JournalView()
}
