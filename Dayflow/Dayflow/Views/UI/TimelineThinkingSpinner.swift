import QuartzCore
import SwiftUI

struct TimelineThinkingSpinner: View {
  var config: TimelineSpinnerConfig = .reference
  var visualScale: CGFloat = 1

  var body: some View {
    TimelineSpinnerView(config: config)
      .id(config.identityKey)
      .scaleEffect(visualScale)
      .frame(
        width: config.sideLength * visualScale,
        height: config.sideLength * visualScale
      )
  }
}

struct TimelineSpinnerConfig {
  // Wave (matches reference JS)
  var cycleDuration: Double = 1.5
  var bandWidth: Double = 0.5
  var trailDecay: Double = 0.94
  var wavePower: Double = 2.2

  // Bloom (approximates SVG filter stages)
  var amplify: Double = 4.0
  var threshold: Double = 1.0
  var blurTight: CGFloat = 0.5
  var blurWide: CGFloat = 50.0
  var gainTight: Double = 0.5
  var gainWide: Double = 6.0

  // Neighbor compounding
  var neighborBoost: Double = 0.80

  // Geometry (8x8 cells, 3px gap, 30x30 grid)
  var pixelSize: CGFloat = 8
  var gap: CGFloat = 3
  var cornerRadius: CGFloat = 2

  // Colors
  var minOpacity: Double = 0.03
  var colorDim: SIMD3<Double> = .init(0.38, 0.23, 0.11)
  var colorMid: SIMD3<Double> = .init(0.93, 0.63, 0.37)
  var colorHot: SIMD3<Double> = .init(1.0, 0.84, 0.66)
  var initialOpacity: Double = 0.04
  var sideLength: CGFloat {
    3 * pixelSize + 2 * gap
  }
  var identityKey: String {
    [
      cycleDuration, bandWidth, trailDecay, wavePower,
      amplify, threshold, Double(blurTight), Double(blurWide), gainTight, gainWide,
      neighborBoost, Double(pixelSize), Double(gap), Double(cornerRadius), minOpacity,
      colorDim.x, colorDim.y, colorDim.z,
      colorMid.x, colorMid.y, colorMid.z,
      colorHot.x, colorHot.y, colorHot.z,
      initialOpacity,
    ]
    .map { String(format: "%.6f", $0) }
    .joined(separator: "|")
  }

  static let reference: TimelineSpinnerConfig = {
    var config = TimelineSpinnerConfig()
    config.colorDim = .init(0.239, 0.102, 0.020)
    config.colorMid = .init(0.878, 0.471, 0.188)
    config.colorHot = .init(1.000, 0.624, 0.353)
    return config
  }()
}

private struct TimelineSpinnerView: View {
  let config: TimelineSpinnerConfig

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @StateObject private var model: TimelineSpinnerModel

  init(config: TimelineSpinnerConfig) {
    self.config = config
    _model = StateObject(wrappedValue: TimelineSpinnerModel(config: config))
  }

  var body: some View {
    let pxSz = config.pixelSize
    let gap = config.gap
    let side = 3 * pxSz + 2 * gap

    ZStack {
      Canvas { ctx, _ in
        drawPixels(&ctx, brightness: model.brightness)
      }

      Canvas { ctx, _ in
        drawBloom(&ctx, brightness: model.brightness, gain: config.gainWide)
      }
      .blur(radius: config.blurWide)
      .blendMode(.screen)
      .allowsHitTesting(false)

      Canvas { ctx, _ in
        drawBloom(&ctx, brightness: model.brightness, gain: config.gainTight)
      }
      .blur(radius: config.blurTight)
      .blendMode(.screen)
      .allowsHitTesting(false)
    }
    .frame(width: side, height: side)
    .drawingGroup()
    .onAppear {
      if reduceMotion {
        model.setStatic()
      } else {
        model.start()
      }
    }
    .onChange(of: reduceMotion) { _, isReduced in
      if isReduced {
        model.setStatic()
      } else {
        model.start()
      }
    }
    .onDisappear {
      model.stop()
    }
  }

  @inline(__always)
  private func drawPixels(_ ctx: inout GraphicsContext, brightness: [Double]) {
    let pxSz = config.pixelSize
    let gap = config.gap

    for i in 0..<9 {
      let b = brightness[i]
      let x = CGFloat(i % 3) * (pxSz + gap)
      let y = CGFloat(i / 3) * (pxSz + gap)
      ctx.fill(
        Path(
          roundedRect: .init(x: x, y: y, width: pxSz, height: pxSz),
          cornerRadius: config.cornerRadius
        ),
        with: .color(pixelColor(b).opacity(b))
      )
    }
  }

