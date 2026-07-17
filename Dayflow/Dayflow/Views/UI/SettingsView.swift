//
//  SettingsView.swift
//  Dayflow
//
//  Settings screen with onboarding-inspired styling and split layout
//

import Foundation
import SwiftUI

struct SettingsView: View {
  private enum SettingsTab: String, CaseIterable, Identifiable {
    case account
    case storage
    case privacy
    case providers
    case data
    case other

    var id: String { rawValue }

    var title: String {
      switch self {
      case .account: return "Account"
      case .storage: return "Storage"
      case .privacy: return "Privacy"
      case .providers: return "Providers"
      case .data: return "Export"
      case .other: return "Other"
      }
    }
  }

  @State private var selectedTab: SettingsTab = .account

  @Namespace private var sidebarSelectionNamespace

  @ObservedObject private var launchAtLoginManager = LaunchAtLoginManager.shared

  @StateObject private var storageViewModel = StorageSettingsViewModel()
  @StateObject private var privacyViewModel = RecordingPrivacySettingsViewModel()
  @StateObject private var providersViewModel = ProvidersSettingsViewModel()
  @StateObject private var otherViewModel = OtherSettingsViewModel()

  var body: some View {
    contentWithSheets
      .environment(\.colorScheme, .light)
  }

  private var contentWithSheets: some View {
    contentWithLifecycle
      .sheet(
        item: Binding(
          get: {
            providersViewModel.setupModalProvider.map {
              ProviderSetupWrapper(providerID: $0)
            }
          },
          set: { wrapper in
            if let wrapper {
              providersViewModel.setupModalProvider = wrapper.providerID
            } else {
              providersViewModel.cancelProviderSetup()
            }
          }
        )
      ) { wrapper in
        LLMProviderSetupView(
          providerType: wrapper.providerID,
          onBack: { providersViewModel.cancelProviderSetup() },
          onComplete: {
            let succeeded = providersViewModel.handleProviderSetupCompletion(wrapper.providerID)
            if succeeded {
              providersViewModel.cancelProviderSetup()
            }
            return succeeded
          }
        )
        .frame(minWidth: 900, minHeight: 650)
      }
      .sheet(isPresented: $providersViewModel.isShowingLocalModelUpgradeSheet) {
        LocalModelUpgradeSheet(
          preset: .qwen3VL4B,
          initialEngine: providersViewModel.localEngine,
          initialBaseURL: providersViewModel.localBaseURL,
          initialModelId: providersViewModel.localModelId,
          initialAPIKey: providersViewModel.localAPIKey,
          onCancel: { providersViewModel.isShowingLocalModelUpgradeSheet = false },
          onUpgradeSuccess: { engine, baseURL, modelId, apiKey in
            providersViewModel.handleUpgradeSuccess(
              engine: engine, baseURL: baseURL, modelId: modelId, apiKey: apiKey)
            providersViewModel.isShowingLocalModelUpgradeSheet = false
          }
        )
        .frame(minWidth: 720, minHeight: 560)
      }
  }

  private var contentWithLifecycle: some View {
    GeometryReader { proxy in
      mainContent
        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
    }
    .onAppear {
      DayflowAuthManager.shared.loadStoredSessionIfNeeded()
      providersViewModel.handleOnAppear()
      otherViewModel.refreshAnalyticsState()
      storageViewModel.refreshStorageIfNeeded(isStorageTab: selectedTab == .storage)
      AnalyticsService.shared.capture("settings_opened")
      launchAtLoginManager.refreshStatus()
    }
    .onChange(of: selectedTab) { _, newValue in
      if newValue == .storage {
        storageViewModel.refreshStorageIfNeeded(isStorageTab: true)
      } else if newValue == .privacy {
        privacyViewModel.handleOnAppear()
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .openProvidersSettings)) { _ in
      guard selectedTab != .providers else { return }
      withAnimation(.easeOut(duration: 0.18)) {
        selectedTab = .providers
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .openAccountSettings)) { _ in
      guard selectedTab != .account else { return }
      withAnimation(.easeOut(duration: 0.18)) {
        selectedTab = .account
      }
    }
  }

