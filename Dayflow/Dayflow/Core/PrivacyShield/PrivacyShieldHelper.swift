import CoreGraphics
import Foundation

/// Runs the Privacy Shield's text check in a separate copy of Dayflow, so it can be restarted.
///
/// Apple Vision's text reading can get stuck failing (CRImageReaderError 1) for hours, and only a fresh process
/// clears it. So the check (Vision plus the privacy model) runs in a helper: Dayflow's own executable started with
/// `launchArgument`. After a few failed frames in a row, or if the helper dies, it's replaced with a new one.
/// While a helper is starting, frames go unchecked and are stored as captured.
///
/// The app sends each frame as raw RGBA pixels over the helper's stdin; the helper answers on stdout with the
/// pixel boxes to hide (see `HelperWire`), and the app pixelates them.
final class PrivacyShieldHelper: @unchecked Sendable {
  static let launchArgument = "--privacy-shield-helper"

  private static let failuresBeforeRestart = 3
  /// A frame normally takes well under a second; a helper that takes longer than this is treated as stuck.
  private static let frameTimeout: TimeInterval = 30
  /// Loading and warming up the models can take tens of seconds on a Mac short on disk space.
  private static let startTimeout: TimeInterval = 180
  /// The least time between two restarts, so a helper that can't start isn't relaunched every frame.
  private static let minimumRestartGap: TimeInterval = 60

  private let version: String
  private let lock = NSLock()
  private var connection: HelperConnection?
  private var isRestarting = false
  private var isStopped = false
  private var lastRestartAt: Date?

  // Touched only from `mask`, which the recorder calls one frame at a time.
  private var failureStreak = 0
  /// The last frame's fingerprint and the boxes masked on it. About half of all captures are pixel-identical
  /// to the one before, and those reuse the boxes instead of asking the helper again.
  private var lastFingerprint: Data?
  private var lastRects: [CGRect] = []

  /// How many times the helper has been replaced since the shield turned on.
  private(set) var restartCount = 0

  private init(version: String, connection: HelperConnection) {
    self.version = version
    self.connection = connection
  }

  deinit {
    connection?.stop()
  }

  /// Starts a helper for the installed model `version` and waits until it has loaded and warmed up the models.
  /// Throws if the helper can't start, for example when the installed model won't load.
  static func start(version: String) throws -> PrivacyShieldHelper {
    let connection = try HelperConnection.launch(version: version, timeout: startTimeout)
    return PrivacyShieldHelper(version: version, connection: connection)
  }

  /// Stops the helper for good (the shield was turned off).
  func stop() {
    lock.lock()
    isStopped = true
    let current = connection
    connection = nil
    lock.unlock()
    current?.stop()
  }

  /// The frame with its secrets pixelated. Throws when the helper couldn't check it.
  /// Not thread-safe: the recorder captures one frame at a time.
  func mask(_ image: CGImage) throws -> CGImage {
    let fingerprint = PrivacyShieldPixelator.fingerprint(of: image)
    let rects: [CGRect]
    if let fingerprint, fingerprint == lastFingerprint {
      rects = lastRects
    } else {
      rects = try maskedRects(in: image)
      lastFingerprint = fingerprint
      lastRects = rects
    }
    guard !rects.isEmpty else { return image }
    return PrivacyShieldPixelator.pixelate(image, rects: rects) ?? image
  }

  private func maskedRects(in image: CGImage) throws -> [CGRect] {
    lock.lock()
    let current = connection
    lock.unlock()
    guard let current else {
      restartIfDue()
      throw PrivacyShieldHelperError.notRunning
    }
    do {
      let rects = try current.maskedRects(in: image, timeout: Self.frameTimeout)
      failureStreak = 0
      return rects
    } catch {
      failureStreak += 1
      if failureStreak >= Self.failuresBeforeRestart || !current.isRunning {
        failureStreak = 0
        restartIfDue()
      }
      throw error
    }
  }

