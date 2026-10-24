//
//  Bridge.swift
//  dayflow-cli
//
//  Client side of the write channel. Reads go straight to SQLite; writes go
//  to the running app over a Unix domain socket, because the app owns the
//  category store (an in-memory array persisted to preferences wholesale) and
//  its UI must refresh when data changes underneath it.
//
//  Protocol: one JSON request line in, one JSON response line out, then the
//  connection closes. {"protocol_version":1,"operation":...,"arguments":{...}}
//  → {"ok":true,"data":{...}} or {"ok":false,"error":{"code","message"}}.
//

import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

enum AgentBridge {
  static let protocolVersion = 1

  static var socketPath: String {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return appSupport.appendingPathComponent("Dayflow/agent.sock").path
  }

  static var editsEnabled: Bool {
    UserDefaults(suiteName: "teleportlabs.com.Dayflow")?
      .bool(forKey: "agentEditsEnabled") ?? false
  }

  static var appIsListening: Bool {
    FileManager.default.fileExists(atPath: socketPath)
  }

  struct BridgeError: Error {
    let code: String
    let message: String
  }

  /// Send one operation to the app and return its `data` payload.
  static func send(operation: String, arguments: [String: Any]) throws -> [String: Any] {
    #if os(Linux)
    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    #endif
    guard fd >= 0 else {
      throw BridgeError(code: "socket_error", message: "Could not create a socket.")
    }
    defer { close(fd) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = socketPath
    guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
      throw BridgeError(code: "socket_error", message: "Socket path too long.")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      path.utf8CString.withUnsafeBytes { source in
        buffer.copyBytes(from: source.prefix(buffer.count))
      }
    }

    let connectResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connectResult == 0 else {
      throw BridgeError(
        code: "app_not_running",
        message: "Dayflow isn't running. Reads work offline; edits need the app open.")
    }

    let request: [String: Any] = [
      "protocol_version": protocolVersion,
      "operation": operation,
      "arguments": arguments,
    ]
    var payload = try JSONSerialization.data(withJSONObject: request)
    payload.append(0x0A)
    payload.withUnsafeBytes { buffer in
      _ = write(fd, buffer.baseAddress, buffer.count)
    }

    // Read until newline or EOF.
    var response = Data()
    var byte: UInt8 = 0
    while read(fd, &byte, 1) == 1 {
      if byte == 0x0A { break }
      response.append(byte)
      if response.count > 1_048_576 {
        throw BridgeError(code: "protocol_error", message: "Response too large.")
      }
    }

    guard
      let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any]
    else {
      throw BridgeError(code: "protocol_error", message: "Unreadable response from Dayflow.")
    }

    if object["ok"] as? Bool == true {
      return object["data"] as? [String: Any] ?? [:]
    }
    let errorInfo = object["error"] as? [String: Any]
    throw BridgeError(
      code: errorInfo?["code"] as? String ?? "unknown",
      message: errorInfo?["message"] as? String ?? "Dayflow reported an error."
    )
  }
}
