import AppKit
import SwiftUI

struct SettingsAccountSection: View {
  @ObservedObject private var authManager = DayflowAuthManager.shared
  @State private var isAuthSheetPresented = false
  @State private var selectedBillingInterval: DayflowBillingInterval = .yearly
  @State private var inviteEmail = ""
  @State private var applyReferralCode = ""
  @State private var copiedReferralLink = false

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
      if authManager.entitlements.status == "active" {
        currentPlanSection
      } else {
        accountSection
        upgradeSection
      }

      referralSection

      if let errorText = authManager.errorText {
        Text(errorText)
          .font(.custom("Figtree", size: 11))
          .foregroundColor(SettingsStyle.destructive)
          .textSelection(.enabled)
      }
    }
    .sheet(isPresented: $isAuthSheetPresented) {
      DayflowSignInSheet {
        isAuthSheetPresented = false
      }
      .frame(width: 430)
      // Sheets get their own window, so force light like the What's New sheet does —
      // otherwise dark mode renders white text on the sheet's white background.
      .environment(\.colorScheme, .light)
      .preferredColorScheme(.light)
    }
    .task {
      authManager.loadStoredSessionIfNeeded()
    }
    .onChange(of: authManager.pendingReferralCode) { _, pendingCode in
      guard let pendingCode, applyReferralCode.isEmpty else { return }
      applyReferralCode = pendingCode
    }
  }

  private var accountSection: some View {
    SettingsSection(
      title: L10n.tr("Account"),
      subtitle: L10n.tr("Sign in once to keep Dayflow Pro and cloud features attached to this Mac.")
    ) {
      VStack(alignment: .leading, spacing: 0) {
        SettingsRow(
          label: L10n.tr("Dayflow account"),
          subtitle: authManager.isSignedIn
            ? authManager.displayIdentity
            : nil,
          showsDivider: authManager.isSignedIn
        ) {
          HStack(spacing: 8) {
            SettingsStatusDot(
              state: authManager.isSignedIn ? .good : .warn,
              label: authManager.isSignedIn ? L10n.tr("Signed in") : L10n.tr("Signed out")
            )

            if authManager.isSignedIn {
              SettingsSecondaryButton(
                title: L10n.tr("Sign out"),
                systemImage: "rectangle.portrait.and.arrow.right",
                isDisabled: authManager.isBusy,
                action: { Task { await authManager.signOut() } }
              )
            } else {
              SettingsPrimaryButton(
                title: L10n.tr("Sign in"),
                systemImage: "person.crop.circle",
                isLoading: authManager.isBusy && authManager.hasLoadedStoredSession == false,
                action: { isAuthSheetPresented = true }
              )
            }
          }
        }
      }
    }
  }

  private var currentPlanSection: some View {
    SettingsSection(
      title: L10n.tr("Account"),
      subtitle: L10n.tr("Manage your Dayflow account and subscription.")
    ) {
      ActiveProCard(
        entitlement: authManager.entitlements,
        email: authManager.displayIdentity,
        isBusy: authManager.isBusy,
        signOutAction: { Task { await authManager.signOut() } },
        manageBillingAction: { Task { await authManager.openBillingPortal() } }
      )
    }
  }

  private var upgradeSection: some View {
    SettingsSection(
      title: L10n.tr("Upgrade to Dayflow Pro"),
      subtitle: L10n.tr("Pick a plan, then finish securely in Stripe Checkout.")
    ) {
      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .top, spacing: 12) {
          BillingPlanCard(
            title: L10n.tr("Monthly"),
            price: "$20",
            cadence: L10n.tr("/mo"),
            note: L10n.tr("Flexible monthly billing."),
            badge: nil,
            isSelected: selectedBillingInterval == .monthly
          ) {
            withAnimation(.easeOut(duration: 0.16)) {
              selectedBillingInterval = .monthly
            }
          }

          BillingPlanCard(
            title: L10n.tr("Yearly"),
            price: "$15",
            cadence: L10n.tr("/mo"),
            note: L10n.tr("Billed yearly."),
            badge: L10n.tr("2 months free"),
            isSelected: selectedBillingInterval == .yearly
          ) {
            withAnimation(.easeOut(duration: 0.16)) {
              selectedBillingInterval = .yearly
            }
          }
        }
        .padding(.leading, 2)

        ProFeatureList()

        HStack(alignment: .center, spacing: 12) {
          SettingsPrimaryButton(
            title: authManager.isSignedIn ? L10n.tr("Continue to checkout") : L10n.tr("Sign in to upgrade"),
            systemImage: authManager.isSignedIn ? "creditcard" : "person.crop.circle",
            isLoading: authManager.isBusy,
            action: upgradeAction
          )

          VStack(alignment: .leading, spacing: 4) {
            Text("Cancel any time. No-questions-asked refunds.")
              .font(.custom("Figtree", size: 12))
              .foregroundColor(SettingsStyle.secondary)
              .fixedSize(horizontal: false, vertical: true)

            SettingsLinkButton(title: L10n.tr("Privacy policy"), systemImage: "lock") {
              openPrivacyPolicy()
            }
          }
        }
      }
    }
  }

  private var referralSection: some View {
    ReferralProgramCard(
      summary: authManager.referralSummary,
      inviteEmail: $inviteEmail,
      applyReferralCode: $applyReferralCode,
      copiedReferralLink: copiedReferralLink,
      isSignedIn: authManager.isSignedIn,
      isBusy: authManager.isBusy,
      copyAction: copyReferralLink,
      sendInviteAction: sendInvite,
      applyCodeAction: applyReferralCodeAction,
      signInAction: { isAuthSheetPresented = true },
      refreshAction: { Task { await authManager.refreshReferrals() } }
    )
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func upgradeAction() {
    guard authManager.isSignedIn else {
      isAuthSheetPresented = true
      return
    }

    Task {
      await authManager.openBillingCheckout(interval: selectedBillingInterval)
    }
  }

  private func openPrivacyPolicy() {
    guard let url = URL(string: "https://dayflow.so/privacy") else { return }
    NSWorkspace.shared.open(url)
  }

  private func copyReferralLink() {
    guard let inviteURL = authManager.referralSummary?.inviteURL else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(inviteURL, forType: .string)
    copiedReferralLink = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
      copiedReferralLink = false
    }
  }

  private func sendInvite() {
    Task {
      await authManager.sendReferralInvite(to: inviteEmail)
      if authManager.errorText == nil {
        inviteEmail = ""
      }
    }
  }

  private func applyReferralCodeAction() {
    let code = applyReferralCode.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !code.isEmpty else { return }
    Task {
      await authManager.claimReferralCode(code)
      if authManager.errorText == nil {
        applyReferralCode = ""
      }
    }
  }
}