  /// Replaces the helper with a fresh one in the background, unless one is already starting or the last
  /// restart was too recent.
  private func restartIfDue() {
    let now = Date()
    lock.lock()
    guard !isStopped, !isRestarting,
      lastRestartAt.map({ now.timeIntervalSince($0) >= Self.minimumRestartGap }) ?? true
    else {
      lock.unlock()
      return
    }
    isRestarting = true
    lastRestartAt = now
    restartCount += 1
    let old = connection
    connection = nil
    lock.unlock()
    old?.stop()

    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      let started = Date()
      let fresh = try? HelperConnection.launch(version: self.version, timeout: Self.startTimeout)
      self.lock.lock()
      self.isRestarting = false
      if self.isStopped {
        self.lock.unlock()
        fresh?.stop()
        return
      }
      self.connection = fresh
      let restarts = self.restartCount
      self.lock.unlock()
      AnalyticsService.shared.capture(
        "privacy_shield_helper_restarted",
        [
          "succeeded": fresh != nil, "restart_count": restarts,
          "seconds": Int(Date().timeIntervalSince(started)),
        ])
    }
  }

  // MARK: - Helper process side

  /// The helper's whole life: load the models, say it's ready, then answer frames until the app closes stdin.
  /// Called from `DayflowMain` before any of the app starts.
  static func runHelperProcess() -> Never {
    // The app ignores SIGPIPE and children inherit that; if the app quits mid-reply, just die quietly.
    signal(SIGPIPE, SIG_DFL)
    let input = FileHandle.standardInput
    let output = FileHandle.standardOutput
    let arguments = CommandLine.arguments
    guard let flag = arguments.firstIndex(of: launchArgument), flag + 1 < arguments.count else { exit(1) }

    // There's no run loop here, so each step drains its own autorelease pool (Vision and Core ML
    // autorelease per frame, and a frame holds megabytes of pixels).
    let loaded: PrivacyShieldFrameMasker? = autoreleasepool {
      guard let masker = try? PrivacyShieldModelStore.loadMasker(version: arguments[flag + 1]) else {
        return nil
      }
      masker.warmUp()
      return masker
    }
    guard let masker = loaded else {
      output.write(Data([HelperWire.modelLoadFailed]))
      exit(1)
    }
    output.write(Data([HelperWire.ready]))

    while true {
      let keepGoing: Bool = autoreleasepool {
        guard let header = try? HelperWire.readExactly(input, count: 8) else { return false }
        let width = Int(HelperWire.uint32(header, at: 0))
        let height = Int(HelperWire.uint32(header, at: 4))
        guard width > 0, height > 0,
          let pixels = try? HelperWire.readExactly(input, count: width * height * 4),
          let image = HelperWire.image(fromRGBA: pixels, width: width, height: height)
        else { return false }
        do {
          output.write(HelperWire.rectsReply(try masker.maskedRects(in: image)))
        } catch {
          output.write(HelperWire.errorReply(error as NSError))
        }
        return true
      }
      if !keepGoing { break }
    }
    exit(0)
  }
}

enum PrivacyShieldHelperError: Error {
  case noExecutable
  /// The installed model wouldn't load in the helper: the only failure that means the install is damaged.
  case modelLoadFailed
  case didNotStart
  case notRunning
  case timedOut
  case exited
  case badFrame
  case badReply
}

/// One running helper process and the pipes to it.
private final class HelperConnection: @unchecked Sendable {
  private let process: Process
  private let toHelper: FileHandle
  private let fromHelper: FileHandle

  private init(process: Process, toHelper: FileHandle, fromHelper: FileHandle) {
    self.process = process
    self.toHelper = toHelper
    self.fromHelper = fromHelper
  }

  var isRunning: Bool { process.isRunning }

  static func launch(version: String, timeout: TimeInterval) throws -> HelperConnection {
    guard let executable = Bundle.main.executableURL else { throw PrivacyShieldHelperError.noExecutable }
    let process = Process()
    process.executableURL = executable
    process.arguments = [PrivacyShieldHelper.launchArgument, version]
    let toHelper = Pipe()
    let fromHelper = Pipe()
    process.standardInput = toHelper
    process.standardOutput = fromHelper
    process.standardError = FileHandle.nullDevice
    // Writing to a helper that just died must fail with an error, not kill Dayflow with SIGPIPE.
    _ = fcntl(toHelper.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    try process.run()

    let connection = HelperConnection(
      process: process, toHelper: toHelper.fileHandleForWriting,
      fromHelper: fromHelper.fileHandleForReading)
    let reply: UInt8?
    do {
      reply = try connection.withTimeout(timeout) {
        try HelperWire.readExactly(connection.fromHelper, count: 1)
      }.first
    } catch {
      reply = nil
    }
    guard reply == HelperWire.ready else {
      connection.stop()
      throw reply == HelperWire.modelLoadFailed
        ? PrivacyShieldHelperError.modelLoadFailed : PrivacyShieldHelperError.didNotStart
    }
    return connection
  }

  func maskedRects(in image: CGImage, timeout: TimeInterval) throws -> [CGRect] {
    guard let request = HelperWire.frameRequest(image) else { throw PrivacyShieldHelperError.badFrame }
    return try withTimeout(timeout) {
      try self.toHelper.write(contentsOf: request)
      return try HelperWire.readReply(self.fromHelper)
    }
  }

  /// Kills the helper outright: it has nothing to clean up, and a stuck one may ignore SIGTERM.
  func stop() {
    try? toHelper.close()
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
  }

  /// Runs `work` on another thread and gives up after `timeout`, killing the helper so the blocked read ends.
  /// If the read still doesn't end, the worker thread is abandoned rather than stalling the recorder.
  private func withTimeout<T>(_ timeout: TimeInterval, _ work: @escaping () throws -> T) throws -> T {
    var result: Result<T, Error> = .failure(PrivacyShieldHelperError.timedOut)
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      result = Result { try work() }
      done.signal()
    }
    if done.wait(timeout: .now() + timeout) == .timedOut {
      stop()
      _ = done.wait(timeout: .now() + 5)
      throw PrivacyShieldHelperError.timedOut
    }
    return try result.get()
  }
}

