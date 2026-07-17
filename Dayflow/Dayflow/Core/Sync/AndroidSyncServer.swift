import AppKit
import CryptoKit
import Darwin
import Foundation
import ImageIO
import Network
import Security

struct AndroidPairingPayload: Codable {
  let protocolVersion: Int
  let serviceType: String
  let serviceName: String
  let serviceId: String
  let port: UInt16
  let hostAddresses: [String]
  let sharedKey: String
}

private struct AndroidSyncRequest: Codable {
  enum Kind: String, Codable {
    case register
    case manifest
    case upload
    case ping
  }

  let kind: Kind
  let requestId: String
  let device: CaptureDevice?
  let deviceId: String?
  let captureIds: [String]?
  let metadata: CaptureImportMetadata?
  let imageBase64: String?
}

private struct AndroidSyncResponse: Codable {
  let requestId: String
  let ok: Bool
  let missingCaptureIds: [String]?
  let acceptedCaptureId: String?
  let error: String?
  let serverTimeUTCMS: Int64
}

final class AndroidSyncServer: ObservableObject, @unchecked Sendable {
  static let shared = AndroidSyncServer()

  static let serviceType = "_dayflow-sync._tcp"
  private static let protocolVersion = 1
  private static let maximumFrameBytes = 12 * 1024 * 1024
  private static let secretAccount = "android-sync-shared-key"

  @Published private(set) var isRunning = false
  @Published private(set) var port: UInt16?
  @Published private(set) var lastError: String?
  @Published private(set) var lastSyncAt: Date?

  private let queue = DispatchQueue(label: "com.dayflow.android-sync", qos: .utility)
  private let fileManager = FileManager.default
  private let stateLock = NSLock()
  private var listener: NWListener?
  private var sharedKeyData: Data
  private let serviceId: String
  private let serviceName: String

  private init() {
    sharedKeyData = Self.loadOrCreateSharedKey()
    serviceId = Self.loadOrCreateServiceId()
    serviceName = "Dayflow-\(Host.current().localizedName ?? "Mac")"
  }

  func start() {
    queue.async { [weak self] in
      guard let self, self.listener == nil else { return }
      do {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.service = NWListener.Service(name: self.serviceName, type: Self.serviceType)
        listener.newConnectionHandler = { [weak self] connection in
          self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
          self?.handleListenerState(state)
        }
        self.listener = listener
        listener.start(queue: self.queue)
      } catch {
        self.publishError(error.localizedDescription)
      }
    }
  }

  func stop() {
    queue.async { [weak self] in
      self?.listener?.cancel()
      self?.listener = nil
      DispatchQueue.main.async {
        self?.isRunning = false
        self?.port = nil
      }
    }
  }

  func resetPairing() {
    let newKey = Self.randomBytes(count: 32)
    guard Self.storeSharedKey(newKey) else { return }
    stateLock.lock()
    sharedKeyData = newKey
    stateLock.unlock()
  }

  func pairingPayload() -> AndroidPairingPayload? {
    stateLock.lock()
    let key = sharedKeyData
    let currentPort = port
    stateLock.unlock()
    guard let currentPort else { return nil }
    return AndroidPairingPayload(
      protocolVersion: Self.protocolVersion,
      serviceType: Self.serviceType,
      serviceName: serviceName,
      serviceId: serviceId,
      port: currentPort,
      hostAddresses: Self.localIPv4Addresses(),
      sharedKey: key.base64EncodedString()
    )
  }

  private func handleListenerState(_ state: NWListener.State) {
    switch state {
    case .ready:
      let listenerPort = listener?.port?.rawValue
      stateLock.lock()
      stateLock.unlock()
      DispatchQueue.main.async { [weak self] in
        self?.port = listenerPort
        self?.isRunning = true
        self?.lastError = nil
      }
    case .failed(let error):
      publishError(error.localizedDescription)
      listener?.cancel()
      listener = nil
    case .cancelled:
      DispatchQueue.main.async { [weak self] in self?.isRunning = false }
    default:
      break
    }
  }

