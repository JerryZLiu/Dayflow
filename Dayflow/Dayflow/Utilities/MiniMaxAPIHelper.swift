//
//  MiniMaxAPIHelper.swift
//  Dayflow
//
//  Small utilities specific to the MiniMax provider.
//

import Foundation

enum MiniMaxAPIHelper {
  /// Returns true if the user has supplied a non-empty MiniMax API key in the Keychain.
  static var hasAPIKey: Bool {
    guard let key = KeychainManager.shared.retrieve(for: MiniMaxProvider.keychainKey) else {
      return false
    }
    return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Persist (or remove) the API key in the Keychain.
  /// Pass `nil` or an empty string to remove the key.
  static func setAPIKey(_ key: String?) {
    let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if trimmed.isEmpty {
      KeychainManager.shared.delete(for: MiniMaxProvider.keychainKey)
    } else {
      KeychainManager.shared.store(trimmed, for: MiniMaxProvider.keychainKey)
    }
  }

  /// Quick connectivity smoke-test that sends a minimal chat-completion request.
  /// Throws on non-200 responses or transport errors.
  static func smokeTest(model: String = MiniMaxProvider.defaultModelId) async throws -> String {
    guard let key = KeychainManager.shared.retrieve(for: MiniMaxProvider.keychainKey),
      !key.isEmpty
    else {
      throw NSError(
        domain: "MiniMaxAPIHelper", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "MiniMax API key is not configured"])
    }

    guard let url = LocalEndpointUtilities.chatCompletionsURL(
      baseURL: MiniMaxProvider.defaultEndpoint)
    else {
      throw NSError(
        domain: "MiniMaxAPIHelper", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Invalid MiniMax endpoint URL"])
    }

    struct Req: Codable {
      let model: String
      let messages: [Msg]
      let max_tokens: Int
      let temperature: Double
    }
    struct Msg: Codable {
      let role: String
      let content: String
    }
    struct Resp: Codable {
      let choices: [Choice]
    }
    struct Choice: Codable {
      let message: ChoiceMessage
    }
    struct ChoiceMessage: Codable {
      let content: String
    }

    let body = Req(
      model: model,
      messages: [Msg(role: "user", content: "ping")],
      max_tokens: 16,
      temperature: 0
    )

    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    req.httpBody = try JSONEncoder().encode(body)
    req.timeoutInterval = 30

    let (data, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      let body = String(data: data, encoding: .utf8) ?? "Unknown error"
      throw NSError(
        domain: "MiniMaxAPIHelper", code: (response as? HTTPURLResponse)?.statusCode ?? 3,
        userInfo: [NSLocalizedDescriptionKey: "MiniMax API error: \(body)"])
    }
    let decoded = try JSONDecoder().decode(Resp.self, from: data)
    let raw = decoded.choices.first?.message.content ?? ""
    return MiniMaxReasoning.stripThinkTags(in: raw)
  }
}