  private var mainContent: some View {
    HStack(alignment: .top, spacing: 32) {
      sidebar
        .frame(maxHeight: .infinity, alignment: .topLeading)

      settingsContent

      Spacer(minLength: 0)
    }
    .padding(.trailing, 40)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder
  private var settingsContent: some View {
    if selectedTab == .privacy {
      VStack(alignment: .leading, spacing: 24) {
        tabContent
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(.top, 24)
      .padding(.trailing, 16)
      .padding(.bottom, 24)
      .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
    } else {
      ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 24) {
          tabContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
        .padding(.trailing, 16)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, minHeight: 0, alignment: .topLeading)
      }
      .frame(maxWidth: 600, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Settings")
        .font(.custom("InstrumentSerif-Regular", size: 22))
        .foregroundColor(.black.opacity(0.9))
        .padding(.leading, 10)
        .padding(.bottom, 18)

      VStack(alignment: .leading, spacing: 2) {
        ForEach(SettingsTab.allCases) { tab in
          sidebarButton(for: tab)
        }
      }

      Spacer()

      sidebarFooter
        .padding(.leading, 10)
    }
    .padding(.top, 0)
    .padding(.bottom, 16)
    .padding(.horizontal, 4)
    .frame(width: 160, alignment: .topLeading)
  }

  private var sidebarFooter: some View {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    return VStack(alignment: .leading, spacing: 8) {
      Text("Dayflow v\(version)")
        .font(.custom("Figtree", size: 11))
        .foregroundColor(.black.opacity(0.4))

      Button {
        NotificationCenter.default.post(name: .showWhatsNew, object: nil)
      } label: {
        HStack(spacing: 4) {
          Text("Release notes")
            .font(.custom("Figtree", size: 11))
            .fontWeight(.semibold)
          Image(systemName: "arrow.up.right")
            .font(.system(size: 9, weight: .semibold))
        }
        .foregroundColor(Color(red: 0.25, green: 0.17, blue: 0))
      }
      .buttonStyle(.plain)
      .pointingHandCursor()
    }
  }

  private func sidebarButton(for tab: SettingsTab) -> some View {
    Button {
      withAnimation(.easeOut(duration: 0.18)) {
        selectedTab = tab
      }
    } label: {
      Text(tab.title)
        .font(.custom("Figtree", size: 13))
        .fontWeight(.semibold)
        .foregroundColor(.black.opacity(selectedTab == tab ? 0.9 : 0.55))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background {
          if selectedTab == tab {
            RoundedRectangle(cornerRadius: 7)
              .fill(Color.black.opacity(0.06))
              .matchedGeometryEffect(id: "sidebarSelection", in: sidebarSelectionNamespace)
          }
        }
    }
    .buttonStyle(SettingsSidebarButtonStyle())
    .pointingHandCursor()
  }

  @ViewBuilder
  private var tabContent: some View {
    // Content swap is a pure fade. The sidebar pill's matchedGeometryEffect
    // carries the "where you went" signal — the content doesn't need to
    // redundantly slide horizontally, which implied a carousel that doesn't
    // actually exist (the sidebar is vertical, not left/right tabs).
    Group {
      switch selectedTab {
      case .account:
        SettingsAccountSection()
      case .storage:
        SettingsStorageTabView(viewModel: storageViewModel)
      case .privacy:
        SettingsRecordingPrivacyTabView(viewModel: privacyViewModel)
      case .providers:
        SettingsProvidersTabView(viewModel: providersViewModel)
      case .data:
        SettingsDataTabView(viewModel: otherViewModel)
      case .other:
        SettingsOtherTabView(viewModel: otherViewModel, launchAtLoginManager: launchAtLoginManager)
      }
    }
    .id(selectedTab)
    .transition(.opacity)
  }
}

private struct ProviderSetupWrapper: Identifiable {
  let providerID: LLMProviderID

  var id: String { providerID.rawValue }
}

struct SettingsView_Previews: PreviewProvider {
  static var previews: some View {
    SettingsView()
      .environmentObject(UpdaterManager.shared)
      .frame(width: 1400, height: 860)
  }
}

private struct SettingsSidebarButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .dayflowPressScale(
        configuration.isPressed,
        pressedScale: 0.98,
        animation: .spring(response: 0.25, dampingFraction: 0.7)
      )
  }
}
