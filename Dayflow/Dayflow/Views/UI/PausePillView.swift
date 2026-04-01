import SwiftUI

/// Dynamic Island-inspired pause pill that morphs between idle, menu, and paused states.
///
/// Storyboard:
///   Idle → Menu:    pill 73→250 (bounce 0.15), chips cascade right-to-left (stagger 50ms)
///   Menu → Idle:    chips exit, pill 250→73 (bounce 0.2, 120ms delay)
///   Menu → Paused:  chips exit, pill 250→84 (bounce 0.2), content morph, status text in
///   Paused → Idle:  status out, pill 84→73 (bounce 0.35), content morph back
struct PausePillView: View {
  @ObservedObject private var appState = AppState.shared
  @ObservedObject private var pauseManager = PauseManager.shared

  private enum Phase { case idle, menu, paused }

  // MARK: - Animated State

  @State private var phase: Phase = .idle
  @State private var pillWidth: CGFloat = 73

  @State private var pauseOpacity: Double = 1
  @State private var pauseScale: Double = 1
  @State private var pauseBlur: Double = 0

  @State private var resumeOpacity: Double = 0
  @State private var resumeScale: Double = 1
  @State private var resumeBlur: Double = 0

  @State private var chipOpacity = [0.0, 0.0, 0.0, 0.0]
  @State private var chipOffsetX = [10.0, 10.0, 10.0, 10.0]
  @State private var chipScaleVal = [0.92, 0.92, 0.92, 0.92]
  @State private var chipBlurVal = [3.0, 3.0, 3.0, 3.0]

  @State private var statusOpacity: Double = 0
  @State private var statusY: Double = 6
  @State private var statusBlurVal: Double = 6
  @State private var isStatusPresented = false
  @State private var statusVisibilityTask: Task<Void, Never>?

  @State private var isPillHovered = false
  @State private var hoveredChip: Int? = nil
  @GestureState private var isPillPressed = false

  // MARK: - Chip Data

  private static let chips: [(label: String, duration: PauseDuration, isInf: Bool)] = [
    ("∞", .indefinite, true),
    ("1 Hour", .hour1, false),
    ("30 Mins", .minutes30, false),
    ("15 Mins", .minutes15, false),
  ]

  private var formattedRemaining: String {
    guard let secs = pauseManager.remainingSeconds, secs > 0 else { return "∞" }
    return String(format: "%02d:%02d", secs / 60, secs % 60)
  }

  private var statusText: String {
    if pauseManager.isPausedIndefinitely {
      return "Dayflow paused indefinitely"
    }

    return "Dayflow paused for \(formattedRemaining)"
  }

  private var pillLabelFont: Font {
    .custom("Nunito-Medium", size: 12)
  }

  private var statusSpacing: CGFloat { 10 }

  private var pillScale: CGFloat {
    let hoverScale = isPillHovered && phase == .idle ? 1.02 : 1
    let pressScale = isPillPressed && phase != .menu ? 0.97 : 1
    return hoverScale * pressScale
  }

  private var showsChips: Bool {
    phase == .menu || chipOpacity.contains { $0 > 0.001 }
  }

  private var controlMode: RecordingControlMode {
    RecordingControl.currentMode(appState: appState, pauseManager: pauseManager)
  }

  private var showsPrimaryContent: Bool {
    phase != .paused || pauseOpacity > 0.001
  }

  private var showsResumeContent: Bool {
    phase == .paused || resumeOpacity > 0.001
  }

  // MARK: - Body

  var body: some View {
    HStack(spacing: isStatusPresented ? statusSpacing : 0) {
      if isStatusPresented {
        Text(statusText)
          .font(pillLabelFont)
          .foregroundColor(Color(hex: "F3854B"))
          .tracking(-0.36)
          .monospacedDigit()
          .lineLimit(1)
          .fixedSize()
          .opacity(statusOpacity)
          .offset(y: statusY)
          .blur(radius: statusBlurVal)
          .allowsHitTesting(false)
      }

      pill
    }
    .frame(height: 32)
    .fixedSize(horizontal: true, vertical: false)
    .onAppear(perform: syncOnAppear)
    .onDisappear { cancelStatusVisibilityTask() }
    .onChange(of: appState.isRecording) {
      handleExternalRecordingChange()
    }
    .onChange(of: pauseManager.isPaused) { _, isPaused in
      handleExternalPauseChange(isPaused)
    }
  }