private func formattedEntitlementDate(_ value: String?) -> String? {
  guard let value, !value.isEmpty else { return nil }

  if value.count >= 10 {
    let datePrefix = String(value.prefix(10))
    let dateOnlyFormatter = DateFormatter()
    dateOnlyFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateOnlyFormatter.timeZone = TimeZone(secondsFromGMT: 0)
    dateOnlyFormatter.dateFormat = "yyyy-MM-dd"

    if let date = dateOnlyFormatter.date(from: datePrefix) {
      let displayFormatter = DateFormatter()
      displayFormatter.locale = Locale.current
      displayFormatter.timeZone = TimeZone(secondsFromGMT: 0)
      displayFormatter.dateStyle = .medium
      displayFormatter.timeStyle = .none
      return displayFormatter.string(from: date)
    }
  }

  let formatters: [ISO8601DateFormatter] = [
    {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      return formatter
    }(),
    {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime]
      return formatter
    }(),
  ]

  let date = formatters.compactMap { $0.date(from: value) }.first
  guard let date else { return nil }

  let displayFormatter = DateFormatter()
  displayFormatter.locale = Locale.current
  displayFormatter.dateStyle = .medium
  displayFormatter.timeStyle = .none
  return displayFormatter.string(from: date)
}

private struct ActiveProCard: View {
  @Environment(\.dayflowTheme) private var theme
  let entitlement: DayflowEntitlement
  let email: String
  let isBusy: Bool
  let signOutAction: () -> Void
  let manageBillingAction: () -> Void

