import AppKit
import Charts
import SwiftUI

// MARK: - Work Status Card

struct WorkStatusCard: View {
  let status: ChatWorkStatus
  @Binding var showDetails: Bool

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 10) {
        header

        if status.stage == .error, let message = status.errorMessage, !message.isEmpty {
          Text(message)
            .font(.custom("Nunito", size: 12).weight(.semibold))
            .foregroundColor(Color(hex: "C62828"))
        }

        if !status.tools.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(status.tools) { tool in
              ToolStatusRow(tool: tool, showDetails: showDetails)
            }
          }
        }

        if status.hasDetails {
          Button(action: { showDetails.toggle() }) {
            HStack(spacing: 4) {
              Text(showDetails ? "Hide details" : "Show details")
              Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
            }
            .font(.custom("Nunito", size: 11).weight(.semibold))
            .foregroundColor(Color(hex: "8B5E3C"))
          }
          .buttonStyle(DayflowPressScaleButtonStyle(pressedScale: 0.97))
          .pointingHandCursor()
        }

        if showDetails, !status.thinkingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          Text(status.thinkingText.trimmingCharacters(in: .whitespacesAndNewlines))
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(Color(hex: "666666"))
            .textSelection(.enabled)
            .padding(8)
            .background(Color(hex: "FFFFFF").opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .background(backgroundColor)
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(borderColor, lineWidth: 1)
      )

      Spacer(minLength: 60)
    }
  }

  var header: some View {
    HStack(spacing: 6) {
      Image(systemName: headerIcon)
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(accentColor)
        .frame(width: 14, height: 14, alignment: .center)

      HStack(spacing: 0) {
        Text(headerTitle)
        if showsEllipsis {
          AnimatedEllipsis()
        }
      }
      .font(.custom("Nunito", size: 12).weight(.semibold))
      .foregroundColor(Color(hex: "4A4A4A"))

      Spacer()
    }
  }

  var headerTitle: String {
    switch status.stage {
    case .thinking:
      return "Thinking"
    case .runningTools:
      return "Running tools"
    case .answering:
      return "Answering"
    case .error:
      return "Something went wrong"
    }
  }

  var showsEllipsis: Bool {
    switch status.stage {
    case .thinking, .runningTools, .answering:
      return true
    case .error:
      return false
    }
  }

  var headerIcon: String {
    switch status.stage {
    case .thinking:
      return "sparkles"
    case .runningTools:
      return "wrench.and.screwdriver"
    case .answering:
      return "text.bubble"
    case .error:
      return "exclamationmark.triangle.fill"
    }
  }

  var accentColor: Color {
    switch status.stage {
    case .error:
      return Color(hex: "C62828")
    default:
      return Color(hex: "F96E00")
    }
  }

  var backgroundColor: Color {
    switch status.stage {
    case .error:
      return Color(hex: "FFEBEE")
    default:
      return Color(hex: "FFF4E9")
    }
  }

  var borderColor: Color {
    switch status.stage {
    case .error:
      return Color(hex: "FFCDD2")
    default:
      return Color(hex: "F96E00").opacity(0.2)
    }
  }
}

struct AnimatedEllipsis: View {
  let interval: TimeInterval = 0.45

  var body: some View {
    TimelineView(.periodic(from: .now, by: interval)) { context in
      let step = Int(context.date.timeIntervalSinceReferenceDate / interval) % 3 + 1
      Text(String(repeating: ".", count: step))
        .accessibilityHidden(true)
    }
  }
}

struct ToolStatusRow: View {
  let tool: ChatWorkStatus.ToolRun
  let showDetails: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        statusIcon
          .frame(width: 14, height: 14, alignment: .center)
        Text(tool.summary)
          .font(.custom("Nunito", size: 12).weight(.semibold))
          .foregroundColor(textColor)
      }

      if showDetails {
        Text(tool.command)
          .font(.system(size: 10, design: .monospaced))
          .foregroundColor(Color(hex: "666666"))
          .textSelection(.enabled)
          .lineLimit(3)

        if !trimmedOutput.isEmpty {
          Text(trimmedOutput)
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(Color(hex: "555555"))
            .lineLimit(6)
            .textSelection(.enabled)
            .padding(6)
            .background(Color(hex: "FFFFFF").opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
      }
    }
  }

  var trimmedOutput: String {
    tool.output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  @ViewBuilder
  var statusIcon: some View {
    switch tool.state {
    case .running:
      ProgressView()
        .scaleEffect(0.6)
        .tint(Color(hex: "F96E00"))
    case .completed:
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(Color(hex: "34C759"))
    case .failed:
      Image(systemName: "xmark.circle.fill")
        .font(.system(size: 12, weight: .semibold))
        .foregroundColor(Color(hex: "C62828"))
    }
  }

  var textColor: Color {
    switch tool.state {
    case .failed:
      return Color(hex: "C62828")
    default:
      return Color(hex: "4A4A4A")
    }
  }
}
