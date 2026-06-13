import AppKit
import Foundation
import Security

struct DayflowAuthUser: Codable, Equatable {
  let id: String
  let email: String
}

struct DayflowEntitlement: Codable, Equatable {
  let plan: String
  let status: String
  let source: String?
  let currentPeriodEnd: String?
  let stripeCustomerId: String?
  let stripeSubscriptionId: String?

  static let free = DayflowEntitlement(
    plan: "free",
    status: "inactive",
    source: nil,
    currentPeriodEnd: nil,
    stripeCustomerId: nil,
    stripeSubscriptionId: nil
  )

  var displayName: String {
    plan == "pro" && status == "active" ? "Dayflow Pro" : "Free"
  }

  private enum CodingKeys: String, CodingKey {
    case plan
    case status
    case source
    case currentPeriodEnd = "current_period_end"
    case stripeCustomerId = "stripe_customer_id"
    case stripeSubscriptionId = "stripe_subscription_id"
  }
}

struct DayflowReferralInvite: Codable, Identifiable, Equatable {
  let id: String
  let email: String
  let status: String
  let usageHours: Double
  let createdAt: String
  let claimedAt: String?
  let unlockedAt: String?

  private enum CodingKeys: String, CodingKey {
    case id
    case email
    case status
    case usageHours = "usage_hours"
    case createdAt = "created_at"
    case claimedAt = "claimed_at"
    case unlockedAt = "unlocked_at"
  }
}

struct DayflowReferralReward: Codable, Identifiable, Equatable {
  let id: String
  let rewardType: String
  let days: Int
  let status: String
  let startsAt: String?
  let expiresAt: String?
  let stripeTrialEndAt: String?
  let createdAt: String
  let appliedAt: String?

  private enum CodingKeys: String, CodingKey {
    case id
    case rewardType = "reward_type"
    case days
    case status
    case startsAt = "starts_at"
    case expiresAt = "expires_at"
    case stripeTrialEndAt = "stripe_trial_end_at"
    case createdAt = "created_at"
    case appliedAt = "applied_at"
  }
}

struct DayflowReferralSummary: Codable, Equatable {
  let code: String
  let inviteURL: String
  let rewardDays: Int
  let pendingInvites: Int
  let earnedInvites: Int
  let unlockHoursRequired: Int
  let invites: [DayflowReferralInvite]
  let rewards: [DayflowReferralReward]

  private enum CodingKeys: String, CodingKey {
    case code
    case inviteURL = "invite_url"
    case rewardDays = "reward_days"
    case pendingInvites = "pending_invites"
    case earnedInvites = "earned_invites"
    case unlockHoursRequired = "unlock_hours_required"
    case invites
    case rewards
  }
}

enum DayflowBillingInterval: String, CaseIterable, Identifiable, Codable {
  case monthly
  case yearly

  var id: String { rawValue }
}

struct DayflowAuthActionResult: Equatable {
  let succeeded: Bool
  let endpoint: String?
  let httpStatus: Int?
  let errorType: String?
  let backendDetailBucket: String?

  var analyticsProps: [String: Any] {
    var props: [String: Any] = [
      "outcome": succeeded ? "success" : "failure"
    ]
    if let endpoint {
      props["endpoint"] = endpoint
    }
    if let httpStatus {
      props["http_status"] = httpStatus
    }
    if let errorType {
      props["error_type"] = errorType
    }
    if let backendDetailBucket {
      props["backend_detail_bucket"] = backendDetailBucket
    }
    return props
  }

  static func success(endpoint: String) -> DayflowAuthActionResult {
    DayflowAuthActionResult(
      succeeded: true,
      endpoint: endpoint,
      httpStatus: nil,
      errorType: nil,
      backendDetailBucket: nil
    )
  }

  static func localFailure(
    errorType: String,
    endpoint: String? = nil
  ) -> DayflowAuthActionResult {
    DayflowAuthActionResult(
      succeeded: false,
      endpoint: endpoint,
      httpStatus: nil,
      errorType: errorType,
      backendDetailBucket: nil
    )
  }

  static func failure(
    _ error: Error,
    endpoint fallbackEndpoint: String? = nil
  ) -> DayflowAuthActionResult {
    DayflowAuthActionResult(
      succeeded: false,
      endpoint: endpoint(from: error) ?? fallbackEndpoint,
      httpStatus: httpStatus(from: error),
      errorType: errorType(from: error),
      backendDetailBucket: backendDetailBucket(from: error)
    )
  }

