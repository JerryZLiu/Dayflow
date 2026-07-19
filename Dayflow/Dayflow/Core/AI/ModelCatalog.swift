//
//  ModelCatalog.swift
//  Dayflow
//
//  Centralized model catalog for all LLM providers. Lets the user pick from
//  models fetched live from the provider's API where possible, falling back
//  to a curated static list where the provider doesn't expose a list endpoint.
//
//  Each provider has a `fetchModels()` implementation. Results are cached in
//  UserDefaults with a TTL so we don't hammer the API on every app launch.
//

import AppKit
import Foundation

// MARK: - Model option

struct LLMModelOption: Codable, Identifiable, Hashable {
  let id: String
  let displayName: String
  let family: String
  let contextWindow: Int?
  let visionCapable: Bool
  let isDeprecated: Bool
  let isRecommended: Bool
  let notes: String?
}

extension LLMModelOption {
  static func curated(
    _ id: String,
    displayName: String? = nil,
    family: String = "",
    contextWindow: Int? = nil,
    visionCapable: Bool = false,
    isDeprecated: Bool = false,
    isRecommended: Bool = false,
    notes: String? = nil
  ) -> LLMModelOption {
    LLMModelOption(
      id: id,
      displayName: displayName ?? id,
      family: family,
      contextWindow: contextWindow,
      visionCapable: visionCapable,
      isDeprecated: isDeprecated,
      isRecommended: isRecommended,
      notes: notes
    )
  }
}

// MARK: - Cached list

struct ModelListSnapshot: Codable {
  let providerID: String
  let models: [LLMModelOption]
  let fetchedAt: Date
  let source: Source
  let fetchError: String?

  enum Source: String, Codable {
    case live  // came from the provider API
    case curated  // from the in-app fallback list
  }

  var isStale: Bool {
    Date().timeIntervalSince(fetchedAt) > 24 * 60 * 60
  }
}

// MARK: - Catalog

