//
//  TestConnectionView.swift
//  Dayflow
//
//  Test connection button for Gemini API
//

import SwiftUI

struct TestConnectionView: View {
  let apiKeyOverride: String?
  let model: GeminiModel
  let onTestComplete: ((Bool) -> Void)?
  /// Checks the key on its own shortly after one is pasted, and again whenever it changes.
  let checksAutomatically: Bool

  @State private var isTesting = false
  @State private var testResult: TestResult?

  init(
    apiKey: String? = nil,
    model: GeminiModel,
    onTestComplete: ((Bool) -> Void)? = nil,
    checksAutomatically: Bool = false
  ) {
    self.apiKeyOverride = apiKey
    self.model = model
    self.onTestComplete = onTestComplete
    self.checksAutomatically = checksAutomatically
  }

  enum TestResult {
    case success(String)
    case failure(String)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SettingsPrimaryButton(
        title: isTesting ? String(localized: "Testing…") : String(localized: "Test connection"),
        systemImage: "bolt.fill",
        isLoading: isTesting,
        action: { Task { await testConnection(source: "button") } }
      )

      if let result = testResult {
        SettingsStatusDot(
          state: result.isSuccess ? .good : .bad,
          label: result.message
        )
      }
    }
    .task(id: automaticCheckID) {
      guard checksAutomatically else { return }
      guard keyToTest != nil else {
        testResult = nil
        isTesting = false
        return
      }
      // Wait for the paste or typing to settle, so one key gets one check.
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled else { return }
      await testConnection(source: "automatic")
    }
  }

  private var automaticCheckID: String {
    "\(apiKeyOverride ?? "")|\(model.rawValue)"
  }

  /// The pasted key, or the saved one when nothing is pasted. nil when there's neither, or the
  /// pasted text is too short to be a key.
  private var keyToTest: String? {
    let override =
      apiKeyOverride?
      .components(separatedBy: .whitespacesAndNewlines).joined() ?? ""
    if !override.isEmpty { return override.count > 20 ? override : nil }
    let storedKey =
      KeychainManager.shared.retrieve(for: "gemini")?
      .components(separatedBy: .whitespacesAndNewlines).joined() ?? ""
    return storedKey.isEmpty ? nil : storedKey
  }

  /// When an automatic check is cancelled because the key changed, its result is dropped: it
  /// belongs to the old key.
  @MainActor
  private func testConnection(source: String) async {
    guard !isTesting || source == "automatic" else { return }

    let override =
      apiKeyOverride?
      .components(separatedBy: .whitespacesAndNewlines).joined() ?? ""
    let storedKey =
      KeychainManager.shared.retrieve(for: "gemini")?
      .components(separatedBy: .whitespacesAndNewlines).joined() ?? ""
    let apiKey = override.isEmpty ? storedKey : override
    guard !apiKey.isEmpty else {
      testResult = .failure(String(localized: "No API key found. Enter your API key first."))
      onTestComplete?(false)
      AnalyticsService.shared.capture(
        "connection_test_failed", ["provider": "gemini", "error_code": "no_api_key"])
      return
    }

    isTesting = true
    testResult = nil
    AnalyticsService.shared.capture(
      "connection_test_started",
      ["provider": "gemini", "model": model.rawValue, "source": source]
    )

    do {
      let result = try await GeminiAPIHelper.shared.testConnection(
        apiKey: apiKey,
        preference: GeminiModelPreference(primary: model)
      )
      if Task.isCancelled {
        isTesting = false
        return
      }
      testResult = .success(String(localized: "Your API key works."))
      isTesting = false
      onTestComplete?(true)
      AnalyticsService.shared.capture(
        "connection_test_succeeded",
        ["provider": "gemini", "model": result.model.rawValue]
      )
    } catch GeminiAPIHelper.APIError.rateLimited(_, let attemptedModel) {
      if Task.isCancelled {
        isTesting = false
        return
      }
      testResult = .success(
        String(localized: "API key works, but Gemini is rate limited right now."))
      isTesting = false
      onTestComplete?(true)
      AnalyticsService.shared.capture(
        "connection_test_succeeded",
        [
          "provider": "gemini",
          "status": "rate_limited",
          "model": attemptedModel.rawValue,
        ])
    } catch {
      if Task.isCancelled {
        isTesting = false
        return
      }
      testResult = .failure(error.localizedDescription)
      isTesting = false
      onTestComplete?(false)
      AnalyticsService.shared.capture(
        "connection_test_failed",
        ["provider": "gemini", "error_code": String((error as NSError).code)])
    }
  }
}

extension TestConnectionView.TestResult {
  var isSuccess: Bool {
    switch self {
    case .success: return true
    case .failure: return false
    }
  }

  var message: String {
    switch self {
    case .success(let msg): return msg
    case .failure(let msg): return msg
    }
  }
}
