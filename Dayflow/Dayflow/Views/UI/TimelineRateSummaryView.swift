//
//  TimelineRateSummaryView.swift
//  Dayflow
//
//  Lightweight footer for rating a generated summary.
//

import SwiftUI

enum TimelineRatingDirection: String, Codable, Sendable {
  case up
  case down
}

private enum TimelineDeleteButtonState: Equatable {
  case idle
  case confirming
  case deleting
}

struct ThumbRatingButtons: View {
  var selectedDirection: TimelineRatingDirection?
  var isEnabled: Bool = true
  var onRate: (TimelineRatingDirection) -> Void

  @Environment(\.dayflowTheme) private var theme
  @Environment(\.stylePreviewAfter) private var stylePreviewAfter

  private var usesDarkChrome: Bool { stylePreviewAfter && theme.isDark }

  var body: some View {
    HStack(spacing: 0) {
      rateButton(for: .up)
      rateButton(for: .down)
    }
  }

  @ViewBuilder
  private func rateButton(for direction: TimelineRatingDirection) -> some View {
    let isSelected = selectedDirection == direction
    Button(action: {
      guard isEnabled else { return }
      onRate(direction)
    }) {
      Image("ThumbsUp")
        .renderingMode(usesDarkChrome ? .template : .original)
        .resizable()
        .scaledToFit()
        .frame(width: 14, height: 14)
        .scaleEffect(x: direction == .down ? -1 : 1, y: direction == .down ? -1 : 1)
        .foregroundColor(usesDarkChrome ? Color.white.opacity(0.75) : nil)
        .padding(4)
        .frame(width: 22, height: 22)
        .background(
          Circle()
            .fill(
              isSelected
                ? (usesDarkChrome ? Color.white.opacity(0.2) : Color.white)
                : Color.clear
            )
            .shadow(
              color: isSelected && !usesDarkChrome ? Color.black.opacity(0.08) : Color.clear,
              radius: 6, x: 0, y: 3)
        )
    }
    .buttonStyle(.plain)
    .contentShape(Rectangle())
    .hoverScaleEffect(enabled: isEnabled, scale: 1.02)
    .pointingHandCursorOnHover(enabled: isEnabled, reassertOnPressEnd: true)
    .accessibilityLabel(direction == .up ? Text("Thumbs up") : Text("Thumbs down"))
  }
}

struct TimelineRateSummaryView: View {

  var title: String = "Rate this summary"
  var isEnabled: Bool = true
  var activityID: String? = nil
  var onRate: ((TimelineRatingDirection) -> Void)? = nil
  var onDelete: (() -> Void)? = nil

  @Environment(\.dayflowTheme) private var theme
  @Environment(\.stylePreviewAfter) private var stylePreviewAfter

  @State private var selectedDirection: TimelineRatingDirection? = nil
  @State private var deleteButtonState: TimelineDeleteButtonState = .idle
  @State private var deleteResetTask: Task<Void, Never>? = nil

  private var usesDarkChrome: Bool { stylePreviewAfter && theme.isDark }

  private var canDelete: Bool {
    isEnabled && onDelete != nil && deleteButtonState != .deleting
  }

