import SwiftUI

// MARK: - Constants

private enum K {
  // Geometry (matching SVG: viewBox 100×100, displayed in 140×140 wrapper)
  static let gapFrac: CGFloat = 0.035
  static let strokeWidth: CGFloat = 8
  static let ringDiameter: CGFloat = 76  // 2 × R(38)
  static let containerSize: CGFloat = 140

  // Animation tuning ("whisper" style from HTML prototype)
  static let squishScale: CGFloat = 0.95
  static let squishRotate: Double = -1.5
  static let popScale: CGFloat = 1.08
  static let particleCount = 6
  static let particleSpread: CGFloat = 40
  static let windUpSec: Double = 0.08
  static let counterSec: Double = 0.25
  static let counterBounce: CGFloat = 1.05
  static let segStaggerSec: Double = 0.07

  // Colors
  static let trackColor = Color(red: 1, green: 200.0 / 255, blue: 160.0 / 255).opacity(0.3)
  static let fillColor = Color(hex: "FF8D40")
  static let textColor = Color(hex: "FF8D40")

  static let particleColors: [Color] = [
    Color(hex: "FF8D40"), Color(hex: "FFB69B"), Color(hex: "FFCC66"),
    Color(hex: "FFA060"), Color(hex: "FFD4A8"),
  ]
  static let confettiColors: [Color] = [
    Color(hex: "FF6B6B"), Color(hex: "FFD93D"), Color(hex: "6BCB77"),
    Color(hex: "4D96FF"), Color(hex: "FF8D40"), Color(hex: "C780FA"),
    Color(hex: "FF6B9D"), Color(hex: "45B7D1"),
  ]

  // Dynamic geometry helpers
  static func segFrac(for count: Int) -> CGFloat {
    (1 - gapFrac * CGFloat(count)) / CGFloat(count)
  }

  static func segRotation(_ i: Int, of count: Int) -> Double {
    (Double(i) / Double(count)) * 360 - 90
  }

  static func segMidAngle(_ i: Int, of count: Int) -> Double {
    segRotation(i, of: count) + (360.0 / Double(count)) / 2
  }
}

// MARK: - ProgressRingView

struct ProgressRingView: View {

  /// Total number of segments in the ring.
  let totalSegments: Int

  /// Number of filled segments (0...totalSegments). Animate on change.
  let filledSegments: Int

  // MARK: Internal state

  @State private var renderedSegCount = 0
  @State private var segFillAmounts: [CGFloat] = []
  @State private var segVisible: [Bool] = []
  @State private var segStrokeWidths: [CGFloat] = []

  @State private var ringScale: CGFloat = 1
  @State private var ringRotation: Double = 0

  @State private var displayPercent: Int = 0
  @State private var percentScale: CGFloat = 1

  @State private var animating = false
  @State private var initialized = false

  @State private var particles: [ParticleData] = []
  @State private var confetti: [ConfettiData] = []

  // MARK: Derived geometry

  private var segFrac: CGFloat { K.segFrac(for: totalSegments) }

  private func segRotation(_ i: Int) -> Double {
    K.segRotation(i, of: totalSegments)
  }

  private func segMidAngle(_ i: Int) -> Double {
    K.segMidAngle(i, of: totalSegments)
  }

  // MARK: - Body

  var body: some View {
    ZStack {
      ring
        .scaleEffect(ringScale)
        .rotationEffect(.degrees(ringRotation))

      Text("\(displayPercent)%")
        .font(.custom("Figtree-Bold", size: 16))
        .foregroundColor(K.textColor)
        .scaleEffect(percentScale)

      ForEach(particles) { p in ParticleView(data: p) }
      ForEach(confetti) { c in ConfettiView(data: c) }
    }
    .frame(width: K.containerSize, height: K.containerSize)
    .onAppear {
      guard !initialized else { return }
      initialized = true
      initializeState()
    }
    .onChange(of: filledSegments) { _, newValue in
      advanceTo(newValue)
    }
  }

  // MARK: - Ring

  private var ring: some View {
    ZStack {
      ForEach(0..<totalSegments, id: \.self) { i in
        Circle()
          .trim(from: 0, to: segFrac)
          .stroke(style: StrokeStyle(lineWidth: K.strokeWidth, lineCap: .round))
          .foregroundColor(K.trackColor)
          .rotationEffect(.degrees(segRotation(i)))
      }

      if !segFillAmounts.isEmpty {
        ForEach(0..<totalSegments, id: \.self) { i in
          Circle()
            .trim(from: 0, to: segFillAmounts[i])
            .stroke(style: StrokeStyle(lineWidth: segStrokeWidths[i], lineCap: .round))
            .foregroundColor(K.fillColor)
            .rotationEffect(.degrees(segRotation(i)))
            .opacity(segVisible[i] ? 1 : 0)
        }
      }
    }
    .frame(width: K.ringDiameter, height: K.ringDiameter)
  }

  // MARK: - Initialize