  private static func endpoint(from error: Error) -> String? {
    switch error {
    case DayflowAuthError.backend(_, _, let path):
      return path
    case DayflowAuthError.nonHTTP(let path):
      return path
    default:
      return nil
    }
  }

  private static func httpStatus(from error: Error) -> Int? {
    guard case DayflowAuthError.backend(let statusCode, _, _) = error else { return nil }
    return statusCode
  }

  private static func errorType(from error: Error) -> String {
    if let urlError = error as? URLError {
      return urlError.code == .timedOut ? "timeout" : "network_error"
    }

    guard let authError = error as? DayflowAuthError else {
      return "unknown_error"
    }

    switch authError {
    case .backend(let statusCode, _, _):
      switch statusCode {
      case 400:
        return "bad_request"
      case 401, 403:
        return "unauthorized"
      case 404:
        return "endpoint_not_found"
      case 409:
        return "conflict"
      case 500...599:
        return "server_error"
      default:
        return "http_error"
      }
    case .busy:
      return "request_in_progress"
    case .message:
      return "client_error"
    case .nonHTTP:
      return "non_http_response"
    case .unauthorized:
      return "unauthorized"
    }
  }

  private static func backendDetailBucket(from error: Error) -> String? {
    guard case DayflowAuthError.backend(_, let detail, _) = error,
      let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines),
      !detail.isEmpty
    else {
      return nil
    }

    switch detail.lowercased() {
    case "not found":
      return "not_found"
    case "referral code not found":
      return "referral_code_not_found"
    case "you cannot use your own referral code":
      return "own_referral_code"
    case "this account has already used a referral code":
      return "referral_already_used"
    case "this account has already used its free trial":
      return "trial_already_used"
    default:
      return "other_backend_error"
    }
  }
}

@MainActor
final class DayflowAuthManager: ObservableObject {
  static let shared = DayflowAuthManager()

  nonisolated private static let sessionService = "com.teleportlabs.dayflow.auth"
  nonisolated private static let sessionAccount = "session_token"
  private static let rememberedEmailKey = "dayflowAccountEmail"
  private static let pendingReferralCodeKey = "dayflowPendingReferralCode"

  @Published private(set) var user: DayflowAuthUser?
  @Published private(set) var entitlements = DayflowEntitlement.free
  @Published private(set) var pendingEmail: String?
  @Published private(set) var codeExpiresAt: Date?
  @Published private(set) var statusText = "Signed out"
  @Published private(set) var errorText: String?
  @Published private(set) var isBusy = false
  @Published private(set) var hasLoadedStoredSession = false
  @Published private(set) var referralSummary: DayflowReferralSummary?
  @Published private(set) var pendingReferralCode: String?

  private let endpoint: String?

  private init() {
    self.endpoint = DayflowBackendConfiguration.endpoint()
    self.pendingReferralCode = UserDefaults.standard.string(forKey: Self.pendingReferralCodeKey)
  }

  var isSignedIn: Bool {
    user != nil && retrieveSessionToken() != nil
  }

  var displayIdentity: String {
    user?.email
      ?? UserDefaults.standard.string(forKey: Self.rememberedEmailKey)
      ?? "Not signed in"
  }

  var signedInEmail: String? {
    user?.email ?? UserDefaults.standard.string(forKey: Self.rememberedEmailKey)
  }

  var canVerifyCode: Bool {
    pendingEmail != nil
  }

  func loadStoredSessionIfNeeded() {
    guard !hasLoadedStoredSession else { return }
    hasLoadedStoredSession = true

    guard retrieveSessionToken() != nil else {
      resetSignedOutState(status: "Signed out")
      return
    }

    Task { await refreshAccount() }
  }

  @discardableResult
  func sendCode(to emailAddress: String) async -> DayflowAuthActionResult {
    let endpoint = "/v1/auth/code/start"
    let email = normalizedEmail(emailAddress)
    guard isLikelyEmail(email) else {
      errorText = "Enter a valid email address."
      return .localFailure(errorType: "invalid_email", endpoint: endpoint)
    }

    let failure = await perform {
      let request = AuthStartRequest(email: email)
      var urlRequest = try makeRequest(path: endpoint, method: "POST")
      urlRequest.httpBody = try JSONEncoder().encode(request)

      let response: AuthStartResponse = try await send(urlRequest)
      pendingEmail = email
      codeExpiresAt = Date().addingTimeInterval(TimeInterval(response.expiresInSeconds))
      statusText = "Code sent to \(email)."
      errorText = nil
    }
    if let failure {
      return .failure(failure, endpoint: endpoint)
    }
    return .success(endpoint: endpoint)
  }

