//
//  SurveyCenter.swift
//  Dayflow
//
//  Decides when to show an in-app survey and records every step.
//
//  The queue comes from the backend. Everything about who qualifies is decided
//  here on the device, from local data: the survey's audience and AI provider,
//  one survey every few days at most (unless it's marked "ask now"), and never
//  twice for someone who already answered or dismissed it.
//
//  Surveys work with analytics turned off. For those people only the things
//  they actively do (answering, dismissing) are sent, with no usage details.
//

import Foundation

@MainActor
final class SurveyCenter: ObservableObject {
  static let shared = SurveyCenter()

  /// The survey on screen, if any.
  @Published private(set) var activeSurvey: Survey?

  private static let finishedSurveyIdsKey = "surveyFinishedIds"
  private static let eligibleReportedIdsKey = "surveyEligibleReportedIds"
  private static let lastShownAtKey = "surveyLastShownAt"
  private static let shownAskNowIdsKey = "surveyShownAskNowIds"

  /// Ask-now surveys should reach people soon, so the queue is refetched this often.
  private static let queueRefreshInterval: TimeInterval = 15 * 60
  /// Keeps a survey and the GitHub star card off the same day.
  static let otherPromptGap: TimeInterval = 20 * 60 * 60
  /// The Sept 7 2026 redesign, for the "used Dayflow before the redesign" audience.
  private static let redesignDate = Date(timeIntervalSince1970: 1_788_739_200)

  private let reporter = SurveyEventReporter.shared
  private var cachedQueue: SurveyQueue?
  private var cachedQueueAt: Date?
  private var isChecking = false
  /// From the last check, so recording an event doesn't hit the database.
  private var lastActivity: SurveyActivitySummary?

  var isShowingSurvey: Bool { activeSurvey != nil }

  static var lastShownAt: Date? {
    UserDefaults.standard.object(forKey: lastShownAtKey) as? Date
  }

  // MARK: - Showing a survey

  /// Shows the next survey this person qualifies for, if any.
  /// `canShow` is checked again after the network call, since something else
  /// (What's New, the star card) may have appeared in the meantime.
  func checkForSurvey(source: String, canShow: @escaping () -> Bool) {
    guard activeSurvey == nil, !isChecking, canShow() else { return }
    guard StorageManager.shared.hasAnyTimelineCards() else { return }

    isChecking = true
    Task {
      defer { isChecking = false }
      await reporter.flush()

      guard let queue = await loadQueue() else { return }
      let activity = await Task.detached(priority: .utility) {
        StorageManager.shared.surveyActivitySummary()
      }.value
      lastActivity = activity

      let candidates = queue.surveys.filter { survey in
        survey.isSupported
          && !finishedSurveyIds.contains(survey.id)
          && qualifies(for: survey, activity: activity, protectionDays: queue.newUserProtectionDays)
      }
      reportEligibility(for: candidates)

      guard
        let survey = candidates.first(where: { isDue($0, pacingDays: queue.pacingDays) }),
        activeSurvey == nil,
        canShow()
      else { return }

      present(survey, source: source)
    }
  }

  private func present(_ survey: Survey, source: String) {
    UserDefaults.standard.set(Date(), forKey: Self.lastShownAtKey)
    if survey.askNow {
      var shownAskNow = Set(UserDefaults.standard.stringArray(forKey: Self.shownAskNowIdsKey) ?? [])
      shownAskNow.insert(survey.id)
      UserDefaults.standard.set(Array(shownAskNow), forKey: Self.shownAskNowIdsKey)
    }
    activeSurvey = survey
    record(.shown, survey: survey, context: ["source": .string(source)])
    AnalyticsService.shared.capture(
      "survey_shown",
      ["survey_id": survey.id, "source": source, "ask_now": survey.askNow])
  }

  /// One survey every `pacingDays`, and not on the same day as the star card.
  /// "Ask now" surveys skip both waits the first time they're shown; if the
  /// person ignores it (say, quits with the card open), normal pacing applies.
  private func isDue(_ survey: Survey, pacingDays: Int) -> Bool {
    let shownAskNow = Set(UserDefaults.standard.stringArray(forKey: Self.shownAskNowIdsKey) ?? [])
    if survey.askNow && !shownAskNow.contains(survey.id) { return true }
    let now = Date()
    if let lastShown = Self.lastShownAt,
      now.timeIntervalSince(lastShown) < TimeInterval(pacingDays) * 24 * 60 * 60
    {
      return false
    }
    if let starShown = GitHubStarPromptState.lastShownAt,
      now.timeIntervalSince(starShown) < Self.otherPromptGap
    {
      return false
    }
    return true
  }

  // MARK: - Answers

  func recordAnswer(_ answer: SurveyAnswer, to question: SurveyQuestion, in survey: Survey) {
    record(.answered, survey: survey, questionId: question.id, answer: answer.jsonValue)
    var props = answer.analyticsProperties
    props["survey_id"] = survey.id
    props["question_id"] = question.id
    AnalyticsService.shared.capture("survey_question_answered", props)
  }

