import XCTest

@testable import Dayflow

final class GeminiAPIHelperTests: XCTestCase {
  func testConnectionStartsWithSelectedModel() async throws {
    let recorder = RequestRecorder()
    let helper = makeHelper(recorder: recorder) { _ in
      (200, Data("{}".utf8))
    }

    let result = try await helper.testConnection(
      apiKey: "test-key",
      preference: GeminiModelPreference(primary: .flash35)
    )

    XCTAssertEqual(result.model, .flash35)
    let requestedModels = await recorder.models
    XCTAssertEqual(requestedModels, [.flash35])
  }

  func testConnectionUsesRuntimeFallbackOrderForTransientFailures() async throws {
    let recorder = RequestRecorder()
    let helper = makeHelper(recorder: recorder) { model in
      switch model {
      case .flash38:
        return (404, Self.errorBody("Model unavailable"))
      case .flash36:
        return (429, Self.errorBody("Rate limit exceeded"))
      case .flash37, .flash35:
        return (503, Self.errorBody("Temporarily unavailable"))
      case .flashLite35:
        return (200, Data("{}".utf8))
      }
    }

    let result = try await helper.testConnection(
      apiKey: "test-key",
      preference: .default
    )

    XCTAssertEqual(result.model, .flashLite35)
    let requestedModels = await recorder.models
    XCTAssertEqual(requestedModels, [.flash38, .flash37, .flash36, .flash35, .flashLite35])
  }

  func testConnectionReturnsRateLimitedAfterAllFallbacksAreTransient() async throws {
    let recorder = RequestRecorder()
    let helper = makeHelper(recorder: recorder) { _ in
      (503, Self.errorBody("Service temporarily unavailable"))
    }

    do {
      _ = try await helper.testConnection(
        apiKey: "test-key",
        preference: .default
      )
      XCTFail("Expected a rate-limited result")
    } catch GeminiAPIHelper.APIError.rateLimited(_, let model) {
      XCTAssertEqual(model, .flashLite35)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    let requestedModels = await recorder.models
    XCTAssertEqual(requestedModels, [.flash38, .flash37, .flash36, .flash35, .flashLite35])
  }

  func testConnectionDoesNotTreat425AsTransientOrFallback() async throws {
    let recorder = RequestRecorder()
    let helper = makeHelper(recorder: recorder) { _ in
      (425, Self.errorBody("Too Early"))
    }

    do {
      _ = try await helper.testConnection(
        apiKey: "test-key",
        preference: .default
      )
      XCTFail("Expected the request to fail")
    } catch GeminiAPIHelper.APIError.networkError(let message) {
      XCTAssertEqual(message, "Too Early")
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    let requestedModels = await recorder.models
    XCTAssertEqual(requestedModels, [.flash38])
  }

  private func makeHelper(
    recorder: RequestRecorder,
    response: @escaping (GeminiModel) -> (status: Int, body: Data)
  ) -> GeminiAPIHelper {
    GeminiAPIHelper(
      requestData: { request in
        let model = try XCTUnwrap(Self.model(from: request))
        await recorder.record(model)
        let result = response(model)
        let httpResponse = try XCTUnwrap(
          HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: result.status,
            httpVersion: nil,
            headerFields: nil
          )
        )
        return (result.body, httpResponse)
      },
      logsRequests: false
    )
  }

  private static func model(from request: URLRequest) -> GeminiModel? {
    guard let path = request.url?.path else { return nil }
    return GeminiModel.allCases.first { path.contains("/models/\($0.rawValue):generateContent") }
  }

  private static func errorBody(_ message: String) -> Data {
    try! JSONSerialization.data(withJSONObject: ["error": ["message": message]])
  }
}

private actor RequestRecorder {
  private(set) var models: [GeminiModel] = []

  func record(_ model: GeminiModel) {
    models.append(model)
  }
}
