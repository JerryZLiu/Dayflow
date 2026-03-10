import Foundation

@MainActor
final class RecordingResumeNotificationCoordinator {
  static let shared = RecordingResumeNotificationCoordinator()

  private var pendingAutoResumeSource: ResumeSource?

  private init() {}

  func markPendingAutoResume(source: ResumeSource) {
    pendingAutoResumeSource = source
  }

  func consumePendingAutoResumeSource() -> ResumeSource? {
    let source = pendingAutoResumeSource
    pendingAutoResumeSource = nil
    return source
  }

  func clearPendingAutoResume() {
    pendingAutoResumeSource = nil
  }
}
