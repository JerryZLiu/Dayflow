import SwiftUI
import UniformTypeIdentifiers
import AppKit
import Combine


fileprivate func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> (r: Double, g: Double, b: Double) {
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

fileprivate func hslToHex(_ h: Double, _ s: Double, _ l: Double) -> String {
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


fileprivate func makeColorWheelCGImage(
    size: CGFloat,
    padding: CGFloat,
    minLight: Double,
    maxLight: Double,
    scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2.0
) -> CGImage? {
    let pixelW = Int((size * scale).rounded())
    let pixelH = Int((size * scale).rounded())
    let bytesPerRow = pixelW * 4

    guard let ctx = CGContext(
        data: nil,
        width: pixelW,
        height: pixelH,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

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
                var angle = atan2(dy, dx) // [-π, π]
                if angle < 0 { angle += .pi * 2 }
                let hue = angle * 180.0 / .pi
                let light = minLight + deltaL * (r / R)

                let (rr, gg, bb) = hslToRGB(hue, 100, light)
                ptr[offset + 0] = UInt8(max(0, min(255, Int(round(rr * 255))))) // R
                ptr[offset + 1] = UInt8(max(0, min(255, Int(round(gg * 255))))) // G
                ptr[offset + 2] = UInt8(max(0, min(255, Int(round(bb * 255))))) // B
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


fileprivate struct DotPattern: View {
    var width: CGFloat = 10
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let cols = Int(ceil(size.width / width))
                let rows = Int(ceil(size.height / height))
                let dot = Path(ellipseIn: CGRect(x: 0, y: 0, width: 2, height: 2))
                let color = Color(.sRGB, red: 107/255, green: 114/255, blue: 128/255, opacity: 0.22)

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
                        .init(color: .clear, location: 1)
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


fileprivate struct ColorPickerView: View {
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
        let c  = colorHex
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
                    .position(x: bx2 - bulletRadius / 1.7 + bulletRadius * 1.2/2,
                              y: by2 - bulletRadius / 1.7 + bulletRadius * 1.2/2)
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
                    .position(x: bx1 - bulletRadius / 1.7 + bulletRadius * 1.2/2,
                              y: by1 - bulletRadius / 1.7 + bulletRadius * 1.2/2)
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
            wheelImage = makeColorWheelCGImage(size: size, padding: padding, minLight: minLight, maxLight: maxLight)
            updateCallbacks()
        }
        .onChange(of: size) { _ in
            wheelImage = makeColorWheelCGImage(size: size, padding: padding, minLight: minLight, maxLight: maxLight)
        }
        .onChange(of: minLight) { _ in
            wheelImage = makeColorWheelCGImage(size: size, padding: padding, minLight: minLight, maxLight: maxLight)
        }
        .onChange(of: maxLight) { _ in
            wheelImage = makeColorWheelCGImage(size: size, padding: padding, minLight: minLight, maxLight: maxLight)
        }
        .onChange(of: angle) { _ in updateCallbacks() }
        .onChange(of: radius) { _ in updateCallbacks() }
        .onChange(of: numPoints) { _ in updateCallbacks() }
    }
}


fileprivate struct ColorSwatch: View {
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


fileprivate struct CategoryView: View {
    var category: TimelineCategory
    var onColorDrop: (String) -> Void
    var onDetailsChange: (String) -> Void
    var onDelete: () -> Void

    @State private var expanded = false
    @State private var hovering = false
    @State private var dragOver = false
    @State private var localDetails: String = ""
    @State private var showHint: Bool = false
    @FocusState private var detailFieldIsFocused: Bool
    private let detailsPlaceholder = "Add details to help teach the AI what belongs in this category. For example, \"Client meetings, Zoom calls, CRM updates.\""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(hex: category.colorHex))
                        .frame(width: 20, height: 20)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(Color.white, lineWidth: 2)
                        )
                        .shadow(color: Color.black.opacity(0.15), radius: 2, y: 1)
                    Text(category.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.black)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    expanded.toggle()
                }

                Spacer()

                if !category.isSystem {
                    HStack(spacing: 8) {
                        if expanded {
                            Text("▲")
                                .font(.system(size: 10))
                                .foregroundColor(Color.gray.opacity(0.7))
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    expanded.toggle()
                                }
                        } else if !localDetails.isEmpty {
                            Text("▼")
                                .font(.system(size: 10))
                                .foregroundColor(Color.gray.opacity(0.7))
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    expanded.toggle()
                                }
                        }

                        Button {
                            onDelete()
                        } label: {
                            Text("×")
                                .font(.system(size: 16))
                                .foregroundColor(.red.opacity(hovering ? 1.0 : 0.6))
                        }
                        .buttonStyle(.plain)
                        .opacity(hovering ? 1.0 : 0.7)
                        .animation(.easeInOut(duration: 0.15), value: hovering)
                    }
                }
            }

            if !expanded && !localDetails.isEmpty {
                Text(localDetails)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .font(.system(size: 12))
                    .foregroundColor(Color.gray.opacity(0.7))
                    .padding(.top, 2)
            }

            if expanded {
                ZStack(alignment: .topLeading) {
                    if localDetails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(detailsPlaceholder)
                            .font(.system(size: 12))
                            .foregroundColor(Color.black.opacity(0.45))
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $localDetails)
                        .font(.system(size: 13))
                        .foregroundColor(.black)
                        .scrollContentBackground(.hidden)
                        .focused($detailFieldIsFocused)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(minHeight: 80)
                        .scrollIndicators(.hidden)
                        .background(ScrollViewHider())
                }
                .background(Color.white)
                .overlay(
                    Rectangle()
                        .stroke(Color.black.opacity(0.12), lineWidth: 1)
                )
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(dragOver ? Color(red: 0.29, green: 0.33, blue: 0.41) : Color(red: 0.89, green: 0.91, blue: 0.94), lineWidth: dragOver ? 2 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: Color.black.opacity(0.1), radius: dragOver ? 12 : 3, y: dragOver ? 4 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            if !expanded {
                expanded = true
            }
        }
        .onHover { hovering in self.hovering = hovering }
        .onAppear {
            localDetails = category.details
            showHint = category.isNew
            if category.isNew {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { showHint = false }
            }
        }
        .onChange(of: expanded) { isExpanded in
            if isExpanded {
                detailFieldIsFocused = true
            } else {
                detailFieldIsFocused = false
                onDetailsChange(localDetails)
            }
        }
        .onChange(of: category.details) { newValue in
            localDetails = newValue
        }
        .onChange(of: localDetails) { newValue in
            if expanded {
                onDetailsChange(newValue)
            }
        }
        .overlay(alignment: .topLeading) {
            if showHint, category.colorHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("← Drop a color here")
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(Color.black.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .offset(x: -140, y: -20)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.plainText], isTargeted: $dragOver) { providers in
            guard category.isSystem == false else { return false }
            guard let prov = providers.first else { return false }
            // Accept the drop immediately; resolve payload asynchronously
            prov.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                let str: String? = {
                    if let data = item as? Data { return String(data: data, encoding: .utf8) }
                    if let s = item as? String { return s }
                    if let ns = item as? NSString { return ns as String }
                    return nil
                }()
                if let hex = str {
                    DispatchQueue.main.async {
                        onColorDrop(hex)
                    }
                }
            }
            return true
        }
        .zIndex((hovering || dragOver || expanded) ? 50 : 0)
        .onDisappear {
            detailFieldIsFocused = false
            onDetailsChange(localDetails)
        }
    }
}