  var body: some View {
    HStack(alignment: .center, spacing: 0) {
      HStack(spacing: 8) {
        Text(title)
          .font(Font.custom("Figtree", size: 12).weight(.medium))
          .foregroundColor(
            (usesDarkChrome
              ? Color.white.opacity(0.9)
              : Color(red: 0.49, green: 0.47, blue: 0.46))
              .opacity(isEnabled ? 0.95 : 0.45)
          )

        ThumbRatingButtons(selectedDirection: selectedDirection, isEnabled: isEnabled) {
          direction in
          withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            selectedDirection = direction
          }
          onRate?(direction)
        }
      }

      Spacer(minLength: 0)

      if onDelete != nil {
        deleteButton
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 3)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      usesDarkChrome ? Color(hex: "494B5B") : Color(red: 0.98, green: 0.98, blue: 0.98)
    )
    .overlay(
      Rectangle()
        .inset(by: 0.5)
        .stroke(
          usesDarkChrome
            ? Color.white.opacity(0.08)
            : Color(red: 0.93, green: 0.93, blue: 0.93),
          lineWidth: 1
        )
    )
    .shadow(
      color: usesDarkChrome
        ? Color(red: 39 / 255, green: 47 / 255, blue: 67 / 255).opacity(0.5)
        : Color.white.opacity(1.0),
      radius: usesDarkChrome ? 18 : 9, x: 0, y: -4
    )
    .opacity(isEnabled ? 1 : 0.6)
    .onChange(of: activityID) {
      selectedDirection = nil
      deleteResetTask?.cancel()
      deleteButtonState = .idle
    }
    .onDisappear {
      deleteResetTask?.cancel()
    }
  }

  private var deleteButton: some View {
    let transition = AnyTransition.opacity.combined(with: .scale(scale: 0.5))
    let idleText = usesDarkChrome ? theme.accentText : Color(hex: "C05C54")
    let idleIconTextOpacity = 0.9
    let confirmBackground = Color(hex: "DF6055")
    let confirmStroke = Color(hex: "CB4E43")
    let isConfirmVisualState = deleteButtonState != .idle

    return Button(action: handleDeleteTap) {
      ZStack {
        if deleteButtonState == .deleting {
          ProgressView()
            .scaleEffect(0.55)
            .progressViewStyle(CircularProgressViewStyle(tint: .white))
            .transition(transition)
        } else if deleteButtonState == .confirming {
          Text("Confirm")
            .font(Font.custom("Figtree", size: 12).weight(.medium))
            .transition(transition)
        } else {
          Text("Delete")
            .font(Font.custom("Figtree", size: 12).weight(.medium))
            .transition(transition)
        }
      }
      .padding(.horizontal, isConfirmVisualState ? 9 : 0)
      .frame(height: 18)
      .foregroundColor(
        isConfirmVisualState
          ? .white
          : idleText.opacity(idleIconTextOpacity)
      )
      .background(
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(isConfirmVisualState ? confirmBackground : Color.clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .inset(by: 0.38)
          .stroke(
            isConfirmVisualState ? confirmStroke : .clear,
            lineWidth: 0.75
          )
      )
      // Keep the visual compact while expanding the click target.
      .contentShape(Rectangle().inset(by: -6))
    }
    .frame(height: 22, alignment: .center)
    .buttonStyle(.plain)
    .disabled(!canDelete)
    .hoverScaleEffect(enabled: canDelete, scale: 1.02)
    .pointingHandCursorOnHover(enabled: canDelete, reassertOnPressEnd: true)
    .animation(.easeInOut(duration: 0.22), value: deleteButtonState)
    .accessibilityLabel(
      Text(
        deleteButtonState == .confirming
          ? "Confirm delete activity card"
          : "Delete activity card"
      )
    )
  }

  private func handleDeleteTap() {
    guard onDelete != nil, isEnabled else { return }

    deleteResetTask?.cancel()

    switch deleteButtonState {
    case .idle:
      withAnimation(.easeInOut(duration: 0.22)) {
        deleteButtonState = .confirming
      }
      deleteResetTask = Task {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard !Task.isCancelled else { return }
        await MainActor.run {
          guard deleteButtonState == .confirming else { return }
          withAnimation(.easeInOut(duration: 0.22)) {
            deleteButtonState = .idle
          }
        }
      }
    case .confirming:
      withAnimation(.easeInOut(duration: 0.22)) {
        deleteButtonState = .deleting
      }
      onDelete?()
      deleteResetTask = Task {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard !Task.isCancelled else { return }
        await MainActor.run {
          guard deleteButtonState == .deleting else { return }
          withAnimation(.easeInOut(duration: 0.22)) {
            deleteButtonState = .idle
          }
        }
      }
    case .deleting:
      break
    }
  }

}

#Preview("TimelineRateSummaryView", traits: .sizeThatFitsLayout) {
  TimelineRateSummaryView()
    .padding()
}
