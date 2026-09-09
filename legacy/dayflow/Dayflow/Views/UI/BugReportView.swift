import AppKit
import SwiftUI

/// The "Report" tab: an in-app support chat (PostHog Support) with email,
/// Discord, and calendar links underneath for people who prefer those.
struct BugReportView: View {
  @Environment(\.dayflowTheme) private var theme
  @Environment(\.stylePreviewAfter) private var stylePreviewAfter

  /// "After" softens the button borders; "Before" keeps the shipped look.
  private var buttonBorderColor: Color {
    stylePreviewAfter
      ? (theme.isDark ? Color(hex: "777777") : Color(hex: "D0D0D0"))
      : theme.textPrimary
  }

  private let emailAddress = "jerry@dayflow.so"
  private let discordInviteURL = URL(string: "https://discord.gg/9YPAtctE6k")
  private let callBookingURL = URL(string: "https://cal.com/jerry-liu/15min")

  @State private var chatState: ChatState = .loading
  @State private var didCopyEmail = false
  @State private var copyResetTask: DispatchWorkItem? = nil
  @State private var didCopyDebugLogs = false
  @State private var isCopyingDebugLogs = false
  @State private var debugCopyResetTask: DispatchWorkItem? = nil

  private enum ChatState {
    case loading
    case ready
    case unavailable
  }

  var body: some View {
    VStack(spacing: 24) {
      VStack(spacing: 10) {
        Text("Thanks for using Dayflow")
          .font(.custom("InstrumentSerif-Regular", size: 40))
          .foregroundColor(theme.textPrimary)

        Text(
          "Bugs, feedback, questions, anything. Send a note below and we'll reply right here. Debug logs come along by default so we can actually fix things; uncheck the box if you'd rather not."
        )
        .font(.custom("Figtree", size: 16))
        .foregroundColor(theme.textSecondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 520)
      }

      chatCard
        .frame(maxWidth: 680, maxHeight: .infinity)

      contactLinks
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.top, 48)
    .padding(.bottom, 28)
    .padding(.horizontal, 48)
    .onAppear {
      AnalyticsService.shared.screen("support_chat")
    }
  }

  // MARK: Chat

  private var chatCard: some View {
    let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
    return ZStack {
      SupportChatWebView(palette: SupportChatPalette.light) { event in
        switch event {
        case .ready:
          chatState = .ready
        case .unavailable:
          chatState = .unavailable
        }
      }
      .opacity(chatState == .unavailable ? 0 : 1)

      if chatState == .unavailable {
        unavailableNotice
      }
    }
    .background(shape.fill(theme.rightPanelFill))
    .overlay(shape.strokeBorder(theme.rightPanelBorder, lineWidth: 1))
    .clipShape(shape)
    .shadow(color: theme.rightPanelShadow, radius: 12, x: 0, y: 4)
  }

  private var unavailableNotice: some View {
    VStack(spacing: 14) {
      Image(systemName: "wifi.exclamationmark")
        .font(.system(size: 28, weight: .medium))
        .foregroundColor(theme.textMuted)
      Text("Chat isn't reachable right now")
        .font(.custom("Figtree", size: 17).weight(.semibold))
        .foregroundColor(theme.textPrimary)
      Text("Email works just as well. Copy the debug logs below and paste them in if you can.")
        .font(.custom("Figtree", size: 14))
        .foregroundColor(theme.textSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)
    }
    .padding(32)
  }

  // MARK: Links

  private var contactLinks: some View {
    HStack(spacing: 12) {
      linkButton(title: "Email", systemImage: "envelope.fill", action: composeEmail)

      DayflowSurfaceButton(
        action: openDiscord,
        content: {
          HStack(spacing: 9) {
            Image("DiscordGlyph")
              .resizable()
              .renderingMode(.original)
              .aspectRatio(contentMode: .fit)
              .frame(width: 18, height: 14)
            Text("Join Discord")
              .font(.custom("Figtree", size: 14).weight(.semibold))
          }
        },
        background: theme.secondaryButtonFill,
        foreground: theme.textPrimary,
        borderColor: buttonBorderColor,
        cornerRadius: 14,
        horizontalPadding: 18,
        verticalPadding: 11,
        showShadow: true
      )

      linkButton(title: "Book a call", systemImage: "calendar.badge.clock", action: bookCall)

      Spacer(minLength: 0)

      textButton(didCopyEmail ? "Copied!" : "Copy email", action: copyEmail)
      textButton(
        didCopyDebugLogs ? "Copied!" : (isCopyingDebugLogs ? "Preparing…" : "Copy debug logs"),
        action: copyDebugLogs
      )
    }
    .frame(maxWidth: 680)
  }

  private func linkButton(title: String, systemImage: String, action: @escaping () -> Void)
    -> some View
  {
    DayflowSurfaceButton(
      action: action,
      content: {
        HStack(spacing: 9) {
          Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
          Text(title)
            .font(.custom("Figtree", size: 14).weight(.semibold))
        }
      },
      background: theme.secondaryButtonFill,
      foreground: theme.textPrimary,
      borderColor: buttonBorderColor,
      cornerRadius: 14,
      horizontalPadding: 18,
      verticalPadding: 11,
      showShadow: true
    )
  }

  private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.custom("Figtree", size: 13).weight(.medium))
        .foregroundColor(theme.textMuted)
        .underline()
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }

  // MARK: Actions

  private func composeEmail() {
    AnalyticsService.shared.capture("bug_report_email_tapped", ["destination": emailAddress])

    var components = URLComponents()
    components.scheme = "mailto"
    components.path = emailAddress
    components.queryItems = [
      URLQueryItem(name: "subject", value: "Dayflow feedback")
    ]

    guard let url = components.url else { return }
    NSWorkspace.shared.open(url)
  }

  private func copyEmail() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(emailAddress, forType: .string)
    AnalyticsService.shared.capture("bug_report_email_copied")

    withAnimation(.easeOut(duration: 0.2)) {
      didCopyEmail = true
    }

    copyResetTask?.cancel()
    let work = DispatchWorkItem {
      withAnimation(.easeInOut(duration: 0.25)) {
        didCopyEmail = false
      }
      self.copyResetTask = nil
    }
    copyResetTask = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
  }

  private func openDiscord() {
    AnalyticsService.shared.capture("bug_report_discord_tapped")

    guard let url = discordInviteURL else { return }
    NSWorkspace.shared.open(url)
  }

  private func bookCall() {
    AnalyticsService.shared.capture("bug_report_call_tapped")

    guard let url = callBookingURL else { return }
    NSWorkspace.shared.open(url)
  }

  private func copyDebugLogs() {
    guard !isCopyingDebugLogs else { return }

    isCopyingDebugLogs = true

    Task.detached(priority: .userInitiated) {
      let snapshot = DebugLogSnapshot.makeCurrent()

      await MainActor.run {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snapshot.text, forType: .string)

        AnalyticsService.shared.capture(
          "bug_report_debug_logs_copied", snapshot.analyticsProperties)

        withAnimation(.easeOut(duration: 0.2)) {
          didCopyDebugLogs = true
        }

        debugCopyResetTask?.cancel()
        let work = DispatchWorkItem {
          withAnimation(.easeInOut(duration: 0.25)) {
            didCopyDebugLogs = false
          }
          self.debugCopyResetTask = nil
        }
        debugCopyResetTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)

        isCopyingDebugLogs = false
      }
    }
  }
}

#Preview {
  BugReportView()
}
