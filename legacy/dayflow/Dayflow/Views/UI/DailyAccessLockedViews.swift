import SwiftUI

struct DailyAccessIntroView: View {
  @Environment(\.dayflowTheme) private var theme

  let betaNoticeCopy: String
  let progressText: String
  let canRequestAccess: Bool
  let onRequestAccess: () -> Void
  let onConfettiStart: () -> Void

  @State private var requestState: DailyAccessRequestState = .idle
  @State private var showsSuccessRing = false
  @State private var transitionTask: Task<Void, Never>? = nil

  private var stateChangeAnimation: Animation {
    .easeInOut(duration: 0.26)
  }

  private var successRingAnimation: Animation {
    .easeOut(duration: 0.24)
  }

  var body: some View {
    VStack(spacing: 18) {
      DailyAccessHeaderView()

      Text(betaNoticeCopy)
        .font(.custom("Figtree-Regular", size: 15))
        .foregroundColor(theme.textSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 480)
        .padding(.horizontal, 24)

      Text("Daily unlocks after 5 hours of analyzed timeline data. \(progressText)")
        .font(.custom("Figtree-SemiBold", size: 13))
        .foregroundColor(theme.textSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 460)
        .padding(.horizontal, 24)

      DailyAnimatedRequestAccessButton(
        requestState: requestState,
        showsSuccessRing: showsSuccessRing,
        isEnabled: canRequestAccess,
        stateChangeAnimation: stateChangeAnimation,
        successRingAnimation: successRingAnimation,
        onTap: animateRequestGranted
      )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    .onDisappear {
      transitionTask?.cancel()
      transitionTask = nil
    }
  }

  private func animateRequestGranted() {
    guard canRequestAccess else { return }
    guard requestState == .idle else { return }

    withAnimation(stateChangeAnimation) {
      requestState = .granted
    }

    withAnimation(successRingAnimation) {
      showsSuccessRing = true
    }

    onConfettiStart()

    transitionTask?.cancel()
    transitionTask = Task {
      let delayNanoseconds: UInt64 = 1_120_000_000
      try? await Task.sleep(nanoseconds: delayNanoseconds)

      guard !Task.isCancelled else { return }
      await MainActor.run {
        onRequestAccess()
      }
    }
  }
}

struct DailyNotificationOnboardingView: View {
  @Environment(\.dayflowTheme) private var theme

  let notificationPermissionMessage: String
  let notificationPermissionButtonTitle: String
  let isNotificationPermissionButtonDisabled: Bool
  let isNotificationRecheckButtonDisabled: Bool
  let onNotificationPermissionAction: () -> Void
  let onRecheckPermissions: () -> Void

  var body: some View {
    VStack(spacing: 18) {
      DailyAccessHeaderView()

      DailyNotificationPermissionPanelView(
        notificationPermissionMessage: notificationPermissionMessage,
        notificationPermissionButtonTitle: notificationPermissionButtonTitle,
        isNotificationPermissionButtonDisabled: isNotificationPermissionButtonDisabled,
        isNotificationRecheckButtonDisabled: isNotificationRecheckButtonDisabled,
        onNotificationPermissionAction: onNotificationPermissionAction,
        onRecheckPermissions: onRecheckPermissions
      )
    }
  }
}

struct DailyProviderOnboardingView: View {
  @Environment(\.dayflowTheme) private var theme

  let selectedProvider: DailyRecapProvider
  let providerAvailability: [DailyRecapProvider: DailyRecapProviderAvailability]
  let isRefreshingProviderAvailability: Bool
  let canContinue: Bool
  let onSelectProvider: (DailyRecapProvider) -> Void
  let onContinue: () -> Void

