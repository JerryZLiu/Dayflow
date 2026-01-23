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
        case storage
        case providers
        case other

        var id: String { rawValue }

        var title: String {
            switch self {
            case .storage: return "Storage"
            case .providers: return "Providers"
            case .other: return "Other"
            }
        }

        var subtitle: String {
            switch self {
            case .storage: return "Recording status and disk usage"
            case .providers: return "Manage LLM providers and customize prompts"
            case .other: return "General preferences & support"
            }
        }
    }

    private enum TabTransitionDirection {
        case none, leading, trailing
    }

    @State private var selectedTab: SettingsTab = .storage
    @State private var tabTransitionDirection: TabTransitionDirection = .none

    @Namespace private var sidebarSelectionNamespace

    @ObservedObject private var launchAtLoginManager = LaunchAtLoginManager.shared

    @StateObject private var storageViewModel = StorageSettingsViewModel()
    @StateObject private var providersViewModel = ProvidersSettingsViewModel()
    @StateObject private var otherViewModel = OtherSettingsViewModel()

    var body: some View {
        contentWithSheets
            .preferredColorScheme(.light)
    }

    private var contentWithSheets: some View {
        contentWithLifecycle
            .sheet(item: Binding(
                get: { providersViewModel.setupModalProvider.map { ProviderSetupWrapper(id: $0) } },
                set: { providersViewModel.setupModalProvider = $0?.id }
            )) { wrapper in
                LLMProviderSetupView(
                    providerType: wrapper.id,
                    onBack: { providersViewModel.setupModalProvider = nil },
                    onComplete: {
                        providersViewModel.completeProviderSwitch(wrapper.id)
                        providersViewModel.setupModalProvider = nil
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
                        providersViewModel.handleUpgradeSuccess(engine: engine, baseURL: baseURL, modelId: modelId, apiKey: apiKey)
                        providersViewModel.isShowingLocalModelUpgradeSheet = false
                    }
                )
                .frame(minWidth: 720, minHeight: 560)
            }
    }

    private var contentWithLifecycle: some View {
        mainContent
            .onAppear {
                providersViewModel.handleOnAppear()
                otherViewModel.refreshAnalyticsState()
                storageViewModel.refreshStorageIfNeeded(isStorageTab: selectedTab == .storage)
                AnalyticsService.shared.capture("settings_opened")
                launchAtLoginManager.refreshStatus()
            }
            .onChange(of: selectedTab) { _, newValue in
                if newValue == .storage {
                    storageViewModel.refreshStorageIfNeeded(isStorageTab: true)
                }
            }
    }

    private var mainContent: some View {
        HStack(alignment: .top, spacing: 32) {
            sidebar

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    tabContent
                }
                .padding(.top, 24)
                .padding(.trailing, 16)
                .padding(.bottom, 24)
            }
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            .frame(maxWidth: 600, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.trailing, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings")
                .font(.custom("InstrumentSerif-Regular", size: 42))
                .foregroundColor(.black.opacity(0.9))
                .padding(.leading, 10)

            Text("Manage how Dayflow runs")
                .font(.custom("Nunito", size: 14))
                .foregroundColor(.black.opacity(0.55))
                .padding(.leading, 10)
                .padding(.bottom, 12)

            ForEach(SettingsTab.allCases) { tab in
                sidebarButton(for: tab)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 12) {
                Text("Dayflow v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    .font(.custom("Nunito", size: 12))
                    .foregroundColor(.black.opacity(0.45))
                    .padding(.leading, 10)
                Button {
                    NotificationCenter.default.post(name: .showWhatsNew, object: nil)
                } label: {
                    HStack(spacing: 6) {
                        Text("View release notes")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .font(.custom("Nunito", size: 12))
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(Color(red: 0.45, green: 0.26, blue: 0.04))
                .padding(.leading, 10)
            }
        }
        .padding(.top, 0)
        .padding(.bottom, 16)
        .padding(.horizontal, 4)
        .frame(width: 198, alignment: .topLeading)
    }

    private func sidebarButton(for tab: SettingsTab) -> some View {
        Button {
            let tabs = SettingsTab.allCases
            let currentIndex = tabs.firstIndex(of: selectedTab) ?? 0
            let newIndex = tabs.firstIndex(of: tab) ?? 0
            let direction: TabTransitionDirection = newIndex > currentIndex ? .trailing : (newIndex < currentIndex ? .leading : .none)

            tabTransitionDirection = direction
            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                selectedTab = tab
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(tab.title)
                    .font(.custom("Nunito", size: 15))
                    .fontWeight(.semibold)
                    .foregroundColor(.black.opacity(selectedTab == tab ? 0.9 : 0.6))
                Text(tab.subtitle)
                    .font(.custom("Nunito", size: 12))
                    .foregroundColor(.black.opacity(selectedTab == tab ? 0.55 : 0.35))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background {
                if selectedTab == tab {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.85))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(hex: "FFE0A5"), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 6)
                        .matchedGeometryEffect(id: "sidebarSelection", in: sidebarSelectionNamespace)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.45))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.3), lineWidth: 1)
                        )
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
    }

    @ViewBuilder
    private var tabContent: some View {
        let slideOffset: CGFloat = tabTransitionDirection == .trailing ? 20 : (tabTransitionDirection == .leading ? -20 : 0)

        Group {
            switch selectedTab {
            case .storage:
                SettingsStorageTabView(viewModel: storageViewModel)
            case .providers:
                SettingsProvidersTabView(viewModel: providersViewModel)
            case .other:
                SettingsOtherTabView(viewModel: otherViewModel, launchAtLoginManager: launchAtLoginManager)
            }
        }
        .id(selectedTab)
        .transition(
            .asymmetric(
                insertion: .opacity.combined(with: .offset(x: slideOffset)),
                removal: .opacity.combined(with: .offset(x: -slideOffset))
            )
        )
    }
}

private struct ProviderSetupWrapper: Identifiable {
    let id: String
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(UpdaterManager.shared)
            .frame(width: 1400, height: 860)
    }
}
