import AppKit
import Foundation

private final class ChatCLIStreamingDebugSink: @unchecked Sendable {
  private let lock = NSLock()
  private var shellCommand: String?
  private var environmentOverrides: [String: String] = [:]

  func update(shellCommand: String, environmentOverrides: [String: String]) {
    lock.lock()
    self.shellCommand = shellCommand
    self.environmentOverrides = environmentOverrides
    lock.unlock()
  }

  func snapshot() -> (shellCommand: String?, environmentOverrides: [String: String]) {
    lock.lock()
    let snapshot = (shellCommand, environmentOverrides)
    lock.unlock()
    return snapshot
  }
}

final class ChatCLIProvider {
  let tool: ChatCLITool
  let runner = ChatCLIProcessRunner()
  let config = ChatCLIConfigManager.shared

  init(tool: ChatCLITool) {
    self.tool = tool
    config.ensureWorkingDirectory()
  }

  /// Run the CLI and clean up temp files after.
  func runAndScrub(
    prompt: String, imagePaths: [String] = [], model: String? = nil, reasoningEffort: String? = nil,
    disableTools: Bool = false
  ) throws -> ChatCLIRunResult {
    // Prepare downsized copies of images (~720p) so Codex input stays compact.
    let (preparedImages, cleanupImages) = try prepareImagesForCLI(imagePaths)
    defer {
      cleanupImages()
    }
    return try runner.run(
      tool: tool, prompt: prompt, workingDirectory: config.workingDirectory,
      imagePaths: preparedImages, model: model, reasoningEffort: reasoningEffort,
      disableTools: disableTools)
  }

  func runStreamingAndCollect(
    prompt: String, model: String?, reasoningEffort: String?, sessionId: String?
  ) async throws -> (run: ChatCLIRunResult, sessionId: String?) {
    let started = Date()
    var collectedText = ""
    var sawTextDelta = false
    var capturedSessionId = sessionId
    let debugSink = ChatCLIStreamingDebugSink()

    let stream = runner.runStreaming(
      tool: tool,
      prompt: prompt,
      workingDirectory: config.workingDirectory,
      model: model,
      reasoningEffort: reasoningEffort,
      sessionId: sessionId,
      onProcessStart: { shellCommand, environmentOverrides in
        debugSink.update(
          shellCommand: shellCommand,
          environmentOverrides: environmentOverrides
        )
      }
    )

    do {
      for try await event in stream {
        switch event {
        case .sessionStarted(let id):
          capturedSessionId = id
        case .textDelta(let chunk):
          sawTextDelta = true
          collectedText += chunk
        case .complete(let text):
          if !sawTextDelta {
            collectedText = text
          }
        case .error(let message):
          let debug = debugSink.snapshot()
          var userInfo: [String: Any] = [
            NSLocalizedDescriptionKey: message,
            "partialStdout": collectedText,
            "partialStderr": message,
            "environmentOverrides": debug.environmentOverrides,
          ]
          if let shellCommand = debug.shellCommand {
            userInfo["shellCommand"] = shellCommand
          }
          throw NSError(
            domain: "ChatCLI",
            code: -4,
            userInfo: userInfo)
        default:
          break
        }
      }
    } catch {
      throw error
    }

    let finished = Date()
    let debug = debugSink.snapshot()
    let run = ChatCLIRunResult(
      exitCode: 0,
      stdout: collectedText,
      rawStdout: collectedText,
      stderr: "",
      shellCommand: debug.shellCommand,
      environmentOverrides: debug.environmentOverrides,
      startedAt: started,
      finishedAt: finished,
      usage: nil
    )

    return (run, capturedSessionId)
  }

  /// Create temporary 720p-max copies of images for Codex/Claude CLI.
  /// Returns the new paths and a cleanup closure.
  func prepareImagesForCLI(_ imagePaths: [String]) throws -> ([String], () -> Void) {
    guard !imagePaths.isEmpty else { return ([], {}) }

    let fm = FileManager.default
    let tmpDir = config.workingDirectory.appendingPathComponent(
      "tmp_images_\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)

    var processed: [String] = []

    func resize(_ src: URL, into dst: URL) throws {
      guard let image = NSImage(contentsOf: src) else {
        throw NSError(
          domain: "ChatCLI", code: -41,
          userInfo: [NSLocalizedDescriptionKey: "Failed to load image at \(src.path)"])
      }
      // Determine pixel size from representations (fallback to point size).
      let rep =
        image.representations.compactMap { $0 as? NSBitmapImageRep }.first
        ?? image.representations.first
      let pixelsWide = rep?.pixelsWide ?? Int(image.size.width)
      let pixelsHigh = rep?.pixelsHigh ?? Int(image.size.height)

      let maxHeight: Double = 720.0
      if pixelsHigh <= Int(maxHeight) {
        // No resize needed; just copy to temp to keep paths isolated.
        try fm.copyItem(at: src, to: dst)
        return
      }

      let scale = maxHeight / Double(pixelsHigh)
      let targetW = max(2, Int((Double(pixelsWide) * scale).rounded(.toNearestOrAwayFromZero)))
      let targetH = Int(maxHeight)

      guard
        let bitmap = NSBitmapImageRep(
          bitmapDataPlanes: nil,
          pixelsWide: targetW,
          pixelsHigh: targetH,
          bitsPerSample: 8,
          samplesPerPixel: 4,
          hasAlpha: true,
          isPlanar: false,
          colorSpaceName: .calibratedRGB,
          bytesPerRow: 0,
          bitsPerPixel: 0)
      else {
        throw NSError(
          domain: "ChatCLI", code: -42,
          userInfo: [NSLocalizedDescriptionKey: "Failed to create bitmap for \(src.path)"])
      }

      bitmap.size = NSSize(width: targetW, height: targetH)
      NSGraphicsContext.saveGraphicsState()
      guard let ctx = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(
          domain: "ChatCLI", code: -43,
          userInfo: [NSLocalizedDescriptionKey: "Failed to create graphics context for \(src.path)"]
        )
      }
      NSGraphicsContext.current = ctx
      image.draw(
        in: NSRect(x: 0, y: 0, width: CGFloat(targetW), height: CGFloat(targetH)),
        from: NSRect(origin: .zero, size: image.size),
        operation: .copy,
        fraction: 1.0,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high])
      ctx.flushGraphics()
      NSGraphicsContext.restoreGraphicsState()

      // Encode as JPEG to keep size small.
      let props: [NSBitmapImageRep.PropertyKey: Any] = [.compressionFactor: 0.85]
      guard
        let data = bitmap.representation(using: NSBitmapImageRep.FileType.jpeg, properties: props)
      else {
        throw NSError(
          domain: "ChatCLI", code: -44,
          userInfo: [NSLocalizedDescriptionKey: "Failed to encode resized image for \(src.path)"])
      }
      try data.write(to: dst, options: Data.WritingOptions.atomic)
    }

    for (idx, path) in imagePaths.enumerated() {
      let srcURL = URL(fileURLWithPath: path)
      let dstURL = tmpDir.appendingPathComponent(
        String(format: "%02d.jpg", idx), isDirectory: false)
      try resize(srcURL, into: dstURL)
      processed.append(dstURL.path)
    }

    let cleanup: () -> Void = {
      try? fm.removeItem(at: tmpDir)
    }

    return (processed, cleanup)
  }

}
