import SwiftUI

/// Cached DateFormatter for day change detection - creating DateFormatters is expensive (ICU initialization)
private let cachedDayFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "yyyy-MM-dd"
  return formatter
}()

extension MainView {
  func startDayChangeTimer() {
    stopDayChangeTimer()
    dayChangeTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { _ in
      handleMinuteTickForDayChange()
    }
  }

  func stopDayChangeTimer() {
    dayChangeTimer?.invalidate()
    dayChangeTimer = nil
  }

  func handleMinuteTickForDayChange() {
    // Detect timeline day rollover (4am boundary) regardless of what day user is viewing
    let currentTimelineDay = cachedDayFormatter.string(from: timelineDisplayDate(from: Date()))
    if currentTimelineDay != lastObservedTimelineDay {
      lastObservedTimelineDay = currentTimelineDay

      // Jump to current timeline day and re-scroll near now
      setSelectedDate(timelineDisplayDate(from: Date()))
      selectedActivity = nil
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        withAnimation(.easeInOut(duration: 0.35)) {
          scrollToNowTick &+= 1
        }
      }
    }
  }

  func performIdleResetAndScroll() {
    // Switch to today
    setSelectedDate(timelineDisplayDate(from: Date()))
    // Clear selection
    selectedActivity = nil
    // Nudge timeline to scroll to now after it reloads
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      #if DEBUG
        print("[MainView] performIdleResetAndScroll -> nudging scrollToNowTick")
      #endif
      withAnimation(.easeInOut(duration: 0.35)) {
        scrollToNowTick &+= 1
      }
    }
  }

  func performInitialScrollIfNeeded() {
    // Check all conditions for initial scroll:
    // 1. Timeline is visible (not in settings)
    // 2. No modal is open
    // 3. Selected date is today
    guard selectedIcon != .settings,
      !showDatePicker,
      timelineIsToday(selectedDate)
    else {
      return
    }

    // Mark that we've attempted initial scroll
    didInitialScroll = true

    // Wait for layout to settle after animations complete
    // Increased delay to ensure ScrollView is fully ready on cold start
    #if DEBUG
      print("[MainView] performInitialScrollIfNeeded scheduled with 1.5s delay")
    #endif
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
      #if DEBUG
        print("[MainView] performInitialScrollIfNeeded firing -> nudging scrollToNowTick")
      #endif
      withAnimation(.easeInOut(duration: 0.35)) {
        scrollToNowTick &+= 1
      }
    }
  }
}