/// The bytes between the app and the helper. All integers are little-endian.
/// - Frame (app to helper): width UInt32, height UInt32, then width × height × 4 bytes of RGBA pixels.
/// - Rects reply: `rectsTag`, count UInt32, then x, y, width, height as Float64 for each box.
/// - Error reply: `errorTag`, code Int64, domain length UInt32, then the domain as UTF-8.
private enum HelperWire {
  static let ready: UInt8 = 0x52
  static let modelLoadFailed: UInt8 = 0x46
  static let rectsTag: UInt8 = 0x00
  static let errorTag: UInt8 = 0x01

  static func frameRequest(_ image: CGImage) -> Data? {
    let width = image.width
    let height = image.height
    var data = Data(count: 8 + width * height * 4)
    put(UInt32(width), into: &data, at: 0)
    put(UInt32(height), into: &data, at: 4)
    let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress!.advanced(by: 8), width: width, height: height,
          bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    return drawn ? data : nil
  }

  static func image(fromRGBA pixels: Data, width: Int, height: Int) -> CGImage? {
    guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }

  static func rectsReply(_ rects: [CGRect]) -> Data {
    var data = Data([rectsTag])
    append(UInt32(rects.count), to: &data)
    for rect in rects {
      for value in [rect.minX, rect.minY, rect.width, rect.height] {
        append(Double(value).bitPattern, to: &data)
      }
    }
    return data
  }

  static func errorReply(_ error: NSError) -> Data {
    var data = Data([errorTag])
    append(UInt64(bitPattern: Int64(error.code)), to: &data)
    let domain = Data(error.domain.utf8)
    append(UInt32(domain.count), to: &data)
    data.append(domain)
    return data
  }

  /// The boxes from a rects reply, or the helper's error (with Vision's domain and code) from an error reply.
  static func readReply(_ handle: FileHandle) throws -> [CGRect] {
    let tag = try readExactly(handle, count: 1)[0]
    switch tag {
    case rectsTag:
      let count = Int(uint32(try readExactly(handle, count: 4), at: 0))
      let values = try readExactly(handle, count: count * 4 * 8)
      return (0..<count).map { index in
        let base = index * 32
        func value(_ offset: Int) -> CGFloat {
          CGFloat(Double(bitPattern: uint64(values, at: base + offset)))
        }
        return CGRect(x: value(0), y: value(8), width: value(16), height: value(24))
      }
    case errorTag:
      let code = Int(Int64(bitPattern: uint64(try readExactly(handle, count: 8), at: 0)))
      let length = Int(uint32(try readExactly(handle, count: 4), at: 0))
      let domain = String(decoding: try readExactly(handle, count: length), as: UTF8.self)
      throw NSError(domain: domain, code: code)
    default:
      throw PrivacyShieldHelperError.badReply
    }
  }

  /// Exactly `count` bytes, or `exited` when the other side closed the pipe first.
  static func readExactly(_ handle: FileHandle, count: Int) throws -> Data {
    var data = Data()
    while data.count < count {
      guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
        throw PrivacyShieldHelperError.exited
      }
      data.append(chunk)
    }
    return data
  }

  static func uint32(_ data: Data, at offset: Int) -> UInt32 {
    data.subdata(in: offset..<offset + 4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
  }

  static func uint64(_ data: Data, at offset: Int) -> UInt64 {
    data.subdata(in: offset..<offset + 8).withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
  }

  private static func put(_ value: UInt32, into data: inout Data, at offset: Int) {
    withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(offset..<offset + 4, with: $0) }
  }

  private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
  }
}
