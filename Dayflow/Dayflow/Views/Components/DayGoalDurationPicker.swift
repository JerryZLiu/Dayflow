import AppKit
import SwiftUI

struct GoalDurationPicker: View {
  @Binding var minutes: Int

  private var hoursBinding: Binding<Int> {
    Binding(
      get: { max(0, minutes / 60) },
      set: { newHours in
        minutes = max(0, min(12 * 60, newHours * 60 + minutes % 60))
      }
    )
  }

  private var minuteBinding: Binding<Int> {
    Binding(
      get: { minutes % 60 },
      set: { newMinutes in
        minutes = max(0, min(12 * 60, (minutes / 60) * 60 + newMinutes))
      }
    )
  }

  var body: some View {
    HStack(spacing: 6) {
      GoalNumberColumn(
        value: hoursBinding,
        range: 0...12,
        label: "Hours",
        step: 1,
        numberStackLeft: 5.25,
        numberStackTop: 12.89,
        labelLeft: 41.5
      )

      GoalNumberColumn(
        value: minuteBinding,
        range: 0...55,
        label: "Mins",
        step: 5,
        numberStackLeft: 5.25,
        numberStackTop: 11.89,
        labelLeft: 47
      )
    }
    .padding(EdgeInsets(top: 7, leading: 9, bottom: 10, trailing: 11))
    .background(Color(hex: "F1F1F1"))
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .overlay(
      RoundedRectangle(cornerRadius: 4)
        .stroke(Color(hex: "E6DDD5"), lineWidth: 1)
    )
  }
}

