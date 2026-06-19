import AppKit
import SwiftUI

private func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> (r: Double, g: Double, b: Double) {
  // Normalize hue to [0, 360)
  var H = h.truncatingRemainder(dividingBy: 360)
  if H < 0 { H += 360 }
  let S = max(0, min(100, s)) / 100.0
  let L = max(0, min(100, l)) / 100.0

  let k: (Double) -> Double = { n in
    (n + H / 30.0).truncatingRemainder(dividingBy: 12.0)
  }
  let a = S * min(L, 1 - L)
  let f: (Double) -> Double = { n in
    let K = k(n)
    return L - a * max(-1, min(K - 3, min(9 - K, 1)))
  }
  return (f(0), f(8), f(4))
}

func hslToHex(_ h: Double, _ s: Double, _ l: Double) -> String {
  let (r, g, b) = hslToRGB(h, s, l)
  func hex(_ x: Double) -> String { String(format: "%02X", max(0, min(255, Int(round(x * 255))))) }
  return "#\(hex(r))\(hex(g))\(hex(b))"
}

extension Color {
  // Keep only HSL helper to avoid redeclaring `init(hex:)` (already defined elsewhere)
  static func fromHSL(h: Double, s: Double, l: Double) -> Color {
    let (r, g, b) = hslToRGB(h, s, l)
    return Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
  }
}

