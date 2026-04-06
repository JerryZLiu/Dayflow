import SwiftUI

struct DailyAccessIntroView: View {
  let betaNoticeCopy: String
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
        .font(.custom("Nunito-Regular", size: 15))
        .foregroundColor(Color(red: 0.35, green: 0.22, blue: 0.12).opacity(0.8))
        .multilineTextAlignment(.center)
        .frame(maxWidth: 480)
        .padding(.horizontal, 24)

      DailyAnimatedRequestAccessButton(
        requestState: requestState,
        showsSuccessRing: showsSuccessRing,
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
            .foregroundColor(Color(red: 0.35, green: 0.22, blue: 0.12))
            .multilineTextAlignment(.center)

          Text("Choose which model generates your daily recap. You can change this later.")
            .font(.custom("Nunito-Regular", size: 13))
            .foregroundColor(Color(red: 0.35, green: 0.22, blue: 0.12).opacity(0.8))
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
        }

        if isRefreshingProviderAvailability {
          ProgressView()
            .controlSize(.small)
            .tint(Color(hex: "B46531"))
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
                    .font(.custom("Nunito-SemiBold", size: 13))
                    .foregroundStyle(Color(hex: isSelected ? "8F522C" : "2F241D"))

                  Text(availability.detail)
                    .font(.custom("Nunito-Regular", size: 11))
                    .foregroundStyle(Color(hex: availability.isAvailable ? "8B6B59" : "B07A74"))
                    .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                  .font(.system(size: 13, weight: .semibold))
                  .foregroundStyle(
                    isSelected ? Color(hex: "C96F3A") : Color(hex: "D3C6BE")
                  )
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
              .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                  .fill(
                    isSelected
                      ? Color(hex: "FFF4EC")
                      : Color(hex: "FAF8F7")
                  )
              )
              .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                  .stroke(
                    isSelected ? Color(hex: "EBC4AB") : Color(hex: "E8E1DC"),
                    lineWidth: 1.2
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
              .font(.custom("Nunito", size: 14))
              .fontWeight(.semibold)
          },
          background: Color(red: 0.25, green: 0.17, blue: 0),
          foreground: .white,
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
          .fill(
            LinearGradient(
              colors: [
                Color.white.opacity(0.72),
                Color(red: 1.0, green: 0.93, blue: 0.89).opacity(0.58),
              ],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
          .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
              .stroke(Color.white.opacity(0.58), lineWidth: 1)
          )
      )
      .shadow(color: Color.black.opacity(0.08), radius: 14, x: 0, y: 6)
    }
  }
}

private struct DailyAccessHeaderView: View {
  var body: some View {
    HStack(alignment: .top, spacing: 4) {
      Text("Dayflow Daily")
        .font(.custom("InstrumentSerif-Italic", size: 38))
        .foregroundColor(Color(red: 0.35, green: 0.22, blue: 0.12))

      Text("BETA")
        .font(.custom("Nunito-Bold", size: 11))
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
  let requestState: DailyAccessRequestState
  let showsSuccessRing: Bool
  let stateChangeAnimation: Animation
  let successRingAnimation: Animation
  let onTap: () -> Void

  private var backgroundColor: Color {
    switch requestState {
    case .idle:
      return Color(red: 0.25, green: 0.17, blue: 0)
    case .granted:
      return Color(red: 0.34, green: 0.24, blue: 0.05)
    }
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
            .font(.custom("Nunito", size: 15))
            .fontWeight(.semibold)
            .foregroundColor(.white)
            .opacity(requestState == .idle ? 1 : 0)
            .offset(y: requestState == .idle ? 0 : -5)

          HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 14, weight: .semibold))
            Text("Daily Unlocked")
              .font(.custom("Nunito", size: 15))
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
    .disabled(requestState == .granted)
    .pointingHandCursor(enabled: requestState == .idle)
  }
}

struct DailyPageConfettiOverlay: View {
  let progress: CGFloat

  let origin: CGPoint

