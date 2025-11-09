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
        .onChange(of: size) { oldValue, newValue in
            wheelImage = makeColorWheelCGImage(size: size, padding: padding, minLight: minLight, maxLight: maxLight)
        }
        .onChange(of: minLight) { oldValue, newValue in
            wheelImage = makeColorWheelCGImage(size: size, padding: padding, minLight: minLight, maxLight: maxLight)
        }
        .onChange(of: maxLight) { oldValue, newValue in
            wheelImage = makeColorWheelCGImage(size: size, padding: padding, minLight: minLight, maxLight: maxLight)
        }
        .onChange(of: angle) { oldValue, newValue in updateCallbacks() }
        .onChange(of: radius) { oldValue, newValue in updateCallbacks() }
        .onChange(of: numPoints) { oldValue, newValue in updateCallbacks() }
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


fileprivate struct EditableCategoryCard: View {
    enum Field: Hashable {
        case name
        case description
    }

    let category: TimelineCategory
    let isEditing: Bool
    @Binding var draftName: String
    @Binding var draftDetails: String
    var onStartEdit: () -> Void
    var onSave: () -> Void
    var onDelete: () -> Void

    @FocusState private var focusedField: Field?

    var body: some View {
        Group {
            if isEditing {
                editingView
                    .onAppear {
                        focusedField = .name
                    }
                    .onDisappear {
                        focusedField = nil
                    }
            } else {
                displayView
            }
        }
    }

    private var editingView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                TextField("", text: $draftName)
                    .font(Font.custom("Nunito", size: 14).weight(.bold))
                    .textFieldStyle(.plain)
                    .foregroundColor(.black)
                    .submitLabel(.next)
                    .focused($focusedField, equals: .name)
                    .onSubmit {
                        focusedField = .description
                    }

                Spacer(minLength: 12)

                Button {
                    focusedField = nil
                    onSave()
                } label: {
                    Image("CategoriesCheckmark")
                        .resizable()
                        .frame(width: 20, height: 20)
                        .accessibilityLabel("Save category edits")
                }
                .buttonStyle(.plain)

            }

            ZStack(alignment: .topLeading) {
                if draftDetails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Professional, school, or career-focused tasks (coding, design, meetings).")
                        .font(Font.custom("Nunito", size: 12).weight(.medium))
                        .foregroundColor(Color.black.opacity(0.35))
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                }

                TextEditor(text: $draftDetails)
                    .font(Font.custom("Nunito", size: 12).weight(.medium))
                    .foregroundColor(.black)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 12)
                    .frame(minHeight: 55)
                    .background(Color.white)
                    .focused($focusedField, equals: .description)
                    .scrollContentBackground(.hidden)
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(red: 0.89, green: 0.86, blue: 0.85), lineWidth: 0.5)
            )
        }
        .padding(16)
        .frame(alignment: .leading)
        .background(Color.white)
        .cornerRadius(8)
        .shadow(color: Color(red: 0.86, green: 0.8, blue: 0.76), radius: 3, x: 0, y: 0)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .inset(by: 0.25)
                .stroke(Color(red: 0.89, green: 0.86, blue: 0.85), lineWidth: 0.5)
        )
    }

    private var displayView: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(category.name)
                    .font(Font.custom("Nunito", size: 12).weight(.bold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity, alignment: .center)

                Text(category.details.isEmpty ? "Add a description to help Dayflow understand your workflow." : category.details)
                    .font(Font.custom("Nunito", size: 12).weight(.medium))
                    .foregroundColor(Color(red: 0.35, green: 0.35, blue: 0.35))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .lineLimit(2)
            }

            Spacer()

            if !category.isSystem {
                Button {
                    onStartEdit()
                } label: {
                    Image("CategoriesEdit")
                        .resizable()
                        .frame(width: 20, height: 20)
                        .accessibilityLabel("Edit category")
                }
                .buttonStyle(.plain)

                Button {
                    onDelete()
                } label: {
                    Image("CategoriesDelete")
                        .resizable()
                        .frame(width: 20, height: 20)
                        .accessibilityLabel("Delete category")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(Color.white)
        .cornerRadius(4)
        .shadow(color: Color.black.opacity(0.06), radius: 2, x: 0, y: 0)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .inset(by: 0.25)
                .stroke(Color(red: 0.89, green: 0.89, blue: 0.89), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if !category.isSystem {
                onStartEdit()
            }
        }
    }
}

