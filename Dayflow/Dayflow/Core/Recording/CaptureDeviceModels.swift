import Foundation

enum CapturePlatform: String, Codable, CaseIterable, Sendable {
  case macOS = "macos"
  case android
}

enum CaptureKind: String, Codable, Sendable {
  case image
  case redacted
  case unavailable
}

enum CaptureOrientation: String, Codable, Sendable {
  case portrait
  case portraitUpsideDown = "portrait_upside_down"
  case landscapeLeft = "landscape_left"
  case landscapeRight = "landscape_right"
  case unknown
}

struct CaptureDevice: Codable, Identifiable, Equatable, Sendable {
  let id: String
  let platform: CapturePlatform
  var displayName: String
  var model: String?
  var osVersion: String?
  var pairedAt: Date?
  var lastSeenAt: Date?
  var isRevoked: Bool
}

struct CaptureImportMetadata: Codable, Sendable {
  let captureId: String
  let deviceId: String
  let sessionId: String?
  let sequence: Int64?
  let capturedAtUTCMS: Int64
  let timezoneId: String
  let utcOffsetSeconds: Int
  let platform: CapturePlatform
  let foregroundAppId: String?
  let foregroundAppName: String?
  let orientation: CaptureOrientation
  let pixelWidth: Int?
  let pixelHeight: Int?
  let kind: CaptureKind
  let mimeType: String?
  let byteLength: Int64?
  let sha256: String?
}

enum LocalCaptureDevice {
  private static let defaultsKey = "localCaptureDeviceId"

  static let id: String = {
    if let stored = UserDefaults.standard.string(forKey: defaultsKey), !stored.isEmpty {
      return stored
    }

    let generated = UUID().uuidString.lowercased()
    UserDefaults.standard.set(generated, forKey: defaultsKey)
    return generated
  }()

  static var current: CaptureDevice {
    CaptureDevice(
      id: id,
      platform: .macOS,
      displayName: Host.current().localizedName ?? "This Mac",
      model: nil,
      osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
      pairedAt: nil,
      lastSeenAt: Date(),
      isRevoked: false
    )
  }
}
