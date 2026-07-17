import SwiftUI

/// Cached DateFormatter for day change detection - creating DateFormatters is expensive (ICU initialization)
private let cachedDayFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "yyyy-MM-dd"
  return formatter
}()

private let dailyGoalPromptHandledDayKey = "dayGoalPromptHandledTimelineDay"

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

  func requestDailyGoalPromptIfNeeded() {
    guard DayGoalPreferences.showDailyGoalPopups else {
      pendingGoalPromptDay = nil
      return
    }

    let today = timelineDisplayDate(from: Date())
    let promptDay = cachedDayFormatter.string(from: today)

    guard UserDefaults.standard.string(forKey: dailyGoalPromptHandledDayKey) != promptDay
    else {
      return
    }
    guard pendingGoalPromptDay != promptDay else { return }
    guard goalFlowPresentation == nil else { return }

    if StorageManager.shared.fetchDayGoalPlan(forDay: promptDay) != nil {
      markDailyGoalPromptHandled(day: promptDay)
      return
    }

    // New users: wait until Dayflow has real data (3 prior days of activity)
    // before asking them to set targets. Not marked handled, so the prompt
    // starts appearing the day the threshold is crossed.
    let activeDays = StorageManager.shared.countDistinctTimelineDays(excludingDay: promptDay)
    guard activeDays >= FeatureAccessRequirements.dayGoalRequiredActiveDays else {
      return
    }

    // Prompt fatigue: if the last 5 answers were all skips, stop auto-prompting.
    // Confirming a goal later (via "Set goals") breaks the streak and resumes.
    let skipStreak = StorageManager.shared.consecutiveSkippedDayGoalCount(
      before: promptDay,
      limit: FeatureAccessRequirements.dayGoalMaxConsecutiveSkips
    )
    guard skipStreak < FeatureAccessRequirements.dayGoalMaxConsecutiveSkips else {
      return
    }

    selectedActivity = nil
    setSelectedDate(today)
    setTimelineMode(.day)

    if selectedIcon != .timeline {
      withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
        selectedIcon = .timeline
      }
    }

    pendingGoalPromptDay = promptDay
  }

  func markDailyGoalPromptHandled(day: String) {
    UserDefaults.standard.set(day, forKey: dailyGoalPromptHandledDayKey)
    if pendingGoalPromptDay == day {
      pendingGoalPromptDay = nil
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
