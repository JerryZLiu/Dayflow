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

enum DayflowBillingInterval: String, CaseIterable, Identifiable, Codable {
  case monthly
  case yearly

  var id: String { rawValue }
}

@MainActor
final class DayflowAuthManager: ObservableObject {
  static let shared = DayflowAuthManager()

  nonisolated private static let sessionService = "com.teleportlabs.dayflow.auth"
  nonisolated private static let sessionAccount = "session_token"
  private static let rememberedEmailKey = "dayflowAccountEmail"
  private static let defaultEndpoint = "https://web-production-f3361.up.railway.app"

  @Published private(set) var user: DayflowAuthUser?
  @Published private(set) var entitlements = DayflowEntitlement.free
  @Published private(set) var pendingEmail: String?
  @Published private(set) var codeExpiresAt: Date?
  @Published private(set) var statusText = "Signed out"
  @Published private(set) var errorText: String?
  @Published private(set) var isBusy = false
  @Published private(set) var hasLoadedStoredSession = false

  private let endpoint: String

  private init() {
    self.endpoint = Self.defaultEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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

  func sendCode(to emailAddress: String) async {
    let email = normalizedEmail(emailAddress)
    guard isLikelyEmail(email) else {
      errorText = "Enter a valid email address."
      return
    }

    await perform {
      let request = AuthStartRequest(email: email)
      var urlRequest = try makeRequest(path: "/v1/auth/code/start", method: "POST")
      urlRequest.httpBody = try JSONEncoder().encode(request)

      let response: AuthStartResponse = try await send(urlRequest)
      pendingEmail = email
      codeExpiresAt = Date().addingTimeInterval(TimeInterval(response.expiresInSeconds))
      statusText = "Code sent to \(email)."
      errorText = nil
    }
  }

  func verifyCode(_ code: String, for emailAddress: String? = nil) async {
    let digits = code.filter(\.isNumber)
    guard digits.count == 6 else {
      errorText = "Enter the 6 digit code."
      return
    }
    let explicitEmail = emailAddress.map(normalizedEmail)
    guard let email = explicitEmail ?? pendingEmail else {
      errorText = "Start with your email first."
      return
    }
    guard isLikelyEmail(email) else {
      errorText = "Enter a valid email address."
      return
    }

    await perform {
      let request = AuthVerifyRequest(
        email: email,
        code: digits,
        deviceName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName
      )
      var urlRequest = try makeRequest(path: "/v1/auth/code/verify", method: "POST")
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
    }
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
      resetSignedOutState(status: "Signed out.")
    } onAuthFailure: {
      self.deleteSessionToken()
      self.resetSignedOutState(status: "Signed out.")
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

  private func perform(
    _ operation: () async throws -> Void,
    onAuthFailure: (() -> Void)? = nil
  ) async {
    guard !isBusy else { return }
    isBusy = true
    errorText = nil
    defer { isBusy = false }

    do {
      try await operation()
    } catch DayflowAuthError.unauthorized {
      onAuthFailure?()
      if onAuthFailure == nil {
        errorText = "Your session could not be verified."
      }
    } catch {
      errorText = error.localizedDescription
      if statusText.isEmpty {
        statusText = "Something went wrong."
      }
    }
  }

  private func resetSignedOutState(status: String) {
    user = nil
    entitlements = .free
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

  private func makeRequest(path: String, method: String) throws -> URLRequest {
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
    guard let httpResponse = response as? HTTPURLResponse else {
      throw DayflowAuthError.message("Dayflow returned a non-HTTP response.")
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
        throw DayflowAuthError.unauthorized
      }

      if let error = try? JSONDecoder().decode(BackendErrorResponse.self, from: data),
        let detail = error.detail,
        !detail.isEmpty
      {
        throw DayflowAuthError.message(detail)
      }

      throw DayflowAuthError.message("Dayflow sign-in failed (\(httpResponse.statusCode)).")
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

private struct BillingCheckoutRequest: Codable {
  let interval: DayflowBillingInterval
}

private struct BillingPortalResponse: Codable {
  let url: String
}

private struct BackendErrorResponse: Codable {
  let detail: String?
}

private enum DayflowAuthError: LocalizedError {
  case message(String)
  case unauthorized

  var errorDescription: String? {
    switch self {
    case .message(let message):
      return message
    case .unauthorized:
      return "Your session could not be verified."
    }
  }
}
