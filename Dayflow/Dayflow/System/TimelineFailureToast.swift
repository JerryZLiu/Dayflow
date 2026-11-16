import Foundation

struct TimelineFailureToastPayload {
  let message: String
  let title: String?
  /// Provider the card is about, used to pick its logo.
  let providerName: String
  /// Plain-language fix steps; `command` is shown under the first one.
  let steps: [String]
  let command: String?
  /// How much recorded time is currently waiting to be turned into cards.
  let waitingSeconds: Int
  let destination: TimelineFailureToastDestination
  let failureKind: String
  let operation: String
  let primaryProvider: String
  let primaryProviderLabel: String
  let backupProvider: String?
  let backupProviderLabel: String?
  let backupConfigured: Bool
  let rateLimitDetected: Bool
  let errorDomain: String
  let errorCode: Int
  let batchId: Int64?
  /// Raw `LLMProviderID` Dayflow can sign back in to with its own button, when that is the fix.
  let signInProvider: String?
  /// Raw `LLMProviderID` of another tool on this Mac that is ready to be the backup provider.
  let backupOfferProvider: String?

  var signInProviderID: LLMProviderID? { signInProvider.flatMap(LLMProviderID.init(rawValue:)) }
  var backupOfferProviderID: LLMProviderID? {
    backupOfferProvider.flatMap(LLMProviderID.init(rawValue:))
  }

  /// "25 min", "3 hrs", "1 day". Nil when nothing is waiting.
  var waitingText: String? {
    let minutes = waitingSeconds / 60
    guard minutes > 0 else { return nil }
    if minutes < 60 {
      return String(localized: "\(minutes) min")
    }
    let hours = minutes / 60
    if hours < 24 {
      return hours == 1 ? String(localized: "1 hr") : String(localized: "\(hours) hrs")
    }
    return String(localized: "1 day")
  }

  var notificationUserInfo: [String: Any] {
    var userInfo: [String: Any] = [
      "message": message,
      "provider_name": providerName,
      "steps": steps,
      "waiting_seconds": waitingSeconds,
      "destination": destination.rawValue,
      "failure_kind": failureKind,
      "operation": operation,
      "primary_provider": primaryProvider,
      "primary_provider_label": primaryProviderLabel,
      "backup_configured": backupConfigured,
      "rate_limit_detected": rateLimitDetected,
      "error_domain": errorDomain,
      "error_code": errorCode,
    ]
    if let title {
      userInfo["title"] = title
    }
    if let command {
      userInfo["command"] = command
    }
    if let backupProvider {
      userInfo["backup_provider"] = backupProvider
    }
    if let backupProviderLabel {
      userInfo["backup_provider_label"] = backupProviderLabel
    }
    if let batchId {
      userInfo["batch_id"] = batchId
    }
    if let signInProvider {
      userInfo["sign_in_provider"] = signInProvider
    }
    if let backupOfferProvider {
      userInfo["backup_offer_provider"] = backupOfferProvider
    }
    return userInfo
  }

  var analyticsProps: [String: Any] {
    notificationUserInfo
  }

  init(
    message: String,
    title: String?,
    providerName: String,
    steps: [String],
    command: String?,
    waitingSeconds: Int,
    destination: TimelineFailureToastDestination,
    failureKind: String,
    operation: String,
    primaryProvider: String,
    primaryProviderLabel: String,
    backupProvider: String?,
    backupProviderLabel: String?,
    backupConfigured: Bool,
    rateLimitDetected: Bool,
    errorDomain: String,
    errorCode: Int,
    batchId: Int64?,
    signInProvider: String? = nil,
    backupOfferProvider: String? = nil
  ) {
    self.message = message
    self.title = title
    self.providerName = providerName
    self.steps = steps
    self.command = command
    self.waitingSeconds = waitingSeconds
    self.destination = destination
    self.failureKind = failureKind
    self.operation = operation
    self.primaryProvider = primaryProvider
    self.primaryProviderLabel = primaryProviderLabel
    self.backupProvider = backupProvider
    self.backupProviderLabel = backupProviderLabel
    self.backupConfigured = backupConfigured
    self.rateLimitDetected = rateLimitDetected
    self.errorDomain = errorDomain
    self.errorCode = errorCode
    self.batchId = batchId
    self.signInProvider = signInProvider
    self.backupOfferProvider = backupOfferProvider
  }

  init?(userInfo: [AnyHashable: Any]) {
    guard let message = userInfo["message"] as? String,
      let operation = userInfo["operation"] as? String,
      let primaryProvider = userInfo["primary_provider"] as? String,
      let backupConfigured = userInfo["backup_configured"] as? Bool,
      let rateLimitDetected = userInfo["rate_limit_detected"] as? Bool,
      let errorDomain = userInfo["error_domain"] as? String
    else {
      return nil
    }

    let title = userInfo["title"] as? String
    let providerName = userInfo["provider_name"] as? String ?? ""
    let steps = userInfo["steps"] as? [String] ?? []
    let command = userInfo["command"] as? String
    let waitingSeconds = (userInfo["waiting_seconds"] as? NSNumber)?.intValue ?? 0
    let destination =
      (userInfo["destination"] as? String)
      .flatMap(TimelineFailureToastDestination.init(rawValue:)) ?? .providers
    let failureKind = userInfo["failure_kind"] as? String ?? TimelineFailureKind.unknown.rawValue
    let primaryProviderLabel = (userInfo["primary_provider_label"] as? String) ?? primaryProvider
    let backupProvider = userInfo["backup_provider"] as? String
    let backupProviderLabel = userInfo["backup_provider_label"] as? String

    let errorCode: Int
    if let code = userInfo["error_code"] as? Int {
      errorCode = code
    } else if let number = userInfo["error_code"] as? NSNumber {
      errorCode = number.intValue
    } else {
      errorCode = 0
    }

    let batchId: Int64?
    if let id = userInfo["batch_id"] as? Int64 {
      batchId = id
    } else if let id = userInfo["batch_id"] as? Int {
      batchId = Int64(id)
    } else if let number = userInfo["batch_id"] as? NSNumber {
      batchId = number.int64Value
    } else {
      batchId = nil
    }

    self.init(
      message: message,
      title: title,
      providerName: providerName,
      steps: steps,
      command: command,
      waitingSeconds: waitingSeconds,
      destination: destination,
      failureKind: failureKind,
      operation: operation,
      primaryProvider: primaryProvider,
      primaryProviderLabel: primaryProviderLabel,
      backupProvider: backupProvider,
      backupProviderLabel: backupProviderLabel,
      backupConfigured: backupConfigured,
      rateLimitDetected: rateLimitDetected,
      errorDomain: errorDomain,
      errorCode: errorCode,
      batchId: batchId,
      signInProvider: userInfo["sign_in_provider"] as? String,
      backupOfferProvider: userInfo["backup_offer_provider"] as? String
    )
  }
}