fileprivate struct ColorAssignmentCard: View {
    let category: TimelineCategory
    var onColorDrop: (String) -> Void

    @State private var isTargeted = false

    private func colorSwatch(_ hex: String) -> some View {
        let color = Color(hex: hex.isEmpty ? "#E5E7EB" : hex)
        return Rectangle()
            .foregroundColor(.clear)
            .frame(width: 18, height: 18)
            .background(color)
            .cornerRadius(6)
            .shadow(color: Color.black.opacity(0.18), radius: 3, x: 0, y: 1)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .inset(by: 0.75)
                    .stroke(.white, lineWidth: 1.5)
            )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 14) {
                colorSwatch(category.colorHex)

                VStack(alignment: .leading, spacing: 4) {
                    Text(category.name)
                        .font(Font.custom("Nunito", size: 12).weight(.bold))
                        .foregroundColor(.black)

                    if !category.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(category.details)
                            .font(Font.custom("Nunito", size: 12).weight(.medium))
                            .foregroundColor(Color(red: 0.35, green: 0.35, blue: 0.35))
                            .lineLimit(2)
                    }
                }

                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(Color.white)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isTargeted ? Color(red: 0.6, green: 0.5, blue: 0.4) : Color(red: 0.89, green: 0.89, blue: 0.89), lineWidth: isTargeted ? 1.5 : 0.8)
        )
        .cornerRadius(8)
        .shadow(color: Color.black.opacity(0.06), radius: 2, x: 0, y: 1)
        .contentShape(Rectangle())
        .onDrop(of: [UTType.plainText], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                let value: String? = {
                    if let data = item as? Data { return String(data: data, encoding: .utf8) }
                    if let string = item as? String { return string }
                    if let ns = item as? NSString { return ns as String }
                    return nil
                }()
                if let hex = value {
                    DispatchQueue.main.async {
                        onColorDrop(hex)
                    }
                }
            }
            return true
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

struct ColorOrganizerRoot: View {
    enum PresentationStyle {
        case embedded
        case sheet
    }

    var presentationStyle: PresentationStyle = .embedded
    var onDismiss: (() -> Void)?
    var completionButtonTitle: String?
    var showsTitles: Bool = true
    @EnvironmentObject private var categoryStore: CategoryStore

    private enum CategorySetupStage {
        case details
        case colors
    }

    @State private var stage: CategorySetupStage = .details
    @State private var editingCategoryID: UUID?
    @State private var draftName: String = ""
    @State private var draftDetails: String = ""
    @State private var numPoints: Int = 3
    @State private var normalizedRadius: Double = 0.7
    @State private var currentAngle: Double = -Double.pi / 2
    @State private var isDraggingColor: Bool = false
    @State private var showFirstTimeHints: Bool = !UserDefaults.standard.bool(forKey: CategoryStore.StoreKeys.hasUsedApp)
    @State private var pendingScrollTarget: UUID? = nil
    @State private var isAddButtonHovered: Bool = false

    private var categories: [TimelineCategory] {
        categoryStore.editableCategories
    }

    private var spectrumColors: [String] {
        (0..<8).map { i in
            let angleOffset = Double(i) * (.pi * 2) / 8.0
            let angle = currentAngle + angleOffset
            let hue = angle * 180.0 / .pi
            let lightness = 15 + 75 * normalizedRadius
            return hslToHex(hue, 100, lightness)
        }
    }

    var body: some View {
        ZStack {
            backgroundView
            contentCard
        }
        .onDisappear {
            commitPendingEditsIfNeeded()
        }
    }

    private var contentCard: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.width < 960
            let innerHorizontalPadding: CGFloat = isCompact ? 28 : 64
            let outerHorizontalPadding: CGFloat = isCompact ? 16 : 40
            let stackSpacing: CGFloat = isCompact ? 32 : 48
            let columnSpacing: CGFloat = isCompact ? 24 : 56
            let verticalSpacing = showsTitles ? stackSpacing / 2 : 24