private struct ScrollViewHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        hideScrollIndicators(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        hideScrollIndicators(for: nsView)
    }

    private func hideScrollIndicators(for view: NSView) {
        DispatchQueue.main.async {
            var ancestor: NSView? = view
            while let current = ancestor {
                if let scrollView = current as? NSScrollView {
                    scrollView.hasVerticalScroller = false
                    scrollView.hasHorizontalScroller = false
                    scrollView.verticalScroller?.alphaValue = 0
                    scrollView.horizontalScroller?.alphaValue = 0
                    scrollView.scrollerStyle = .overlay
                    break
                }
                ancestor = current.superview
            }
        }
    }
}

enum ColorOrganizerBackgroundStyle {
    case none
    case gradient
    case color(Color)
}

struct ColorOrganizerRoot: View {
    var backgroundStyle: ColorOrganizerBackgroundStyle = .gradient
    var onDismiss: (() -> Void)?
    @EnvironmentObject private var categoryStore: CategoryStore
    @State private var numPoints: Int = 3
    @State private var normalizedRadius: Double = 0.7
    @State private var currentAngle: Double = -Double.pi / 2
    @State private var newCategoryName: String = ""
    @State private var isDragging: Bool = false
    @State private var showFirstTimeHints: Bool = !UserDefaults.standard.bool(forKey: CategoryStore.StoreKeys.hasUsedApp)