  @discardableResult
  func verifyCode(_ code: String, for emailAddress: String? = nil) async -> DayflowAuthActionResult
  {
    let endpoint = "/v1/auth/code/verify"
    let digits = code.filter(\.isNumber)
    guard digits.count == 6 else {
      errorText = "Enter the 6 digit code."
      return .localFailure(errorType: "invalid_code", endpoint: endpoint)
    }
    let explicitEmail = emailAddress.map(normalizedEmail)
    guard let email = explicitEmail ?? pendingEmail else {
      errorText = "Start with your email first."
      return .localFailure(errorType: "missing_email", endpoint: endpoint)
    }
    guard isLikelyEmail(email) else {
      errorText = "Enter a valid email address."
      return .localFailure(errorType: "invalid_email", endpoint: endpoint)
    }

    let failure = await perform {
      let request = AuthVerifyRequest(
        email: email,
        code: digits,
        deviceName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName
      )
      var urlRequest = try makeRequest(path: endpoint, method: "POST")
      urlRequest.httpBody = try JSONEncoder().encode(request)

      let response: AuthVerifyResponse = try await send(urlRequest)
      guard storeSessionToken(response.sessionToken) else {
        throw DayflowAuthError.message("Could not save your session to Keychain.")
      }

      user = response.user
      entitlements = response.entitlements
      pendingEmail = nil
      codeExpiresAt = nil
      statusText = "Signed in."
      errorText = nil
      UserDefaults.standard.set(response.user.email, forKey: Self.rememberedEmailKey)

      if let pendingReferralCode {
        do {
          let claim = try await sendReferralClaim(
            code: pendingReferralCode, token: response.sessionToken)
          entitlements = claim.entitlements
          referralSummary = claim.referral
          clearPendingReferralCode()
          statusText = claim.message
        } catch {
          referralSummary = try? await fetchReferralSummary(token: response.sessionToken)
          errorText = error.localizedDescription
          statusText = "Signed in. Referral code was not applied."
        }
      } else {
        referralSummary = try? await fetchReferralSummary(token: response.sessionToken)
      }
    }
    if let failure {
      return .failure(failure, endpoint: endpoint)
    }
    return .success(endpoint: endpoint)
  }

  func resendCode() async {
    guard let email = pendingEmail else { return }
    await sendCode(to: email)
  }

  func useDifferentEmail() {
    pendingEmail = nil
    codeExpiresAt = nil
    errorText = nil
    statusText = "Signed out"
  }

  func refreshAccount() async {
    guard let token = retrieveSessionToken() else {
      resetSignedOutState(status: "Signed out")
      return
    }

    await perform {
      var request = try makeRequest(path: "/v1/me", method: "GET")
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

      let response: MeResponse = try await send(request)
      user = response.user
      entitlements = response.entitlements
      referralSummary = try? await fetchReferralSummary(token: token)
      statusText = "Signed in."
      errorText = nil
      UserDefaults.standard.set(response.user.email, forKey: Self.rememberedEmailKey)
    } onAuthFailure: {
      self.deleteSessionToken()
      self.resetSignedOutState(status: "Session expired. Sign in again.")
    }
  }

  func openBillingCheckout(interval: DayflowBillingInterval = .monthly) async {
    guard let token = retrieveSessionToken() else {
      errorText = "Sign in first."
      return
    }

    await perform {
      var request = try makeRequest(path: "/v1/billing/checkout", method: "POST")
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      request.httpBody = try JSONEncoder().encode(BillingCheckoutRequest(interval: interval))

      let response: BillingCheckoutResponse = try await send(request)
      guard let url = URL(string: response.url) else {
        throw DayflowAuthError.message("Stripe returned an invalid checkout link.")
      }

      NSWorkspace.shared.open(url)
      statusText = "Opened Stripe checkout in your browser."
      errorText = nil
    }
  }