private func makeColorWheelCGImage(
  size: CGFloat,
  padding: CGFloat,
  minLight: Double,
  maxLight: Double,
  scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2.0
) -> CGImage? {
  let pixelW = Int((size * scale).rounded())
  let pixelH = Int((size * scale).rounded())
  let bytesPerRow = pixelW * 4

  guard
    let ctx = CGContext(
      data: nil,
      width: pixelW,
      height: pixelH,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  else { return nil }

  guard let data = ctx.data else { return nil }
  let ptr = data.bindMemory(to: UInt8.self, capacity: pixelW * pixelH * 4)

  let cx = Double(pixelW) / 2.0
  let cy = Double(pixelH) / 2.0
  let R = Double((size / 2.0 - padding) * scale)
  let deltaL = maxLight - minLight

  for y in 0..<pixelH {
    for x in 0..<pixelW {
      let dx = Double(x) - cx
      let dy = Double(y) - cy
      let r = sqrt(dx * dx + dy * dy)
      let offset = (y * pixelW + x) * 4

      if r <= R {
        var angle = atan2(dy, dx)  // [-π, π]
        if angle < 0 { angle += .pi * 2 }
        let hue = angle * 180.0 / .pi
        let light = minLight + deltaL * (r / R)

        let (rr, gg, bb) = hslToRGB(hue, 100, light)
        ptr[offset + 0] = UInt8(max(0, min(255, Int(round(rr * 255)))))  // R
        ptr[offset + 1] = UInt8(max(0, min(255, Int(round(gg * 255)))))  // G
        ptr[offset + 2] = UInt8(max(0, min(255, Int(round(bb * 255)))))  // B
        ptr[offset + 3] = 255
      } else {
        ptr[offset + 0] = 0
        ptr[offset + 1] = 0
        ptr[offset + 2] = 0
        ptr[offset + 3] = 0
      }
    }
  }
  return ctx.makeImage()
}

struct DotPattern: View {
  var width: CGFloat = 10
  var height: CGFloat = 10

  var body: some View {
    GeometryReader { geo in
      Canvas { context, size in
        let cols = Int(ceil(size.width / width))
        let rows = Int(ceil(size.height / height))
        let dot = Path(ellipseIn: CGRect(x: 0, y: 0, width: 2, height: 2))
        let color = Color(.sRGB, red: 107 / 255, green: 114 / 255, blue: 128 / 255, opacity: 0.22)

        for i in 0..<cols {
          for j in 0..<rows {
            let x = CGFloat(i) * width + width * 0.5 - 1
            let y = CGFloat(j) * height + height * 0.5 - 1
            context.translateBy(x: x, y: y)
            context.fill(dot, with: .color(color))
            context.translateBy(x: -x, y: -y)
          }
        }
      }
      .mask(
        RadialGradient(
          gradient: Gradient(stops: [
            .init(color: .white, location: 0),
            .init(color: .clear, location: 1),
          ]),
          center: .center,
          startRadius: 0,
          endRadius: 200
        )
      )
    }
    .allowsHitTesting(false)
    .zIndex(10)
  }
}

struct ColorPickerView: View {
  // Props (mirroring your defaults)
  var size: CGFloat = 280
  var padding: CGFloat = 20
  var bulletRadius: CGFloat = 24
  var spreadFactor: Double = 0.4
  var minSpread: Double = .pi / 1.5
  var maxSpread: Double = .pi / 3
  var minLight: Double = 15
  var maxLight: Double = 90
  var showColorWheel: Bool = false

  var numPoints: Int
  var onColorChange: ([String]) -> Void
  var onRadiusChange: (Double) -> Void
  var onAngleChange: (Double) -> Void

  // Internal state
  @State private var angle: Double = -.pi / 2
  @State private var radius: CGFloat = 0
  @State private var wheelImage: CGImage? = nil
  private var RADIUS: CGFloat { size / 2 - padding }

  // Derived (exactly like your React code)
  private var hue: Double { angle * 180 / .pi }
  private var light: Double { maxLight * Double(radius / RADIUS) }
  private var colorHex: String { hslToHex(hue, 100, light) }

  private var normalizedRadius: Double { Double(radius / RADIUS) }
  private var spread: Double {
    (minSpread + (maxSpread - minSpread) * pow(normalizedRadius, 3)) * spreadFactor
  }

  private func color(at deltaAngle: Double) -> String {
    let a = angle + deltaAngle
    let h = a * 180 / .pi
    return hslToHex(h, 100, light)
  }

  private func updateCallbacks() {
    // Color array ordering mirrors your useEffect:
    // 1: [color]
    // 2: [color2, color]
    // 3: [color2, color, color1]
    // 4: [color2, color, color1, color3]
    // 5+: [color4, color2, color, color1, color3]
    let c = colorHex
    let c1 = color(at: -spread)
    let c2 = color(at: +spread)
    let c3 = color(at: -spread * 2)
    let c4 = color(at: +spread * 2)

    let out: [String]
    switch numPoints {
    case 1: out = [c]
    case 2: out = [c2, c]
    case 3: out = [c2, c, c1]
    case 4: out = [c2, c, c1, c3]
    default: out = [c4, c2, c, c1, c3]
    }
    onColorChange(out)
    onRadiusChange(Double(radius / RADIUS))
    onAngleChange(angle)
  }

  private func setFrom(location: CGPoint) {
    let center = CGPoint(x: size / 2, y: size / 2)
    let vx = Double(location.x - center.x)
    let vy = Double(location.y - center.y)
    var a = atan2(vy, vx)
    if a < 0 { a += .pi * 2 }
    let r = min(RADIUS, max(0, CGFloat(hypot(vx, vy))))
    angle = a
    radius = r
    updateCallbacks()
  }

  var body: some View {
    ZStack {
      // Wheel
      Group {
        if let img = wheelImage {
          Image(decorative: img, scale: 1, orientation: .up)
            .resizable()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .opacity(showColorWheel ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: showColorWheel)
        } else {
          // Lazy placeholder before image is built
          Circle().fill(Color.clear).frame(width: size, height: size)
        }
      }

      // Drag area overlay
      GeometryReader { _ in
        Color.clear
          .contentShape(Circle().path(in: CGRect(x: 0, y: 0, width: size, height: size)))
          .gesture(
            DragGesture(minimumDistance: 0)
              .onChanged { value in setFrom(location: value.location) }
              .onEnded { _ in }
          )
          .frame(width: size, height: size)
      }
      .allowsHitTesting(true)

      // Bullets
      let bx = size / 2 + CGFloat(cos(angle)) * radius
      let by = size / 2 + CGFloat(sin(angle)) * radius

      let angle1 = angle - spread
      let angle2 = angle + spread
      let angle3 = angle - spread * 2
      let angle4 = angle + spread * 2

      let bx1 = size / 2 + CGFloat(cos(angle1)) * radius
      let by1 = size / 2 + CGFloat(sin(angle1)) * radius
      let bx2 = size / 2 + CGFloat(cos(angle2)) * radius
      let by2 = size / 2 + CGFloat(sin(angle2)) * radius
      let bx3 = size / 2 + CGFloat(cos(angle3)) * radius
      let by3 = size / 2 + CGFloat(sin(angle3)) * radius
      let bx4 = size / 2 + CGFloat(cos(angle4)) * radius
      let by4 = size / 2 + CGFloat(sin(angle4)) * radius

      // Secondary bullets (ordered & sized like your JSX)
      if numPoints >= 2 {
        Circle()
          .fill(Color(hex: color(at: +spread)))
          .frame(width: bulletRadius * 1.2, height: bulletRadius * 1.2)
          .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 2))
          .shadow(radius: 4, y: 2)
          .position(
            x: bx2 - bulletRadius / 1.7 + bulletRadius * 1.2 / 2,
            y: by2 - bulletRadius / 1.7 + bulletRadius * 1.2 / 2
          )
          .opacity(0.9)
          .zIndex(20)
          .allowsHitTesting(false)
      }
      // Primary draggable bullet
      Circle()
        .fill(Color(hex: colorHex))
        .frame(width: bulletRadius * 2, height: bulletRadius * 2)
        .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 3))
        .shadow(radius: 8, y: 2)
        .position(x: bx, y: by)
        .zIndex(30)
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { value in setFrom(location: value.location) }
        )

      if numPoints >= 3 {
        Circle()
          .fill(Color(hex: color(at: -spread)))
          .frame(width: bulletRadius * 1.2, height: bulletRadius * 1.2)
          .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 2))
          .shadow(radius: 4, y: 2)
          .position(
            x: bx1 - bulletRadius / 1.7 + bulletRadius * 1.2 / 2,
            y: by1 - bulletRadius / 1.7 + bulletRadius * 1.2 / 2
          )
          .opacity(0.9)
          .zIndex(20)
          .allowsHitTesting(false)
      }
      if numPoints >= 4 {
        Circle()
          .fill(Color(hex: color(at: -spread * 2)))
          .frame(width: bulletRadius, height: bulletRadius)
          .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 2))
          .shadow(radius: 4, y: 2)
          .position(x: bx3, y: by3)
          .opacity(0.8)
          .zIndex(15)
          .allowsHitTesting(false)
      }
      if numPoints >= 5 {
        Circle()
          .fill(Color(hex: color(at: +spread * 2)))
          .frame(width: bulletRadius, height: bulletRadius)
          .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 2))
          .shadow(radius: 4, y: 2)
          .position(x: bx4, y: by4)
          .opacity(0.8)
          .zIndex(15)
          .allowsHitTesting(false)
      }
    }
    .frame(width: size, height: size)
    .onAppear {
      radius = RADIUS * 0.7
      wheelImage = makeColorWheelCGImage(
        size: size, padding: padding, minLight: minLight, maxLight: maxLight)
      updateCallbacks()
    }
    .onChange(of: size) {
      wheelImage = makeColorWheelCGImage(
        size: size, padding: padding, minLight: minLight, maxLight: maxLight)
    }
    .onChange(of: minLight) {
      wheelImage = makeColorWheelCGImage(
        size: size, padding: padding, minLight: minLight, maxLight: maxLight)
    }
    .onChange(of: maxLight) {
      wheelImage = makeColorWheelCGImage(
        size: size, padding: padding, minLight: minLight, maxLight: maxLight)
    }
    .onChange(of: angle) { updateCallbacks() }
    .onChange(of: radius) { updateCallbacks() }
    .onChange(of: numPoints) { updateCallbacks() }
  }
}

struct ColorSwatch: View {
  var hex: String
  var showHint: Bool
  var onDragStart: () -> Void

  @State private var hovering = false

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 6)
        .fill(Color(hex: hex))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white, lineWidth: 2))
        .frame(width: 60, height: 36)
        .offset(y: hovering ? -2 : 0)
        .animation(.easeInOut(duration: 0.15), value: hovering)

      if showHint && hovering {
        Text("Drag to category")
          .font(.system(size: 11))
          .foregroundColor(.white)
          .padding(.vertical, 4)
          .padding(.horizontal, 8)
          .background(Color.black.opacity(0.8))
          .clipShape(RoundedRectangle(cornerRadius: 4))
          .offset(y: -30)
          .allowsHitTesting(false)
      }
    }
    .onHover { hovering in self.hovering = hovering }
    .onDrag {
      onDragStart()
      return NSItemProvider(object: hex as NSString)
    }
  }
}
