//
//  GeminiDirectProvider.swift
//  Dayflow
//

import Foundation

/// Remembers, for the life of the app, which Gemini models recently refused a request for
/// quota or capacity, so the next call starts on a model that is likely to answer.
/// Without it every call walked the chain from the top and paid for the same refusals again.
final class GeminiModelCooldowns: @unchecked Sendable {
  static let shared = GeminiModelCooldowns()

  private let lock = NSLock()
  // Keyed by API key and model, because quota belongs to the key.
  private var coolingUntil: [String: Date] = [:]

  /// How long to skip a model after this refusal, or nil when the status is not a refusal.
  static func cooldown(forStatus status: Int, responseBody: String) -> TimeInterval? {
    switch status {
    case 429:
      // A used-up daily quota does not come back in minutes; Gemini names it in the body.
      let body = responseBody.lowercased()
      let isDailyQuota =
        body.contains("perday") || body.contains("per day") || body.contains("daily")
      return isDailyQuota ? 60 * 60 : 10 * 60
    case 503:
      return 10 * 60
    case 403, 404:
      // The model is not available to this key.
      return 60 * 60
    default:
      return nil
    }
  }

  func mark(
    _ model: GeminiModel, apiKey: String, for duration: TimeInterval, now: Date = Date()
  ) {
    lock.lock()
    defer { lock.unlock() }
    coolingUntil[apiKey + "|" + model.rawValue] = now.addingTimeInterval(duration)
  }

  func isCoolingDown(_ model: GeminiModel, apiKey: String, now: Date = Date()) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard let until = coolingUntil[apiKey + "|" + model.rawValue] else { return false }
    return until > now
  }

  /// The models worth trying, in their original order. When every model is cooling down the
  /// whole list comes back, so a call never ends up with nothing to try.
  func usable(_ models: [GeminiModel], apiKey: String, now: Date = Date()) -> [GeminiModel] {
    let ready = models.filter { !isCoolingDown($0, apiKey: apiKey, now: now) }
    return ready.isEmpty ? models : ready
  }
}

final class GeminiDirectProvider {
  let apiKey: String
  let fileEndpoint = "https://generativelanguage.googleapis.com/upload/v1beta/files"
  let modelPreference: GeminiModelPreference

  static let capacityErrorCodes: Set<Int> = [403, 404, 429, 503]

  struct ModelRunState {
    let models: [GeminiModel]
    private(set) var index: Int = 0

    init(models: [GeminiModel]) {
      self.models = models.isEmpty ? GeminiModelPreference.default.orderedModels : models
    }

    var current: GeminiModel {
      models[min(index, models.count - 1)]
    }

    mutating func advance() -> (from: GeminiModel, to: GeminiModel)? {
      guard index < models.count - 1 else { return nil }
      let fromModel = models[index]
      index += 1
      return (fromModel, models[index])
    }
  }

  /// The fallback chain without the models that recently refused this key.
  var modelsToTry: [GeminiModel] {
    GeminiModelCooldowns.shared.usable(modelPreference.orderedModels, apiKey: apiKey)
  }

  /// Call when a request to `model` comes back with an HTTP error.
  func noteModelRefused(_ model: GeminiModel, status: Int, body: Data) {
    let bodyText = String(data: body, encoding: .utf8) ?? ""
    guard
      let duration = GeminiModelCooldowns.cooldown(forStatus: status, responseBody: bodyText)
    else { return }
    GeminiModelCooldowns.shared.mark(model, apiKey: apiKey, for: duration)
  }

  func endpointForModel(_ model: GeminiModel) -> String {
    return
      "https://generativelanguage.googleapis.com/v1beta/models/\(model.rawValue):generateContent"
  }

  init(apiKey: String, preference: GeminiModelPreference = .default) {
    self.apiKey = apiKey.components(separatedBy: .whitespacesAndNewlines).joined()
    self.modelPreference = preference
  }
}
