//
//  Layout+TimelineHeader.swift
//  Dayflow
//

import AppKit
import SwiftUI

private struct TimelineHeaderTrailingWidthPreferenceKey: PreferenceKey {
  static var defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

extension View {
  fileprivate func trackTimelineHeaderTrailingWidth() -> some View {
    background(
      GeometryReader { proxy in
        Color.clear.preference(
          key: TimelineHeaderTrailingWidthPreferenceKey.self,
          value: proxy.size.width
        )
      }
    )
  }

  fileprivate func trackTimelineCalendarButtonFrame() -> some View {
    background(
      GeometryReader { proxy in
        Color.clear.preference(
          key: TimelineCalendarButtonFramePreferenceKey.self,
          value: proxy.frame(in: .named("TimelinePanel"))
        )
      }
    )
  }
}

// Priority-based visibility gates for the timeline header's leading controls.
// Computed once per render from available width + trailing reservation; every
// conditional in `timelineLeadingControls` reads this, so the full header
// renders as a single variant (no `ViewThatFits` shuffle).
private struct TimelineHeaderVisibility {
  var showTodayButton: Bool
  var showDayWeekToggle: Bool
  var showInlineDate: Bool
}

private struct TimelineNavigationButton: View {
  let assetName: String
  var isEnabled = true
  var arrowSize: CGFloat = TimelineNavigationLayout.arrowSize
  var hoverCircleSize: CGFloat = TimelineNavigationLayout.hoverCircleSize
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: {
      guard isEnabled else { return }
      action()
    }) {
      ZStack {
        Circle()
          .fill(Color(hex: "FFEBD3").opacity(0.79))
          .frame(width: hoverCircleSize, height: hoverCircleSize)
          .opacity(isHovering && isEnabled ? 1 : 0)

        Image(assetName)
          .resizable()
          .scaledToFit()
          .frame(width: arrowSize, height: arrowSize)
          .opacity(isEnabled ? 1 : 0.35)
      }
      .frame(width: max(arrowSize, hoverCircleSize), height: max(arrowSize, hoverCircleSize))
      .contentShape(Circle())
    }
    .buttonStyle(DayflowPressScaleButtonStyle(enabled: isEnabled))
    .disabled(!isEnabled)
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.12)) {
        isHovering = isEnabled && hovering
      }
    }
    .onChange(of: isEnabled) { _, enabled in
      if !enabled {
        isHovering = false
      }
    }
    .pointingHandCursorOnHover(enabled: isEnabled, reassertOnPressEnd: true)
  }
}

extension MainView {
  // Priority-based responsive layout.
  //
  // The trailing Pause pill is *right-pinned and inviolable* — its measured
  // width (including expanded duration chips or "paused for HH:MM" status
  // text) feeds `timelineHeaderTrailingReservation`, which we subtract from
  // the GeometryReader's reported width to get how much room the leading
  // cluster has. `computeHeaderVisibility` then walks a priority ladder
  // (Today → Day/Week → inline date) and decides which optional elements
  // fit. A single variant of `timelineLeadingControls` renders — no
  // `ViewThatFits` branch-flipping, no `.fixedSize(horizontal:)` fighting
  // child widths, no `.animation(...value: trailingReservation)` firing
  // concurrently with the Day/Week matchedGeometryEffect toggle.
  var timelineHeader: some View {
    ZStack(alignment: .trailing) {
      GeometryReader { geo in
        let visibility = computeHeaderVisibility(availableWidth: geo.size.width)
        timelineLeadingControls(visibility: visibility)
          .padding(.trailing, timelineHeaderTrailingReservation)
          // maxHeight: .infinity is load-bearing — without it the HStack pins
          // to the GR's top edge while the Pause pill sits center-vertically
          // in the sibling ZStack, visibly misaligning the two clusters.
          // `Alignment.leading` = horizontal .leading + vertical .center.
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      }

      timelineTrailingControls
        .trackTimelineHeaderTrailingWidth()
    }
    .frame(height: 36)
    .padding(.horizontal, 10)
    .onPreferenceChange(TimelineHeaderTrailingWidthPreferenceKey.self) { width in
      timelineHeaderTrailingWidth = width
    }
  }

  // Actual pixel width of the current date label text, measured via NSFont
  // metrics. Replaces a conservative 240pt estimate — "Today, Apr 16" is
  // ~170pt, "September 12 - September 18" is ~330pt, so a single estimate
  // either over- or under-reserves. This matches the measurement pattern
  // used in `DateNavigationControls.swift:calculateOptimalPillWidth()`.
  private var measuredDateLabelWidth: CGFloat {
    let font =
      NSFont(name: "InstrumentSerif-Regular", size: 26)
      ?? NSFont.systemFont(ofSize: 26)
    return timelineTitleText.size(withAttributes: [.font: font]).width
  }

