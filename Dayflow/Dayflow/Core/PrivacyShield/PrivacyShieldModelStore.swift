import CoreML
import CryptoKit
import Foundation

/// Where the backend says to download the privacy model from (`GET /v1/privacy-model`, Pro and Plus only).
struct PrivacyModelDownload: Decodable {
  let version: String
  let url: String
  let sha256: String
  let sizeBytes: Int

  private enum CodingKeys: String, CodingKey {
    case version
    case url
    case sha256
    case sizeBytes = "size_bytes"
  }
}

/// The contents of `manifest.json` inside the model zip.
private struct PrivacyModelManifest: Decodable {
  let version: String
  let threshold: Float
  /// Window size ("192", "320", "496") to the `.mlpackage` folder name inside the zip.
  let models: [String: String]
  let bip39: String
}

/// Downloads, checks, unpacks and compiles the privacy model, and keeps it in
/// `~/Library/Application Support/Dayflow/privacy-model/<version>/`. The model never ships in the app
/// or the repo: only signed-in Pro and Plus accounts get a download link from the backend.
enum PrivacyShieldModelStore {
  private static let compiledNames = [
    192: "L192.mlmodelc", 320: "L320.mlmodelc", 496: "L496.mlmodelc",
  ]

  static var rootDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Dayflow/privacy-model", isDirectory: true)
  }

  private static func directory(for version: String) -> URL {
    rootDirectory.appendingPathComponent(version, isDirectory: true)
  }

  /// The newest model already on disk, if any (only one version is kept).
  static func installedVersion() -> String? {
    let versions = (try? FileManager.default.contentsOfDirectory(atPath: rootDirectory.path)) ?? []
    // ".<version>-building" folders are installs in progress.
    return versions.first { !$0.hasPrefix(".") && isComplete(directory(for: $0)) }
  }

  private static func isComplete(_ directory: URL) -> Bool {
    let names = Array(compiledNames.values) + ["manifest.json", "bip39.txt"]
    return names.allSatisfy {
      FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
    }
  }

  /// Loads an installed version into a ready-to-use masker.
  static func loadMasker(version: String) throws -> PrivacyShieldFrameMasker {
    let directory = directory(for: version)
    let manifest = try JSONDecoder().decode(
      PrivacyModelManifest.self,
      from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
    let words = try String(
      contentsOf: directory.appendingPathComponent("bip39.txt"), encoding: .utf8
    )
    .split(separator: "\n").map(String.init)
    var compiled: [Int: URL] = [:]
    for (size, name) in compiledNames {
      compiled[size] = directory.appendingPathComponent(name)
    }
    let runner = try PIIModelRunner(compiledModels: compiled)
    return PrivacyShieldFrameMasker(
      runner: runner, rules: PIIMaskRules(threshold: manifest.threshold, bip39Words: words))
  }

  /// Downloads and installs `download`, replacing any older version. Returns the installed version.
  static func install(_ download: PrivacyModelDownload) async throws -> String {
    guard let url = URL(string: download.url) else { throw PrivacyShieldModelError.badLink }
    let (zipURL, response) = try await URLSession.shared.download(from: url)
    defer { try? FileManager.default.removeItem(at: zipURL) }
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw PrivacyShieldModelError.downloadFailed
    }

    let digest = SHA256.hash(data: try Data(contentsOf: zipURL, options: .mappedIfSafe))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    guard hex == download.sha256.lowercased() else {
      throw PrivacyShieldModelError.checksumMismatch
    }

    let fileManager = FileManager.default
    let staging = fileManager.temporaryDirectory.appendingPathComponent(
      "dayflow-privacy-model-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: staging) }
    try unzip(zipURL, to: staging)

    let manifest = try JSONDecoder().decode(
      PrivacyModelManifest.self,
      from: Data(contentsOf: staging.appendingPathComponent("manifest.json")))
    guard manifest.version == download.version else { throw PrivacyShieldModelError.badArchive }

    let target = directory(for: download.version)
    let building = rootDirectory.appendingPathComponent(
      ".\(download.version)-building", isDirectory: true)
    try? fileManager.removeItem(at: building)
    try fileManager.createDirectory(at: building, withIntermediateDirectories: true)
    for (size, name) in compiledNames {
      guard let package = manifest.models[String(size)] else {
        throw PrivacyShieldModelError.badArchive
      }
      let compiledURL = try await MLModel.compileModel(at: staging.appendingPathComponent(package))
      try fileManager.moveItem(at: compiledURL, to: building.appendingPathComponent(name))
    }
    try fileManager.copyItem(
      at: staging.appendingPathComponent("manifest.json"),
      to: building.appendingPathComponent("manifest.json"))
    try fileManager.copyItem(
      at: staging.appendingPathComponent(manifest.bip39),
      to: building.appendingPathComponent("bip39.txt"))

    // Swap in the new version and drop any older one.
    for old
      in (try? fileManager.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil))
      ?? []
    where old.lastPathComponent != building.lastPathComponent {
      try? fileManager.removeItem(at: old)
    }
    try fileManager.moveItem(at: building, to: target)
    return download.version
  }

  /// Removes every installed version, so the next prepare downloads a fresh copy (used when an install won't load).
  static func removeAll() {
    try? FileManager.default.removeItem(at: rootDirectory)
  }

  private static func unzip(_ zip: URL, to destination: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-x", "-k", zip.path, destination.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw PrivacyShieldModelError.badArchive }
  }
}

enum PrivacyShieldModelError: Error {
  case badLink
  case downloadFailed
  case checksumMismatch
  case badArchive
}
