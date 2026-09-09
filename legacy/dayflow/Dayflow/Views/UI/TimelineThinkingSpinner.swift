import AppKit
import CoreImage
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
  var cycleDuration: Double = 1.5
  var bandWidth: Double = 0.5
  var trailDecay: Double = 0.94
  var wavePower: Double = 2.2
  var amplify: Double = 4.0
  var threshold: Double = 1.0
  var blurTight: CGFloat = 0.5
  var gainTight: Double = 0.5
  var neighborBoost: Double = 0.80
  var pixelSize: CGFloat = 8
  var gap: CGFloat = 3
  var cornerRadius: CGFloat = 2
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
      amplify, threshold, Double(blurTight), gainTight,
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

// MARK: - Core Animation Spinner

private struct TimelineSpinnerView: View {
  let config: TimelineSpinnerConfig
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    SpinnerNSViewWrapper(config: config, reduceMotion: reduceMotion)
      .frame(width: config.sideLength, height: config.sideLength)
  }
}

private struct SpinnerNSViewWrapper: NSViewRepresentable {
  let config: TimelineSpinnerConfig
  let reduceMotion: Bool

  func makeNSView(context: Context) -> SpinnerNSView {
    SpinnerNSView(config: config)
  }

  func updateNSView(_ nsView: SpinnerNSView, context: Context) {
    nsView.update(config: config, reduceMotion: reduceMotion)
  }
}

private class SpinnerNSView: NSView {
  private var config: TimelineSpinnerConfig
  private var reduceMotion: Bool = false

  private let pixelContainer = CALayer()
  private let bloomContainer = CALayer()
  private var gridLayers: [(pixel: CALayer, bloom: CALayer)] = []

  private var isAnimating = false
  private var pixelAnimations: [CAKeyframeAnimation] = []
  private var bloomColorAnimations: [CAKeyframeAnimation] = []

  // Match SwiftUI Canvas coordinates.
  override var isFlipped: Bool { true }