  // Walks from "always visible" core upward, adding each optional element
  // if it fits in the remaining budget. Order matters: Today (smallest,
  // most task-relevant) is added first; Day/Week is added next; the inline
  // date is added last. When Pause expands, trailing reservation grows,
  // `usable` shrinks, and elements drop off in reverse priority order —
  // automatic, no explicit "if Pause expanded hide X" logic needed.
  private func computeHeaderVisibility(availableWidth: CGFloat) -> TimelineHeaderVisibility {
    let reservation = timelineHeaderTrailingReservation
    let usable = max(0, availableWidth - reservation)

    // Matches the pinned widths of each control (Figma-spec accurate).
    let chevronsWidth = (TimelineNavigationLayout.arrowSize * 2) + 2
    let calendarWidth: CGFloat = 36
    let dayWeekWidth: CGFloat = 104
    let todayWidth: CGFloat = 56
    let gap = TimelineNavigationLayout.calendarGap
    let datePad: CGFloat = 10

    var used = chevronsWidth + gap + calendarWidth
    var vis = TimelineHeaderVisibility(
      showTodayButton: false,
      showDayWeekToggle: false,
      showInlineDate: false
    )

    if shouldShowTodayButton, used + gap + todayWidth <= usable {
      used += gap + todayWidth
      vis.showTodayButton = true
    }
    if used + gap + dayWeekWidth <= usable {
      used += gap + dayWeekWidth
      vis.showDayWeekToggle = true
    }
    // The liberal allowance (date shows 55pt earlier than strict fit) only
    // applies when the trailing cluster is in its *compact* state. When
    // Pause expands — either the duration-chip menu (~250pt) or the
    // paused-status text "Dayflow paused for HH:MM" (~290pt) — the trailing
    // cluster's leftward occupation already fills the header; piling on
    // a date-allowance at that point produces overlap with the status
    // text. Threshold of 100pt safely partitions compact (idle 73, paused
    // 84) from expanded (menu 250+, paused+status 290).
    let trailingIsCompact = timelineHeaderTrailingWidth < 100
    let dateLiberalAllowance: CGFloat = trailingIsCompact ? 55 : 0
    if used + datePad + measuredDateLabelWidth <= usable + dateLiberalAllowance {
      vis.showInlineDate = true
    }
    return vis
  }

  // Single-variant rendering. Every optional element is gated by the
  // visibility flags computed in `computeHeaderVisibility`. No
  // `.fixedSize(horizontal:)` — element widths are all explicit (see the
  // in-file comments on `timelineModeSwitch` and `timelineCalendarButton`
  // for the history of that decision).
  //
  // `.frame(height: 30)` on the HStack pins its vertical dimension to the
  // pill height so the date label (which has a ~31pt natural line height
  // at InstrumentSerif 26pt) can't grow the HStack when it appears. Without
  // this pin, the pills visibly shifted by ~0.5pt when the date entered.
  private func timelineLeadingControls(visibility: TimelineHeaderVisibility) -> some View {
    HStack(spacing: TimelineNavigationLayout.calendarGap) {
      timelineNavigationButtons
      timelineCalendarButton

      if visibility.showDayWeekToggle {
        timelineModeSwitch
      }

      if visibility.showTodayButton {
        timelineTodayButton
          .transition(.opacity.combined(with: .scale(scale: 0.94)))
      }

      if visibility.showInlineDate {
        timelineHeaderDateLabel
          .padding(.leading, 10)
      }
    }
    .frame(height: 30)
    .offset(x: timelineOffset + TimelineAlignment.pickerRowOffset)
    .opacity(timelineOpacity)
  }

  private var timelineTrailingControls: some View {
    PausePillView()
  }

  private var timelineHeaderTrailingReservation: CGFloat {
    let measuredWidth = max(timelineHeaderTrailingWidth, 120)
    return measuredWidth + 18
  }

  private var timelineNavigationButtons: some View {
    HStack(spacing: 2) {
      TimelineNavigationButton(
        assetName: "LeftArrow",
        arrowSize: TimelineNavigationLayout.arrowSize,
        hoverCircleSize: TimelineNavigationLayout.hoverCircleSize
      ) {
        navigateTimeline(to: previousTimelineDate(), method: "prev")
      }

      TimelineNavigationButton(
        assetName: "RightArrow",
        isEnabled: canNavigateTimelineForward,
        arrowSize: TimelineNavigationLayout.arrowSize,
        hoverCircleSize: TimelineNavigationLayout.hoverCircleSize
      ) {
        navigateTimeline(to: nextTimelineDate(), method: "next")
      }
    }
  }

