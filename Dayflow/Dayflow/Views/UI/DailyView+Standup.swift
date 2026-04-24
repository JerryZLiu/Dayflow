import AppKit
import Foundation
import SwiftUI
import UserNotifications

extension DailyView {
  @ViewBuilder
  func actionRow(scale: CGFloat) -> some View {
    let actionButtons = HStack(spacing: 10 * scale) {
      if hasPersistedStandupEntry {
        standupCopyButton(scale: scale)
      }
      standupRegenerateButton(scale: scale)
      dailyProviderButton(scale: scale)
    }

    HStack {
      Spacer(minLength: 0)
      actionButtons
    }
  }
  func standupCopyButton(scale: CGFloat) -> some View {
    let transition = AnyTransition.opacity.combined(with: .scale(scale: 0.5))

    return Button(action: copyStandupUpdateToClipboard) {
      HStack(spacing: 6 * scale) {
        ZStack {
          if standupCopyState == .copied {
            Image(systemName: "checkmark")
              .font(.system(size: 12 * scale, weight: .semibold))
              .transition(transition)
          } else {
            Image("Copy")
              .resizable()
              .interpolation(.high)
              .renderingMode(.template)
              .scaledToFit()
              .frame(width: 16 * scale, height: 16 * scale)
              .transition(transition)
          }
        }
        .frame(width: 16 * scale, height: 16 * scale)

        ZStack(alignment: .leading) {
          Text("Copy standup update")
            .font(.custom("Nunito-Medium", size: 14 * scale))
            .lineLimit(1)
            .opacity(standupCopyState == .copied ? 0 : 1)

          Text("Copied")
            .font(.custom("Nunito-Medium", size: 14 * scale))
            .lineLimit(1)
            .opacity(standupCopyState == .copied ? 1 : 0)
        }
        .frame(minWidth: 136 * scale, alignment: .leading)
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 12 * scale)
      .padding(.vertical, 10 * scale)
      .background(
        LinearGradient(
          colors: [
            Color(hex: "FF986F"),
            Color(hex: "BDAAFF"),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
      .clipShape(Capsule(style: .continuous))
      .overlay(
        Capsule(style: .continuous)
          .stroke(Color(hex: "F2D7C3"), lineWidth: max(1.2, 1.5 * scale))
      )
      .contentShape(Capsule(style: .continuous))
    }
    .buttonStyle(DailyCopyPressButtonStyle())
    .animation(.easeInOut(duration: 0.22), value: standupCopyState)
    .pointingHandCursorOnHover(reassertOnPressEnd: true)
    .accessibilityLabel(
      Text(standupCopyState == .copied ? "Copied standup update" : "Copy standup update"))
  }
  func standupRegenerateButton(scale: CGFloat) -> some View {
    let transition = AnyTransition.opacity.combined(with: .scale(scale: 0.5))

    return Button(action: regenerateStandupFromTimeline) {
      HStack(spacing: 6 * scale) {
        ZStack {
          if standupRegenerateState == .regenerating {
            ProgressView()
              .progressViewStyle(.circular)
              .scaleEffect(0.6 * scale)
              .tint(.white)
          } else if standupRegenerateState == .regenerated {
            Image(systemName: "checkmark")
              .font(.system(size: 12 * scale, weight: .semibold))
              .transition(transition)
          } else if standupRegenerateState == .noData {
            Image(systemName: "exclamationmark.circle")
              .font(.system(size: 12 * scale, weight: .semibold))
              .transition(transition)
          } else {
            Image(systemName: "arrow.clockwise")
              .font(.system(size: 12 * scale, weight: .semibold))
              .transition(transition)
          }
        }
        .frame(width: 16 * scale, height: 16 * scale)

        ZStack(alignment: .leading) {
          Text(regenerateButtonLabel)
            .font(.custom("Nunito-Medium", size: 14 * scale))
            .lineLimit(1)
            .opacity(transientRegenerateButtonLabel == nil ? 1 : 0)

          Text(transientRegenerateButtonLabel ?? "")
            .font(.custom("Nunito-Medium", size: 14 * scale))
            .lineLimit(1)
            .opacity(transientRegenerateButtonLabel == nil ? 0 : 1)
        }
        .frame(minWidth: 108 * scale, alignment: .leading)
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 12 * scale)
      .padding(.vertical, 10 * scale)
      .background(
        LinearGradient(
          colors: [
            Color(hex: "FFB58A"),
            Color(hex: "ED9BC0"),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
      .clipShape(Capsule(style: .continuous))
      .overlay(
        Capsule(style: .continuous)
          .stroke(Color(hex: "F2D7C3"), lineWidth: max(1.2, 1.5 * scale))
      )
      .contentShape(Capsule(style: .continuous))
    }
    .buttonStyle(DailyCopyPressButtonStyle())
    .animation(.easeInOut(duration: 0.22), value: standupRegenerateState)
    .disabled(!canRegenerateStandup)
    .pointingHandCursorOnHover(
      enabled: canRegenerateStandup, reassertOnPressEnd: true
    )
    .accessibilityLabel(Text("Regenerate standup highlights"))
    .help(regenerateButtonHelpText)
    .background {
      if standupRegenerateState == .regenerating {
        Color.clear
          .onReceive(Timer.publish(every: 0.45, on: .main, in: .common).autoconnect()) { _ in
            standupRegeneratingDotsPhase = (standupRegeneratingDotsPhase % 3) + 1
          }
      }
    }
    .onChange(of: standupRegenerateState) {
      if standupRegenerateState != .regenerating {
        standupRegeneratingDotsPhase = 1
      }
    }
  }
  @ViewBuilder
  func highlightsAndTasksSection(
    useSingleColumn: Bool,
    contentWidth: CGFloat,
    scale: CGFloat,
    heading: String,
    titles: DailyStandupSectionTitles
  ) -> some View {
    VStack(alignment: .leading, spacing: 8 * scale) {
      Text(heading)
        .font(.custom("InstrumentSerif-Regular", size: 24 * scale))
        .foregroundStyle(Color(hex: "B46531"))

      if useSingleColumn {
        VStack(alignment: .leading, spacing: 12 * scale) {
          DailyBulletCard(
            style: .highlights,
            seamMode: .standalone,
            title: titles.highlights,
            items: $standupDraft.highlights,
            blockersTitle: $standupDraft.blockersTitle,
            blockersBody: $standupDraft.blockersBody,
            scale: scale
          )
          DailyBulletCard(
            style: .tasks,
            seamMode: .standalone,
            title: titles.tasks,
            items: $standupDraft.tasks,
            blockersTitle: $standupDraft.blockersTitle,
            blockersBody: $standupDraft.blockersBody,
            scale: scale
          )
        }
      } else {
        // Figma overlaps borders by ~1px to avoid a visible gutter.
        let cardSpacing = -1 * scale
        let cardWidth = (contentWidth - cardSpacing) / 2
        HStack(alignment: .top, spacing: cardSpacing) {
          DailyBulletCard(
            style: .highlights,
            seamMode: .joinedLeading,
            title: titles.highlights,
            items: $standupDraft.highlights,
            blockersTitle: $standupDraft.blockersTitle,
            blockersBody: $standupDraft.blockersBody,
            scale: scale
          )
          .frame(width: cardWidth)

          DailyBulletCard(
            style: .tasks,
            seamMode: .joinedTrailing,
            title: titles.tasks,
            items: $standupDraft.tasks,
            blockersTitle: $standupDraft.blockersTitle,
            blockersBody: $standupDraft.blockersBody,
            scale: scale
          )
          .frame(width: cardWidth)
        }
      }
    }
  }
  func copyStandupUpdateToClipboard() {
    let clipboardText = standupClipboardText(for: selectedDate)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(clipboardText, forType: .string)

    standupCopyResetTask?.cancel()

    withAnimation(.easeInOut(duration: 0.22)) {
      standupCopyState = .copied
    }

    AnalyticsService.shared.capture(
      "daily_standup_copied",
      [
        "timeline_day": workflowDayString(for: selectedDate),
        "highlights_count": standupDraft.highlights.count,
        "tasks_count": standupDraft.tasks.count,
      ])

    standupCopyResetTask = Task {
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      guard !Task.isCancelled else { return }

      await MainActor.run {
        withAnimation(.easeInOut(duration: 0.22)) {
          standupCopyState = .idle
        }
        standupCopyResetTask = nil
      }
    }
  }
  func regenerateStandupFromTimeline() {
    guard standupRegenerateState != .regenerating else { return }
    let regenerateRunId = UUID().uuidString

    let targetDay = workflowDayInfo(for: selectedDate)
    let storageDayString = targetDay.dayString
    let selectedProvider = dailyRecapProvider
    let usesDayflowInputs = selectedProvider.usesDayflowInputs

    guard selectedProvider.canGenerate else {
      standupDraft = .noProviderSelected
      standupRegenerateState = .idle
      return
    }
    let providerProps: [String: Any] = [
      "daily_provider": selectedProvider.analyticsName,
      "daily_provider_label": selectedProvider.displayName,
      "daily_runtime": selectedProvider.runtimeLabel,
      "daily_model_or_tool": selectedProvider.modelOrTool as Any,
    ]
    guard let sourceDayInfo = standupSourceDay ?? resolveStandupSourceDay(for: targetDay) else {
      standupRegenerateState = .noData
      AnalyticsService.shared.capture(
        "daily_generation_failed",
        providerProps.merging(
          [
            "timeline_day": storageDayString,
            "source": "regenerate_button",
            "reason": "not_enough_recent_activity",
          ],
          uniquingKeysWith: { _, new in new }
        ))
      scheduleStandupRegenerateReset()
      return
    }

    let dayString = sourceDayInfo.dayString
    let dayStartTs = Int(sourceDayInfo.startOfDay.timeIntervalSince1970)
    let dayEndTs = Int(sourceDayInfo.endOfDay.timeIntervalSince1970)
    let standupTitles = standupSectionTitles(for: selectedDate, sourceDay: sourceDayInfo)
    let currentHighlightsTitle = standupTitles.highlights
    let currentTasksTitle = standupTitles.tasks
    let currentBlockersTitle = standupTitles.blockers

    standupRegenerateTask?.cancel()
    standupRegenerateResetTask?.cancel()

    AnalyticsService.shared.capture(
      "daily_standup_regenerate_clicked",
      providerProps.merging(
        [
          "timeline_day": storageDayString,
          "source": "regenerate_button",
        ],
        uniquingKeysWith: { _, new in new }
      ))
    print(
      "[Daily] Regenerate started run_id=\(regenerateRunId) day=\(dayString) provider=\(selectedProvider.analyticsName) model=\(selectedProvider.modelOrTool ?? "default")"
    )

    standupRegenerateState = .regenerating

    standupRegenerateTask = Task.detached(priority: .userInitiated) {
      let startedAt = Date()
      let cards = StorageManager.shared.fetchTimelineCards(forDay: dayString)
      guard !cards.isEmpty else {
        guard !Task.isCancelled else { return }
        print(
          "[Daily] Regenerate failed run_id=\(regenerateRunId) day=\(dayString) reason=no_cards")
        await MainActor.run {
          AnalyticsService.shared.capture(
            "daily_generation_failed",
            providerProps.merging(
              [
                "timeline_day": storageDayString,
                "source": "regenerate_button",
                "reason": "no_cards",
              ],
              uniquingKeysWith: { _, new in new }
            ))

          guard isStillViewingWorkflowDay(storageDayString) else { return }

          standupRegenerateState = .noData
          standupRegenerateTask = nil
          scheduleStandupRegenerateReset()
        }
        return
      }

      let observations =
        usesDayflowInputs
        ? StorageManager.shared.fetchObservations(startTs: dayStartTs, endTs: dayEndTs) : []
      let priorEntries =
        usesDayflowInputs
        ? StorageManager.shared.fetchRecentDailyStandups(
          limit: priorStandupHistoryLimit,
          excludingDay: dayString
        ) : []
      let cardsText = DailyRecapGenerator.makeCardsText(day: dayString, cards: cards)
      let observationsText =
        usesDayflowInputs
        ? DailyRecapGenerator.makeObservationsText(day: dayString, observations: observations)
        : ""
      let priorDailyText =
        usesDayflowInputs ? DailyRecapGenerator.makePriorDailyText(entries: priorEntries) : ""
      let preferencesText =
        usesDayflowInputs
        ? DailyRecapGenerator.makePreferencesText(
          highlightsTitle: currentHighlightsTitle,
          tasksTitle: currentTasksTitle,
          blockersTitle: currentBlockersTitle
        ) : ""

      AnalyticsService.shared.capture(
        "daily_generation_payload_built",
        providerProps.merging(
          [
            "timeline_day": dayString,
            "source": "regenerate_button",
            "input_mode": usesDayflowInputs ? "cards_observations_prior" : "cards_only",
            "cards_count": cards.count,
            "observations_count": observations.count,
            "prior_daily_count": priorEntries.count,
            "cards_text_chars": cardsText.count,
            "observations_text_chars": observationsText.count,
            "prior_daily_text_chars": priorDailyText.count,
            "preferences_text_chars": preferencesText.count,
          ],
          uniquingKeysWith: { _, new in new }
        ))
      print(
        "[Daily] Regenerate payload run_id=\(regenerateRunId) day=\(dayString) "
          + "cards=\(cards.count) observations=\(observations.count) prior_daily=\(priorEntries.count) input_mode=\(usesDayflowInputs ? "cards_observations_prior" : "cards_only")"
      )

      do {
        let context = DailyRecapGenerationContext(
          targetDayString: storageDayString,
          sourceDayString: dayString,
          cards: cards,
          observations: observations,
          priorEntries: priorEntries,
          highlightsTitle: currentHighlightsTitle,
          tasksTitle: currentTasksTitle,
          blockersTitle: currentBlockersTitle
        )
        let regeneratedDraft = try await DailyRecapGenerator.shared.generate(context: context)

        guard let payloadJSON = regeneratedDraft.encodedJSONString() else {
          guard !Task.isCancelled else { return }
          print(
            "[Daily] Regenerate failed run_id=\(regenerateRunId) day=\(dayString) "
              + "reason=encode_failed"
          )
          await MainActor.run {
            AnalyticsService.shared.capture(
              "daily_generation_failed",
              providerProps.merging(
                [
                  "timeline_day": storageDayString,
                  "source": "regenerate_button",
                  "reason": "encode_failed",
                ],
                uniquingKeysWith: { _, new in new }
              ))

            guard isStillViewingWorkflowDay(storageDayString) else { return }

            standupRegenerateState = .idle
            standupRegenerateTask = nil
          }
          return
        }

        StorageManager.shared.saveDailyStandup(forDay: storageDayString, payloadJSON: payloadJSON)

        guard !Task.isCancelled else { return }
        let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let blockersCount = regeneratedDraft.blockersBody
          .split(whereSeparator: \.isNewline)
          .count
        print(
          "[Daily] Regenerate succeeded run_id=\(regenerateRunId) day=\(dayString) cards=\(cards.count) observations=\(observations.count) highlights=\(regeneratedDraft.highlights.count) tasks=\(regeneratedDraft.tasks.count) blockers=\(blockersCount) latency_ms=\(latencyMs)"
        )

        let shouldApplyVisibleResult = await MainActor.run {
          isStillViewingWorkflowDay(storageDayString)
        }

        await MainActor.run {
          AnalyticsService.shared.capture(
            "daily_standup_regenerated",
            providerProps.merging(
              [
                "timeline_day": storageDayString,
                "highlights_count": regeneratedDraft.highlights.count,
                "tasks_count": regeneratedDraft.tasks.count,
                "blockers_count": blockersCount,
              ],
              uniquingKeysWith: { _, new in new }
            ))
          AnalyticsService.shared.capture(
            "daily_generation_succeeded",
            providerProps.merging(
              [
                "timeline_day": storageDayString,
                "source": "regenerate_button",
                "highlights_count": regeneratedDraft.highlights.count,
                "tasks_count": regeneratedDraft.tasks.count,
                "blockers_count": blockersCount,
                "latency_ms": latencyMs,
              ],
              uniquingKeysWith: { _, new in new }
            ))
          print(
            "[Daily] Regenerate notification enqueue run_id=\(regenerateRunId) "
              + "day=\(storageDayString)"
          )
          NotificationService.shared.scheduleDailyRecapReadyNotification(forDay: storageDayString)

          guard shouldApplyVisibleResult else { return }

          standupDraft = regeneratedDraft
          loadedStandupDraftDay = storageDayString
          loadedStandupFallbackSourceDay = sourceDayInfo.dayString
          standupSourceDay = sourceDayInfo
          hasPersistedStandupEntry = true
          standupRegenerateTask = nil
          standupRegenerateState = .regenerated

          scheduleStandupRegenerateReset()
        }
      } catch {
        let nsError = error as NSError
        guard !Task.isCancelled else { return }
        print(
          "[Daily] Regenerate failed run_id=\(regenerateRunId) day=\(dayString) reason=api_error error_domain=\(nsError.domain) error_code=\(nsError.code) error_message=\(nsError.localizedDescription)"
        )
        await MainActor.run {
          AnalyticsService.shared.capture(
            "daily_generation_failed",
            providerProps.merging(
              [
                "timeline_day": storageDayString,
                "source": "regenerate_button",
                "reason": "api_error",
                "error_domain": nsError.domain,
                "error_code": nsError.code,
                "error_message": String(nsError.localizedDescription.prefix(500)),
              ],
              uniquingKeysWith: { _, new in new }
            ))

          guard isStillViewingWorkflowDay(storageDayString) else { return }

          standupRegenerateState = .idle
          standupRegenerateTask = nil
        }
      }
    }
  }
  func standupClipboardText(for date: Date) -> String {
    let targetDay = workflowDayInfo(for: date)
    let sourceDay = resolveStandupSourceDay(for: targetDay)
    let titles = standupSectionTitles(for: date, sourceDay: sourceDay)
    let yesterdayItems = sanitizedStandupItems(standupDraft.highlights)
    let todayItems = sanitizedStandupItems(standupDraft.tasks)
    let blockersItems = sanitizedBlockers(standupDraft.blockersBody)

    var lines: [String] = []
    lines.append(titles.highlights)
    if yesterdayItems.isEmpty {
      lines.append("- None right now")
    } else {
      yesterdayItems.forEach { lines.append("- \($0)") }
    }
    lines.append("")

    lines.append(titles.tasks)
    if todayItems.isEmpty {
      lines.append("- None right now")
    } else {
      todayItems.forEach { lines.append("- \($0)") }
    }
    lines.append("")

    lines.append(titles.blockers)
    if blockersItems.isEmpty {
      lines.append("- None right now")
    } else {
      blockersItems.forEach { lines.append("- \($0)") }
    }

    return lines.joined(separator: "\n")
  }
  func sanitizedStandupItems(_ items: [DailyBulletItem]) -> [String] {
    items.compactMap { sanitizedBulletText($0.text) }
  }
  func sanitizedBlockers(_ text: String) -> [String] {
    let segments = text.split(whereSeparator: \.isNewline).map(String.init)
    if segments.isEmpty {
      return sanitizedBulletText(text).map { [$0] } ?? []
    }
    return segments.compactMap(sanitizedBulletText)
  }
  func sanitizedBulletText(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard
      trimmed.caseInsensitiveCompare(DailyStandupPlaceholder.notGeneratedMessage) != .orderedSame
    else {
      return nil
    }
    guard
      trimmed.caseInsensitiveCompare(DailyStandupPlaceholder.todayNotGeneratedMessage)
        != .orderedSame
    else {
      return nil
    }
    guard
      trimmed.caseInsensitiveCompare(DailyStandupPlaceholder.insufficientHistoryMessage)
        != .orderedSame
    else {
      return nil
    }
    guard
      trimmed.caseInsensitiveCompare(DailyStandupPlaceholder.noProviderSelectedMessage)
        != .orderedSame
    else {
      return nil
    }
    return trimmed
  }
  func refreshStandupDraftIfNeeded(
    storageDayString: String,
    sourceDay: DailyStandupDayInfo?
  ) {
    let fallbackSourceDayString = sourceDay?.dayString
    let isSameDraftDay = loadedStandupDraftDay == storageDayString
    let isSameFallbackSourceDay = loadedStandupFallbackSourceDay == fallbackSourceDayString
    let entry = StorageManager.shared.fetchDailyStandup(forDay: storageDayString)
    hasPersistedStandupEntry = entry != nil

    if dailyRecapProvider == .none, entry == nil {
      guard !isSameDraftDay || !isSameFallbackSourceDay || standupDraft != .noProviderSelected
      else {
        return
      }

      loadedStandupDraftDay = storageDayString
      loadedStandupFallbackSourceDay = fallbackSourceDayString
      standupDraft = .noProviderSelected
      return
    }

    if entry != nil {
      guard !isSameDraftDay else { return }
    } else {
      guard !isSameDraftDay || !isSameFallbackSourceDay else { return }
    }

    loadedStandupDraftDay = storageDayString
    loadedStandupFallbackSourceDay = fallbackSourceDayString

    guard let entry,
      let data = entry.payloadJSON.data(using: .utf8),
      var decoded = try? JSONDecoder().decode(DailyStandupDraft.self, from: data)
    else {
      standupDraft = placeholderStandupDraft(sourceDay: sourceDay)
      return
    }

    if decoded.generation == nil {
      decoded.generation = .legacyDayflow
    }
    standupDraft = decoded
  }
  func scheduleStandupDraftSave() {
    guard let dayString = loadedStandupDraftDay else { return }
    let draftToSave = standupDraft

    standupDraftSaveTask?.cancel()
    standupDraftSaveTask = Task.detached(priority: .utility) {
      try? await Task.sleep(nanoseconds: 250_000_000)
      guard !Task.isCancelled else { return }

      let existing = StorageManager.shared.fetchDailyStandup(forDay: dayString)
      let placeholderDrafts: [DailyStandupDraft] = [
        .default,
        .insufficientHistory,
      ]
      if draftToSave == .noProviderSelected {
        return
      }
      if existing == nil && placeholderDrafts.contains(draftToSave) {
        return
      }

      guard let data = try? JSONEncoder().encode(draftToSave),
        let json = String(data: data, encoding: .utf8)
      else {
        return
      }

      StorageManager.shared.saveDailyStandup(forDay: dayString, payloadJSON: json)
      await MainActor.run {
        if loadedStandupDraftDay == dayString {
          hasPersistedStandupEntry = true
        }
      }
    }
  }
  func placeholderStandupDraft(sourceDay: DailyStandupDayInfo?) -> DailyStandupDraft {
    if dailyRecapProvider == .none {
      return .noProviderSelected
    }

    if sourceDay == nil {
      return .insufficientHistory
    }

    return .default
  }
  var regenerateButtonLabel: String {
    switch standupRegenerateState {
    case .regenerating:
      return "Regenerating" + String(repeating: ".", count: standupRegeneratingDotsPhase)
    case .idle, .regenerated, .noData:
      return "Regenerate"
    }
  }
  var transientRegenerateButtonLabel: String? {
    switch standupRegenerateState {
    case .regenerated:
      return "Regenerated"
    case .noData:
      return "No data"
    case .idle, .regenerating:
      return nil
    }
  }
  func scheduleStandupRegenerateReset() {
    standupRegenerateResetTask?.cancel()
    standupRegenerateResetTask = Task {
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      guard !Task.isCancelled else { return }

      await MainActor.run {
        standupRegenerateState = .idle
        standupRegenerateResetTask = nil
      }
    }
  }
  func standupSectionTitles(for date: Date, sourceDay: DailyStandupDayInfo?)
    -> DailyStandupSectionTitles
  {
    let targetDay = workflowDayInfo(for: date)
    return DailyStandupSectionTitles(
      highlights: standupHighlightsTitle(for: sourceDay),
      tasks: standupTasksTitle(for: targetDay),
      blockers: "Blockers"
    )
  }
  func standupSectionHeading(for date: Date) -> String {
    "Standup for \(dailyDateTitle(for: date))"
  }
  func standupHighlightsTitle(for sourceDay: DailyStandupDayInfo?) -> String {
    guard let sourceDay else { return "Recent highlights" }

    let label = standupDayLabelText(for: sourceDay.startOfDay)
    if label == "Today" || label == "Yesterday" || label.hasPrefix("Last ") {
      return "\(label)'s highlights"
    }
    return "Highlights from \(label)"
  }
  func standupTasksTitle(for targetDay: DailyStandupDayInfo) -> String {
    let label = standupDayLabelText(for: targetDay.startOfDay)
    if label == "Today" || label == "Yesterday" {
      return "\(label)'s tasks"
    }
    return "Tasks for \(label)"
  }
  func standupDayLabelText(for date: Date) -> String {
    let calendar = Calendar.current
    let displayDate = normalizedTimelineDate(date)
    let timelineToday = timelineDisplayDate(from: Date())

    if calendar.isDate(displayDate, inSameDayAs: timelineToday) {
      return "Today"
    }

    guard let timelineYesterday = calendar.date(byAdding: .day, value: -1, to: timelineToday)
    else {
      return dailyOtherDayDisplayFormatter.string(from: displayDate)
    }

    if calendar.isDate(displayDate, inSameDayAs: timelineYesterday) {
      return "Yesterday"
    }

    let daysAgo = calendar.dateComponents([.day], from: displayDate, to: timelineToday).day ?? 99
    if (2...6).contains(daysAgo) {
      return "Last \(dailyStandupWeekdayFormatter.string(from: displayDate))"
    }

    return dailyOtherDayDisplayFormatter.string(from: displayDate)
  }
}