  private var isGifted: Bool {
    entitlement.source == "manual"
  }

  private var title: String {
    isGifted ? L10n.tr("Gifted Pro") : "Dayflow Pro"
  }

  private var badge: String {
    isGifted ? L10n.tr("Gifted") : L10n.tr("Active")
  }

  private var description: String {
    if isGifted {
      return
        L10n.tr("You have complimentary Dayflow Pro access. There is no billing to manage for this account.")
    }

    return L10n.tr("Your Pro access is active on this Mac and attached to your Dayflow account.")
  }

  private var dateLabel: String {
    if formattedEntitlementDate(entitlement.currentPeriodEnd) == nil {
      return L10n.tr("Status")
    }

    return isGifted ? L10n.tr("Access through") : L10n.tr("Renews")
  }

  private var dateValue: String {
    formattedEntitlementDate(entitlement.currentPeriodEnd) ?? L10n.tr("Active")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top, spacing: 16) {
        planIcon

        VStack(alignment: .leading, spacing: 5) {
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
              .font(.custom("Figtree", size: 22))
              .fontWeight(.bold)
              .foregroundColor(SettingsStyle.text)

            SettingsBadge(text: badge.uppercased(), isAccent: true)
          }

          Text(description)
            .font(.custom("Figtree", size: 13))
            .foregroundColor(SettingsStyle.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 16)

        SettingsStatusDot(state: .good, label: L10n.tr("Active"))
          .padding(.top, 4)
      }

      HStack(alignment: .top, spacing: 12) {
        ActiveProInfoTile(label: L10n.tr("Signed in as"), value: email)
        ActiveProInfoTile(label: dateLabel, value: dateValue)
      }

      Rectangle()
        .fill(SettingsStyle.divider)
        .frame(height: 1)

      HStack(alignment: .center, spacing: 16) {
        ProFeatureList()

        Spacer(minLength: 16)

        HStack(spacing: 8) {
          SettingsSecondaryButton(
            title: L10n.tr("Sign out"),
            systemImage: "rectangle.portrait.and.arrow.right",
            isDisabled: isBusy,
            action: signOutAction
          )

          if !isGifted {
            SettingsPrimaryButton(
              title: L10n.tr("Manage billing"),
              systemImage: "creditcard",
              isLoading: isBusy,
              action: manageBillingAction
            )
          }
        }
      }
    }
    .padding(18)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(theme.summaryCardFill)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(SettingsStyle.divider, lineWidth: 1)
    )
  }

  @ViewBuilder
  private var planIcon: some View {
    if isGifted {
      ZStack {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(SettingsStyle.ink.opacity(0.1))
        Image(systemName: "gift.fill")
          .font(.system(size: 15, weight: .semibold))
          .foregroundColor(SettingsStyle.ink)
      }
      .frame(width: 34, height: 34)
    } else {
      Image("DayflowLogo")
        .resizable()
        .scaledToFit()
        .frame(width: 34, height: 34)
    }
  }
}

private struct ActiveProInfoTile: View {
  @Environment(\.dayflowTheme) private var theme
  let label: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(label.uppercased())
        .font(.custom("Figtree", size: 10))
        .fontWeight(.bold)
        .kerning(0.5)
        .foregroundColor(SettingsStyle.meta)

      Text(value)
        .font(.custom("Figtree", size: 14))
        .fontWeight(.semibold)
        .foregroundColor(SettingsStyle.text)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(theme.summaryCardFill)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(SettingsStyle.divider, lineWidth: 1)
    )
  }
}

private struct ReferralProgramCard: View {
  @Environment(\.dayflowTheme) private var theme
  let summary: DayflowReferralSummary?
  @Binding var inviteEmail: String
  @Binding var applyReferralCode: String
  let copiedReferralLink: Bool
  let isSignedIn: Bool
  let isBusy: Bool
  let copyAction: () -> Void
  let sendInviteAction: () -> Void
  let applyCodeAction: () -> Void
  let signInAction: () -> Void
  let refreshAction: () -> Void

  @State private var selectedTab: ReferralTab = .refer