  // Calendar pill — Figma 1:1 visuals (fill #FFA777, icon 16×16, h=30, border
  // #F2D2BD). The arrowless card itself is rendered at the panel level so it
  // can own outside-click dismissal without taps leaking through to the
  // timeline below.
  private var timelineCalendarButton: some View {
    Button(action: {
      if showTimelineCalendarPopover {
        closeTimelineCalendarPopover()
      } else {
        openTimelineCalendarPopover()
      }
    }) {
      ZStack {
        Capsule(style: .continuous)
          .fill(timelineCalendarButtonFillColor)
          .overlay(
            Capsule(style: .continuous)
              .stroke(timelineCalendarButtonBorderColor, lineWidth: 1)
          )
          .shadow(
            color: timelineCalendarButtonShadowColor,
            radius: showTimelineCalendarPopover ? 8 : 0,
            x: 0,
            y: showTimelineCalendarPopover ? 2 : 0
          )

        Image("CalendarIcon")
          .resizable()
          .scaledToFit()
          .frame(width: 16, height: 16)
      }
      .frame(width: 36, height: 30)
      .contentShape(Capsule(style: .continuous))
    }
    .buttonStyle(
      DayflowPressScaleButtonStyle(
        pressedScale: 0.985,
        animation: .spring(response: 0.18, dampingFraction: 0.88)
      )
    )
    .pointingHandCursorOnHover(reassertOnPressEnd: true)
    .animation(timelineCalendarButtonStateAnimation, value: showTimelineCalendarPopover)
    .trackTimelineCalendarButtonFrame()
  }

  private var timelineCalendarButtonFillColor: Color {
    showTimelineCalendarPopover ? Color(hex: "FFB38E") : Color(hex: "FFA777")
  }

  private var timelineCalendarButtonBorderColor: Color {
    showTimelineCalendarPopover ? Color(hex: "E8BDA1") : Color(hex: "F2D2BD")
  }

  private var timelineCalendarButtonShadowColor: Color {
    showTimelineCalendarPopover ? .black.opacity(0.10) : .clear
  }