  var body: some View {
    VStack(spacing: 14) {
      DailyAccessHeaderView()

      VStack(spacing: 12) {
        VStack(spacing: 6) {
          Text("Pick your Daily provider")
            .font(.custom("InstrumentSerif-Regular", size: 24))
            .foregroundColor(theme.textPrimary)
            .multilineTextAlignment(.center)

          Text(
            "Choose how Daily generates your recap, or turn generation off. You can change this later."
          )
          .font(.custom("Figtree-Regular", size: 13))
          .foregroundColor(theme.textSecondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 420)
        }

        if isRefreshingProviderAvailability {
          ProgressView()
            .controlSize(.small)
            .tint(theme.accent)
        }

        VStack(spacing: 6) {
          ForEach(DailyRecapProvider.allCases, id: \.self) { provider in
            let availability =
              providerAvailability[provider]
              ?? DailyRecapProviderAvailability(
                isAvailable: true,
                detail: provider.pickerSubtitle
              )
            let isSelected = selectedProvider == provider

            Button {
              onSelectProvider(provider)
            } label: {
              HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                  Text(provider.displayName)
                    .font(.custom("Figtree-SemiBold", size: 13))
                    .foregroundStyle(theme.textPrimary)

                  Text(availability.detail)
                    .font(.custom("Figtree-Regular", size: 11))
                    .foregroundStyle(
                      availability.isAvailable ? theme.textSecondary : theme.textMuted
                    )
                    .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                  .font(.system(size: 13, weight: .semibold))
                  .foregroundStyle(isSelected ? theme.accent : theme.textMuted)
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
              .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                  .fill(isSelected ? theme.controlFill : theme.chipFill)
              )
              .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                  .stroke(
                    isSelected ? theme.controlBorder : theme.chipBorder,
                    lineWidth: 1
                  )
              )
              .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!availability.isAvailable)
            .pointingHandCursor(enabled: availability.isAvailable)
          }
        }

        DayflowSurfaceButton(
          action: onContinue,
          content: {
            Text("Continue to Daily")
              .font(.custom("Figtree", size: 14))
              .fontWeight(.semibold)
          },
          background: theme.primaryButtonFill,
          foreground: theme.primaryButtonText,
          borderColor: .clear,
          cornerRadius: 10,
          horizontalPadding: 20,
          verticalPadding: 10,
          showOverlayStroke: true
        )
        .disabled(!canContinue)
        .pointingHandCursor(enabled: canContinue)
      }
      .padding(.horizontal, 28)
      .padding(.vertical, 24)
      .frame(maxWidth: 460)
      .background(
        RoundedRectangle(cornerRadius: 24, style: .continuous)
          .fill(theme.summaryCardFill)
          .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
              .stroke(theme.summaryCardBorder, lineWidth: 1)
          )
      )
      .shadow(color: Color.black.opacity(0.08), radius: 14, x: 0, y: 6)
    }
  }
}

private struct DailyAccessHeaderView: View {
  @Environment(\.dayflowTheme) private var theme

  var body: some View {
    HStack(alignment: .top, spacing: 4) {
      Text("Dayflow Daily")
        .font(.custom("InstrumentSerif-Italic", size: 38))
        .foregroundColor(theme.textPrimary)

      Text("BETA")
        .font(.custom("Figtree-Bold", size: 11))
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(Color(red: 0.98, green: 0.55, blue: 0.20))
        )
        .rotationEffect(.degrees(-12))
        .offset(x: -4, y: -4)
    }
  }
}

private enum DailyAccessRequestState {
  case idle
  case granted
}

private struct DailyAnimatedRequestAccessButton: View {
  @Environment(\.dayflowTheme) private var theme

  let requestState: DailyAccessRequestState
  let showsSuccessRing: Bool
  let isEnabled: Bool
  let stateChangeAnimation: Animation
  let successRingAnimation: Animation
  let onTap: () -> Void

  private var backgroundColor: Color {
    guard isEnabled else {
      return theme.textMuted
    }
    return theme.primaryButtonFill
  }

  private var buttonScale: CGFloat {
    return requestState == .granted ? 1.015 : 1
  }

