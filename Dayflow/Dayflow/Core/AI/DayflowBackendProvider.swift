//
//  DayflowBackendProvider.swift
//  Dayflow
//

import Foundation

struct DayflowDailyGenerationRequest: Codable, Sendable {
    let day: String
    let cardsText: String
    let observationsText: String
    let priorDailyText: String
    let preferencesText: String

    init(
        day: String,
        cardsText: String,
        observationsText: String = "",
        priorDailyText: String = "",
        preferencesText: String = ""
    ) {
        self.day = day
        self.cardsText = cardsText
        self.observationsText = observationsText
        self.priorDailyText = priorDailyText
        self.preferencesText = preferencesText
    }

    private enum CodingKeys: String, CodingKey {
        case day
        case cardsText = "cards_text"
        case observationsText = "observations_text"
        case priorDailyText = "prior_daily_text"
        case preferencesText = "preferences_text"
    }
}

struct DayflowDailyGenerationResponse: Codable, Sendable {
    let day: String
    let highlights: [String]
    let unfinished: [String]
    let blockers: [String]
}

final class DayflowBackendProvider {
    private let token: String
    private let endpoint: String

    init(token: String, endpoint: String = "https://web-production-f3361.up.railway.app") {
        self.token = token
        self.endpoint = endpoint
    }

    func generateDaily(_ request: DayflowDailyGenerationRequest) async throws -> DayflowDailyGenerationResponse {
        let requestId = UUID().uuidString
        let startedAt = Date()
        let normalizedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let endpointHost: String = {
            guard let parsed = URL(string: normalizedEndpoint), let host = parsed.host, !host.isEmpty else {
                return "invalid_host"
            }
            return host
        }()

        let baseProps: [String: Any] = [
            "daily_request_id": requestId,
            "day": request.day,
            "endpoint_host": endpointHost,
            "cards_text_chars": request.cardsText.count,
            "observations_text_chars": request.observationsText.count,
            "prior_daily_text_chars": request.priorDailyText.count,
            "preferences_text_chars": request.preferencesText.count
        ]

        AnalyticsService.shared.capture("daily_generation_request_started", baseProps)

        var httpStatusCode: Int? = nil
        var responseByteCount = 0

        do {
            guard let url = URL(string: "\(normalizedEndpoint)/v1/daily") else {
                throw NSError(
                    domain: "DayflowBackend",
                    code: -10,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid Dayflow backend endpoint: \(endpoint)"]
                )
            }

            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            urlRequest.httpBody = try JSONEncoder().encode(request)

            let requestByteCount = urlRequest.httpBody?.count ?? 0
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            responseByteCount = data.count

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(
                    domain: "DayflowBackend",
                    code: -11,
                    userInfo: [NSLocalizedDescriptionKey: "Daily generation request returned a non-HTTP response."]
                )
            }

            httpStatusCode = httpResponse.statusCode

            guard (200...299).contains(httpResponse.statusCode) else {
                let responseBody = String(data: data, encoding: .utf8) ?? ""
                throw NSError(
                    domain: "DayflowBackend",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Daily generation failed (\(httpResponse.statusCode)): \(responseBody)"]
                )
            }

            let decoded: DayflowDailyGenerationResponse
            do {
                decoded = try JSONDecoder().decode(DayflowDailyGenerationResponse.self, from: data)
            } catch {
                let responseBody = String(data: data, encoding: .utf8) ?? ""
                throw NSError(
                    domain: "DayflowBackend",
                    code: -12,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to decode daily generation response: \(responseBody)"]
                )
            }

            var successProps = baseProps
            successProps["latency_ms"] = Int(Date().timeIntervalSince(startedAt) * 1000)
            successProps["http_status"] = httpResponse.statusCode
            successProps["request_bytes"] = requestByteCount
            successProps["response_bytes"] = responseByteCount
            successProps["highlights_count"] = decoded.highlights.count
            successProps["unfinished_count"] = decoded.unfinished.count
            successProps["blockers_count"] = decoded.blockers.count
            AnalyticsService.shared.capture("daily_generation_request_succeeded", successProps)

            return decoded
        } catch {
            let nsError = error as NSError
            var failureProps = baseProps
            failureProps["latency_ms"] = Int(Date().timeIntervalSince(startedAt) * 1000)
            failureProps["response_bytes"] = responseByteCount
            failureProps["error_domain"] = nsError.domain
            failureProps["error_code"] = nsError.code
            failureProps["error_message"] = String(nsError.localizedDescription.prefix(500))
            if let httpStatusCode {
                failureProps["http_status"] = httpStatusCode
            } else if nsError.code >= 100, nsError.code <= 599 {
                failureProps["http_status"] = nsError.code
            }
            AnalyticsService.shared.capture("daily_generation_request_failed", failureProps)
            throw error
        }
    }

    func transcribeScreenshots(_ screenshots: [Screenshot], batchStartTime: Date, batchId: Int64?) async throws -> (observations: [Observation], log: LLMCall) {
        fatalError("DayflowBackendProvider not implemented yet")
    }

    func generateActivityCards(observations: [Observation], context: ActivityGenerationContext, batchId: Int64?) async throws -> (cards: [ActivityCardData], log: LLMCall) {
        fatalError("DayflowBackendProvider not implemented yet")
    }

    func generateText(prompt: String) async throws -> (text: String, log: LLMCall) {
        throw NSError(
            domain: "DayflowBackend",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Text generation is not yet supported with Dayflow Backend. Please configure Gemini, Ollama, or ChatGPT/Claude CLI in Settings."]
        )
    }
}
