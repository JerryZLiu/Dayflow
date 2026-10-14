import Foundation

enum LocalOnlyNetworkingError: LocalizedError {
  case remoteURLBlocked(String)
  case cloudProcessingDisabled

  var errorDescription: String? {
    switch self {
    case .remoteURLBlocked(let host):
      return
        "Dayflow kept this request on this Mac. Nothing is sent to \(host)."
    case .cloudProcessingDisabled:
      return
        "Cloud model processing is turned off. Images, OCR text, and traces stay on this Mac. Use a local model instead."
    }
  }
}

/// Allows HTTP only to this machine. Screen images, OCR, transcripts, and traces
/// never leave the Mac, including when a saved provider URL points at a cloud API.
enum LocalOnlyNetworking {
  static let blockedPageHTML = """
    <!doctype html>
    <html>
    <body style="font-family: -apple-system, sans-serif; padding: 24px; color: #1d1d1f;">
      <p>This view stays on your Mac. Dayflow does not load remote pages that could receive recordings, messages, or debug logs.</p>
    </body>
    </html>
    """

  static func allows(_ url: URL?) -> Bool {
    guard let url else { return false }
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      return false
    }
    guard var host = url.host?.lowercased(), !host.isEmpty else { return false }
    if host.hasPrefix("["), host.hasSuffix("]") {
      host = String(host.dropFirst().dropLast())
    }
    if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" {
      return true
    }
    return host.split(separator: ".").count == 4 && host.hasPrefix("127.")
  }

  static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    try assertLocal(request.url)
    return try await URLSession.shared.data(for: request)
  }

  static func data(from url: URL) async throws -> (Data, URLResponse) {
    try assertLocal(url)
    return try await URLSession.shared.data(from: url)
  }

  static func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
    try assertLocal(request.url)
    return try await URLSession.shared.bytes(for: request)
  }

  static func refuseCloudProcessing() throws {
    throw LocalOnlyNetworkingError.cloudProcessingDisabled
  }

  static func assertLocal(_ url: URL?) throws {
    guard allows(url) else {
      throw LocalOnlyNetworkingError.remoteURLBlocked(
        url?.host ?? url?.absoluteString ?? "unknown host")
    }
  }
}
