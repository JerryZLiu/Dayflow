import AppKit
import CoreGraphics
import Foundation

enum ScreenRecordingPermissionNotice {
  private static let history = ScreenCapturePermissionHistory()

  static var isGranted: Bool {
    CGPreflightScreenCaptureAccess()
  }

  static var permissionWasGranted: Bool {
    history.wasGranted
  }

  static func post(reason: String) {
    let notification = {
      NotificationCenter.default.post(
        name: .showScreenRecordingPermissionNotice,
        object: nil,
        userInfo: ["reason": reason]
      )
    }

    if Thread.isMainThread {
      notification()
    } else {
      DispatchQueue.main.async(execute: notification)
    }
  }

  static func postAuthorizationState(
    _ state: ScreenCaptureAuthorizationState,
    reason: String
  ) {
    let notification = {
      NotificationCenter.default.post(
        name: .screenCaptureAuthorizationStateChanged,
        object: state,
        userInfo: ["reason": reason]
      )
    }

    if Thread.isMainThread {
      notification()
    } else {
      DispatchQueue.main.async(execute: notification)
    }
  }

  static func openSystemSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    else { return }

    NSWorkspace.shared.open(url)
  }
}