  private func initializeState() {
    segFillAmounts = Array(repeating: 0, count: totalSegments)
    segVisible = Array(repeating: false, count: totalSegments)
    segStrokeWidths = Array(repeating: K.strokeWidth, count: totalSegments)

    // Set already-filled segments instantly (no animation on first appear)
    for i in 0..<min(filledSegments, totalSegments) {
      segFillAmounts[i] = segFrac
      segVisible[i] = true
    }
    renderedSegCount = filledSegments
    displayPercent = percent(for: filledSegments)
  }

  // MARK: - Advance to target

  private func advanceTo(_ target: Int) {
    guard initialized else { return }
    let clamped = min(target, totalSegments)
    guard clamped > renderedSegCount else { return }

    let prev = renderedSegCount
    let next = clamped
    let hit100 = next >= totalSegments

    let prevPct = percent(for: prev)
    let newPct = percent(for: next)

    animating = true

    // ① SQUISH
    withAnimation(.timingCurve(0.4, 0, 1, 1, duration: 0.12)) {
      ringScale = K.squishScale
      ringRotation = K.squishRotate
    }

    // ② After wind-up: pop, fill, particles, counter
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: nsec(K.windUpSec))

      let popTarget: CGFloat = hit100 ? K.popScale * 1.15 : K.popScale
      withAnimation(.timingCurve(0.34, 1.56, 0.64, 1, duration: 0.25)) {
        ringScale = popTarget
        ringRotation = 0
      }

      let newSegs = Array(prev..<next)
      for (idx, seg) in newSegs.enumerated() {
        let stagger = Double(idx) * K.segStaggerSec
        Task { @MainActor in
          try? await Task.sleep(nanoseconds: nsec(stagger))
          fillSegment(seg, hit100: hit100, totalNewSegs: newSegs.count)
        }
      }

      renderedSegCount = next

      if hit100 {
        spawnConfetti(count: 40, spread: 140)
      }

      let counterDuration = K.counterSec + Double(newSegs.count) * K.segStaggerSec
      animateCounter(from: prevPct, to: newPct, duration: counterDuration)

      // ③ RETURN to rest
      let totalStagger = Double(newSegs.count) * K.segStaggerSec
      try? await Task.sleep(nanoseconds: nsec(totalStagger + 0.12))

      withAnimation(.timingCurve(0.34, 1.56, 0.64, 1, duration: 0.4)) {
        ringScale = 1
        ringRotation = 0
      }

      try? await Task.sleep(nanoseconds: nsec(0.2))
      animating = false

      if hit100 {
        celebrate()
      }
    }
  }

  // MARK: - Fill a single segment

  private func fillSegment(_ index: Int, hit100: Bool, totalNewSegs: Int) {
    guard index < segFillAmounts.count else { return }

    segVisible[index] = true
    withAnimation(.timingCurve(0.34, 1.56, 0.64, 1, duration: 0.4)) {
      segFillAmounts[index] = segFrac
    }

    withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.2)) {
      segStrokeWidths[index] = K.strokeWidth * 1.3
    }
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: nsec(0.2))
      withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.2)) {
        segStrokeWidths[index] = K.strokeWidth
      }
    }

    let pCount = hit100 ? 25 : K.particleCount
    let pPerSeg = Int(ceil(Double(pCount) / Double(totalNewSegs)))
    let spread = hit100 ? K.particleSpread * 1.3 : K.particleSpread
    spawnParticles(count: pPerSeg, spread: spread, atAngle: segMidAngle(index))
  }

  // MARK: - Counter animation

  private func animateCounter(from: Int, to: Int, duration: Double) {
    Task { @MainActor in
      let startTime = CACurrentMediaTime()
      var lastVal = from

      while true {
        try? await Task.sleep(nanoseconds: 16_666_667)  // ~60 fps
        let elapsed = CACurrentMediaTime() - startTime
        let t = min(elapsed / duration, 1)
        let eased = 1 - pow(1 - t, 3)  // easeOutCubic
        let val = Int(round(Double(from) + Double(to - from) * eased))

        if val != lastVal {
          displayPercent = val
          lastVal = val
          bouncePercent()
        }

        if t >= 1 {
          displayPercent = to
          break
        }
      }
    }
  }

  private func bouncePercent() {
    withAnimation(.easeOut(duration: 0.06)) {
      percentScale = K.counterBounce
    }
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: nsec(0.06))
      withAnimation(.easeOut(duration: 0.06)) {
        percentScale = 1
      }
    }
  }

  // MARK: - Particles

  private func spawnParticles(count: Int, spread: CGFloat, atAngle: Double) {
    var batch: [ParticleData] = []
    for _ in 0..<count {
      let sz = CGFloat.random(in: 3...7)
      let angle = atAngle + Double.random(in: -60...60)
      let dist = CGFloat.random(in: spread * 0.5...spread)
      let rad = angle * .pi / 180
      let col = K.particleColors.randomElement()!
      let delay = Double.random(in: 0...0.1)
      let duration = Double.random(in: 0.4...0.6)

      batch.append(
        ParticleData(
          size: sz,
          targetX: cos(rad) * dist,
          targetY: sin(rad) * dist,
          color: col,
          delay: delay,
          duration: duration
        ))
    }
    particles.append(contentsOf: batch)

    let ids = Set(batch.map(\.id))
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: nsec(0.9))
      particles.removeAll { ids.contains($0.id) }
    }
  }

  // MARK: - Confetti

  private func spawnConfetti(count: Int, spread: CGFloat) {
    var batch: [ConfettiData] = []
    for _ in 0..<count {
      let w = CGFloat.random(in: 4...10)
      let h = CGFloat.random(in: 6...14)
      let angle = Double.random(in: 0...360)
      let dist = CGFloat.random(in: spread * 0.4...spread)
      let rad = angle * .pi / 180
      let col = K.confettiColors.randomElement()!
      let delay = Double.random(in: 0...0.15)
      let spin = Double.random(in: -720...720)
      let dur = Double.random(in: 0.8...1.4)
      let yExtra = CGFloat.random(in: 30...80)
      let endScale = CGFloat.random(in: 0.3...0.8)

      batch.append(
        ConfettiData(
          width: w, height: h,
          targetX: cos(rad) * dist,
          targetY: sin(rad) * dist + yExtra,
          spin: spin,
          endScale: endScale,
          color: col,
          delay: delay,
          duration: dur
        ))
    }
    confetti.append(contentsOf: batch)

    let ids = Set(batch.map(\.id))
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: nsec(1.6))
      confetti.removeAll { ids.contains($0.id) }
    }
  }

  // MARK: - Celebration

  private func celebrate() {
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: nsec(0.4))
      spawnConfetti(count: 30, spread: 160)
    }
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: nsec(0.8))
      spawnConfetti(count: 20, spread: 120)
    }
  }

  // MARK: - Helpers

  private func percent(for filled: Int) -> Int {
    totalSegments > 0 ? Int(round(Double(filled) / Double(totalSegments) * 100)) : 0
  }

  private func nsec(_ seconds: Double) -> UInt64 {
    UInt64(seconds * 1_000_000_000)
  }
}

