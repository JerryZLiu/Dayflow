import Foundation

/// The entry point. Dayflow's own executable doubles as the Privacy Shield helper process
/// (`PrivacyShieldHelper`): started with its flag, it runs the text check and never shows any UI.
@main
enum DayflowMain {
  static func main() {
    if CommandLine.arguments.contains(PrivacyShieldHelper.launchArgument) {
      PrivacyShieldHelper.runHelperProcess()
    }
    DayflowApp.main()
  }
}