            VStack(spacing: verticalSpacing) {
                if stage == .details && showsTitles {
                    Text("Customize your categories")
                        .font(Font.custom("Instrument Serif", size: 44))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                if stage == .details {
                    HStack(alignment: .top, spacing: columnSpacing) {
                        instructionsPanel(isCompact: isCompact, showTitles: showsTitles)
                            .frame(minWidth: 200, maxWidth: isCompact ? 240 : 280, alignment: .leading)
                            .layoutPriority(1)

                        categoryEditorPanel(isCompact: isCompact)
                            .layoutPriority(0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(alignment: .top, spacing: columnSpacing) {
                        colorPickerPanel(isCompact: isCompact, showTitles: showsTitles)
                            .frame(minWidth: 220, maxWidth: isCompact ? 260 : 320, alignment: .leading)
                            .layoutPriority(1)

                        colorAssignmentPanel(isCompact: isCompact)
                            .layoutPriority(0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, innerHorizontalPadding)
            .padding(.vertical, isCompact ? 32 : 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(
                Group {
                    if presentationStyle == .sheet {
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color.white)
                            .shadow(color: Color.black.opacity(0.15), radius: 20, x: 0, y: 8)
                    }
                }
            )
            .padding(.horizontal, outerHorizontalPadding)
            .padding(.vertical, presentationStyle == .sheet ? 24 : 0)
        }
    }

    private func instructionsPanel(isCompact: Bool, showTitles: Bool) -> some View {
        VStack(alignment: .leading, spacing: showTitles ? 20 : 16) {
            if showTitles {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Part 1 of 2")
                        .font(Font.custom("Nunito", size: 14).weight(.bold))
                        .foregroundColor(Color(red: 0.98, green: 0.43, blue: 0))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("Edit title and description")
                        .font(Font.custom("Instrument Serif", size: 30))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                instructionRow(
                    icon: "CategoriesOrganize",
                    text: "Dayflow organizes your activities by the category titles and descriptions you provide."
                )
                .frame(maxWidth: isCompact ? .infinity : 280, alignment: .leading)

                instructionRow(
                    icon: "CategoriesTextSelect",
                    text: "Try to provide as much details in the descriptions as you can to help Dayflow understand your workflow and habits."
                )
                .frame(maxWidth: isCompact ? .infinity : 280, alignment: .leading)
            }

            Text("This step is optional. You can customize the categories or create new ones anytime while using Dayflow.")
                .font(Font.custom("Nunito", size: 12).weight(.medium))
                .foregroundColor(Color(red: 0.48, green: 0.48, blue: 0.48))
                .frame(maxWidth: isCompact ? .infinity : 280, alignment: .leading)
        }
    }

    private func instructionRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(icon)
                .resizable()
                .frame(width: 28, height: 28)

            Text(text)
                .font(Font.custom("Nunito", size: 14).weight(.medium))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func colorPickerPanel(isCompact: Bool, showTitles: Bool) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            if showTitles {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Part 2 of 2")
                        .font(Font.custom("Nunito", size: 14).weight(.bold))
                        .foregroundColor(Color(red: 0.98, green: 0.43, blue: 0))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("Edit colors")
                        .font(Font.custom("Instrument Serif", size: 30))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            VStack(spacing: 12) {
                ZStack {
                    DotPattern(width: 10, height: 10)
                        .frame(width: 224, height: 224)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 4)

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
                }
                .frame(width: 224, height: 224)

            }

            VStack(alignment: .leading, spacing: 12) {
                Text(isDraggingColor ? "Drop on a category →" : "Click and drag on the canvas above to change the color palette. Then drag a color onto a category.")
                    .font(Font.custom("Nunito", size: 13).weight(.medium))
                    .foregroundColor(Color(red: 0.3, green: 0.3, blue: 0.3))

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(Array(spectrumColors.enumerated()), id: \.offset) { index, hex in
                        ColorSwatch(
                            hex: hex,
                            showHint: showFirstTimeHints && index == 0,
                            onDragStart: {
                                isDraggingColor = true
                                showFirstTimeHints = false
                            }
                        )
                    }
                }
                .onDrop(of: [UTType.plainText], isTargeted: nil) { _ in
                    isDraggingColor = false
                    return false
                }
            }
        }
    }

    private var canAddMoreCategories: Bool {
        categories.count < 10
    }

    private var addCategoryButton: some View {
        Button {
            createNewCategory()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color(red: 0.49, green: 0.33, blue: 0.16))

                Text("Create a new category")
                    .font(Font.custom("Nunito", size: 14).weight(.bold))
                    .foregroundColor(Color(red: 0.49, green: 0.33, blue: 0.16))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color(red: 1, green: 0.94, blue: 0.79), location: 0),
                        .init(color: Color(red: 1, green: 0.72, blue: 0.43), location: 1)
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .inset(by: 0.5)
                    .stroke(Color(red: 0.95, green: 0.71, blue: 0.56), lineWidth: 1)
            )
            .opacity(canAddMoreCategories ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!canAddMoreCategories)
        .scaleEffect(isAddButtonHovered ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.18), value: isAddButtonHovered)
        .shadow(color: Color.black.opacity(isAddButtonHovered ? 0.18 : 0.1), radius: isAddButtonHovered ? 6 : 3, x: 0, y: isAddButtonHovered ? 3 : 1)
        .onHover { hovering in
            if canAddMoreCategories {
                isAddButtonHovered = hovering
            } else {
                isAddButtonHovered = false
            }
        }
        .pointingHandCursor(enabled: canAddMoreCategories)
    }

    private func colorAssignmentPanel(isCompact: Bool) -> some View {
        let containerHeight: CGFloat = (isCompact ? 404 : 494) * 0.75

        return VStack(alignment: .leading, spacing: 16) {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.2))
                    .frame(maxWidth: .infinity, minHeight: containerHeight, maxHeight: containerHeight)

                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color(red: 0.94, green: 0.91, blue: 0.87), lineWidth: 1)
                    .frame(maxWidth: .infinity, minHeight: containerHeight, maxHeight: containerHeight)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(categories) { category in
                            ColorAssignmentCard(
                                category: category,
                                onColorDrop: { hex in
                                    categoryStore.assignColor(hex, to: category.id)
                                    isDraggingColor = false
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(maxWidth: isCompact ? .infinity : 708)
            .frame(height: containerHeight, alignment: .topLeading)

            Text("This step is optional. You can change the colors anytime while using Dayflow.")
                .font(Font.custom("Nunito", size: 12).weight(.medium))
                .foregroundColor(Color(red: 0.48, green: 0.48, blue: 0.48))
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 16) {
                SetupSecondaryButton(title: "Back") {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isDraggingColor = false
                        stage = .details
                    }
                }

                SetupContinueButton(title: completionButtonTitle ?? "Next", isEnabled: !categories.isEmpty) {
                    categoryStore.persist()
                    onDismiss?()
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)
    }

    private func categoryEditorPanel(isCompact: Bool) -> some View {
        let containerHeight: CGFloat = (isCompact ? 404 : 494) * 0.75

        return ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 24) {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white.opacity(0.2))
                        .frame(maxWidth: .infinity, minHeight: containerHeight, maxHeight: containerHeight)

                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(red: 0.94, green: 0.91, blue: 0.87), lineWidth: 1)
                        .frame(maxWidth: .infinity, minHeight: containerHeight, maxHeight: containerHeight)

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 8) {
                            if categories.isEmpty {
                                emptyState
                            } else {
                                ForEach(categories) { category in
                                    EditableCategoryCard(
                                        category: category,
                                        isEditing: editingCategoryID == category.id,
                                        draftName: editingCategoryID == category.id ? $draftName : .constant(category.name),
                                        draftDetails: editingCategoryID == category.id ? $draftDetails : .constant(category.details),
                                        onStartEdit: { startEditing(category) },
                                        onSave: { saveEdits(for: category) },
                                        onDelete: { deleteCategory(category) }
                                    )
                                    .id(category.id)
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                        .padding(.bottom, 16)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(maxWidth: isCompact ? .infinity : 708)
                .frame(height: containerHeight, alignment: .topLeading)
                .onChange(of: pendingScrollTarget) { oldValue, target in
                    guard let target else { return }
                    withAnimation(.easeOut(duration: 0.35)) {
                        proxy.scrollTo(target, anchor: .bottom)
                    }
                    DispatchQueue.main.async { pendingScrollTarget = nil }
                }

                HStack {
                    addCategoryButton
                    Spacer()
                    SetupContinueButton(title: "Next", isEnabled: !categories.isEmpty) {
                        commitPendingEditsIfNeeded()
                        categoryStore.persist()
                        withAnimation(.easeInOut(duration: 0.25)) {
                            stage = .colors
                        }
                    }
                }
            }
            .frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyState: some View {
        Text("Add a category to get started.")
            .font(Font.custom("Nunito", size: 13).weight(.medium))
            .foregroundColor(Color(red: 0.35, green: 0.35, blue: 0.35))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(red: 0.89, green: 0.89, blue: 0.89), lineWidth: 0.5)
            )
    }

    @ViewBuilder
    private var backgroundView: some View {
        switch presentationStyle {
        case .embedded:
            Color.clear
        case .sheet:
            Color.black.opacity(0.16)
                .ignoresSafeArea()
        }
    }

    private func shapedIconButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Font.custom("Instrument Serif", size: 20))
                .foregroundColor(Color(red: 0.33, green: 0.33, blue: 0.33))
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(red: 0.93, green: 0.9, blue: 0.86), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .shadow(color: Color.black.opacity(0.08), radius: 2, x: 0, y: 1)
    }

    private struct SetupSecondaryButton: View {
        let title: String
        let isEnabled: Bool
        let action: () -> Void

        @State private var isPressed = false
        @State private var isHovered = false

        init(title: String, isEnabled: Bool = true, action: @escaping () -> Void) {
            self.title = title
            self.isEnabled = isEnabled
            self.action = action
        }

        var body: some View {
            Button(action: isEnabled ? action : {}) {
                Text(title)
                    .font(Font.custom("Nunito", size: 16).weight(.semibold))
                    .foregroundColor(Color(red: 0.26, green: 0.26, blue: 0.26))
                    .padding(.horizontal, 59)
                    .padding(.vertical, 18)
                    .frame(width: 160, alignment: .center)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.85))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color(red: 0.88, green: 0.88, blue: 0.88), lineWidth: 1)
                            )
                    )
                    .opacity(isEnabled ? 1.0 : 0.4)
            }
            .buttonStyle(.plain)
            .scaleEffect(isPressed ? 0.96 : (isHovered && isEnabled ? 1.02 : 1.0))
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isPressed)
            .animation(.easeOut(duration: 0.2), value: isHovered)
            .onHover { hovering in
                if isEnabled {
                    isHovered = hovering
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if isEnabled {
                            isPressed = true
                        }
                    }
                    .onEnded { _ in
                        isPressed = false
                    }
            )
            .disabled(!isEnabled)
            .pointingHandCursor(enabled: isEnabled)
        }
    }

    private func createNewCategory() {
        guard canAddMoreCategories else { return }

        withAnimation(.easeInOut(duration: 0.25)) {
            if stage != .details {
                stage = .details
            }

            showFirstTimeHints = false

            let baseName = "New category"
            var candidate = baseName
            var suffix = 2
            let existingNames = Set(categories.map { $0.name.lowercased() })
            while existingNames.contains(candidate.lowercased()) {
                candidate = "\(baseName) \(suffix)"
                suffix += 1
            }

            categoryStore.addCategory(name: candidate)
            let editable = categoryStore.editableCategories
            if let newlyCreated = editable.last {
                editingCategoryID = newlyCreated.id
                draftName = newlyCreated.name
                draftDetails = newlyCreated.details

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    pendingScrollTarget = newlyCreated.id
                }
            }
        }
    }

    private func startEditing(_ category: TimelineCategory) {
        if editingCategoryID != nil && editingCategoryID != category.id {
            commitPendingEditsIfNeeded()
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            editingCategoryID = category.id
            draftName = category.name
            draftDetails = category.details
        }
    }

    private func saveEdits(for category: TimelineCategory) {
        let trimmedName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty && trimmedName != category.name {
            categoryStore.renameCategory(id: category.id, to: trimmedName)
        }
        categoryStore.updateDetails(draftDetails, for: category.id)
        endEditing()
    }

    private func deleteCategory(_ category: TimelineCategory) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if editingCategoryID == category.id {
                endEditing()
            }
            categoryStore.removeCategory(id: category.id)
        }
    }

    private func commitPendingEditsIfNeeded() {
        guard let editingID = editingCategoryID,
              let category = categories.first(where: { $0.id == editingID }) else { return }
        saveEdits(for: category)
    }

    private func endEditing() {
        editingCategoryID = nil
        draftName = ""
        draftDetails = ""
    }
}

// App entry point intentionally omitted; DayflowApp provides the main entry.

#Preview("Timeline Card Color Picker") {
    ColorOrganizerRoot()
        .environmentObject(CategoryStore())
        .frame(minWidth: 980, minHeight: 640)
}
