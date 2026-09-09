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
          .fill(theme.controlFill)

        InnerGlow(shape: Circle(), color: theme.controlInnerGlow, radius: 3)

        Circle()
          .strokeBorder(theme.controlBorder, lineWidth: 0.75)

        Image(systemName: "gearshape.fill")
          .font(.system(size: 13 * scale, weight: .semibold))
          .foregroundStyle(theme.controlText)
      }
      .frame(width: 38 * scale, height: 38 * scale)
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
        .resolveDayflowTheme()
    }
  }
  func dailyProviderPicker(scale: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 12 * scale) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2 * scale) {
          Text("Daily recap provider")
            .font(.custom("InstrumentSerif-Regular", size: 22 * scale))
            .foregroundStyle(theme.textPrimary)

          Text("Choose how Daily generates this recap, or turn generation off.")
            .font(.custom("Figtree-Regular", size: 12 * scale))
            .foregroundStyle(theme.textSecondary)
        }

        Spacer(minLength: 0)

        if isRefreshingProviderAvailability {
          ProgressView()
            .controlSize(.small)
            .tint(theme.accent)
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
                  .font(.custom("Figtree-SemiBold", size: 13 * scale))
                  .foregroundStyle(theme.textPrimary)

                Text(availability.detail)
                  .font(.custom("Figtree-Regular", size: 12 * scale))
                  .foregroundStyle(availability.isAvailable ? theme.textSecondary : theme.textMuted)
                  .multilineTextAlignment(.leading)
              }

              Spacer(minLength: 0)

              Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14 * scale, weight: .semibold))
                .foregroundStyle(isSelected ? theme.accent : theme.textMuted)
            }
            .padding(.horizontal, 12 * scale)
            .padding(.vertical, 10 * scale)
            .background(
              RoundedRectangle(cornerRadius: 14 * scale, style: .continuous)
                .fill(isSelected ? theme.controlFill : theme.chipFill)
            )
            .overlay(
              RoundedRectangle(cornerRadius: 14 * scale, style: .continuous)
                .stroke(
                  isSelected ? theme.controlBorder : theme.chipBorder,
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
