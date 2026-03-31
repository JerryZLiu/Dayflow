import Foundation

@MainActor
final class AppDeepLinkRouter {
  enum Action: String {
    case startRecording = "start-recording"
    case stopRecording = "stop-recording"

    init?(identifier: String) {
      switch identifier.lowercased() {
      case Self.startRecording.rawValue, "start", "resume":
        self = .startRecording
      case Self.stopRecording.rawValue, "stop", "pause":
        self = .stopRecording
      default:
        return nil
      }
    }
  }

  init() {}

  @discardableResult
  func handle(_ url: URL) -> Bool {
    guard let action = resolveAction(from: url) else {
      print("[DeepLink] Unsupported URL: \(url.absoluteString)")
      return false
    }

    perform(action)
    return true
  }

  private func resolveAction(from url: URL) -> Action? {
    guard let scheme = url.scheme, scheme.caseInsensitiveCompare("dayflow") == .orderedSame else {
      return nil
    }

    var candidates: [String] = []
    if let host = url.host, !host.isEmpty {
      candidates.append(host)
    }

    let pathComponents = url.path
      .split(separator: "/")
      .map { String($0) }

    candidates.append(contentsOf: pathComponents)

    if candidates.isEmpty {
      if let actionItem = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
        .first(where: { $0.name.lowercased() == "action" }),
        let value = actionItem.value, !value.isEmpty
      {
        candidates.append(value)
      }
    }

    guard let identifier = candidates.first else { return nil }
    return Action(identifier: identifier)
  }

  private func perform(_ action: Action) {
    switch action {
    case .startRecording:
      startRecording()
    case .stopRecording:
      stopRecording()
    }
  }

  private func startRecording() {
    guard RecordingControl.currentMode() != .active else {
      print("[DeepLink] Recording already active; ignoring start request")
      return
    }
    RecordingControl.start(reason: "deeplink")
  }

  private func stopRecording() {
    guard RecordingControl.currentMode() != .stopped else {
      print("[DeepLink] Recording already stopped; ignoring stop request")
      return
    }
    RecordingControl.stop(reason: "deeplink")
  }

}