// MARK: - ParticleData

private struct ParticleData: Identifiable {
  let id = UUID()
  let size: CGFloat
  let targetX: CGFloat
  let targetY: CGFloat
  let color: Color
  let delay: Double
  let duration: Double
}

// MARK: - ParticleView

private struct ParticleView: View {
  let data: ParticleData
  @State private var progress: CGFloat = 0

  var body: some View {
    Circle()
      .fill(data.color)
      .frame(width: data.size, height: data.size)
      .offset(x: data.targetX * progress, y: data.targetY * progress)
      .scaleEffect(1 - progress)
      .opacity(Double(1 - progress))
      .onAppear {
        withAnimation(
          .timingCurve(0.16, 0.84, 0.44, 1, duration: data.duration).delay(data.delay)
        ) {
          progress = 1
        }
      }
  }
}

// MARK: - ConfettiData

private struct ConfettiData: Identifiable {
  let id = UUID()
  let width: CGFloat
  let height: CGFloat
  let targetX: CGFloat
  let targetY: CGFloat
  let spin: Double
  let endScale: CGFloat
  let color: Color
  let delay: Double
  let duration: Double
}

// MARK: - ConfettiView

private struct ConfettiView: View {
  let data: ConfettiData
  @State private var progress: CGFloat = 0

  var body: some View {
    RoundedRectangle(cornerRadius: 2)
      .fill(data.color)
      .frame(width: data.width, height: data.height)
      .offset(x: data.targetX * progress, y: data.targetY * progress)
      .rotationEffect(.degrees(data.spin * Double(progress)))
      .scaleEffect(1 - (1 - data.endScale) * progress)
      .opacity(Double(1 - progress))
      .onAppear {
        withAnimation(
          .timingCurve(0.16, 0.84, 0.44, 1, duration: data.duration).delay(data.delay)
        ) {
          progress = 1
        }
      }
  }
}

// MARK: - Preview

#Preview("Progress Ring") {
  ProgressRingDemoView()
    .frame(width: 300, height: 280)
    .background(Color(red: 253.0 / 255, green: 248.0 / 255, blue: 241.0 / 255))
}

/// Interactive demo wrapper for previewing the ring with step controls.
private struct ProgressRingDemoView: View {
  @State private var filled = 0

  var body: some View {
    VStack(spacing: 20) {
      ProgressRingView(totalSegments: 7, filledSegments: filled)

      HStack(spacing: 8) {
        Button("Advance") { filled = min(filled + 1, 7) }
          .buttonStyle(.borderedProminent)
          .disabled(filled >= 7)

        Button("Reset") { filled = 0 }
          .buttonStyle(.bordered)
      }
    }
  }
}