  var body: some View {
    Button(action: onTap) {
      ZStack {
        Capsule()
          .stroke(Color.white.opacity(0.24), lineWidth: 1.5)
          .scaleEffect(showsSuccessRing ? 1.08 : 0.96)
          .opacity(showsSuccessRing ? 0 : 0.65)

        RoundedRectangle(cornerRadius: 10)
          .fill(backgroundColor)
          .overlay(
            RoundedRectangle(cornerRadius: 10)
              .stroke(Color.white.opacity(0.16), lineWidth: 1.5)
          )
          .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
          .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)

        ZStack {
          Text("Unlock Daily")
            .font(.custom("Figtree", size: 15))
            .fontWeight(.semibold)
            .foregroundColor(.white)
            .opacity(requestState == .idle ? 1 : 0)
            .offset(y: requestState == .idle ? 0 : -5)

          HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 14, weight: .semibold))
            Text("Daily Unlocked")
              .font(.custom("Figtree", size: 15))
              .fontWeight(.semibold)
          }
          .foregroundColor(.white)
          .opacity(requestState == .granted ? 1 : 0)
          .offset(y: requestState == .granted ? 0 : 5)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 13)
      }
      .compositingGroup()
      .fixedSize()
      .scaleEffect(buttonScale)
      .animation(stateChangeAnimation, value: requestState)
      .animation(successRingAnimation, value: showsSuccessRing)
    }
    .buttonStyle(.plain)
    .disabled(requestState == .granted || !isEnabled)
    .pointingHandCursor(enabled: requestState == .idle && isEnabled)
  }
}

private struct DailyNotificationPermissionPanelView: View {
  @Environment(\.dayflowTheme) private var theme

  let notificationPermissionMessage: String
  let notificationPermissionButtonTitle: String
  let isNotificationPermissionButtonDisabled: Bool
  let isNotificationRecheckButtonDisabled: Bool
  let onNotificationPermissionAction: () -> Void
  let onRecheckPermissions: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      Text("Turn on notifications to unlock Daily")
        .font(.custom("InstrumentSerif-Regular", size: 30))
        .foregroundColor(theme.accentText)
        .multilineTextAlignment(.center)

      Text("Dayflow uses notifications to tell you when your recap is ready.")
        .font(.custom("Figtree-SemiBold", size: 16))
        .foregroundColor(theme.textPrimary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)

      Text(notificationPermissionMessage)
        .font(.custom("Figtree-Regular", size: 14))
        .foregroundColor(theme.textSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 430)

      VStack(spacing: 10) {
        DayflowSurfaceButton(
          action: onNotificationPermissionAction,
          content: {
            Text(notificationPermissionButtonTitle)
              .font(.custom("Figtree", size: 15))
              .fontWeight(.semibold)
          },
          background: theme.primaryButtonFill,
          foreground: theme.primaryButtonText,
          borderColor: .clear,
          cornerRadius: 10,
          horizontalPadding: 24,
          verticalPadding: 12,
          showOverlayStroke: true
        )
        .disabled(isNotificationPermissionButtonDisabled)
        .pointingHandCursor(enabled: !isNotificationPermissionButtonDisabled)

        DayflowSurfaceButton(
          action: onRecheckPermissions,
          content: {
            Text("Recheck permissions")
              .font(.custom("Figtree", size: 14))
              .fontWeight(.semibold)
          },
          background: theme.secondaryButtonFill,
          foreground: theme.secondaryButtonText,
          borderColor: theme.secondaryButtonBorder,
          cornerRadius: 10,
          horizontalPadding: 20,
          verticalPadding: 11,
          isSecondaryStyle: true
        )
        .disabled(isNotificationRecheckButtonDisabled)
        .pointingHandCursor(enabled: !isNotificationRecheckButtonDisabled)
      }
    }
    .padding(.horizontal, 34)
    .padding(.vertical, 30)
    .frame(maxWidth: 560)
    .background(
      RoundedRectangle(cornerRadius: 28, style: .continuous)
        .fill(theme.summaryCardFill)
        .overlay(
          RoundedRectangle(cornerRadius: 28, style: .continuous)
            .stroke(theme.summaryCardBorder, lineWidth: 1)
        )
    )
    .shadow(color: Color.black.opacity(0.08), radius: 18, x: 0, y: 8)
  }
}