  private static let pieces: [DailyRequestConfettiPiece] = [
    .init(
      x: -320, y: -250, rotation: -180, size: CGSize(width: 12, height: 18),
      color: Color(hex: "FF8A3D"), isCircle: false),
    .init(
      x: -286, y: -308, rotation: -144, size: CGSize(width: 10, height: 10),
      color: Color(hex: "59C3FF"), isCircle: true),
    .init(
      x: -236, y: -272, rotation: -118, size: CGSize(width: 11, height: 17),
      color: Color(hex: "FFD166"), isCircle: false),
    .init(
      x: -194, y: -330, rotation: -96, size: CGSize(width: 9, height: 9),
      color: Color(hex: "FF5C8A"), isCircle: true),
    .init(
      x: -152, y: -288, rotation: -70, size: CGSize(width: 10, height: 15),
      color: Color(hex: "6EE7B7"), isCircle: false),
    .init(
      x: -104, y: -346, rotation: -36, size: CGSize(width: 9, height: 9),
      color: Color(hex: "FFF3B0"), isCircle: true),
    .init(
      x: -56, y: -300, rotation: -14, size: CGSize(width: 10, height: 15),
      color: Color(hex: "FFB347"), isCircle: false),
    .init(
      x: -18, y: -356, rotation: 8, size: CGSize(width: 9, height: 9), color: Color(hex: "A78BFA"),
      isCircle: true),
    .init(
      x: 34, y: -320, rotation: 28, size: CGSize(width: 10, height: 16),
      color: Color(hex: "FF7A59"), isCircle: false),
    .init(
      x: 82, y: -350, rotation: 56, size: CGSize(width: 9, height: 9), color: Color(hex: "34D399"),
      isCircle: true),
    .init(
      x: 136, y: -298, rotation: 84, size: CGSize(width: 11, height: 18),
      color: Color(hex: "FFD166"), isCircle: false),
    .init(
      x: 186, y: -332, rotation: 112, size: CGSize(width: 9, height: 9),
      color: Color(hex: "93C5FD"), isCircle: true),
    .init(
      x: 238, y: -278, rotation: 138, size: CGSize(width: 10, height: 16),
      color: Color(hex: "F96E00"), isCircle: false),
    .init(
      x: 296, y: -232, rotation: 166, size: CGSize(width: 9, height: 9),
      color: Color(hex: "FFC857"), isCircle: true),
    .init(
      x: -268, y: -148, rotation: -132, size: CGSize(width: 9, height: 14),
      color: Color(hex: "FFFFFF"), isCircle: false),
    .init(
      x: -210, y: -114, rotation: -94, size: CGSize(width: 8, height: 8),
      color: Color(hex: "FF9F68"), isCircle: true),
    .init(
      x: -130, y: -138, rotation: -58, size: CGSize(width: 8, height: 12),
      color: Color(hex: "C4B5FD"), isCircle: false),
    .init(
      x: -70, y: -96, rotation: -26, size: CGSize(width: 8, height: 8), color: Color(hex: "FDE68A"),
      isCircle: true),
    .init(
      x: 64, y: -102, rotation: 32, size: CGSize(width: 8, height: 12), color: Color(hex: "F9A8D4"),
      isCircle: false),
    .init(
      x: 126, y: -144, rotation: 64, size: CGSize(width: 8, height: 8), color: Color(hex: "86EFAC"),
      isCircle: true),
    .init(
      x: 198, y: -110, rotation: 98, size: CGSize(width: 8, height: 12),
      color: Color(hex: "FDBA74"), isCircle: false),
    .init(
      x: 258, y: -158, rotation: 126, size: CGSize(width: 8, height: 8),
      color: Color(hex: "67E8F9"), isCircle: true),
  ]

  private var easedProgress: CGFloat {
    let clamped = min(max(progress, 0), 1)
    return 1 - pow(1 - clamped, 3)
  }

  private var fadeProgress: CGFloat {
    let clamped = min(max(progress, 0), 1)
    if clamped < 0.08 {
      return clamped / 0.08
    }

    let tail = max(0, clamped - 0.54) / 0.46
    return max(0, 1 - tail)
  }

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Circle()
          .fill(
            RadialGradient(
              colors: [
                Color.white.opacity(0.62),
                Color(hex: "FFE3B8").opacity(0.28),
                .clear,
              ],
              center: .center,
              startRadius: 0,
              endRadius: 54
            )
          )
          .frame(width: 124, height: 124)
          .position(x: origin.x, y: origin.y)
          .scaleEffect(0.4 + (easedProgress * 1.15))
          .opacity((1 - progress) * 0.82)

        ForEach(Array(Self.pieces.enumerated()), id: \.offset) { _, piece in
          Group {
            if piece.isCircle {
              Circle()
                .fill(piece.color)
            } else {
              RoundedRectangle(cornerRadius: piece.size.width * 0.42, style: .continuous)
                .fill(piece.color)
            }
          }
          .frame(width: piece.size.width, height: piece.size.height)
          .rotationEffect(.degrees(piece.rotation * Double(easedProgress)))
          .position(
            x: origin.x + (piece.x * easedProgress),
            y: origin.y + (piece.y * easedProgress) + (26 * progress)
          )
          .scaleEffect(1.08 - (progress * 0.16))
          .opacity(fadeProgress)
          .shadow(color: piece.color.opacity(0.34), radius: 6, x: 0, y: 2)
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
    .allowsHitTesting(false)
  }
}

struct DailyRequestConfettiPiece {
  let x: CGFloat
  let y: CGFloat
  let rotation: Double
  let size: CGSize
  let color: Color
  let isCircle: Bool
}

private struct DailyNotificationPermissionPanelView: View {
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
        .foregroundColor(Color(red: 0.85, green: 0.45, blue: 0.25))
        .multilineTextAlignment(.center)

      Text("Dayflow uses notifications to tell you when your recap is ready.")
        .font(.custom("Nunito-SemiBold", size: 16))
        .foregroundColor(Color(red: 0.25, green: 0.15, blue: 0.10))
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)

      Text(notificationPermissionMessage)
        .font(.custom("Nunito-Regular", size: 14))
        .foregroundColor(Color(red: 0.35, green: 0.22, blue: 0.12).opacity(0.8))
        .multilineTextAlignment(.center)
        .frame(maxWidth: 430)

      VStack(spacing: 10) {
        DayflowSurfaceButton(
          action: onNotificationPermissionAction,
          content: {
            Text(notificationPermissionButtonTitle)
              .font(.custom("Nunito", size: 15))
              .fontWeight(.semibold)
          },
          background: Color(red: 0.25, green: 0.17, blue: 0),
          foreground: .white,
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
              .font(.custom("Nunito", size: 14))
              .fontWeight(.semibold)
          },
          background: .white.opacity(0.9),
          foreground: Color(red: 0.25, green: 0.17, blue: 0),
          borderColor: Color(red: 0.25, green: 0.17, blue: 0).opacity(0.16),
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
        .fill(
          LinearGradient(
            colors: [
              Color.white.opacity(0.72),
              Color(red: 1.0, green: 0.93, blue: 0.89).opacity(0.58),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
        .overlay(
          RoundedRectangle(cornerRadius: 28, style: .continuous)
            .stroke(Color.white.opacity(0.58), lineWidth: 1)
        )
    )
    .shadow(color: Color.black.opacity(0.08), radius: 18, x: 0, y: 8)
  }
}
