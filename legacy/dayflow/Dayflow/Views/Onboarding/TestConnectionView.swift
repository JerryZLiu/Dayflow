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

  @State private var isTesting = false
  @State private var testResult: TestResult?

  init(
    apiKey: String? = nil,
    model: GeminiModel,
    onTestComplete: ((Bool) -> Void)? = nil
  ) {
    self.apiKeyOverride = apiKey
    self.model = model
    self.onTestComplete = onTestComplete
  }

  enum TestResult {
    case success(String)
    case failure(String)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SettingsPrimaryButton(
        title: isTesting ? "Testing…" : "Test connection",
        systemImage: "bolt.fill",
        isLoading: isTesting,
        action: testConnection
      )

      if let result = testResult {
        SettingsStatusDot(
          state: result.isSuccess ? .good : .bad,
          label: result.message
        )
      }
    }
  }

  private func testConnection() {
    guard !isTesting else { return }

    let override =
      apiKeyOverride?
      .components(separatedBy: .whitespacesAndNewlines).joined() ?? ""
    let storedKey =
      KeychainManager.shared.retrieve(for: "gemini")?
      .components(separatedBy: .whitespacesAndNewlines).joined() ?? ""
    let apiKey = override.isEmpty ? storedKey : override
    guard !apiKey.isEmpty else {
      testResult = .failure("No API key found. Enter your API key first.")
      onTestComplete?(false)
      AnalyticsService.shared.capture(
        "connection_test_failed", ["provider": "gemini", "error_code": "no_api_key"])
      return
    }

    isTesting = true
    testResult = nil
    AnalyticsService.shared.capture(
      "connection_test_started",
      ["provider": "gemini", "model": model.rawValue]
    )

    Task {
      do {
        let result = try await GeminiAPIHelper.shared.testConnection(
          apiKey: apiKey,
          preference: GeminiModelPreference(primary: model)
        )
        await MainActor.run {
          testResult = .success("Connection successful.")
          isTesting = false
          onTestComplete?(true)
        }
        AnalyticsService.shared.capture(
          "connection_test_succeeded",
          ["provider": "gemini", "model": result.model.rawValue]
        )
      } catch GeminiAPIHelper.APIError.rateLimited(_, let attemptedModel) {
        await MainActor.run {
          testResult = .success("API key works, but Gemini is rate limited right now.")
          isTesting = false
          onTestComplete?(true)
        }
        AnalyticsService.shared.capture(
          "connection_test_succeeded",
          [
            "provider": "gemini",
            "status": "rate_limited",
            "model": attemptedModel.rawValue,
          ])
      } catch {
        await MainActor.run {
          testResult = .failure(error.localizedDescription)
          isTesting = false
          onTestComplete?(false)
        }
        AnalyticsService.shared.capture(
          "connection_test_failed",
          ["provider": "gemini", "error_code": String((error as NSError).code)])
      }
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