  @inline(__always)
  private func drawBloom(_ ctx: inout GraphicsContext, brightness: [Double], gain: Double) {
    let pxSz = config.pixelSize
    let gap = config.gap
    let amp = config.amplify
    let thr = config.threshold

    for i in 0..<9 {
      let b = brightness[i]
      let tb = b * amp - thr
      guard tb > 0 else { continue }
      let x = CGFloat(i % 3) * (pxSz + gap)
      let y = CGFloat(i / 3) * (pxSz + gap)
      ctx.fill(
        Path(
          roundedRect: .init(x: x, y: y, width: pxSz, height: pxSz),
          cornerRadius: config.cornerRadius
        ),
        with: .color(pixelColor(b).opacity(min(1.0, tb * gain)))
      )
    }
  }

  @inline(__always)
  private func pixelColor(_ b: Double) -> Color {
    let rgb: SIMD3<Double> =
      b < 0.45
      ? config.colorDim + (config.colorMid - config.colorDim) * (b / 0.45)
      : config.colorMid + (config.colorHot - config.colorMid) * ((b - 0.45) / 0.55)
    return Color(red: rgb.x, green: rgb.y, blue: rgb.z)
  }
}

@MainActor
private final class TimelineSpinnerModel: NSObject, ObservableObject {
  @Published private(set) var brightness: [Double]

  private let config: TimelineSpinnerConfig
  private var timer: Timer?
  private var trails: [Double] = Array(repeating: 0, count: 9)
  private var startTime: CFTimeInterval = 0
  private var lastFrameTime: CFTimeInterval = 0

  private let diagNorm: [Double]
  private let neighbors: [[Int]]

  init(config: TimelineSpinnerConfig) {
    self.config = config
    self.brightness = Array(repeating: config.initialOpacity, count: 9)

    diagNorm = (0..<9).map { Double($0 % 3 + $0 / 3) / 4.0 }
    neighbors = (0..<9).map { i in
      var result: [Int] = []
      if i % 3 > 0 { result.append(i - 1) }
      if i % 3 < 2 { result.append(i + 1) }
      if i / 3 > 0 { result.append(i - 3) }
      if i / 3 < 2 { result.append(i + 3) }
      return result
    }
    super.init()
  }

  func setStatic() {
    stop()
    brightness = [
      0.06, 0.12, 0.20,
      0.12, 0.20, 0.36,
      0.20, 0.36, 0.58,
    ]
  }

  func start() {
    guard timer == nil else { return }
    let now = CACurrentMediaTime()
    startTime = now
    lastFrameTime = now
    let frameTimer = Timer(
      timeInterval: 1.0 / 60.0,
      target: self,
      selector: #selector(handleFrameTimer),
      userInfo: nil,
      repeats: true
    )
    RunLoop.main.add(frameTimer, forMode: .common)
    timer = frameTimer
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  @objc private func handleFrameTimer() {
    tick()
  }

  private func tick() {
    let now = CACurrentMediaTime()
    let deltaMs = min((now - lastFrameTime) * 1000.0, 50.0)
    lastFrameTime = now

    let decay = pow(config.trailDecay, deltaMs / 16.0)
    let elapsed = now - startTime
    let phase =
      (elapsed.truncatingRemainder(dividingBy: config.cycleDuration)) / config.cycleDuration

    let bw = config.bandWidth
    let wp = config.wavePower
    for i in 0..<9 {
      var dist = abs(diagNorm[i] - phase)
      if dist > 0.5 {
        dist = 1.0 - dist
      }
      let driven = pow(max(0.0, 1.0 - dist / bw), wp)
      trails[i] = max(driven, trails[i] * decay)
    }

    let boost = config.neighborBoost
    var next = brightness
    for i in 0..<9 {
      var sum = 0.0
      for index in neighbors[i] {
        sum += trails[index]
      }
      let average = sum / Double(neighbors[i].count)
      let compound = sqrt(trails[i] * average) * boost
      next[i] = max(config.minOpacity, min(1.0, trails[i] + compound))
    }

    brightness = next
  }
}