    // Spectrum colors (8) around the circle starting from current picker angle
    private var spectrumColors: [String] {
        (0..<8).map { i in
            let angleOffset = Double(i) * (.pi * 2) / 8.0
            let a = currentAngle + angleOffset
            let h = a * 180.0 / .pi
            let lightness = 15 + 75 * normalizedRadius
            return hslToHex(h, 100, lightness)
        }
    }

    // Precomputed background gradient to help the type-checker
    private var backgroundGradient: LinearGradient {
        let start = Color(hex: "#667EEA")
        let end = Color(hex: "#764BA2")
        return LinearGradient(gradient: Gradient(colors: [start, end]), startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var hasExactlyDefaultCategories: Bool {
        let editableCategories = categoryStore.editableCategories
        let defaultNames = Set(["Work", "Personal", "Distraction"])
        let currentNames = Set(editableCategories.map { $0.name })
        return editableCategories.count == 3 && currentNames == defaultNames
    }

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Picker container (translucent with dot mask)
            ZStack {
                Color.clear
                    .frame(width: 290, height: 224 + 12 + 28)

                VStack(spacing: 8) {
                    ZStack {
                        DotPattern(width: 10, height: 10)
                            .frame(width: 224, height: 224)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .zIndex(10)

                        ColorPickerView(
                            size: 224,
                            padding: 20,
                            bulletRadius: 24,
                            spreadFactor: 0.4,
                            minSpread: .pi / 1.5,
                            maxSpread: .pi / 3,
                            minLight: 15,
                            maxLight: 90,
                            showColorWheel: false,
                            numPoints: numPoints,
                            onColorChange: { _ in },
                            onRadiusChange: { normalizedRadius = $0 },
                            onAngleChange: { currentAngle = $0 }
                        )
                        .zIndex(20)
                    }

                    // +/- buttons
                    HStack(spacing: 8) {
                        shapedIconButton(label: "−") { numPoints = max(1, numPoints - 1) }
                        shapedIconButton(label: "+") { numPoints = min(5, numPoints + 1) }
                    }
                    .frame(height: 28)
                }
                .padding(12)
            }

            // Spectrum swatches (centered)
            VStack(alignment: .center, spacing: 12) {
                Text(isDragging ? "Drop on a category →" : "Drag a color onto a category")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(red: 0.3, green: 0.3, blue: 0.3))

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(Array(spectrumColors.enumerated()), id: \.offset) { i, hex in
                        ColorSwatch(
                            hex: hex,
                            showHint: showFirstTimeHints && i == 0,
                            onDragStart: { isDragging = true }
                        )
                    }
                }
                .onDrop(of: [UTType.plainText], isTargeted: nil) { _ in
                    isDragging = false
                    return false
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 320, maxWidth: 400)
    }

    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configure Categories")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.black)

            let visibleCategories = categoryStore.editableCategories
            let isShowingDefaultCategoriesOnly = hasExactlyDefaultCategories