  private enum ReferralTab: CaseIterable, Hashable {
    case refer
    case past
    case apply
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 23) {
      header

      VStack(alignment: .leading, spacing: 16) {
        tabBar
        contentPanel
      }
    }
    .padding(20)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(theme.summaryCardFill)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(theme.summaryCardBorder, lineWidth: 1)
    )
    .task {
      if isSignedIn && summary == nil {
        refreshAction()
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Refer and earn rewards")
        .font(.custom("Figtree", size: 16))
        .fontWeight(.bold)
        .foregroundColor(theme.textPrimary)

      Text("Give a month of Dayflow Pro and earn $20 in credits for each person you refer!")
        .font(.custom("Figtree", size: 12))
        .foregroundColor(theme.textPrimary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var tabBar: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 24) {
        ForEach(ReferralTab.allCases, id: \.self) { tab in
          Button {
            withAnimation(.easeOut(duration: 0.16)) {
              selectedTab = tab
            }
          } label: {
            Text(tabTitle(for: tab))
              .font(.custom("Figtree", size: 12))
              .fontWeight(selectedTab == tab ? .bold : .regular)
              .foregroundColor(theme.textPrimary)
              .padding(.bottom, 8)
              .overlay(alignment: .bottom) {
                if selectedTab == tab {
                  Rectangle()
                    .fill(theme.textPrimary)
                    .frame(height: 2)
                }
              }
          }
          .buttonStyle(.plain)
          .pointingHandCursor()
        }

        Spacer()
      }
      .padding(.leading, 8)

      Rectangle()
        .fill(SettingsStyle.divider)
        .frame(height: 1)
    }
  }

  private var contentPanel: some View {
    VStack(alignment: .center, spacing: 28) {
      switch selectedTab {
      case .refer:
        referPanel
      case .past:
        pastInvitesPanel
      case .apply:
        applyCodePanel
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(SettingsStyle.subtleFill)
    )
  }

  private var referPanel: some View {
    VStack(alignment: .center, spacing: 28) {
      ReferralPassCard()

      VStack(alignment: .leading, spacing: 22) {
        howItWorks
        if isSignedIn {
          inviteLinkControl
        } else {
          signInReferralPrompt
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var signInReferralPrompt: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Sign in to get your invite link")
          .font(.custom("Figtree", size: 12))
          .fontWeight(.bold)
          .foregroundColor(theme.textPrimary)

        Text(
          "Referral credits are tied to your Dayflow account so we can credit you when friends join."
        )
        .font(.custom("Figtree", size: 11))
        .foregroundColor(theme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 12)

      ReferralMiniButton(
        title: L10n.tr("Sign in"),
        style: .send,
        isDisabled: isBusy,
        action: signInAction
      )
    }
  }

  private var inviteLinkControl: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("Your invite link")
        .font(.custom("Figtree", size: 12))
        .foregroundColor(theme.textPrimary)

      HStack(spacing: 8) {
        ReferralFieldText(
          icon: "link",
          text: summary?.inviteURL ?? L10n.tr("Loading invite link..."),
          color: theme.textPrimary
        )

        ReferralMiniButton(
          title: copiedReferralLink ? L10n.tr("Copied") : L10n.tr("Copy"),
          style: .copy,
          isDisabled: summary == nil,
          action: copyAction
        )
      }
    }
  }

  private var sendInviteControl: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("Send invites")
        .font(.custom("Figtree", size: 12))
        .foregroundColor(theme.textPrimary)

      HStack(spacing: 8) {
        ReferralEmailField(email: $inviteEmail, isDisabled: isBusy)

        ReferralMiniButton(
          title: L10n.tr("Send"),
          style: .send,
          isDisabled: isBusy || inviteEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          action: sendInviteAction
        )
      }
    }
  }

  private var howItWorks: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("How it works")
        .font(.custom("Figtree", size: 12))
        .fontWeight(.bold)
        .foregroundColor(theme.textPrimary)

      VStack(alignment: .leading, spacing: 4) {
        ReferralStepRow(
          icon: .system("point.3.connected.trianglepath.dotted"),
          content: Text("Share your invite link")
        )
        ReferralStepRow(
          icon: .menuBarMark,
          content: Text("They sign up and get a free month of Dayflow Pro!")
        )
        ReferralStepRow(
          icon: .system("sparkles"),
          content: Text(
            "You earn 1 month of Dayflow Pro (stackable!), when they use Dayflow for a week.")
        )
      }
    }
    .frame(width: 332, alignment: .leading)
  }

  private var pastInvitesPanel: some View {
    VStack(alignment: .leading, spacing: 18) {
      if let invites = summary?.invites, !invites.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(invites.prefix(8)) { invite in
            HStack(spacing: 12) {
              VStack(alignment: .leading, spacing: 3) {
                Text(invite.email)
                  .font(.custom("Figtree", size: 12))
                  .fontWeight(.semibold)
                  .foregroundColor(theme.textPrimary)
                  .lineLimit(1)
                  .truncationMode(.middle)

                Text(inviteStatusText(invite))
                  .font(.custom("Figtree", size: 11))
                  .foregroundColor(theme.textSecondary)
              }

              Spacer()

              SettingsBadge(
                text: invite.status.uppercased(),
                isAccent: invite.unlockedAt != nil
              )
            }
            .padding(.vertical, 8)

            if invite.id != invites.prefix(8).last?.id {
              Rectangle()
                .fill(SettingsStyle.divider)
                .frame(height: 1)
            }
          }
        }
      } else {
        EmptyReferralState(text: L10n.tr("No invites yet."))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var applyCodePanel: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Redeem a referral code")
        .font(.custom("Figtree", size: 12))
        .fontWeight(.bold)
        .foregroundColor(theme.textPrimary)

      HStack(spacing: 8) {
        ReferralCodeField(code: $applyReferralCode, isDisabled: isBusy)

        ReferralMiniButton(
          title: L10n.tr("Apply"),
          style: .send,
          isDisabled: isBusy || applyReferralCode.count != 6,
          action: applyCodeAction
        )
      }
    }
    .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
  }

  private func tabTitle(for tab: ReferralTab) -> String {
    switch tab {
    case .refer:
      return L10n.tr("Refer")
    case .past:
      return L10n.tr("Past referrals (%lld)", summary?.invites.count ?? 0)
    case .apply:
      return L10n.tr("Apply referral")
    }
  }

  private func inviteStatusText(_ invite: DayflowReferralInvite) -> String {
    if invite.unlockedAt != nil {
      return L10n.tr("Reward earned")
    }
    if invite.claimedAt != nil {
      return L10n.tr("%.1f / 40 hours recorded", invite.usageHours)
    }
    return L10n.tr("Invite sent")
  }
}