actor ModelCatalog {
  static let shared = ModelCatalog()

  private let cacheKey = "llmModelCatalogCache.v1"
  private let ttl: TimeInterval = 24 * 60 * 60  // 24h

  private var cache: [String: ModelListSnapshot] = [:]
  private var inFlight: [String: Task<ModelListSnapshot, Error>] = [:]

  init() {
    if let data = UserDefaults.standard.data(forKey: cacheKey),
      let decoded = try? JSONDecoder().decode([String: ModelListSnapshot].self, from: data)
    {
      cache = decoded
    }
  }

  // MARK: Public read

  func cachedList(for providerID: String) -> ModelListSnapshot? {
    cache[providerID]
  }

  /// Returns the cached list immediately (possibly stale) and then triggers a
  /// background refresh. The UI binds to the returned snapshot and re-renders
  /// when the refresh finishes.
  func snapshot(for providerID: String) -> ModelListSnapshot? {
    cache[providerID]
  }

  // MARK: Public refresh

  /// Force a fresh fetch from the provider. Falls back to the curated list
  /// when the network call fails.
  func refresh(for providerID: String) async throws -> ModelListSnapshot {
    if let inflight = inFlight[providerID] {
      return try await inflight.value
    }
    let task = Task<ModelListSnapshot, Error> { [weak self] in
      guard let self else { throw CancellationError() }
      return try await self.performFetch(for: providerID)
    }
    inFlight[providerID] = task
    defer { inFlight[providerID] = nil }
    let snapshot = try await task.value
    cache[providerID] = snapshot
    persistCache()
    return snapshot
  }

  /// Used when the user picks a model that isn't in the current snapshot —
  /// e.g. a custom model ID or one that was just removed from the API.
  func ensureModelExists(_ modelID: String, in providerID: String) {
    guard var snapshot = cache[providerID] else { return }
    if snapshot.models.contains(where: { $0.id == modelID }) { return }
    let custom = LLMModelOption.curated(
      modelID, displayName: "\(modelID) (custom)", isRecommended: false)
    snapshot = ModelListSnapshot(
      providerID: providerID,
      models: [custom] + snapshot.models,
      fetchedAt: snapshot.fetchedAt,
      source: snapshot.source,
      fetchError: snapshot.fetchError
    )
    cache[providerID] = snapshot
    persistCache()
  }

  // MARK: Internals

  private func performFetch(for providerID: String) async throws -> ModelListSnapshot {
    do {
      let models: [LLMModelOption]
      switch providerID {
      case "gemini":
        models = try await fetchGeminiModels()
      case "minimax":
        models = try await fetchMiniMaxModels()
      case "ollama":
        models = try await fetchOllamaModels()
      case "codex":
        models = curatedCodexModels
      case "claude":
        models = curatedClaudeModels
      default:
        models = []
      }
      return ModelListSnapshot(
        providerID: providerID,
        models: models,
        fetchedAt: Date(),
        source: .live,
        fetchError: nil
      )
    } catch {
      let fallback = ModelListSnapshot(
        providerID: providerID,
        models: curatedFallback(for: providerID),
        fetchedAt: Date(),
        source: .curated,
        fetchError: error.localizedDescription
      )
      return fallback
    }
  }

  private func persistCache() {
    if let data = try? JSONEncoder().encode(cache) {
      UserDefaults.standard.set(data, forKey: cacheKey)
    }
  }

  // MARK: Per-provider live fetchers

  private func fetchGeminiModels() async throws -> [LLMModelOption] {
    guard let apiKey = KeychainManager.shared.retrieve(for: "gemini"),
      !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw NSError(
        domain: "ModelCatalog", code: 401,
        userInfo: [NSLocalizedDescriptionKey: "Gemini API key is not configured"])
    }
    var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")
    components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
    guard let url = components?.url else {
      throw NSError(
        domain: "ModelCatalog", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Invalid Gemini models URL"])
    }

    struct Resp: Codable {
      let models: [Model]
      struct Model: Codable {
        let name: String
        let displayName: String?
        let inputTokenLimit: Int?
        let outputTokenLimit: Int?
        let supportedGenerationMethods: [String]?

        enum CodingKeys: String, CodingKey {
          case name
          case displayName = "displayName"
          case inputTokenLimit = "inputTokenLimit"
          case outputTokenLimit = "outputTokenLimit"
          case supportedGenerationMethods = "supportedGenerationMethods"
        }
      }
    }

    let (data, response) = try await URLSession.shared.data(from: url)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      let body = String(data: data, encoding: .utf8) ?? "Unknown error"
      throw NSError(
        domain: "ModelCatalog", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Gemini models endpoint error: \(body)"])
    }
    let decoded = try JSONDecoder().decode(Resp.self, from: data)
    return decoded.models.compactMap { m in
      let family = m.name.split(separator: "-").first.map(String.init) ?? ""
      let vision = m.supportedGenerationMethods?.contains("generateContent") == true
      let deprecated = m.name.contains("1.0") || m.name.contains("1.5")
      return LLMModelOption.curated(
        m.name,
        displayName: m.displayName ?? m.name,
        family: family,
        contextWindow: m.inputTokenLimit,
        visionCapable: vision,
        isDeprecated: deprecated,
        isRecommended: m.name.contains("2.5") || m.name.contains("2.0-flash"),
        notes: nil
      )
    }
  }

  private func fetchMiniMaxModels() async throws -> [LLMModelOption] {
    guard let url = URL(string: "https://api.minimax.io/v1/models") else {
      throw NSError(
        domain: "ModelCatalog", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Invalid MiniMax models URL"])
    }
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.timeoutInterval = 30
    if let key = KeychainManager.shared.retrieve(for: MiniMaxProvider.keychainKey),
      !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
    struct Resp: Codable {
      let data: [Model]
      struct Model: Codable {
        let id: String
      }
    }
    let (data, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      let body = String(data: data, encoding: .utf8) ?? "Unknown error"
      throw NSError(
        domain: "ModelCatalog", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "MiniMax models endpoint error: \(body)"])
    }
    let decoded = try JSONDecoder().decode(Resp.self, from: data)
    return decoded.data.map { m in
      let family: String
      if m.id.lowercased().contains("m3") { family = "M3" }
      else if m.id.lowercased().contains("m2") { family = "M2" }
      else { family = "M-series" }
      return LLMModelOption.curated(
        m.id, family: family, visionCapable: true,
        isRecommended: m.id == "MiniMax-M3",
        notes: m.id == "MiniMax-M3" ? "Default. 1M-token context, multimodal." : nil
      )
    }
  }

  private func fetchOllamaModels() async throws -> [LLMModelOption] {
    let baseURL = UserDefaults.standard.string(forKey: "llmLocalBaseURL") ?? "http://localhost:11434"
    let engine = UserDefaults.standard.string(forKey: "llmLocalEngine") ?? "ollama"
    let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let urlString: String
    if engine == "lmstudio" {
      urlString = "\(trimmedBase)/v1/models"
    } else {
      urlString = "\(trimmedBase)/api/tags"
    }
    guard let url = URL(string: urlString) else {
      throw NSError(
        domain: "ModelCatalog", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Invalid local models URL"])
    }
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.timeoutInterval = 15
    if engine == "lmstudio" {
      req.setValue("Bearer lm-studio", forHTTPHeaderField: "Authorization")
    }

    struct OllamaResp: Codable {
      let models: [OllamaModel]
      struct OllamaModel: Codable {
        let name: String
        let size: Int64?
        let details: Details?
        struct Details: Codable {
          let family: String?
          let parameter_size: String?
        }
      }
    }
    struct LMSResp: Codable {
      let data: [LMModel]
      struct LMModel: Codable {
        let id: String
      }
    }
    let (data, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      let body = String(data: data, encoding: .utf8) ?? "Unknown error"
      throw NSError(
        domain: "ModelCatalog", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Local models endpoint error: \(body)"])
    }
    if engine == "lmstudio" {
      let decoded = try JSONDecoder().decode(LMSResp.self, from: data)
      return decoded.data.map { m in
        LLMModelOption.curated(
          m.id, family: "Local",
          visionCapable: isLikelyVisionModel(m.id),
          isRecommended: m.id.contains("qwen3-vl") || m.id.contains("vision"))
      }
    } else {
      let decoded = try JSONDecoder().decode(OllamaResp.self, from: data)
      return decoded.models.map { m in
        LLMModelOption.curated(
          m.name, family: m.details?.family ?? "Local",
          visionCapable: isLikelyVisionModel(m.name),
          isRecommended: m.name.contains("qwen3-vl") || m.name.contains("vision")
        )
      }
    }
  }

  private func isLikelyVisionModel(_ name: String) -> Bool {
    let lower = name.lowercased()
    return lower.contains("vl") || lower.contains("vision") || lower.contains("llava")
      || lower.contains("qwen2.5vl") || lower.contains("qwen3-vl")
  }

  // MARK: Curated fallbacks (used when live fetch fails or for providers
  // that have no public list endpoint)

  private func curatedFallback(for providerID: String) -> [LLMModelOption] {
    switch providerID {
    case "gemini": return curatedGeminiModels
    case "minimax": return curatedMiniMaxModels
    case "ollama": return curatedOllamaModels
    case "codex": return curatedCodexModels
    case "claude": return curatedClaudeModels
    default: return []
    }
  }

  private var curatedGeminiModels: [LLMModelOption] {
    [
      .curated(
        "gemini-3.5-flash", displayName: "Gemini 3.5 Flash", family: "Gemini 3.5",
        contextWindow: 1_048_576, visionCapable: true, isRecommended: true,
        notes: "Default workhorse. Fast, 1M context, multimodal."
      ),
      .curated(
        "gemini-2.5-pro", displayName: "Gemini 2.5 Pro", family: "Gemini 2.5",
        contextWindow: 1_048_576, visionCapable: true, isRecommended: false,
        notes: "Best for complex reasoning. Scheduled for shutdown 2026-10-16."
      ),
      .curated(
        "gemini-2.5-flash", displayName: "Gemini 2.5 Flash", family: "Gemini 2.5",
        contextWindow: 1_048_576, visionCapable: true, isRecommended: false,
        notes: "Faster, lower cost. Scheduled for shutdown 2026-10-16."
      ),
      .curated(
        "gemini-2.5-flash-lite", displayName: "Gemini 2.5 Flash-Lite",
        family: "Gemini 2.5", contextWindow: 1_048_576, visionCapable: true,
        isRecommended: false, notes: "Cheapest, fastest."
      ),
      .curated(
        "gemini-2.0-flash", displayName: "Gemini 2.0 Flash", family: "Gemini 2.0",
        contextWindow: 1_048_576, visionCapable: true, isDeprecated: true,
        notes: "Shut down 2026-06-01."
      ),
      .curated(
        "gemini-1.5-pro", displayName: "Gemini 1.5 Pro", family: "Gemini 1.5",
        contextWindow: 2_097_152, visionCapable: true, isDeprecated: true,
        notes: "Deprecated."
      ),
    ]
  }

  private var curatedMiniMaxModels: [LLMModelOption] {
    [
      .curated(
        "MiniMax-M3", displayName: "MiniMax M3", family: "M3",
        contextWindow: 1_000_000, visionCapable: true, isRecommended: true,
        notes: "Default. Frontier multimodal, 1M context."
      ),
      .curated(
        "MiniMax-M2.7", displayName: "MiniMax M2.7", family: "M2",
        contextWindow: 1_000_000, visionCapable: true, isRecommended: false,
        notes: "Previous flagship."
      ),
      .curated(
        "MiniMax-M2.7-highspeed", displayName: "MiniMax M2.7 Highspeed",
        family: "M2", contextWindow: 1_000_000, visionCapable: true,
        isRecommended: false, notes: "Lower-latency M2.7."
      ),
      .curated(
        "MiniMax-M2.5", displayName: "MiniMax M2.5", family: "M2",
        contextWindow: 1_000_000, visionCapable: true, isRecommended: false
      ),
      .curated(
        "MiniMax-M2.5-highspeed", displayName: "MiniMax M2.5 Highspeed",
        family: "M2", contextWindow: 1_000_000, visionCapable: true,
        isRecommended: false
      ),
    ]
  }

  private var curatedOllamaModels: [LLMModelOption] {
    [
      .curated("qwen3-vl:4b", displayName: "Qwen3-VL 4B (Recommended)",
               family: "Qwen3-VL", contextWindow: 32_768, visionCapable: true,
               isRecommended: true,
               notes: "Dayflow's recommended local VLM."),
      .curated("qwen2.5vl:3b", displayName: "Qwen2.5-VL 3B",
               family: "Qwen2.5-VL", contextWindow: 32_768, visionCapable: true,
               isRecommended: false),
      .curated("llama3.2-vision:11b", displayName: "Llama 3.2 Vision 11B",
               family: "Llama 3.2", contextWindow: 128_000, visionCapable: true,
               isRecommended: false),
      .curated("llava:13b", displayName: "LLaVA 13B",
               family: "LLaVA", contextWindow: 4_096, visionCapable: true,
               isRecommended: false),
      .curated("gemma3:4b", displayName: "Gemma 3 4B",
               family: "Gemma 3", contextWindow: 128_000, visionCapable: true,
               isRecommended: false),
    ]
  }

  private var curatedCodexModels: [LLMModelOption] {
    [
      .curated("gpt-4o", displayName: "GPT-4o", family: "GPT-4o",
               contextWindow: 128_000, visionCapable: true, isRecommended: true),
      .curated("gpt-4o-mini", displayName: "GPT-4o mini", family: "GPT-4o",
               contextWindow: 128_000, visionCapable: true, isRecommended: false),
      .curated("gpt-4.1", displayName: "GPT-4.1", family: "GPT-4.1",
               contextWindow: 1_000_000, visionCapable: true, isRecommended: false),
      .curated("gpt-4.1-mini", displayName: "GPT-4.1 mini", family: "GPT-4.1",
               contextWindow: 1_000_000, visionCapable: true, isRecommended: false),
      .curated("o3", displayName: "o3", family: "o-series",
               contextWindow: 200_000, visionCapable: false, isRecommended: false),
      .curated("o3-mini", displayName: "o3-mini", family: "o-series",
               contextWindow: 200_000, visionCapable: false, isRecommended: false),
      .curated("o4-mini", displayName: "o4-mini", family: "o-series",
               contextWindow: 200_000, visionCapable: false, isRecommended: false),
    ]
  }

  private var curatedClaudeModels: [LLMModelOption] {
    [
      .curated(
        "claude-opus-4-8", displayName: "Claude Opus 4.8", family: "Opus",
        contextWindow: 1_000_000, visionCapable: true, isRecommended: true,
        notes: "Frontier. Best for complex agent tasks."
      ),
      .curated(
        "claude-opus-4-7", displayName: "Claude Opus 4.7", family: "Opus",
        contextWindow: 1_000_000, visionCapable: true, isRecommended: false
      ),
      .curated(
        "claude-sonnet-4-5", displayName: "Claude Sonnet 4.5", family: "Sonnet",
        contextWindow: 1_000_000, visionCapable: true, isRecommended: false,
        notes: "Dayflow's default. Good balance."
      ),
      .curated(
        "claude-3-5-sonnet-latest", displayName: "Claude 3.5 Sonnet (latest)",
        family: "Sonnet", contextWindow: 200_000, visionCapable: true,
        isDeprecated: true
      ),
      .curated(
        "claude-3-5-haiku-latest", displayName: "Claude 3.5 Haiku (latest)",
        family: "Haiku", contextWindow: 200_000, visionCapable: true,
        isRecommended: false, notes: "Cheapest, fastest Claude."
      ),
    ]
  }
}

// MARK: - Provider id helpers

extension LLMProviderID {
  /// The provider-id used by `ModelCatalog`. (Today this is the same string
  /// the settings UI uses, but keeping the indirection lets us rename later
  /// without rewriting every catalog call site.)
  var modelCatalogID: String { rawValue }
}