            if visibleCategories.isEmpty && newCategoryName.isEmpty {
                VStack(spacing: 4) {
                    Text("No categories yet")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Color(red: 0.1, green: 0.1, blue: 0.1))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Create one below and drag colors to assign them")
                        .font(.system(size: 13))
                        .foregroundColor(Color(red: 0.4, green: 0.4, blue: 0.4))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.02))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.black.opacity(0.08), lineWidth: 1)
                        )
                )
            } else if isShowingDefaultCategoriesOnly {
                VStack(spacing: 4) {
                    Text("You can always adjust these later in the Timeline view, but here are some to get you started.")
                        .font(.system(size: 14))
                        .foregroundColor(Color(red: 0.1, green: 0.1, blue: 0.1))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.02))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.black.opacity(0.08), lineWidth: 1)
                        )
                )
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(visibleCategories) { cat in
                        CategoryView(
                            category: cat,
                            onColorDrop: { hex in
                                categoryStore.assignColor(hex, to: cat.id)
                                isDragging = false
                            },
                            onDetailsChange: { text in
                                categoryStore.updateDetails(text, for: cat.id)
                            },
                            onDelete: {
                                categoryStore.removeCategory(id: cat.id)
                            }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
            }
            .background(ScrollViewHider())
            .frame(maxWidth: .infinity)
            .frame(maxHeight: 400) // Fixed max height prevents layout jank

            let maxCategories = 10
            let canAddMore = visibleCategories.count < maxCategories

            HStack(alignment: .center, spacing: 8) {
                TextField(canAddMore ? "Add category..." : "Max categories reached", text: $newCategoryName, onCommit: {
                    if canAddMore && !newCategoryName.isEmpty {
                        categoryStore.addCategory(name: newCategoryName)
                        showFirstTimeHints = false
                        newCategoryName = ""
                    }
                })
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(canAddMore ? .black : .gray)
                .disabled(!canAddMore)
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(canAddMore ? Color.white : Color.gray.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.black.opacity(canAddMore && !newCategoryName.isEmpty ? 0.25 : 0.12), lineWidth: 1)
                        )
                        .animation(.easeOut(duration: 0.2), value: newCategoryName.isEmpty)
                )

                Button {
                    if canAddMore && !newCategoryName.isEmpty {
                        categoryStore.addCategory(name: newCategoryName)
                        showFirstTimeHints = false
                        newCategoryName = ""
                    }
                } label: {
                    Text("Add")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                        .background(canAddMore && !newCategoryName.isEmpty ? Color(red: 0.25, green: 0.17, blue: 0) : Color.gray)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(!canAddMore || newCategoryName.isEmpty)
            }
            .frame(minWidth: 280)
            .frame(maxWidth: .infinity)
        }
        .padding(24)
        .frame(minWidth: 280) // Removed maxWidth constraint to allow full expansion
    }

    private var contentCard: some View {
        HStack(alignment: .top, spacing: 60) {
            leftPanel

            VStack(spacing: 0) {
                rightPanel

                HStack {
                    Spacer()
                    SetupContinueButton(title: "Save", isEnabled: !categoryStore.editableCategories.isEmpty) {
                        categoryStore.persist()
                        onDismiss?()
                    }
                }
                .padding(.top, 24)
            }
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 40)
        .background(
            Group {
                if case .none = backgroundStyle {
                    // Onboarding: No background, completely transparent
                    Color.clear
                } else {
                    // Main app: White background for visibility over timeline
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.white.opacity(0.95))
                        .shadow(color: Color.black.opacity(0.15), radius: 20, x: 0, y: 8)
                }
            }
        )
        .padding(.horizontal, 60)
    }

    @ViewBuilder
    private var backgroundView: some View {
        switch backgroundStyle {
        case .gradient:
            backgroundGradient
                .ignoresSafeArea()
        case .color(let color):
            color
                .ignoresSafeArea()
        case .none:
            EmptyView()
        }
    }

    var body: some View {
        ZStack {
            backgroundView
            contentCard
        }
        .onAppear {
            showFirstTimeHints = !UserDefaults.standard.bool(forKey: CategoryStore.StoreKeys.hasUsedApp)
        }
    }

    // Styled +/- button matching your design
    private func shapedIconButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 24, weight: .regular, design: .default))
                .foregroundColor(Color(hex: "#6B7280"))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.clear)
        )
        .onHover { hover in
            // hover highlight
        }
    }

}


// App entry point intentionally omitted; DayflowApp provides the main entry.

#Preview("Timeline Card Color Picker") {
    ColorOrganizerRoot()
        .environmentObject(CategoryStore())
        .frame(minWidth: 980, minHeight: 640)
}