enum TimelineFailureToastCenter {
  /// Reports a problem the user has to fix. Safe to call for every failed or waiting batch:
  /// the card, the Mac notification and the menu bar warning each decide how often to show.
  static func post(_ payload: TimelineFailureToastPayload) {
    Task { @MainActor in
      ProviderProblemCenter.shared.report(payload)
    }
  }

  /// A batch just succeeded, so whatever the card asked the user to fix is fixed.
  static func hide() {
    Task { @MainActor in
      ProviderProblemCenter.shared.resolve()
    }
  }
}

private let cardLastShownDayByKindKey = "timelineFailureToastLastShownDayByKind"
private let backupOfferDeclinedKey = "providerBackupOfferDeclined"

/// The provider problem that currently needs the user, if any. The card in the main window,
/// the Mac notification, the menu bar warning and the timeline's sign-in button all read it.
@MainActor
final class ProviderProblemCenter: ObservableObject {
  static let shared = ProviderProblemCenter()

  @Published private(set) var problem: TimelineFailureToastPayload?

  /// Set when the user asked to see the card, so a main window that is still opening shows it.
  private var cardWasRequested = false

  func report(_ payload: TimelineFailureToastPayload) {
    if problem == nil { ProviderSignIn.shared.clearFailure() }
    problem = payload
    NotificationService.shared.notifyProviderProblem(payload)
    NotificationCenter.default.post(
      name: .showTimelineFailureToast, object: nil, userInfo: payload.notificationUserInfo)
  }

  func resolve() {
    guard problem != nil else { return }
    problem = nil
    cardWasRequested = false
    ProviderSignIn.shared.cancel()
    NotificationService.shared.clearProviderProblemNotification()
    NotificationCenter.default.post(name: .hideTimelineFailureToast, object: nil)
  }

  /// Brings the card back in the main window even if it was already shown or dismissed today,
  /// because the user asked for it from the menu bar or a notification.
  func showCardAgain() {
    guard let problem else { return }
    cardWasRequested = true
    var userInfo = problem.notificationUserInfo
    userInfo["force"] = true
    NotificationCenter.default.post(
      name: .showTimelineFailureToast, object: nil, userInfo: userInfo)
  }

  /// True once after the user asked to see the card.
  func takeCardRequest() -> Bool {
    defer { cardWasRequested = false }
    return cardWasRequested
  }

  /// The card interrupts once a day per kind of problem. The slot is only used up when the
  /// card is actually put on screen, so a closed window doesn't count as having shown it.
  func claimDailyCardSlot(failureKind: String, now: Date = Date()) -> Bool {
    let logicalDay = now.getDayInfoFor4AMBoundary().dayString
    let defaults = UserDefaults.standard
    var lastShownDayByKind =
      defaults.dictionary(forKey: cardLastShownDayByKindKey) as? [String: String] ?? [:]
    guard lastShownDayByKind[failureKind] != logicalDay else { return false }
    lastShownDayByKind[failureKind] = logicalDay
    defaults.set(lastShownDayByKind, forKey: cardLastShownDayByKindKey)
    return true
  }

  // MARK: Backup offer

  nonisolated static var backupOfferWasDeclined: Bool {
    UserDefaults.standard.bool(forKey: backupOfferDeclinedKey)
  }

  func declineBackupOffer() {
    UserDefaults.standard.set(true, forKey: backupOfferDeclinedKey)
  }

  /// Makes `provider` the backup, then retries what is waiting. Returns false if saving failed.
  func acceptBackupOffer(_ provider: LLMProviderID) -> Bool {
    do {
      let routing = try LLMProviderRoutingStore.load()
      guard routing.primary != provider else { return false }
      try LLMProviderRoutingStore.save(
        LLMProviderRouting(primary: routing.primary, secondary: provider))
      try LLMProviderSetupPreferences.markComplete(provider, in: .standard)
      AnalyticsService.shared.capture(
        "provider_backup_updated",
        [
          "backup_provider": provider.rawValue,
          "provider_id": provider.rawValue,
          "primary_provider": routing.primary.rawValue,
          "source": "failure_card_offer",
        ])
    } catch {
      print("[ProviderProblemCenter] Could not save backup provider: \(error)")
      return false
    }
    // The backup takes over from here, so nothing is waiting on the user any more.
    ProviderHoldStore.shared.clear(provider)
    resolve()
    AnalysisManager.shared.catchUpFailedBatches(reason: "backup_offer_accepted")
    return true
  }
}