  // MARK: - Pill

  private var pill: some View {
    ZStack(alignment: .leading) {
      ZStack {
        Grad.idle.opacity(phase == .idle ? 1 : 0)
        Grad.menu.opacity(phase == .menu ? 1 : 0)
        Grad.paused.opacity(phase == .paused ? 1 : 0)
      }
      .allowsHitTesting(false)
      .animation(.easeInOut(duration: 0.35), value: phase)

      ZStack {
        shineLayer(Col.shineIdle).opacity(phase == .idle ? 1 : 0)
        shineLayer(Col.shineMenu).opacity(phase == .menu ? 1 : 0)
        shineLayer(Col.shinePaused).opacity(phase == .paused ? 1 : 0)
      }
      .allowsHitTesting(false)
      .animation(.easeInOut(duration: 0.35), value: phase)

      if showsPrimaryContent || showsChips {
        HStack(spacing: 0) {
          if showsPrimaryContent {
            primaryContent
          }

          if showsChips {
            chipsContent
          }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      }

      if showsResumeContent {
        resumeContent
          .padding(.leading, 12)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      }

      Capsule()
        .strokeBorder(Color(hex: "FFE1C9"), lineWidth: 1.25)
        .allowsHitTesting(false)
    }
    .frame(width: pillWidth, height: 32)
    .clipShape(Capsule())
    .contentShape(Capsule())
    .onTapGesture(perform: handlePillTap)
    .simultaneousGesture(
      DragGesture(minimumDistance: 0)
        .updating($isPillPressed) { _, state, _ in
          guard phase != .menu else { return }
          state = true
        }
    )
    .scaleEffect(pillScale)
    .animation(.spring(duration: 0.2, bounce: 0), value: pillScale)
    .onHover { isPillHovered = $0 }
    .pointingHandCursor()
  }

  private var primaryContent: some View {
    HStack(spacing: 4) {
      PillPauseIcon()
      Text("Pause")
        .font(pillLabelFont)
        .foregroundColor(Color(hex: "786655"))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
    .layoutPriority(1)
    .opacity(pauseOpacity)
    .scaleEffect(pauseScale)
    .blur(radius: pauseBlur)
    .allowsHitTesting(false)
  }

  private var chipsContent: some View {
    HStack(spacing: 2) {
      ForEach(0..<4, id: \.self) { i in chipButton(i) }
    }
    .padding(.leading, 8)
    .allowsHitTesting(phase == .menu)
  }

  private var resumeContent: some View {
    HStack(spacing: 4) {
      PillPlayIcon().offset(x: 0.5)
      Text("Resume")
        .font(pillLabelFont)
        .foregroundColor(.white)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
    .layoutPriority(1)
    .opacity(resumeOpacity)
    .scaleEffect(resumeScale)
    .blur(radius: resumeBlur)
    .allowsHitTesting(false)
  }

  // MARK: - Shine

  private func shineLayer(_ color: Color) -> some View {
    // CSS: inset ±3px 0 5px — horizontal glow on left/right edges only
    HStack(spacing: 0) {
      LinearGradient(colors: [color, color.opacity(0)], startPoint: .leading, endPoint: .trailing)
        .frame(width: 8)
      Spacer(minLength: 0)
      LinearGradient(colors: [color.opacity(0), color], startPoint: .leading, endPoint: .trailing)
        .frame(width: 8)
    }
    .clipShape(Capsule())
  }

  // MARK: - Chip Button

  private func chipButton(_ i: Int) -> some View {
    let chip = Self.chips[i]
    let hovered = hoveredChip == i
    let combinedScale = CGFloat(chipScaleVal[i] * (hovered ? 1.05 : 1))

    return Button {
      startPause(chip.duration)
    } label: {
      ZStack {
        Capsule().fill(Grad.chip)
        Capsule().fill(Grad.chipHover).opacity(hovered ? 1 : 0)
        Capsule().strokeBorder(Color.white.opacity(0.6), lineWidth: 1)
        Text(chip.label)
          .font(
            chip.isInf
              ? .system(size: 11, weight: .medium)
              : .system(size: 8, weight: .semibold)
          )
          .foregroundColor(hovered ? .white : Color(hex: "494949"))
      }
      .frame(width: 42, height: 20)
      .contentShape(Capsule())
    }
    .buttonStyle(PillChipButtonStyle())
    .opacity(chipOpacity[i])
    .offset(x: chipOffsetX[i])
    .scaleEffect(combinedScale)
    .blur(radius: chipBlurVal[i])
    .animation(.spring(duration: 0.15, bounce: 0), value: hovered)
    .onHover { h in
      withAnimation(.easeInOut(duration: 0.15)) {
        hoveredChip = h ? i : nil
      }
    }
  }

  // MARK: - Tap Handler

  private func handlePillTap() {
    switch phase {
    case .idle:
      if controlMode == .stopped {
        startRecordingFromResumePill()
      } else {
        openMenu()
      }
    case .menu: closeMenu()
    case .paused:
      switch controlMode {
      case .pausedTimed, .pausedIndefinite:
        resumeFromPause()
      case .stopped:
        startRecordingFromResumePill()
      case .active:
        openMenu()
      }
    }
  }

  private func startRecordingFromResumePill() {
    phase = .idle
    RecordingControl.start(reason: "user_main_app")
    animatePausedToIdle()
  }

  // MARK: - Idle → Menu

  private func openMenu() {
    phase = .menu
    resetChips()

    withAnimation(.spring(duration: 0.5, bounce: 0.15)) {
      pillWidth = 250
    }

    // Chips cascade in next frame (after reset is committed)
    Task { @MainActor in
      for i in (0..<4).reversed() {
        let delay = 0.06 + Double(3 - i) * 0.05
        withAnimation(.interpolatingSpring(stiffness: 500, damping: 25).delay(delay)) {
          chipOpacity[i] = 1
          chipOffsetX[i] = 0
          chipScaleVal[i] = 1
          chipBlurVal[i] = 0
        }
      }
    }
  }

  // MARK: - Menu → Idle

  private func closeMenu() {
    phase = .idle
    exitChips()

    withAnimation(.spring(duration: 0.45, bounce: 0.2).delay(0.12)) {
      pillWidth = 73
    }
  }

  // MARK: - Menu → Paused

  private func startPause(_ duration: PauseDuration) {
    phase = .paused
    pauseManager.pause(for: duration, source: .mainApp)

    exitChips()

    withAnimation(.spring(duration: 0.5, bounce: 0.2)) {
      pillWidth = 84
    }

    // Pause content exits (scale down + blur out)
    withAnimation(.spring(duration: 0.2, bounce: 0)) {
      pauseOpacity = 0
      pauseScale = 0.7
      pauseBlur = 5
    }

    // Snap resume to start position (instant)
    resumeOpacity = 0
    resumeScale = 0.8
    resumeBlur = 5

    // Resume enters + status fades in (after snap is committed)
    Task { @MainActor in
      withAnimation(.spring(duration: 0.35, bounce: 0.25).delay(0.06)) {
        resumeOpacity = 1
        resumeScale = 1
        resumeBlur = 0
      }
      presentStatusText(autoHide: duration == .indefinite, animationDelay: 0.1)
    }
  }

  // MARK: - Paused → Idle

  private func resumeFromPause() {
    phase = .idle
    pauseManager.resume(source: .userClickedMainApp)
    animatePausedToIdle()
  }

  private func animatePausedToIdle() {
    hideStatusText(animation: .spring(duration: 0.2, bounce: 0))

    // Pill shrinks to idle
    withAnimation(.spring(duration: 0.4, bounce: 0.35)) {
      pillWidth = 73
    }

    // Resume content exits
    withAnimation(.spring(duration: 0.18, bounce: 0)) {
      resumeOpacity = 0
      resumeScale = 0.85
      resumeBlur = 4
    }

    // Snap pause content to start position (instant)
    pauseOpacity = 0
    pauseScale = 0.85
    pauseBlur = 4

    // Pause content enters (after snap is committed)
    Task { @MainActor in
      withAnimation(.spring(duration: 0.3, bounce: 0.3).delay(0.05)) {
        pauseOpacity = 1
        pauseScale = 1
        pauseBlur = 0
      }
    }
  }

  private func setResumePillState(showStatusText: Bool) {
    phase = .paused
    pillWidth = 84
    pauseOpacity = 0
    pauseScale = 0.7
    pauseBlur = 5
    resumeOpacity = 1
    resumeScale = 1
    resumeBlur = 0

    if showStatusText {
      isStatusPresented = true
      statusOpacity = 1
      statusY = 0
      statusBlurVal = 0
    } else {
      cancelStatusVisibilityTask()
      isStatusPresented = false
      statusOpacity = 0
      statusY = 6
      statusBlurVal = 6
    }
  }

  private func transitionToResumePill(showStatusText: Bool) {
    phase = .paused
    exitChips()

    withAnimation(.spring(duration: 0.5, bounce: 0.2)) {
      pillWidth = 84
    }

    withAnimation(.spring(duration: 0.2, bounce: 0)) {
      pauseOpacity = 0
      pauseScale = 0.7
      pauseBlur = 5
    }

    resumeOpacity = 0
    resumeScale = 0.8
    resumeBlur = 5

    if !showStatusText {
      cancelStatusVisibilityTask()
      isStatusPresented = false
      statusOpacity = 0
      statusY = 6
      statusBlurVal = 6
    }

    Task { @MainActor in
      withAnimation(.spring(duration: 0.35, bounce: 0.25).delay(0.06)) {
        resumeOpacity = 1
        resumeScale = 1
        resumeBlur = 0
      }

      if showStatusText {
        presentStatusText(autoHide: pauseManager.isPausedIndefinitely, animationDelay: 0.1)
      }
    }
  }

  // MARK: - Helpers

  private func exitChips() {
    for i in 0..<4 {
      withAnimation(.spring(duration: 0.2, bounce: 0)) {
        chipOpacity[i] = 0
        chipOffsetX[i] = 4
        chipBlurVal[i] = 2
      }
    }
  }

  private func resetChips() {
    for i in 0..<4 {
      chipOpacity[i] = 0
      chipOffsetX[i] = 10
      chipScaleVal[i] = 0.92
      chipBlurVal[i] = 3
    }
  }

  // MARK: - External State Sync

  private func syncOnAppear() {
    switch controlMode {
    case .pausedTimed, .pausedIndefinite:
      setResumePillState(showStatusText: true)
      if pauseManager.isPausedIndefinitely {
        scheduleStatusAutoHide(after: 3)
      }
    case .stopped:
      setResumePillState(showStatusText: false)
    case .active:
      break
    }
  }

  private func handleExternalPauseChange(_ isPaused: Bool) {
    if isPaused {
      transitionToResumePill(showStatusText: true)
    } else if !isPaused, phase == .paused {
      if controlMode == .stopped {
        setResumePillState(showStatusText: false)
      } else {
        phase = .idle
        animatePausedToIdle()
      }
    }
  }

  private func handleExternalRecordingChange() {
    guard !pauseManager.isPaused else { return }
    if controlMode == .active {
      guard phase == .paused else { return }
      phase = .idle
      animatePausedToIdle()
      return
    }

    guard phase != .paused else { return }
    transitionToResumePill(showStatusText: false)
  }

  private func presentStatusText(autoHide: Bool, animationDelay: Double = 0) {
    cancelStatusVisibilityTask()
    isStatusPresented = true
    statusOpacity = 0
    statusY = 6
    statusBlurVal = 6

    withAnimation(.spring(duration: 0.3, bounce: 0).delay(animationDelay)) {
      statusOpacity = 1
      statusY = 0
      statusBlurVal = 0
    }

    if autoHide {
      scheduleStatusAutoHide(after: animationDelay + 3)
    }
  }

  private func hideStatusText(animation: Animation = .easeOut(duration: 0.22)) {
    cancelStatusVisibilityTask()
    guard isStatusPresented else { return }

    withAnimation(animation) {
      statusOpacity = 0
      statusY = 6
      statusBlurVal = 6
    }

    statusVisibilityTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 240_000_000)
      guard !Task.isCancelled else { return }
      isStatusPresented = false
    }
  }

  private func scheduleStatusAutoHide(after delay: Double) {
    cancelStatusVisibilityTask()
    statusVisibilityTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard !Task.isCancelled else { return }
      hideStatusText(animation: .easeOut(duration: 0.22))
    }
  }

