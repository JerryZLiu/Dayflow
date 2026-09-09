//
//  AgentBridgeServer.swift
//  Dayflow
//
//  The app side of the agent write channel. The bundled `dayflow` CLI (and
//  its MCP server) read the database directly, but writes come here, because
//  the app owns the category store and its UI must refresh when data changes.
//
//  Transport: a Unix domain socket at ~/Library/Application Support/Dayflow/
//  agent.sock, mode 0600. One JSON request line per connection, one JSON
//  response line back. The server only runs while "Allow edits" is on.
//

import Foundation

enum AgentAccessPreferences {
  static let editsEnabledKey = "agentEditsEnabled"

  static var editsEnabled: Bool {
    get { UserDefaults.standard.bool(forKey: editsEnabledKey) }
    set { UserDefaults.standard.set(newValue, forKey: editsEnabledKey) }
  }
}

final class AgentBridgeServer {
  static let shared = AgentBridgeServer()

  private var listenFD: Int32 = -1
  private var acceptSource: DispatchSourceRead?
  private let queue = DispatchQueue(label: "com.dayflow.agent-bridge", qos: .userInitiated)

  static var socketPath: String {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return appSupport.appendingPathComponent("Dayflow/agent.sock").path
  }

  private static var writeLogPath: String {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return appSupport.appendingPathComponent("Dayflow/agent-writes.log").path
  }

  // MARK: - Lifecycle

  func startIfEnabled() {
    if AgentAccessPreferences.editsEnabled { start() }
  }

  func start() {
    guard listenFD < 0 else { return }
    let path = Self.socketPath

    // A stale socket file from a previous run blocks bind().
    unlink(path)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
      print("⚠️ AgentBridge: could not create socket")
      return
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
      close(fd)
      return
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      path.utf8CString.withUnsafeBytes { source in
        buffer.copyBytes(from: source.prefix(buffer.count))
      }
    }

    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bindResult == 0, listen(fd, 4) == 0 else {
      print("⚠️ AgentBridge: could not bind \(path), errno \(errno)")
      close(fd)
      return
    }

    // Owner-only: file permissions are the access control.
    chmod(path, 0o600)

    listenFD = fd
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in self?.acceptConnection() }
    source.setCancelHandler {
      close(fd)
      unlink(path)
    }
    source.resume()
    acceptSource = source
    print("ℹ️ AgentBridge: listening at \(path)")
  }

  func stop() {
    guard listenFD >= 0 else { return }
    acceptSource?.cancel()
    acceptSource = nil
    listenFD = -1
  }

  // MARK: - Connections

  private func acceptConnection() {
    let clientFD = accept(listenFD, nil, nil)
    guard clientFD >= 0 else { return }

    queue.async {
      defer { close(clientFD) }

      // One request line, capped at 1 MB.
      var request = Data()
      var byte: UInt8 = 0
      while read(clientFD, &byte, 1) == 1 {
        if byte == 0x0A { break }
        request.append(byte)
        if request.count > 1_048_576 { return }
      }

      let response = self.process(request)
      var payload =
        (try? JSONSerialization.data(withJSONObject: response)) ?? Data("{\"ok\":false}".utf8)
      payload.append(0x0A)
      payload.withUnsafeBytes { buffer in
        _ = write(clientFD, buffer.baseAddress, buffer.count)
      }
    }
  }

  private func process(_ request: Data) -> [String: Any] {
    guard
      let message = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
      let operation = message["operation"] as? String
    else {
      return failure("protocol_error", "Unreadable request.")
    }

    guard (message["protocol_version"] as? Int) == 1 else {
      return failure("protocol_mismatch", "Update Dayflow — the CLI and app disagree on protocol.")
    }

    // Authoritative permission check, independent of whether the CLI checked.
    guard AgentAccessPreferences.editsEnabled else {
      return failure("edits_disabled", "Editing is off in Dayflow → Settings → MCP / CLI.")
    }

    let arguments = message["arguments"] as? [String: Any] ?? [:]

    // Handlers touch CategoryStore (@MainActor) and the UI, so hop over.
    var result: [String: Any] = failure("internal_error", "Handler did not run.")
    DispatchQueue.main.sync {
      MainActor.assumeIsolated {
        do {
          let data = try AgentWriteHandlers.handle(operation: operation, arguments: arguments)
          Self.logWrite(operation: operation, arguments: arguments)
          result = ["ok": true, "data": data]
        } catch let error as AgentWriteError {
          result = failure(error.code, error.message)
        } catch {
          result = failure("internal_error", error.localizedDescription)
        }
      }
    }
    return result
  }

  private func failure(_ code: String, _ message: String) -> [String: Any] {
    ["ok": false, "error": ["code": code, "message": message]]
  }

  // Every write is recorded so there is something to inspect if an agent
  // does something unexpected. Arguments only — never returned data.
  private static func logWrite(operation: String, arguments: [String: Any]) {
    let entry: [String: Any] = [
      "at": ISO8601DateFormatter().string(from: Date()),
      "operation": operation,
      "arguments": arguments,
    ]
    guard var line = try? JSONSerialization.data(withJSONObject: entry) else { return }
    line.append(0x0A)
    if let handle = FileHandle(forWritingAtPath: writeLogPath) {
      handle.seekToEndOfFile()
      handle.write(line)
      try? handle.close()
    } else {
      try? line.write(to: URL(fileURLWithPath: writeLogPath))
    }
  }
}