  @discardableResult
  func startNoCardTrial() async -> DayflowAuthActionResult {
    let endpoint = "/v1/billing/no-card-trial"
    guard let token = retrieveSessionToken() else {
      errorText = "Sign in first."
      return .localFailure(errorType: "not_signed_in", endpoint: endpoint)
    }

    let failure = await perform {
      var request = try makeRequest(path: endpoint, method: "POST")
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

      let response: BillingTrialResponse = try await send(request)
      entitlements = response.entitlements
      referralSummary = response.referral
      statusText = response.message
      errorText = nil
    } onAuthFailure: {
      self.deleteSessionToken()
      self.referralSummary = nil
      self.resetSignedOutState(status: "Session expired. Sign in again.")
    }
    if let failure {
      return .failure(failure, endpoint: endpoint)
    }
    return .success(endpoint: endpoint)
  }

  func openBillingPortal() async {
    guard let token = retrieveSessionToken() else {
      errorText = "Sign in first."
      return
    }

    await perform {
      var request = try makeRequest(path: "/v1/billing/portal", method: "POST")
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

      let response: BillingPortalResponse = try await send(request)
      guard let url = URL(string: response.url) else {
        throw DayflowAuthError.message("Stripe returned an invalid billing link.")
      }

      NSWorkspace.shared.open(url)
      statusText = "Opened Stripe billing in your browser."
      errorText = nil
    }
  }

  func signOut() async {
    let token = retrieveSessionToken()

    await perform {
      if let token {
        var request = try makeRequest(path: "/v1/auth/logout", method: "POST")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let _: LogoutResponse = try await send(request)
      }

      deleteSessionToken()
      referralSummary = nil
      resetSignedOutState(status: "Signed out.")
    } onAuthFailure: {
      self.deleteSessionToken()
      self.referralSummary = nil
      self.resetSignedOutState(status: "Signed out.")
    }
  }

  func setPendingReferralCode(_ code: String) {
    guard let normalized = normalizedReferralCode(code) else {
      errorText = "Enter a valid 6-character referral code."
      return
    }
    pendingReferralCode = normalized
    UserDefaults.standard.set(normalized, forKey: Self.pendingReferralCodeKey)
    statusText =
      isSignedIn ? "Referral code ready to claim." : "Referral code saved. Sign in to claim it."
  }

  func clearPendingReferralCode() {
    pendingReferralCode = nil
    UserDefaults.standard.removeObject(forKey: Self.pendingReferralCodeKey)
  }

  func refreshReferrals() async {
    guard let token = retrieveSessionToken() else {
      referralSummary = nil
      return
    }

    await perform {
      referralSummary = try await fetchReferralSummary(token: token)
    } onAuthFailure: {
      self.deleteSessionToken()
      self.referralSummary = nil
      self.resetSignedOutState(status: "Session expired. Sign in again.")
    }
  }

  @discardableResult
  func claimReferralCode(_ code: String) async -> DayflowAuthActionResult {
    let endpoint = "/v1/referrals/claim"
    guard let token = retrieveSessionToken() else {
      setPendingReferralCode(code)
      errorText = "Sign in to claim this referral code."
      return .localFailure(errorType: "not_signed_in", endpoint: endpoint)
    }
    guard let normalized = normalizedReferralCode(code) else {
      errorText = "Enter a valid 6-character referral code."
      return .localFailure(errorType: "invalid_referral_code", endpoint: endpoint)
    }

    let failure = await perform {
      let response = try await sendReferralClaim(code: normalized, token: token)
      entitlements = response.entitlements
      referralSummary = response.referral
      clearPendingReferralCode()
      statusText = response.message
      errorText = nil
    } onAuthFailure: {
      self.deleteSessionToken()
      self.referralSummary = nil
      self.resetSignedOutState(status: "Session expired. Sign in again.")
    }
    if let failure {
      return .failure(failure, endpoint: endpoint)
    }
    return .success(endpoint: endpoint)
  }

  func sendReferralInvite(to emailAddress: String) async {
    guard let token = retrieveSessionToken() else {
      errorText = "Sign in first."
      return
    }
    let email = normalizedEmail(emailAddress)
    guard isLikelyEmail(email) else {
      errorText = "Enter a valid email address."
      return
    }

    await perform {
      let request = ReferralInviteRequest(email: email)
      var urlRequest = try makeRequest(path: "/v1/referrals/invites", method: "POST")
      urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      urlRequest.httpBody = try JSONEncoder().encode(request)

      let _: ReferralInviteResponse = try await send(urlRequest)
      referralSummary = try await fetchReferralSummary(token: token)
      statusText = "Invite sent."
      errorText = nil
    } onAuthFailure: {
      self.deleteSessionToken()
      self.referralSummary = nil
      self.resetSignedOutState(status: "Session expired. Sign in again.")
    }
  }