  private func cancelStatusVisibilityTask() {
    statusVisibilityTask?.cancel()
    statusVisibilityTask = nil
  }
}

// MARK: - Pill Icons

private struct PillPauseIcon: View {
  var body: some View {
    Canvas { ctx, _ in
      let color = Color(hex: "786655")
      ctx.fill(Path(CGRect(x: 3, y: 2.5, width: 2, height: 7)), with: .color(color))
      ctx.fill(Path(CGRect(x: 7, y: 2.5, width: 2, height: 7)), with: .color(color))
    }
    .frame(width: 12, height: 12)
  }
}

private struct PillPlayIcon: View {
  var body: some View {
    Canvas { ctx, _ in
      var p = Path()
      p.move(to: CGPoint(x: 4, y: 2.5))
      p.addLine(to: CGPoint(x: 4, y: 9.5))
      p.addLine(to: CGPoint(x: 9.5, y: 6))
      p.closeSubpath()
      ctx.fill(p, with: .color(.white))
    }
    .frame(width: 12, height: 12)
  }
}

// MARK: - Chip Button Style

private struct PillChipButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.95 : 1)
      .animation(.spring(duration: 0.15, bounce: 0), value: configuration.isPressed)
  }
}

// MARK: - Gradients (exact from React CSS tokens)

