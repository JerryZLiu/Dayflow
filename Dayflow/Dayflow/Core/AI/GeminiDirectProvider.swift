//
//  GeminiDirectProvider.swift
//  Dayflow
//

import Foundation

final class GeminiDirectProvider {
  let apiKey: String
  let fileEndpoint = "https://generativelanguage.googleapis.com/upload/v1beta/files"
  let modelPreference: GeminiModelPreference

  static let capacityErrorCodes: Set<Int> = [403, 429, 503]

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

  func endpointForModel(_ model: GeminiModel) -> String {
    return
      "https://generativelanguage.googleapis.com/v1beta/models/\(model.rawValue):generateContent"
  }

  init(apiKey: String, preference: GeminiModelPreference = .default) {
    self.apiKey = apiKey
    self.modelPreference = preference
  }
}