private struct BillingPlanCard: View {
  @Environment(\.dayflowTheme) private var theme
  let title: String
  let price: String
  let cadence: String
  let note: String
  let badge: String?
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(title)
            .font(.custom("Figtree", size: 13))
            .fontWeight(.bold)
            .foregroundColor(SettingsStyle.text)

          Spacer(minLength: 8)

          if let badge {
            SettingsBadge(text: badge.uppercased(), isAccent: true)
          }
        }

        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Text(price)
            .font(.custom("InstrumentSerif-Regular", size: 38))
            .foregroundColor(SettingsStyle.text)
          Text(cadence)
            .font(.custom("Figtree", size: 13))
            .fontWeight(.semibold)
            .foregroundColor(SettingsStyle.secondary)
        }

        Text(note)
          .font(.custom("Figtree", size: 12))
          .foregroundColor(SettingsStyle.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
      .padding(14)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(isSelected ? SettingsStyle.ink.opacity(0.06) : SettingsStyle.subtleFill)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(isSelected ? SettingsStyle.ink.opacity(0.8) : SettingsStyle.divider, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }
}

private struct ProFeatureList: View {
  private var features: [String] {
    [
      L10n.tr("Zero setup cloud AI for timeline generation"),
      L10n.tr("Daily and weekly reports without provider setup"),
      L10n.tr("Priority support"),
      L10n.tr("Processed securely and never used to train AI models"),
    ]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(features, id: \.self) { feature in
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(SettingsStyle.statusGood)
            .padding(.top, 1)

          Text(feature)
            .font(.custom("Figtree", size: 12))
            .foregroundColor(SettingsStyle.text)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .padding(.top, 2)
  }
}