private enum Grad {
  static let idle = LinearGradient(
    stops: [
      .init(color: Color(red: 1, green: 0.973, blue: 0.949).opacity(0.6), location: 0),
      .init(color: Color(red: 1, green: 0.906, blue: 0.827).opacity(0.6), location: 0.495),
      .init(color: Color(red: 1, green: 0.804, blue: 0.690).opacity(0.6), location: 0.755),
      .init(color: Color(red: 1, green: 0.906, blue: 0.827).opacity(0.6), location: 1),
    ],
    startPoint: .top, endPoint: .bottom
  )

  static let menu = LinearGradient(
    stops: [
      .init(color: Color(red: 0.973, green: 0.784, blue: 0.675).opacity(0.6), location: 0),
      .init(color: Color(red: 1, green: 0.906, blue: 0.835).opacity(0.6), location: 0.14),
      .init(color: Color(red: 1, green: 0.816, blue: 0.694).opacity(0.6), location: 0.688),
      .init(color: Color(red: 0.973, green: 0.784, blue: 0.675).opacity(0.6), location: 1),
    ],
    startPoint: .top, endPoint: .bottom
  )

  static let paused = LinearGradient(
    stops: [
      .init(color: Color(red: 1, green: 0.714, blue: 0.608), location: 0),
      .init(color: Color(red: 1, green: 0.569, blue: 0.278), location: 0.495),
      .init(color: Color(red: 1, green: 0.553, blue: 0.251), location: 0.760),
      .init(color: Color(red: 1, green: 0.643, blue: 0.510), location: 1),
    ],
    startPoint: .top, endPoint: .bottom
  )

