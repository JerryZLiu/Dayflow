import Combine
import CoreGraphics
import Foundation

/// The masker the screen recorder runs on each captured frame. It sits outside the main actor behind a lock,
/// because the recorder reads it from its own capture tasks; `PrivacyShield` is the only writer.
final class PrivacyShieldMaskerBox: @unchecked Sendable {
  static let shared = PrivacyShieldMaskerBox()

  private let lock = NSLock()
  private var masker: PrivacyShieldFrameMasker?

  /// The masker to run on a captured frame, or nil when the shield shouldn't touch frames right now.
  func current() -> PrivacyShieldFrameMasker? {
    lock.lock()
    defer { lock.unlock() }
    return masker
  }

  func set(_ newValue: PrivacyShieldFrameMasker?) {
    lock.lock()
    masker = newValue
    lock.unlock()
  }
}

/// The Privacy Shield feature: the user's on/off switch, the Pro/Plus gate, getting the model onto this Mac,
/// and handing the screen recorder a masker while it's on.
///
/// It masks while the switch is on, the account has an active Dayflow Pro or Plus plan, and the model is
/// loaded. At launch the account takes a few seconds to load (or fails to, offline), so until it does the
/// last plan seen on this Mac counts, and an installed model starts masking right away.
@MainActor
final class PrivacyShield: ObservableObject {
  static let shared = PrivacyShield()

  enum Status: Equatable {
    case off
    case preparing
    case on
    case failed
  }

  private static let enabledKey = "privacyShieldEnabled"
  private static let calloutDismissedKey = "privacyShieldCalloutDismissed"
  private static let lastKnownEntitledKey = "privacyShieldLastKnownEntitled"

  @Published private(set) var isEnabled: Bool
  @Published private(set) var status: Status = .off
  @Published private(set) var calloutDismissed: Bool
  /// Shows the upgrade modal over the main window.
  @Published var showUpgrade = false

  private var accountObserver: AnyCancellable?
  private var prepareTask: Task<Void, Never>?
  /// Identifies the current prepare, so a cancelled one never clears or overrides a newer one.
  private var prepareID = UUID()

  private init() {
    isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    calloutDismissed = UserDefaults.standard.bool(forKey: Self.calloutDismissedKey)
  }

  /// An active Dayflow Pro or Plus plan on the loaded account.
  var isEntitled: Bool {
    let entitlement = DayflowAuthManager.shared.entitlements
    return entitlement.status == "active"
      && (entitlement.plan == "pro" || entitlement.plan == "plus")
  }

  /// Whether to mask right now. Before a saved login's account has loaded, the plan last seen on this Mac counts,
  /// so frames aren't stored unmasked at every launch or while the backend is unreachable.
  private var effectivelyEntitled: Bool {
    let auth = DayflowAuthManager.shared
    if auth.user != nil {
      return isEntitled
    }
    if auth.hasUnrestoredSession {
      return UserDefaults.standard.bool(forKey: Self.lastKnownEntitledKey)
    }
    return false
  }

  /// What the footer switch shows: on whenever the shield is on or getting ready, never just because it was asked for.
  var showsOn: Bool {
    isEnabled && status != .off
  }

  /// Call once at launch. Turns the shield on or off as the account and its plan load and change.
  func start() {
    guard accountObserver == nil else { return }
    let auth = DayflowAuthManager.shared
    accountObserver = auth.$user.combineLatest(auth.$entitlements)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] user, _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          if user != nil {
            UserDefaults.standard.set(self.isEntitled, forKey: Self.lastKnownEntitledKey)
          }
          self.refresh()
        }
      }
  }

  /// The footer toggle. Without Pro or Plus it opens the upgrade modal instead of turning on.
  func toggleTapped() {
    dismissCallout()
    if showsOn {
      setEnabled(false)
    } else if effectivelyEntitled {
      setEnabled(true)
    } else {
      showUpgrade = true
      AnalyticsService.shared.capture("privacy_shield_upgrade_shown", ["source": "toggle"])
    }
  }

  func setEnabled(_ enabled: Bool) {
    isEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
    AnalyticsService.shared.capture("privacy_shield_toggled", ["enabled": enabled])
    refresh()
  }

  func dismissCallout() {
    guard !calloutDismissed else { return }
    calloutDismissed = true
    UserDefaults.standard.set(true, forKey: Self.calloutDismissedKey)
  }

  /// Brings the masker in line with the switch and the plan.
  private func refresh() {
    guard isEnabled && effectivelyEntitled else {
      cancelPrepare()
      PrivacyShieldMaskerBox.shared.set(nil)
      status = .off
      return
    }
    guard PrivacyShieldMaskerBox.shared.current() == nil, prepareTask == nil else { return }
    status = .preparing
    let id = UUID()
    prepareID = id
    prepareTask = Task { [weak self] in
      await self?.prepare(id: id)
    }
  }

  private func cancelPrepare() {
    prepareTask?.cancel()
    prepareTask = nil
    prepareID = UUID()
  }

  /// Loads the installed model, downloading it first when this Mac doesn't have the backend's current version.
  /// A model that is installed but won't load is deleted and downloaded once more.
  private func prepare(id: UUID) async {
    let started = Date()
    do {
      var masker: PrivacyShieldFrameMasker?
      for attempt in 0..<2 where masker == nil {
        let version = try await installCurrentVersion(started: started)
        do {
          masker = try await Task.detached(priority: .utility) {
            let loaded = try PrivacyShieldModelStore.loadMasker(version: version)
            loaded.warmUp()
            return loaded
          }.value
        } catch {
          // A damaged install (or one that no longer loads after an OS update): start over once.
          PrivacyShieldModelStore.removeAll()
          if attempt == 1 { throw error }
        }
        try Task.checkCancellation()
      }
      guard id == prepareID, isEnabled, effectivelyEntitled, let masker else { return }
      PrivacyShieldMaskerBox.shared.set(masker)
      status = .on
      prepareTask = nil
    } catch {
      // Turned off or lost the plan mid-download: refresh() already set the status.
      guard id == prepareID, !(error is CancellationError), !Task.isCancelled else { return }
      prepareTask = nil
      status = .failed
      // Domain and code only: a URLError's description carries the signed download link.
      let nsError = error as NSError
      AnalyticsService.shared.capture(
        "privacy_shield_prepare_failed",
        [
          "error_type": String(describing: type(of: error)), "error_domain": nsError.domain,
          "error_code": nsError.code,
        ])
    }
  }

  /// The installed version after making sure it's the backend's current one. Offline, or before the account
  /// has loaded, an installed model is used as is.
  private func installCurrentVersion(started: Date) async throws -> String {
    let installed = PrivacyShieldModelStore.installedVersion()
    do {
      let download = try await DayflowAuthManager.shared.privacyModelDownload()
      guard download.version != installed else { return download.version }
      let version = try await PrivacyShieldModelStore.install(download)
      AnalyticsService.shared.capture(
        "privacy_shield_model_downloaded",
        ["version": download.version, "seconds": Int(Date().timeIntervalSince(started))])
      return version
    } catch {
      if error is CancellationError || Task.isCancelled { throw CancellationError() }
      guard let installed else { throw error }
      return installed
    }
  }
}
