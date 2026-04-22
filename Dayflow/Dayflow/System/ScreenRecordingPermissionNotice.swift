import AppKit
import CoreGraphics
import Foundation

enum ScreenRecordingPermissionNotice {
  static var isGranted: Bool {
    CGPreflightScreenCaptureAccess()
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

  static func openSystemSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    else { return }

    NSWorkspace.shared.open(url)
  }
}