private struct GoalNumberColumn: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @Binding var value: Int
  let range: ClosedRange<Int>
  let label: String
  let step: Int
  let numberStackLeft: CGFloat
  let numberStackTop: CGFloat
  let labelLeft: CGFloat
  @State private var dragStartValue: Int?
  @State private var scrollAccumulator: CGFloat = 0
  @State private var wheelOffset: CGFloat = 0

  private let rowStride: CGFloat = 29

  var body: some View {
    ZStack(alignment: .topLeading) {
      VStack(spacing: 6) {
        wheelRow(offset: -2, size: 21, color: Color(hex: "AAA6A3"))
        wheelRow(offset: -1, size: 23, color: Color(hex: "8A8582"))
        wheelRow(offset: 0, size: 25, color: .black)
        wheelRow(offset: 1, size: 23, color: Color(hex: "8A8582"))
        wheelRow(offset: 2, size: 21, color: Color(hex: "AAA6A3"))
      }
      .frame(width: numberStackWidth)
      .offset(x: numberStackLeft, y: numberStackTop + wheelOffset)

      Text(label)
        .font(.custom("Figtree", size: 14))
        .foregroundColor(.black)
        .lineLimit(1)
        .frame(width: labelWidth, alignment: .leading)
        .offset(x: labelLeft, y: 72)

      VStack(spacing: 0) {
        Color.clear
          .frame(height: 85)
          .contentShape(Rectangle())
          .onTapGesture {
            stepValue(by: -step)
          }

        Color.clear
          .frame(height: 85)
          .contentShape(Rectangle())
          .onTapGesture {
            stepValue(by: step)
          }
      }
      .frame(width: 83, height: 170)
    }
    .frame(width: 83, height: 170)
    .background(
      LinearGradient(
        colors: [
          Color(hex: "E9E4E2"),
          Color(hex: "FFFDFC"),
          Color(hex: "FFFDFC"),
          Color(hex: "E9E4E2"),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
    )
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(Color(hex: "E6DDD9"), lineWidth: 1)
    )
    .contentShape(Rectangle())
    .simultaneousGesture(numberDragGesture)
    .background(
      GoalNumberScrollMonitor { deltaY, isPrecise in
        applyScroll(deltaY, isPrecise: isPrecise)
      }
    )
    .help("Drag or scroll to adjust \(label.lowercased())")
  }

  @ViewBuilder
  private func wheelRow(offset: Int, size: CGFloat, color: Color) -> some View {
    if let rowValue = valueAtOffset(offset) {
      wheelText(rowValue, size: size, color: color)
    } else {
      Color.clear
        .frame(width: numberStackWidth, height: size)
    }
  }

  private func valueAtOffset(_ offset: Int) -> Int? {
    let proposedValue = value + offset * step
    guard range.contains(proposedValue) else { return nil }
    return proposedValue
  }

  private func wheelText(_ value: Int, size: CGFloat, color: Color) -> some View {
    Text(formattedValue(value))
      .font(.custom("Figtree", size: size))
      .foregroundColor(color)
      .lineLimit(1)
      .minimumScaleFactor(0.85)
      .allowsTightening(true)
      .monospacedDigit()
      .frame(width: numberStackWidth, height: size, alignment: .center)
  }

  private var numberStackWidth: CGFloat {
    step == 1 ? 34 : 38
  }

  private var labelWidth: CGFloat {
    label == "Hours" ? 40 : 32
  }

  private func formattedValue(_ value: Int) -> String {
    step == 5 ? String(format: "%02d", value) : "\(value)"
  }

  @discardableResult
  private func stepValue(
    by delta: Int,
    resetsAccumulator: Bool = true,
    showsWheelMotion: Bool = true
  ) -> Bool {
    let proposedValue = clamped(value + delta)
    if resetsAccumulator {
      scrollAccumulator = 0
    }

    guard proposedValue != value else {
      settleWheel()
      return false
    }

    let direction = proposedValue > value ? 1 : -1
    value = proposedValue
    if showsWheelMotion {
      startWheelMotion(direction: direction)
    }
    return true
  }

  private var numberDragGesture: some Gesture {
    DragGesture(minimumDistance: 1)
      .onChanged { gestureValue in
        if dragStartValue == nil {
          dragStartValue = self.value
          scrollAccumulator = 0
        }

        guard let startValue = dragStartValue else { return }
        let rawSteps = Int((-gestureValue.translation.height / rowStride).rounded())
        let nextValue = clamped(startValue + rawSteps * step)
        let appliedSteps = (nextValue - startValue) / step
        let snappedTranslation = -CGFloat(appliedSteps) * rowStride
        let remainingTranslation = gestureValue.translation.height - snappedTranslation

        self.value = nextValue
        self.wheelOffset = rubberBandedOffset(remainingTranslation, at: nextValue)
      }
      .onEnded { gestureValue in
        if let startValue = dragStartValue {
          let rawSteps = Int((-gestureValue.translation.height / rowStride).rounded())
          self.value = clamped(startValue + rawSteps * step)
        }
        dragStartValue = nil
        scrollAccumulator = 0
        settleWheel()
      }
  }

  private func applyScroll(_ deltaY: CGFloat, isPrecise: Bool) {
    guard deltaY != 0 else { return }

    if !isPrecise {
      let direction = deltaY > 0 ? step : -step
      stepValue(by: direction)
      return
    }

    scrollAccumulator += deltaY
    let threshold: CGFloat = 22

    while abs(scrollAccumulator) >= threshold {
      if scrollAccumulator > 0 {
        guard stepValue(by: step, resetsAccumulator: false) else {
          scrollAccumulator = 0
          break
        }
        scrollAccumulator -= threshold
      } else {
        guard stepValue(by: -step, resetsAccumulator: false) else {
          scrollAccumulator = 0
          break
        }
        scrollAccumulator += threshold
      }
    }
  }

  private func startWheelMotion(direction: Int) {
    guard !reduceMotion else {
      wheelOffset = 0
      return
    }

    wheelOffset = direction > 0 ? rowStride : -rowStride
    settleWheel()
  }

  private func settleWheel() {
    guard !reduceMotion else {
      wheelOffset = 0
      return
    }

    withAnimation(.spring(duration: 0.22, bounce: 0)) {
      wheelOffset = 0
    }
  }

  private func rubberBandedOffset(_ offset: CGFloat, at currentValue: Int) -> CGFloat {
    if currentValue == range.lowerBound && offset > 0 {
      return offset * 0.35
    }
    if currentValue == range.upperBound && offset < 0 {
      return offset * 0.35
    }
    return offset
  }

  private func clamped(_ proposedValue: Int) -> Int {
    min(max(proposedValue, range.lowerBound), range.upperBound)
  }

}

private struct GoalNumberScrollMonitor: NSViewRepresentable {
  var onScroll: (CGFloat, Bool) -> Void

  func makeNSView(context: Context) -> ScrollMonitorView {
    let view = ScrollMonitorView()
    view.onScroll = onScroll
    return view
  }

  func updateNSView(_ nsView: ScrollMonitorView, context: Context) {
    nsView.onScroll = onScroll
  }

  static func dismantleNSView(_ nsView: ScrollMonitorView, coordinator: ()) {
    nsView.removeMonitor()
  }

  final class ScrollMonitorView: NSView {
    var onScroll: ((CGFloat, Bool) -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window == nil {
        removeMonitor()
      } else {
        installMonitorIfNeeded()
      }
    }

    func removeMonitor() {
      if let monitor {
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
      }
    }

    private func installMonitorIfNeeded() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
        guard let self, self.isEventInside(event) else {
          return event
        }

        self.onScroll?(event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
        return nil
      }
    }

    private func isEventInside(_ event: NSEvent) -> Bool {
      guard event.window === window else { return false }
      let location = convert(event.locationInWindow, from: nil)
      return bounds.contains(location)
    }
  }
}