  func reportReferralUsage(seconds: Int, idempotencyKey: String) async {
    guard seconds > 0, let token = retrieveSessionToken() else { return }

    do {
      let request = ReferralUsageRequest(seconds: seconds, idempotencyKey: idempotencyKey)
      var urlRequest = try makeRequest(path: "/v1/referrals/usage", method: "POST")
      urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      urlRequest.httpBody = try JSONEncoder().encode(request)

      let _: ReferralUsageResponse = try await send(urlRequest)
    } catch {
      print("Referral usage report failed: \(error.localizedDescription)")
    }
  }

  func sessionToken() -> String? {
    Self.storedSessionToken()
  }

  nonisolated static func storedSessionToken() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: sessionService,
      kSecAttrAccount as String: sessionAccount,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var item: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess else {
      logSessionTokenReadFailure(status: status)
      return nil
    }

    guard let data = item as? Data else {
      print(
        "❌ [DayflowAuthManager] Session token keychain item had unexpected type: \(type(of: item))"
      )
      return nil
    }

    guard let token = String(data: data, encoding: .utf8) else {
      print(
        "❌ [DayflowAuthManager] Session token keychain item could not be decoded as UTF-8"
      )
      return nil
    }

    return token
  }

  nonisolated private static func logSessionTokenReadFailure(status: OSStatus) {
    let reason: String
    switch status {
    case errSecItemNotFound:
      reason = "item not found"
    case errSecAuthFailed:
      reason = "authentication failed"
    case errSecInteractionNotAllowed:
      reason = "interaction not allowed"
    case errSecNotAvailable:
      reason = "keychain not available"
    case errSecParam:
      reason = "invalid keychain query"
    default:
      reason = "unexpected keychain status"
    }

    print(
      "❌ [DayflowAuthManager] Session token read failed: \(reason) (status=\(status))"
    )
  }

  @discardableResult
  private func perform(
    _ operation: () async throws -> Void,
    onAuthFailure: (() -> Void)? = nil
  ) async -> Error? {
    guard !isBusy else { return DayflowAuthError.busy }
    isBusy = true
    errorText = nil
    defer { isBusy = false }

    do {
      try await operation()
      return nil
    } catch DayflowAuthError.unauthorized {
      onAuthFailure?()
      if onAuthFailure == nil {
        errorText = "Your session could not be verified."
      }
      return DayflowAuthError.unauthorized
    } catch {
      errorText = error.localizedDescription
      if statusText.isEmpty {
        statusText = "Something went wrong."
      }
      return error
    }
  }

  private func resetSignedOutState(status: String) {
    user = nil
    entitlements = .free
    referralSummary = nil
    pendingEmail = nil
    codeExpiresAt = nil
    statusText = status
  }

  private func normalizedEmail(_ email: String) -> String {
    email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private func isLikelyEmail(_ email: String) -> Bool {
    email.contains("@") && email.contains(".") && !email.contains(" ")
  }

  private func normalizedReferralCode(_ code: String) -> String? {
    let allowed = CharacterSet.alphanumerics
    let normalized =
      code
      .uppercased()
      .unicodeScalars
      .filter { allowed.contains($0) }
      .map(String.init)
      .joined()

    return normalized.count == 6 ? normalized : nil
  }

  private func fetchReferralSummary(token: String) async throws -> DayflowReferralSummary {
    var request = try makeRequest(path: "/v1/referrals/me", method: "GET")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    return try await send(request)
  }

  private func sendReferralClaim(code: String, token: String) async throws -> ReferralClaimResponse
  {
    let request = ReferralClaimRequest(code: code)
    var urlRequest = try makeRequest(path: "/v1/referrals/claim", method: "POST")
    urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    urlRequest.httpBody = try JSONEncoder().encode(request)
    return try await send(urlRequest)
  }

  private func makeRequest(path: String, method: String) throws -> URLRequest {
    guard let endpoint else {
      throw DayflowAuthError.message("Invalid Dayflow backend URL.")
    }

    guard let url = URL(string: "\(endpoint)\(path)") else {
      throw DayflowAuthError.message("Invalid Dayflow backend URL.")
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 20
    return request
  }

  private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
    let (data, response) = try await URLSession.shared.data(for: request)
    let path = request.url?.path
    guard let httpResponse = response as? HTTPURLResponse else {
      throw DayflowAuthError.nonHTTP(path: path)
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
        throw DayflowAuthError.unauthorized
      }

      if let error = try? JSONDecoder().decode(BackendErrorResponse.self, from: data),
        let detail = error.detail,
        !detail.isEmpty
      {
        throw DayflowAuthError.backend(
          statusCode: httpResponse.statusCode,
          detail: detail,
          path: path
        )
      }

      throw DayflowAuthError.backend(
        statusCode: httpResponse.statusCode,
        detail: nil,
        path: path
      )
    }

    return try JSONDecoder().decode(Response.self, from: data)
  }

  private func storeSessionToken(_ token: String) -> Bool {
    guard let data = token.data(using: .utf8) else { return false }
    deleteSessionToken()

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.sessionService,
      kSecAttrAccount as String: Self.sessionAccount,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecValueData as String: data,
    ]
    return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
  }

  private func retrieveSessionToken() -> String? {
    Self.storedSessionToken()
  }

  private func deleteSessionToken() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.sessionService,
      kSecAttrAccount as String: Self.sessionAccount,
    ]
    SecItemDelete(query as CFDictionary)
  }
}