  init(config: TimelineSpinnerConfig) {
    self.config = config
    super.init(frame: .zero)
    self.wantsLayer = true
    self.layer?.masksToBounds = false

    pixelContainer.masksToBounds = false
    bloomContainer.masksToBounds = false

    self.layer?.addSublayer(pixelContainer)
    self.layer?.addSublayer(bloomContainer)

    applyFilters()
    setupLayers()
    precomputeAnimations()
    updateState()

    NotificationCenter.default.addObserver(
      self, selector: #selector(appStateChanged), name: NSApplication.didBecomeActiveNotification,
      object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(appStateChanged), name: NSApplication.didResignActiveNotification,
      object: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  deinit { NotificationCenter.default.removeObserver(self) }

  private func applyFilters() {
    if let blurFilter = CIFilter(name: "CIGaussianBlur") {
      blurFilter.setValue(config.blurTight, forKey: kCIInputRadiusKey)
      bloomContainer.filters = [blurFilter]
    }
    if let screenBlend = CIFilter(name: "CIScreenBlendMode") {
      bloomContainer.compositingFilter = screenBlend
    }
  }

  override func layout() {
    super.layout()
    let side = config.sideLength
    let originX = (bounds.width - side) / 2.0
    let originY = (bounds.height - side) / 2.0

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    pixelContainer.frame = CGRect(x: originX, y: originY, width: side, height: side)

    // Expand bloom bounds so the blur does not clip.
    let expand: CGFloat = 20
    bloomContainer.frame = CGRect(
      x: originX - expand, y: originY - expand, width: side + expand * 2, height: side + expand * 2)

    let pxSz = config.pixelSize
    let gap = config.gap

    for i in 0..<9 {
      let x = CGFloat(i % 3) * (pxSz + gap)
      let y = CGFloat(i / 3) * (pxSz + gap)
      gridLayers[i].pixel.frame = CGRect(x: x, y: y, width: pxSz, height: pxSz)

      gridLayers[i].bloom.frame = CGRect(x: x + expand, y: y + expand, width: pxSz, height: pxSz)
    }
    CATransaction.commit()
  }

  func update(config: TimelineSpinnerConfig, reduceMotion: Bool) {
    let configChanged = self.config.identityKey != config.identityKey
    self.config = config
    self.reduceMotion = reduceMotion

    if configChanged {
      stopAnimating()
      applyFilters()
      setupLayers()
      precomputeAnimations()
    }
    updateState()
  }

  private func setupLayers() {
    pixelContainer.sublayers?.forEach { $0.removeFromSuperlayer() }
    bloomContainer.sublayers?.forEach { $0.removeFromSuperlayer() }
    gridLayers.removeAll()

    for _ in 0..<9 {
      let pixelLayer = CALayer()
      pixelLayer.cornerRadius = config.cornerRadius
      pixelLayer.actions = ["backgroundColor": NSNull(), "position": NSNull(), "bounds": NSNull()]

      let bloomLayer = CALayer()
      bloomLayer.cornerRadius = config.cornerRadius
      bloomLayer.actions = ["backgroundColor": NSNull(), "position": NSNull(), "bounds": NSNull()]

      pixelContainer.addSublayer(pixelLayer)
      bloomContainer.addSublayer(bloomLayer)
      gridLayers.append((pixel: pixelLayer, bloom: bloomLayer))
    }
    self.needsLayout = true
  }

  private func precomputeAnimations() {
    let framesPerCycle = max(1, Int(round(config.cycleDuration * 60.0)))
    let dt = config.cycleDuration / Double(framesPerCycle)
    let decay = pow(config.trailDecay, (dt * 1000.0) / 16.0)

    var trails = Array(repeating: 0.0, count: 9)
    var brightness = Array(repeating: config.initialOpacity, count: 9)

    let diagNorm = (0..<9).map { Double($0 % 3 + $0 / 3) / 4.0 }
    let neighbors = (0..<9).map { i in
      var result: [Int] = []
      if i % 3 > 0 { result.append(i - 1) }
      if i % 3 < 2 { result.append(i + 1) }
      if i / 3 > 0 { result.append(i - 3) }
      if i / 3 < 2 { result.append(i + 3) }
      return result
    }

    func tick(frame: Int) {
      let phase = Double(frame % framesPerCycle) / Double(framesPerCycle)
      let bw = config.bandWidth
      let wp = config.wavePower

      for i in 0..<9 {
        var dist = abs(diagNorm[i] - phase)
        if dist > 0.5 { dist = 1.0 - dist }
        let driven = pow(max(0.0, 1.0 - dist / bw), wp)
        trails[i] = max(driven, trails[i] * decay)
      }

      var next = brightness
      let boost = config.neighborBoost
      for i in 0..<9 {
        var sum = 0.0
        for index in neighbors[i] { sum += trails[index] }
        let average = sum / Double(neighbors[i].count)
        let compound = sqrt(trails[i] * average) * boost
        next[i] = max(config.minOpacity, min(1.0, trails[i] + compound))
      }
      brightness = next
    }

    // Warm up the trail before recording the looping sequence.
    for _ in 0..<3 {
      for f in 0..<framesPerCycle { tick(frame: f) }
    }

    // Record N + 1 frames so the loop boundary interpolates cleanly.
    var recordedBrightnesses: [[Double]] = Array(repeating: [], count: 9)
    for f in 0...framesPerCycle {
      tick(frame: f)
      for i in 0..<9 { recordedBrightnesses[i].append(brightness[i]) }
    }

    pixelAnimations.removeAll()
    bloomColorAnimations.removeAll()

    for i in 0..<9 {
      let bValues = recordedBrightnesses[i]

      let pAnim = CAKeyframeAnimation(keyPath: "backgroundColor")
      pAnim.values = bValues.map { SpinnerNSView.color(for: $0, alpha: $0, config: config) as Any }
      pAnim.calculationMode = .linear
      pAnim.duration = config.cycleDuration
      pAnim.repeatCount = .infinity

      let bcAnim = CAKeyframeAnimation(keyPath: "backgroundColor")
      bcAnim.values = bValues.map { b in
        let tb = b * config.amplify - config.threshold
        let alpha = tb > 0 ? min(1.0, tb * config.gainTight) : 0.0
        return SpinnerNSView.color(for: b, alpha: alpha, config: config) as Any
      }
      bcAnim.calculationMode = .linear
      bcAnim.duration = config.cycleDuration
      bcAnim.repeatCount = .infinity

      pixelAnimations.append(pAnim)
      bloomColorAnimations.append(bcAnim)
    }
  }

  @objc private func appStateChanged() { updateState() }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateState()
  }

  private func updateState() {
    let shouldAnimate = NSApp.isActive && !reduceMotion && self.window != nil
    if shouldAnimate {
      if !isAnimating { startAnimating() }
    } else {
      if isAnimating { stopAnimating() }
      applyStaticState()
    }
  }

  private func startAnimating() {
    guard !isAnimating else { return }
    isAnimating = true
    for i in 0..<9 {
      gridLayers[i].pixel.add(pixelAnimations[i], forKey: "color")
      gridLayers[i].bloom.add(bloomColorAnimations[i], forKey: "color")
    }
  }

  private func stopAnimating() {
    guard isAnimating else { return }
    isAnimating = false
    for i in 0..<9 {
      gridLayers[i].pixel.removeAllAnimations()
      gridLayers[i].bloom.removeAllAnimations()
    }
  }

  private func applyStaticState() {
    let staticBrightnesses: [Double] = [0.06, 0.12, 0.20, 0.12, 0.20, 0.36, 0.20, 0.36, 0.58]

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for i in 0..<9 {
      guard i < gridLayers.count else { continue }
      let b = staticBrightnesses[i]

      gridLayers[i].pixel.backgroundColor = SpinnerNSView.color(for: b, alpha: b, config: config)

      let tb = b * config.amplify - config.threshold
      let alpha = tb > 0 ? min(1.0, tb * config.gainTight) : 0.0
      gridLayers[i].bloom.backgroundColor = SpinnerNSView.color(
        for: b, alpha: alpha, config: config)
    }
    CATransaction.commit()
  }

  // Use sRGB to match SwiftUI color interpolation.
  private static func color(for b: Double, alpha: Double, config: TimelineSpinnerConfig) -> CGColor
  {
    let rgb: SIMD3<Double> =
      b < 0.45
      ? config.colorDim + (config.colorMid - config.colorDim) * (b / 0.45)
      : config.colorMid + (config.colorHot - config.colorMid) * ((b - 0.45) / 0.55)
    return CGColor(
      srgbRed: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: CGFloat(alpha))
  }
}