  private func accept(_ connection: NWConnection) {
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let self, let connection else { return }
      switch state {
      case .ready:
        self.receiveFrame(on: connection)
      case .failed, .cancelled:
        connection.cancel()
      default:
        break
      }
    }
    connection.start(queue: queue)
  }

  private func receiveFrame(on connection: NWConnection) {
    receiveExactly(4, on: connection) { [weak self] lengthData in
      guard let self, let lengthData else {
        connection.cancel()
        return
      }
      let length = lengthData.reduce(0) { ($0 << 8) | Int($1) }
      guard length > 0, length <= Self.maximumFrameBytes else {
        connection.cancel()
        return
      }
      self.receiveExactly(length, on: connection) { [weak self] encryptedData in
        guard let self, let encryptedData else {
          connection.cancel()
          return
        }
        let response = self.process(encryptedData)
        self.send(response, on: connection) { [weak self] success in
          guard success else {
            connection.cancel()
            return
          }
          self?.receiveFrame(on: connection)
        }
      }
    }
  }

  private func process(_ encryptedData: Data) -> AndroidSyncResponse {
    let requestIdFallback = "unknown"
    do {
      let plaintext = try decrypt(encryptedData)
      let request = try JSONDecoder().decode(AndroidSyncRequest.self, from: plaintext)
      return try handle(request)
    } catch {
      return AndroidSyncResponse(
        requestId: requestIdFallback,
        ok: false,
        missingCaptureIds: nil,
        acceptedCaptureId: nil,
        error: error.localizedDescription,
        serverTimeUTCMS: Self.nowUTCMS
      )
    }
  }

  private func handle(_ request: AndroidSyncRequest) throws -> AndroidSyncResponse {
    var missing: [String]?
    var acceptedCaptureId: String?

    switch request.kind {
    case .register:
      guard var device = request.device, device.platform == .android else {
        throw SyncError.invalidRequest("Android device metadata is required")
      }
      device.lastSeenAt = Date()
      device.isRevoked = false
      StorageManager.shared.upsertCaptureDevice(device)

    case .manifest:
      guard let deviceId = request.deviceId, let captureIds = request.captureIds,
        captureIds.count <= 2_000
      else {
        throw SyncError.invalidRequest("Invalid manifest")
      }
      let existing = StorageManager.shared.existingCaptureIds(
        deviceId: deviceId,
        captureIds: captureIds
      )
      missing = captureIds.filter { !existing.contains($0) }

    case .upload:
      guard let metadata = request.metadata, metadata.platform == .android,
        let encodedImage = request.imageBase64,
        let imageData = Data(base64Encoded: encodedImage),
        imageData.count <= 8 * 1024 * 1024
      else {
        throw SyncError.invalidRequest("Invalid screenshot upload")
      }
      try importCapture(metadata: metadata, imageData: imageData)
      acceptedCaptureId = metadata.captureId
      DispatchQueue.main.async { [weak self] in self?.lastSyncAt = Date() }

    case .ping:
      break
    }

    return AndroidSyncResponse(
      requestId: request.requestId,
      ok: true,
      missingCaptureIds: missing,
      acceptedCaptureId: acceptedCaptureId,
      error: nil,
      serverTimeUTCMS: Self.nowUTCMS
    )
  }

  private func importCapture(metadata: CaptureImportMetadata, imageData: Data) throws {
    if let expectedHash = metadata.sha256?.lowercased() {
      let actualHash = SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined()
      guard actualHash == expectedHash else { throw SyncError.checksumMismatch }
    }
    guard CGImageSourceCreateWithData(imageData as CFData, nil) != nil else {
      throw SyncError.invalidImage
    }

    let destination = try StorageManager.shared.importedScreenshotURL(for: metadata)
    if !fileManager.fileExists(atPath: destination.path) {
      let incoming = destination.deletingLastPathComponent()
        .appendingPathComponent(".\(UUID().uuidString).incoming")
      try imageData.write(to: incoming, options: .atomic)
      do {
        try fileManager.moveItem(at: incoming, to: destination)
      } catch {
        try? fileManager.removeItem(at: incoming)
        throw error
      }
    }

    do {
      _ = try StorageManager.shared.saveImportedScreenshot(url: destination, metadata: metadata)
    } catch {
      try? fileManager.removeItem(at: destination)
      throw error
    }
  }

  private func decrypt(_ data: Data) throws -> Data {
    stateLock.lock()
    let keyData = sharedKeyData
    stateLock.unlock()
    let box = try AES.GCM.SealedBox(combined: data)
    return try AES.GCM.open(
      box,
      using: SymmetricKey(data: keyData),
      authenticating: Data(serviceId.utf8)
    )
  }

  private func encrypt(_ data: Data) throws -> Data {
    stateLock.lock()
    let keyData = sharedKeyData
    stateLock.unlock()
    let box = try AES.GCM.seal(
      data,
      using: SymmetricKey(data: keyData),
      authenticating: Data(serviceId.utf8)
    )
    guard let combined = box.combined else { throw SyncError.encryptionFailed }
    return combined
  }

  private func send(
    _ response: AndroidSyncResponse,
    on connection: NWConnection,
    completion: @escaping (Bool) -> Void
  ) {
    do {
      let encoded = try JSONEncoder().encode(response)
      let encrypted = try encrypt(encoded)
      var length = UInt32(encrypted.count).bigEndian
      var frame = withUnsafeBytes(of: &length) { Data($0) }
      frame.append(encrypted)
      connection.send(content: frame, completion: .contentProcessed { error in
        completion(error == nil)
      })
    } catch {
      completion(false)
    }
  }

  private func receiveExactly(
    _ count: Int,
    on connection: NWConnection,
    accumulated: Data = Data(),
    completion: @escaping (Data?) -> Void
  ) {
    guard accumulated.count < count else {
      completion(accumulated)
      return
    }
    connection.receive(
      minimumIncompleteLength: 1,
      maximumLength: count - accumulated.count
    ) { [weak self] data, _, isComplete, error in
      guard let self, error == nil, let data, !data.isEmpty else {
        completion(nil)
        return
      }
      var next = accumulated
      next.append(data)
      if next.count == count {
        completion(next)
      } else if isComplete {
        completion(nil)
      } else {
        self.receiveExactly(count, on: connection, accumulated: next, completion: completion)
      }
    }
  }

  private func publishError(_ message: String) {
    DispatchQueue.main.async { [weak self] in
      self?.lastError = message
      self?.isRunning = false
    }
  }

  private static var nowUTCMS: Int64 {
    Int64((Date().timeIntervalSince1970 * 1_000).rounded())
  }

  private static func loadOrCreateServiceId() -> String {
    let key = "androidSyncServiceId"
    if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
      return existing
    }
    let value = UUID().uuidString.lowercased()
    UserDefaults.standard.set(value, forKey: key)
    return value
  }

  private static func loadOrCreateSharedKey() -> Data {
    if let existing = loadSharedKey() { return existing }
    let generated = randomBytes(count: 32)
    _ = storeSharedKey(generated)
    return generated
  }

  private static func randomBytes(count: Int) -> Data {
    var data = Data(count: count)
    data.withUnsafeMutableBytes { buffer in
      guard let address = buffer.baseAddress else { return }
      _ = SecRandomCopyBytes(kSecRandomDefault, count, address)
    }
    return data
  }

  private static func localIPv4Addresses() -> [String] {
    var firstInterface: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&firstInterface) == 0, let firstInterface else { return [] }
    defer { freeifaddrs(firstInterface) }

    var addresses = Set<String>()
    var interface: UnsafeMutablePointer<ifaddrs>? = firstInterface
    while let current = interface {
      defer { interface = current.pointee.ifa_next }
      let flags = Int32(current.pointee.ifa_flags)
      guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
        let address = current.pointee.ifa_addr,
        address.pointee.sa_family == UInt8(AF_INET)
      else { continue }

      var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard getnameinfo(
        address,
        socklen_t(address.pointee.sa_len),
        &hostname,
        socklen_t(hostname.count),
        nil,
        0,
        NI_NUMERICHOST
      ) == 0 else { continue }
      addresses.insert(String(cString: hostname))
    }

    return addresses.sorted { lhs, rhs in
      let lhsPrivate = lhs.hasPrefix("192.168.") || lhs.hasPrefix("10.") || lhs.hasPrefix("172.")
      let rhsPrivate = rhs.hasPrefix("192.168.") || rhs.hasPrefix("10.") || rhs.hasPrefix("172.")
      return lhsPrivate == rhsPrivate ? lhs < rhs : lhsPrivate
    }
  }

  private static func storeSharedKey(_ data: Data) -> Bool {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.teleportlabs.dayflow.android-sync",
      kSecAttrAccount as String: secretAccount,
    ]
    SecItemDelete(query as CFDictionary)
    var add = query
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
  }

  private static func loadSharedKey() -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.teleportlabs.dayflow.android-sync",
      kSecAttrAccount as String: secretAccount,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
    return result as? Data
  }
}

private enum SyncError: LocalizedError {
  case invalidRequest(String)
  case checksumMismatch
  case invalidImage
  case encryptionFailed

  var errorDescription: String? {
    switch self {
    case .invalidRequest(let message): return message
    case .checksumMismatch: return "Screenshot checksum mismatch"
    case .invalidImage: return "Screenshot image could not be decoded"
    case .encryptionFailed: return "Could not encrypt sync response"
    }
  }
}