  /// All questions answered (or the optional follow-up skipped).
  func recordCompleted(_ survey: Survey) {
    markFinished(survey)
    record(.completed, survey: survey)
    AnalyticsService.shared.capture("survey_completed", ["survey_id": survey.id])
  }

  /// Called once the card's thank-you has been on screen long enough.
  func close() {
    activeSurvey = nil
  }

  /// The person closed the card. `question` is the one they were looking at.
  func dismiss(_ survey: Survey, on question: SurveyQuestion) {
    markFinished(survey)
    record(.dismissed, survey: survey, questionId: question.id)
    AnalyticsService.shared.capture(
      "survey_dismissed", ["survey_id": survey.id, "question_id": question.id])
    activeSurvey = nil
  }

  // MARK: - Who qualifies

  private func qualifies(
    for survey: Survey, activity: SurveyActivitySummary, protectionDays: Int
  ) -> Bool {
    guard survey.provider == "any" || survey.provider == currentProviderId else { return false }
    guard let firstCard = activity.firstCardStart else { return false }
    let daysUsing = Date().timeIntervalSince(firstCard) / (24 * 60 * 60)

    switch survey.audience {
    case "everyone":
      return daysUsing >= Double(protectionDays)
    case "new_users":
      return daysUsing < 7
    case "regulars":
      return daysUsing >= 14 && activity.activeDaysLastWeek >= 2
    case "gone_quiet":
      return activity.activeDaysTotal >= 5 && activity.activeDaysLastWeek <= 1
    case "pre_redesign":
      return firstCard < Self.redesignDate
    default:
      // An audience added on the backend after this app version shipped.
      return false
    }
  }

  private var currentProviderId: String? {
    (try? LLMProviderRoutingStore.load())?.primary.rawValue
  }

  /// "Eligible" is passive tracking, so it's only sent with analytics on,
  /// and only once per survey per device.
  private func reportEligibility(for surveys: [Survey]) {
    guard AnalyticsService.shared.isOptedIn else { return }
    var reported = Set(UserDefaults.standard.stringArray(forKey: Self.eligibleReportedIdsKey) ?? [])
    for survey in surveys where !reported.contains(survey.id) {
      reported.insert(survey.id)
      record(.eligible, survey: survey)
      AnalyticsService.shared.capture("survey_eligible", ["survey_id": survey.id])
    }
    UserDefaults.standard.set(Array(reported), forKey: Self.eligibleReportedIdsKey)
  }

  private var finishedSurveyIds: Set<String> {
    Set(UserDefaults.standard.stringArray(forKey: Self.finishedSurveyIdsKey) ?? [])
  }

  private func markFinished(_ survey: Survey) {
    var finished = finishedSurveyIds
    finished.insert(survey.id)
    UserDefaults.standard.set(Array(finished), forKey: Self.finishedSurveyIdsKey)
  }

  // MARK: - Backend

  private func loadQueue() async -> SurveyQueue? {
    if let cachedQueue, let cachedQueueAt,
      Date().timeIntervalSince(cachedQueueAt) < Self.queueRefreshInterval
    {
      return cachedQueue
    }
    guard let url = SurveyBackend.url(path: "/v1/surveys/live") else { return nil }

    do {
      var request = URLRequest(url: url)
      request.timeoutInterval = 15
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        throw URLError(.badServerResponse)
      }
      let queue = try SurveyBackend.decoder.decode(SurveyQueue.self, from: data)
      cachedQueue = queue
      cachedQueueAt = Date()
      return queue
    } catch {
      AnalyticsService.shared.capture(
        "survey_fetch_failed", ["error": String(describing: type(of: error))])
      return cachedQueue
    }
  }

  // MARK: - Events

  private enum Step: String {
    case eligible, shown, answered, completed, dismissed
  }

  private func record(
    _ step: Step,
    survey: Survey,
    questionId: String? = nil,
    answer: SurveyJSONValue? = nil,
    context extra: [String: SurveyJSONValue] = [:]
  ) {
    reporter.record(
      SurveyEvent(
        clientEventId: UUID().uuidString.lowercased(),
        surveyId: survey.id,
        event: step.rawValue,
        questionId: questionId,
        answer: answer,
        context: eventContext().merging(extra) { current, _ in current },
        occurredAt: Date()
      ))
  }

  /// Who answered, in broad strokes. Empty apart from the opt-out flag for
  /// people who turned analytics off.
  private func eventContext() -> [String: SurveyJSONValue] {
    guard AnalyticsService.shared.isOptedIn else {
      return ["analytics_enabled": .bool(false)]
    }

    var context: [String: SurveyJSONValue] = ["analytics_enabled": .bool(true)]
    if let provider = currentProviderId {
      context["provider"] = .string(provider)
    }
    if let role = UserDefaults.standard.string(
      forKey: CategoryStore.StoreKeys.onboardingSelectedRole)
    {
      context["role"] = .string(role)
    }
    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
      context["app_version"] = .string(version)
    }
    if let firstCard = lastActivity?.firstCardStart {
      let weeks = Int(Date().timeIntervalSince(firstCard) / (7 * 24 * 60 * 60))
      context["weeks_using"] = .int(weeks)
    }
    return context
  }
}