private struct AuthStartRequest: Codable {
  let email: String
}

private struct AuthStartResponse: Codable {
  let ok: Bool
  let expiresInSeconds: Int

  private enum CodingKeys: String, CodingKey {
    case ok
    case expiresInSeconds = "expires_in_seconds"
  }
}

private struct AuthVerifyRequest: Codable {
  let email: String
  let code: String
  let deviceName: String

  private enum CodingKeys: String, CodingKey {
    case email
    case code
    case deviceName = "device_name"
  }
}

private struct AuthVerifyResponse: Codable {
  let sessionToken: String
  let user: DayflowAuthUser
  let entitlements: DayflowEntitlement

  private enum CodingKeys: String, CodingKey {
    case sessionToken = "session_token"
    case user
    case entitlements
  }
}

private struct MeResponse: Codable {
  let user: DayflowAuthUser
  let entitlements: DayflowEntitlement
}

private struct LogoutResponse: Codable {
  let ok: Bool
}

private struct BillingCheckoutResponse: Codable {
  let url: String
}

private struct BillingTrialResponse: Codable {
  let ok: Bool
  let message: String
  let entitlements: DayflowEntitlement
  let referral: DayflowReferralSummary?
}

private struct BillingCheckoutRequest: Codable {
  let interval: DayflowBillingInterval
}

private struct BillingPortalResponse: Codable {
  let url: String
}

private struct ReferralClaimRequest: Codable {
  let code: String
}

private struct ReferralClaimResponse: Codable {
  let ok: Bool
  let message: String
  let entitlements: DayflowEntitlement
  let referral: DayflowReferralSummary?
}

private struct ReferralInviteRequest: Codable {
  let email: String
}

private struct ReferralInviteResponse: Codable {
  let ok: Bool
  let invite: DayflowReferralInvite
}

private struct ReferralUsageRequest: Codable {
  let seconds: Int
  let idempotencyKey: String

  private enum CodingKeys: String, CodingKey {
    case seconds
    case idempotencyKey = "idempotency_key"
  }
}

private struct ReferralUsageResponse: Codable {
  let ok: Bool
  let usageHours: Double
  let unlocked: Bool

  private enum CodingKeys: String, CodingKey {
    case ok
    case usageHours = "usage_hours"
    case unlocked
  }
}

private struct BackendErrorResponse: Codable {
  let detail: String?
}

private enum DayflowAuthError: LocalizedError {
  case backend(statusCode: Int, detail: String?, path: String?)
  case busy
  case message(String)
  case nonHTTP(path: String?)
  case unauthorized

  var errorDescription: String? {
    switch self {
    case .backend(let statusCode, let detail, _):
      if let detail, !detail.isEmpty {
        return detail
      }
      return "Dayflow sign-in failed (\(statusCode))."
    case .busy:
      return "Another Dayflow account request is already running."
    case .message(let message):
      return message
    case .nonHTTP:
      return "Dayflow returned a non-HTTP response."
    case .unauthorized:
      return "Your session could not be verified."
    }
  }
}
