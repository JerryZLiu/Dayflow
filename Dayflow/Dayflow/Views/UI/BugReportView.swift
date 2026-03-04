import AppKit
import SwiftUI

struct BugReportView: View {
  private let emailAddress = "liu.z.jerry@gmail.com"
  private let discordInviteURL = URL(string: "https://discord.gg/9YPAtctE6k")
  private let callBookingURL = URL(string: "https://cal.com/jerry-liu/15min")
  @State private var didCopyEmail = false
  @State private var copyResetTask: DispatchWorkItem? = nil
  @State private var didCopyDebugLogs = false
  @State private var isCopyingDebugLogs = false
  @State private var debugCopyResetTask: DispatchWorkItem? = nil

  var body: some View {
    VStack(spacing: 36) {
      VStack(spacing: 16) {
        Text("Thanks for using Dayflow")
          .font(.custom("InstrumentSerif-Regular", size: 40))
          .foregroundColor(.black.opacity(0.9))

        Text(
          "Email works great if you want to drop a quick note, Discord if you want to join the community, and if you’d prefer to chat, find some time on my calendar - I’d love to dig into why Dayflow is or isn’t working well for you."
        )
        .font(.custom("Nunito", size: 16))
        .foregroundColor(.black.opacity(0.65))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 520)
      }
      VStack(spacing: 24) {
        VStack(spacing: 12) {
          Text("Reach out")
            .font(.custom("Nunito", size: 14).weight(.medium))
            .foregroundColor(.black.opacity(0.55))
            .textCase(.uppercase)
            .tracking(0.75)

          HStack(spacing: 16) {
            DayflowSurfaceButton(
              action: composeEmail,
              content: {
                HStack(spacing: 12) {
                  Image(systemName: "envelope.fill")
                    .font(.system(size: 18, weight: .semibold))
                  Text("Email")
                    .font(.custom("Nunito", size: 16).weight(.semibold))
                }
              },
              background: Color.white,
              foreground: Color.black,
              borderColor: Color.black.opacity(0.12),
              cornerRadius: 18,
              horizontalPadding: 28,
              verticalPadding: 16,
              showShadow: true
            )

            DayflowSurfaceButton(
              action: openDiscord,
              content: {
                HStack(spacing: 12) {
                  Image("DiscordGlyph")
                    .resizable()
                    .renderingMode(.original)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 18)
                  Text("Join Discord")
                    .font(.custom("Nunito", size: 16).weight(.semibold))
                }
              },
              background: Color.white,
              foreground: Color.black,
              borderColor: Color.black.opacity(0.12),
              cornerRadius: 18,
              horizontalPadding: 28,
              verticalPadding: 16,
              showShadow: true
            )

            DayflowSurfaceButton(
              action: bookCall,
              content: {
                HStack(spacing: 12) {
                  Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 18, weight: .semibold))
                  Text("Calendar")
                    .font(.custom("Nunito", size: 16).weight(.semibold))
                }
              },
              background: Color.white,
              foreground: Color.black,
              borderColor: Color.black.opacity(0.12),
              cornerRadius: 18,
              horizontalPadding: 28,
              verticalPadding: 16,
              showShadow: true
            )
          }
        }

        VStack(spacing: 12) {
          Text("Quick utilities")
            .font(.custom("Nunito", size: 14).weight(.medium))
            .foregroundColor(.black.opacity(0.55))
            .textCase(.uppercase)
            .tracking(0.75)

          HStack(spacing: 16) {
            DayflowSurfaceButton(
              action: copyEmail,
              content: {
                HStack(spacing: 10) {
                  Image(systemName: "doc.on.doc")
                    .font(.system(size: 16, weight: .semibold))
                  Text(didCopyEmail ? "Copied!" : "Copy email")
                    .font(.custom("Nunito", size: 15).weight(.semibold))
                }
              },
              background: Color.white,
              foreground: Color.black,
              borderColor: Color.black.opacity(0.12),
              cornerRadius: 14,
              horizontalPadding: 22,
              verticalPadding: 14,
              showShadow: true
            )
            .opacity(didCopyEmail ? 0.85 : 1.0)

            DayflowSurfaceButton(
              action: copyDebugLogs,
              content: {
                HStack(spacing: 10) {
                  Image(systemName: "ladybug.fill")
                    .font(.system(size: 16, weight: .semibold))
                  Text(
                    didCopyDebugLogs
                      ? "Copied!" : (isCopyingDebugLogs ? "Preparing..." : "Copy debug logs")
                  )
                  .font(.custom("Nunito", size: 15).weight(.semibold))
                }
              },
              background: Color.white,
              foreground: Color.black,
              borderColor: Color.black.opacity(0.12),
              cornerRadius: 14,
              horizontalPadding: 20,
              verticalPadding: 14,
              showShadow: true
            )
            .opacity(didCopyDebugLogs ? 0.85 : 1.0)
          }
        }
      }
      .padding(.horizontal, 8)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.top, 100)
    .padding(.horizontal, 48)
  }

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

    Task {
      // Fetch recent timeline cards first
      let timeline = StorageManager.shared.fetchRecentTimelineCardsForDebug(limit: 5)

      // Extract unique batch IDs from timeline cards
      let batchIds = Array(Set(timeline.compactMap { $0.batchId }))

      // Fetch LLM calls, falling back to global recent calls if we have no timeline batches
      let llmCalls: [LLMCallDebugEntry]
      let llmCallSource: String
      if batchIds.isEmpty {
        llmCalls = StorageManager.shared.fetchRecentLLMCallsForDebug(limit: 20)
        llmCallSource = "global"
      } else {
        llmCalls = StorageManager.shared.fetchLLMCallsForBatches(batchIds: batchIds, limit: 100)
        llmCallSource = "timeline_batches"
      }

      let batches = StorageManager.shared.fetchRecentAnalysisBatchesForDebug(limit: 5)

      let logString = DebugLogFormatter.makeLog(
        timeline: timeline, llmCalls: llmCalls, batches: batches)

      await MainActor.run {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(logString, forType: .string)

        AnalyticsService.shared.capture(
          "bug_report_debug_logs_copied",
          [
            "timeline_count": timeline.count,
            "llm_call_count": llmCalls.count,
            "llm_call_source": llmCallSource,
            "batch_count": batches.count,
          ]
        )

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
