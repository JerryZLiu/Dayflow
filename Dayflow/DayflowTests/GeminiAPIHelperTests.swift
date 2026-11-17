import XCTest

@testable import Dayflow

final class GeminiAPIHelperTests: XCTestCase {
  func testConnectionChecksTheKeyWithOneModelListRequest() async throws {
    let recorder = RequestRecorder()
    let helper = makeHelper(recorder: recorder) { (200, Data(#"{"models":[]}"#.utf8)) }

    let result = try await helper.testConnection(
      apiKey: " test-key ",
      preference: GeminiModelPreference(primary: .flash35)
    )

    XCTAssertEqual(result.model, .flash35)
    let requests = await recorder.requests
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.httpMethod, "GET")
    XCTAssertEqual(requests.first?.url?.path, "/v1beta/models")
    XCTAssertTrue(requests.first?.url?.query?.contains("key=test-key") == true)
  }

  func testConnectionReportsAnInvalidKey() async throws {
    for status in [400, 401, 403] {
      let helper = makeHelper(recorder: RequestRecorder()) {
        (status, Self.errorBody("API key not valid. Please pass a valid API key."))
      }
      do {
        _ = try await helper.testConnection(apiKey: "bad-key", preference: .default)
        XCTFail("Expected status \(status) to fail")
      } catch GeminiAPIHelper.APIError.apiError(let message) {
        XCTAssertEqual(message, "API key not valid. Please pass a valid API key.")
      } catch {
        XCTFail("Unexpected error for status \(status): \(error)")
      }
    }
  }

  func testConnectionTreatsRateLimitAsRateLimited() async throws {
    let helper = makeHelper(recorder: RequestRecorder()) {
      (429, Self.errorBody("Resource has been exhausted (e.g. check quota)."))
    }

    do {
      _ = try await helper.testConnection(apiKey: "test-key", preference: .default)
      XCTFail("Expected a rate-limited result")
    } catch GeminiAPIHelper.APIError.rateLimited(_, let model) {
      XCTAssertEqual(model, GeminiModelPreference.default.primary)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testConnectionRejectsAnEmptyKeyWithoutARequest() async throws {
    let recorder = RequestRecorder()
    let helper = makeHelper(recorder: recorder) { (200, Data()) }

    do {
      _ = try await helper.testConnection(apiKey: "  \n", preference: .default)
      XCTFail("Expected an invalid key error")
    } catch GeminiAPIHelper.APIError.invalidAPIKey {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    let requests = await recorder.requests
    XCTAssertTrue(requests.isEmpty)
  }

  private func makeHelper(
    recorder: RequestRecorder,
    response: @escaping () -> (status: Int, body: Data)
  ) -> GeminiAPIHelper {
    GeminiAPIHelper(
      requestData: { request in
        await recorder.record(request)
        let result = response()
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

  private static func errorBody(_ message: String) -> Data {
    try! JSONSerialization.data(withJSONObject: ["error": ["message": message]])
  }
}

private actor RequestRecorder {
  private(set) var requests: [URLRequest] = []

  func record(_ request: URLRequest) {
    requests.append(request)
  }
}