  // Chip default — 320deg CSS ≈ bottomTrailing→topLeading
  static let chip = LinearGradient(
    stops: [
      .init(color: Color.white.opacity(0.72), location: 0),
      .init(color: Color.white.opacity(0.56), location: 0.38),
      .init(color: Color.white.opacity(0.44), location: 1),
    ],
    startPoint: UnitPoint(x: 0.91, y: 0.97),
    endPoint: UnitPoint(x: 0.11, y: 0)
  )

  // Chip hover — orange gradient overlay
  static let chipHover = LinearGradient(
    stops: [
      .init(color: Color(red: 1, green: 0.702, blue: 0.565).opacity(0.82), location: 0),
      .init(color: Color(red: 1, green: 0.624, blue: 0.416).opacity(0.82), location: 0.42),
      .init(color: Color(red: 1, green: 0.553, blue: 0.251).opacity(0.82), location: 1),
    ],
    startPoint: UnitPoint(x: 0.91, y: 0.97),
    endPoint: UnitPoint(x: 0.11, y: 0)
  )
}

// MARK: - Shine Colors (inset glow per state)

private enum Col {
  static let shineIdle = Color.white.opacity(0.5)
  static let shineMenu = Color(red: 0.949, green: 0.749, blue: 0.655).opacity(0.5)
  static let shinePaused = Color(red: 1, green: 0.894, blue: 0.761).opacity(0.5)
}

// MARK: - Preview

#Preview("Pause Pill") {
  VStack(spacing: 40) {
    PausePillView()
  }
  .frame(width: 400, height: 200)
  .background(Color(red: 0.992, green: 0.973, blue: 0.945))  // #FDF8F1
}