  private var timelineCalendarButtonStateAnimation: Animation {
    reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.14)
  }

  private var timelineCalendarPopoverOpenAnimation: Animation {
    reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.18)
  }

  private var timelineCalendarPopoverCloseAnimation: Animation {
    reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.12)
  }

  private var timelineCalendarPopoverTransition: AnyTransition {
    guard !reduceMotion else { return .opacity }

    return .asymmetric(
      insertion: .opacity
        .combined(with: .offset(y: -6))
        .animation(timelineCalendarPopoverOpenAnimation),
      removal: .opacity
        .combined(with: .offset(y: -4))
        .animation(timelineCalendarPopoverCloseAnimation)
    )
  }

  private func openTimelineCalendarPopover() {
    withAnimation(timelineCalendarPopoverOpenAnimation) {
      showTimelineCalendarPopover = true
    }
  }

  private func closeTimelineCalendarPopover() {
    withAnimation(timelineCalendarPopoverCloseAnimation) {
      showTimelineCalendarPopover = false
    }
  }

  func timelineCalendarPopoverOverlay(panelWidth: CGFloat) -> some View {
    let cardWidth = TimelineCalendarPopover.preferredWidth
    let horizontalPadding: CGFloat = 12
    let maxX = max(
      horizontalPadding,
      panelWidth - cardWidth - horizontalPadding
    )
    let cardX = min(
      max(horizontalPadding, timelineCalendarButtonFrame.midX - (cardWidth / 2)),
      maxX
    )

    return ZStack(alignment: .topLeading) {
      if showTimelineCalendarPopover {
        Rectangle()
          .fill(Color.black.opacity(0.001))
          .contentShape(Rectangle())
          .onTapGesture {
            closeTimelineCalendarPopover()
          }

        TimelineCalendarPopover(
          isPresented: $showTimelineCalendarPopover,
          selectedDate: selectedDate,
          canSelectFutureDates: false,
          highlightsSelectedWeek: timelineMode == .week,
          onSelect: { date in
            let tappedDay = dayString(date)
            let currentDay = dayString(selectedDate)
            let tappedWeek = TimelineWeekRange.containing(date)
            let currentWeek = timelineWeekRange
            let weekChanged = tappedWeek != currentWeek

            timelinePerfLog(
              "calendarPopover.select tapped=\(tappedDay) current=\(currentDay) mode=\(timelineMode.rawValue) weekChanged=\(weekChanged)"
            )

            timelinePerfLog(
              "calendarPopover.navigateDispatch tapped=\(tappedDay) mode=\(timelineMode.rawValue) weekChanged=\(weekChanged)"
            )
            navigateTimeline(to: date, method: "picker")
            DispatchQueue.main.async {
              closeTimelineCalendarPopover()
            }
          }
        )
        .offset(x: cardX, y: timelineCalendarButtonFrame.maxY + 55)
        .transition(timelineCalendarPopoverTransition)
        .zIndex(1)
      }
    }
    .allowsHitTesting(showTimelineCalendarPopover)
  }

  private var timelineModeSwitch: some View {
    HStack(spacing: 0) {
      ForEach(TimelineMode.allCases) { mode in
        let isSelected = timelineMode == mode

        Button(action: {
          setTimelineMode(mode)
        }) {
          ZStack {
            if isSelected {
              Capsule(style: .continuous)
                .fill(
                  LinearGradient(
                    colors: [
                      Color(hex: "FFB18D").opacity(0.6),
                      Color(hex: "FFA46F"),
                      Color(hex: "FFB18D"),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                  )
                )
                .shadow(color: Color(hex: "E89A6C").opacity(0.18), radius: 4, x: 0, y: 1)
                .matchedGeometryEffect(
                  id: "timeline_mode_highlight",
                  in: timelineModeSwitchNamespace
                )
            }

            Text(mode.title)
              .font(.custom("Figtree", size: 12).weight(.medium))
              .foregroundColor(isSelected ? .white : Color(hex: "796E64"))
              // Concrete width (52pt × 2 = 104pt container) instead of
              // `.frame(maxWidth: .infinity)`. The infinity was being fought
              // by the `.fixedSize(horizontal: true)` ancestor on
              // `timelineLeadingControls`, which resolved the toggle's
              // ideal width as ~0 and collapsed the cream background +
              // "Day" label. Three independent parallel investigations
              // converged on this exact change.
              .frame(width: 52, height: 30)
          }
          .contentShape(Capsule(style: .continuous))
        }
        // Reverted to PlainButtonStyle: DayflowPressScaleButtonStyle — even
        // with `enabled: false` — still wraps the label in `.animation(...)`,
        // which appears to conflict with the outer `.animation(...)` tied to
        // the matchedGeometryEffect gradient. The press-darkening flash is
        // the accepted tradeoff for a correctly-behaving matched slide.
        .buttonStyle(PlainButtonStyle())
        .hoverScaleEffect(scale: 1.01)
        .pointingHandCursorOnHover(reassertOnPressEnd: true)
      }
    }
    .frame(width: 104, height: 30)
    .background(Color(hex: "FFEFE4"))
    .clipShape(Capsule(style: .continuous))
    .overlay(
      Capsule(style: .continuous)
        .stroke(Color(hex: "F2D2BD"), lineWidth: 1)
    )
    .animation(timelineModeSwitchAnimation, value: timelineMode)
  }

  private var timelineTodayButton: some View {
    Button(action: {
      navigateTimeline(to: timelineDisplayDate(from: Date()), method: "today")
    }) {
      Text("Today")
        .font(.custom("Figtree", size: 12).weight(.medium))
        .foregroundColor(Color(hex: "796E64"))
        .padding(.horizontal, 10)
        // Explicit width pinned (natural ~52pt + 4pt safety margin). Same
        // rationale as the calendar pill: under the ancestor's `.fixedSize`
        // inside a `ViewThatFits`, implicit widths can resolve to unstable
        // values mid-transition, nudging the Day/Week toggle's position and
        // desyncing its `matchedGeometryEffect` anchors during a mode flip.
        .frame(width: 56, height: 30)
        .background(Color(hex: "FFEFE4"))
        .clipShape(Capsule(style: .continuous))
        .overlay(
          Capsule(style: .continuous)
            .stroke(Color(hex: "F2D2BD"), lineWidth: 1)
        )
    }
    .buttonStyle(DayflowPressScaleButtonStyle(pressedScale: 0.97))
    .hoverScaleEffect(scale: 1.02)
    .pointingHandCursorOnHover(reassertOnPressEnd: true)
  }

  private var timelineHeaderDateLabel: some View {
    Text(timelineTitleText)
      .font(.custom("InstrumentSerif-Regular", size: 26))
      .foregroundColor(Color.black)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .onTapGesture {
        guard timelineMode == .day else { return }
        showDatePicker = true
        lastDateNavMethod = "picker"
      }
  }
}
