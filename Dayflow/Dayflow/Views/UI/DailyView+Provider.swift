import AppKit
import Foundation
import SwiftUI
import UserNotifications

extension DailyView {
  var canFinishDailyProviderOnboarding: Bool {
    guard !(isRefreshingProviderAvailability && providerAvailability.isEmpty) else {
      return false
    }

    return selectedProviderAvailability.isAvailable
  }
  var selectedProviderAvailability: DailyRecapProviderAvailability {
    providerAvailability[dailyRecapProvider]
      ?? DailyRecapProviderAvailability(
        isAvailable: true,
        detail: dailyRecapProvider.pickerSubtitle
      )
  }
  var canRegenerateStandup: Bool {
    dailyRecapProvider.canGenerate
      && selectedProviderAvailability.isAvailable
      && standupRegenerateState != .regenerating
  }
  var regenerateButtonHelpText: String {
    if !dailyRecapProvider.canGenerate {
      return DailyStandupPlaceholder.noProviderSelectedMessage
    }

    if !selectedProviderAvailability.isAvailable {
      return selectedProviderAvailability.detail
    }

    return "Regenerate standup highlights"
  }
  func dailyProviderButton(scale: CGFloat) -> some View {
    Button {
      if !isShowingProviderPicker {
        refreshProviderAvailability()
      }
      isShowingProviderPicker.toggle()
    } label: {
      ZStack {
        Circle()
          .fill(Color(hex: "F7F3F1"))

        Circle()
          .stroke(Color(hex: "E4D7D0"), lineWidth: max(1.1, 1.3 * scale))

        Image(systemName: "gearshape.fill")
          .font(.system(size: 13 * scale, weight: .semibold))
          .foregroundStyle(Color(hex: "B46531"))
      }
      .frame(width: 38 * scale, height: 38 * scale)
      .shadow(color: Color.black.opacity(0.03), radius: 5, x: 0, y: 2)
      .contentShape(Circle())
    }
    .buttonStyle(DailyCopyPressButtonStyle())
    .disabled(standupRegenerateState == .regenerating)
    .pointingHandCursorOnHover(
      enabled: standupRegenerateState != .regenerating,
      reassertOnPressEnd: true
    )
    .accessibilityLabel(Text("Choose daily recap provider"))
    .help("Daily recap provider: \(dailyRecapProvider.selectionLabel)")
    .popover(isPresented: $isShowingProviderPicker, arrowEdge: .bottom) {
      dailyProviderPicker(scale: scale)
        .padding(16)
        .frame(width: 312)
        .environment(\.colorScheme, .light)
        .preferredColorScheme(.light)
    }
  }
  func dailyProviderPicker(scale: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 12 * scale) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2 * scale) {
          Text("Daily recap provider")
            .font(.custom("InstrumentSerif-Regular", size: 22 * scale))
            .foregroundStyle(Color(hex: "2E221B"))

          Text("Choose how Daily generates this recap, or turn generation off.")
            .font(.custom("Nunito-Regular", size: 12 * scale))
            .foregroundStyle(Color(hex: "8B6B59"))
        }

        Spacer(minLength: 0)

        if isRefreshingProviderAvailability {
          ProgressView()
            .controlSize(.small)
            .tint(Color(hex: "B46531"))
        }
      }

      VStack(spacing: 8 * scale) {
        ForEach(DailyRecapProvider.allCases, id: \.self) { provider in
          let availability =
            providerAvailability[provider]
            ?? DailyRecapProviderAvailability(isAvailable: true, detail: provider.pickerSubtitle)
          let isSelected = dailyRecapProvider == provider

          Button {
            selectDailyRecapProvider(provider)
          } label: {
            HStack(alignment: .top, spacing: 10 * scale) {
              VStack(alignment: .leading, spacing: 2 * scale) {
                Text(provider.displayName)
                  .font(.custom("Nunito-SemiBold", size: 13 * scale))
                  .foregroundStyle(Color(hex: isSelected ? "8F522C" : "2F241D"))

                Text(availability.detail)
                  .font(.custom("Nunito-Regular", size: 12 * scale))
                  .foregroundStyle(Color(hex: availability.isAvailable ? "8B6B59" : "B07A74"))
                  .multilineTextAlignment(.leading)
              }

              Spacer(minLength: 0)

              Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14 * scale, weight: .semibold))
                .foregroundStyle(
                  isSelected ? Color(hex: "C96F3A") : Color(hex: "D3C6BE")
                )
            }
            .padding(.horizontal, 12 * scale)
            .padding(.vertical, 10 * scale)
            .background(
              RoundedRectangle(cornerRadius: 14 * scale, style: .continuous)
                .fill(
                  isSelected
                    ? Color(hex: "FFF4EC")
                    : Color(hex: "FAF8F7")
                )
            )
            .overlay(
              RoundedRectangle(cornerRadius: 14 * scale, style: .continuous)
                .stroke(
                  isSelected ? Color(hex: "EBC4AB") : Color(hex: "E8E1DC"),
                  lineWidth: max(1, 1.2 * scale)
                )
            )
            .contentShape(RoundedRectangle(cornerRadius: 14 * scale, style: .continuous))
          }
          .buttonStyle(.plain)
          .disabled(!availability.isAvailable)
          .pointingHandCursorOnHover(enabled: availability.isAvailable, reassertOnPressEnd: true)
        }
      }
    }
  }
  func selectDailyRecapProvider(_ provider: DailyRecapProvider) {
    let previousProvider = dailyRecapProvider
    guard previousProvider != provider else {
      isShowingProviderPicker = false
      return
    }

    dailyRecapProvider = provider
    DailyRecapGenerator.shared.persistSelectedProvider(provider)
    isShowingProviderPicker = false
    standupRegenerateResetTask?.cancel()
    standupRegenerateResetTask = nil
    standupRegenerateState = .idle
    loadedStandupDraftDay = nil
    loadedStandupFallbackSourceDay = nil

    AnalyticsService.shared.capture(
      "daily_provider_selected",
      [
        "previous_daily_provider": previousProvider.analyticsName,
        "previous_daily_provider_label": previousProvider.displayName,
        "daily_provider": provider.analyticsName,
        "daily_provider_label": provider.displayName,
        "daily_runtime": provider.runtimeLabel,
        "daily_model_or_tool": provider.modelOrTool as Any,
      ]
    )

    refreshWorkflowData()
  }
  func refreshProviderAvailability() {
    providerAvailabilityTask?.cancel()
    isRefreshingProviderAvailability = true

    providerAvailabilityTask = Task.detached(priority: .utility) {
      let snapshot = DailyRecapGenerator.shared.availabilitySnapshot()
      guard !Task.isCancelled else { return }

      await MainActor.run {
        providerAvailability = snapshot
        isRefreshingProviderAvailability = false
        providerAvailabilityTask = nil
      }
    }
  }
}
