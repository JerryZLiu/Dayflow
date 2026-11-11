import AppKit
import SwiftUI

/// Settings › Account (Figma "Dayflow - minor adjustments": 22:50 signed out, 29:2297 free, 26:90 Pro).
/// Signed out, it's a two-plan pricing page. Signed in, it shows the email, the current plan, the plan
/// to subscribe or switch to, and the billing and sign-out buttons.
struct SettingsAccountSection: View {
  @ObservedObject private var authManager = DayflowAuthManager.shared
  @State private var isAuthSheetPresented = false
  @State private var selectedBillingInterval: DayflowBillingInterval = .yearly
  /// This account's prices for both plans (they're part of a price test); nil until loaded or signed out.
  @State private var offer: DayflowBillingOffer?
  @State private var inviteEmail = ""
  @State private var applyReferralCode = ""
  @State private var copiedReferralLink = false

  private var entitlement: DayflowEntitlement { authManager.entitlements }
  private var hasActivePlan: Bool { entitlement.status == "active" }
  private var isPlus: Bool { entitlement.plan == "plus" }
  private var isGifted: Bool { entitlement.source == "manual" }
  private var isTrial: Bool { entitlement.source == "trial" }
  /// A plan the person pays for through Stripe, so it has billing to manage.
  private var hasPaidPlan: Bool { hasActivePlan && !isGifted && !isTrial }

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
      if authManager.isSignedIn {
        signedInPage
        // The referral section ("Refer and earn rewards") is hidden for now. Add `referralSection` back here to show it.
      } else {
        signedOutPage
      }

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
      await authManager.refreshAccount()
    }
    .task(id: authManager.isSignedIn) {
      guard authManager.isSignedIn else {
        offer = nil
        return
      }
      do {
        offer = try await authManager.billingOffer()
        AnalyticsService.shared.capture(
          "settings_account_offer_loaded",
          [
            "variant": offer?.variant ?? "", "plus_currency": offer?.plus.monthly.currency ?? "",
          ])
      } catch {
        // The page falls back to list prices in US dollars.
        let nsError = error as NSError
        AnalyticsService.shared.capture(
          "settings_account_offer_failed",
          ["error_domain": nsError.domain, "error_code": nsError.code])
      }
    }
    .onAppear {
      AnalyticsService.shared.capture(
        "settings_account_viewed",
        [
          "signed_in": authManager.isSignedIn, "plan": entitlement.plan,
          "plan_status": entitlement.status,
          "plan_source": entitlement.source ?? "", "source": analyticsSource,
        ])
    }
    .onChange(of: selectedBillingInterval) { _, interval in
      AnalyticsService.shared.capture(
        "settings_account_interval_changed",
        [
          "interval": interval.rawValue, "signed_in": authManager.isSignedIn,
          "source": analyticsSource,
        ])
    }
    .onChange(of: authManager.pendingReferralCode) { _, pendingCode in
      guard let pendingCode, applyReferralCode.isEmpty else { return }
      applyReferralCode = pendingCode
    }
  }

  // MARK: - Signed out (22:50)

  private var signedOutPage: some View {
    VStack(spacing: 22) {
      VStack(spacing: 8) {
        Text("Upgrade or sign in to access premium features")
          .font(.custom("InstrumentSerif-Regular", size: 24))
          .foregroundColor(SettingsStyle.text)
          .multilineTextAlignment(.center)
        checkoutNote
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: 555)
      .padding(.top, 72)

      AccountIntervalPicker(selection: $selectedBillingInterval)

      HStack(alignment: .top, spacing: 16) {
        AccountTallPlanCard(
          title: String(localized: "Plus"),
          subtitle: String(localized: "Access to all premium features"),
          price: plusPrice,
          interval: selectedBillingInterval,
          freeMonths: Self.freeMonths(plusPrices),
          featuresTitle: String(localized: "All the basic features, plus:"),
          features: AccountPlanFeature.plus,
          background: "AccountCardGlowTall",
          isBusy: authManager.isBusy,
          action: { signIn(from: "plus_card") }
        )
        AccountTallPlanCard(
          title: String(localized: "Pro"),
          subtitle: String(localized: "All premium features without usage limits"),
          price: proPrice,
          interval: selectedBillingInterval,
          freeMonths: Self.freeMonths(proPrices),
          featuresTitle: String(localized: "Everything in Plus and more:"),
          features: AccountPlanFeature.proExtras,
          background: "AccountCardGlowTallWarm",
          isBusy: authManager.isBusy,
          action: { signIn(from: "pro_card") }
        )
      }
      .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity)
    .overlay(alignment: .topTrailing) {
      VStack(alignment: .trailing, spacing: 6) {
        Text("Already have an account?")
          .font(.custom("Figtree", size: 14))
          .foregroundColor(SettingsStyle.secondary)
        AccountDarkButton(
          title: String(localized: "Sign in"), icon: "AccountUserCircle", style: .compact,
          action: { signIn(from: "header") })
      }
    }
  }

  // MARK: - Signed in (29:2297 free, 26:90 Pro)

  private var signedInPage: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Account")
          .font(.custom("Figtree", size: 14.5))
          .fontWeight(.semibold)
          .foregroundColor(SettingsStyle.text)
        Text("Manage your Dayflow account and subscription.")
          .font(.custom("Figtree", size: 12))
          .foregroundColor(SettingsStyle.secondary)
      }
      .padding(.bottom, 4)

      AccountDivider()
      emailRow
      AccountDivider()

      VStack(alignment: .leading, spacing: 13) {
        AccountSectionTitle(text: String(localized: "Current subscription"))
        AccountCurrentPlanCard(
          title: currentPlanTitle,
          features: currentPlanFeatures,
          dateLabel: currentPlanDateLabel,
          date: hasActivePlan ? formattedEntitlementDate(entitlement.currentPeriodEnd) : nil
        )
      }

      if let offerKind {
        AccountDivider()
        offersSection(offerKind)
      }

      if hasActivePlan {
        AccountDivider()
        HStack(spacing: 8) {
          if hasPaidPlan {
            AccountDarkButton(
              title: String(localized: "Manage billing"), icon: "AccountCreditCard", style: .large,
              action: { openBillingPortal(reason: "manage_billing") })
          }
          AccountSignOutButton(isBusy: authManager.isBusy, style: .large) {
            signOut()
          }
        }
      }
    }
  }

  /// Email on the left; for a free account the sign-out button sits here, since there's no billing row.
  @ViewBuilder
  private var emailRow: some View {
    if hasActivePlan {
      HStack {
        Text("Email")
          .fontWeight(.semibold)
        Spacer(minLength: 16)
        Text(authManager.displayIdentity)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
      }
      .font(.custom("Figtree", size: 14))
      .foregroundColor(SettingsStyle.text)
    } else {
      HStack(alignment: .center) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Email")
            .fontWeight(.semibold)
          Text(authManager.displayIdentity)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
        .font(.custom("Figtree", size: 14))
        .foregroundColor(SettingsStyle.text)
        Spacer(minLength: 16)
        AccountSignOutButton(isBusy: authManager.isBusy, style: .compact) {
          signOut()
        }
      }
    }
  }

  /// What the offers block below the current plan shows.
  private enum OfferKind {
    /// Free (or trying Plus): both plans, bought through Stripe Checkout.
    case subscribe
    /// Paying for Plus: Pro, switched through Stripe's billing page.
    case upgradeToPro
    /// Paying for Pro: Plus, switched through Stripe's billing page.
    case downgradeToPlus
  }

  /// Nil for gifted Pro, which has nothing to buy or switch.
  private var offerKind: OfferKind? {
    if !hasActivePlan || isTrial { return .subscribe }
    if isGifted { return nil }
    return isPlus ? .upgradeToPro : .downgradeToPlus
  }

  @ViewBuilder
  private func offersSection(_ kind: OfferKind) -> some View {
    switch kind {
    case .subscribe:
      VStack(alignment: .leading, spacing: 13) {
        VStack(alignment: .leading, spacing: 18) {
          VStack(alignment: .leading, spacing: 6) {
            AccountSectionTitle(text: String(localized: "Subscribe to access premium features"))
            checkoutNote
          }
          AccountIntervalPicker(selection: $selectedBillingInterval)
        }
        .padding(.bottom, 5)
        proOfferCard(buttonTitle: String(localized: "Subscribe to Pro")) { checkout(plan: nil) }
        plusOfferCard(buttonTitle: String(localized: "Subscribe to Plus")) {
          checkout(plan: "plus")
        }
      }
    case .upgradeToPro, .downgradeToPlus:
      // A paid plan switches through Stripe's billing page, which handles proration.
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          AccountSectionTitle(
            text: kind == .upgradeToPro
              ? String(localized: "Upgrade subscription")
              : String(localized: "Downgrade subscription"))
          Spacer()
          AccountIntervalPicker(selection: $selectedBillingInterval)
        }
        if kind == .upgradeToPro {
          proOfferCard(buttonTitle: String(localized: "Switch to Pro")) {
            openBillingPortal(reason: "switch_to_pro")
          }
        } else {
          plusOfferCard(buttonTitle: String(localized: "Switch to Plus")) {
            openBillingPortal(reason: "switch_to_plus")
          }
        }
      }
    }
  }

  private func proOfferCard(buttonTitle: String, action: @escaping () -> Void) -> some View {
    AccountWidePlanCard(
      title: String(localized: "Dayflow Pro"),
      features: AccountPlanFeature.pro,
      price: proPrice,
      interval: selectedBillingInterval,
      freeMonths: Self.freeMonths(proPrices),
      buttonTitle: buttonTitle,
      background: "AccountCardGlowWide",
      isBusy: authManager.isBusy,
      action: action
    )
  }

  private func plusOfferCard(buttonTitle: String, action: @escaping () -> Void) -> some View {
    AccountWidePlanCard(
      title: String(localized: "Dayflow Plus"),
      features: AccountPlanFeature.plus,
      price: plusPrice,
      interval: selectedBillingInterval,
      freeMonths: Self.freeMonths(plusPrices),
      buttonTitle: buttonTitle,
      background: "AccountCardGlowWideSoft",
      isBusy: authManager.isBusy,
      action: action
    )
  }

  // MARK: - Current plan

  private var currentPlanTitle: String {
    guard hasActivePlan else { return String(localized: "Free") }
    if isPlus { return String(localized: "Dayflow Plus") }
    return isGifted ? String(localized: "Gifted Pro") : String(localized: "Dayflow Pro")
  }

  private var currentPlanFeatures: [AccountPlanFeature] {
    guard hasActivePlan else { return AccountPlanFeature.free }
    return isPlus ? AccountPlanFeature.plus : AccountPlanFeature.pro
  }

  private var currentPlanDateLabel: String {
    if isTrial { return String(localized: "Trial ends") }
    return isGifted ? String(localized: "Access through") : String(localized: "Next renewal")
  }

  // MARK: - Prices

  /// List prices, shown signed out and until this account's offer loads. These match Stripe:
  /// Plus $20 a month or $180 a year, Pro $40 a month or $360 a year.
  private static let listPlus = DayflowPlanPrices(
    monthly: DayflowOfferPrice(amountCents: 2000, currency: "usd"),
    yearly: DayflowOfferPrice(amountCents: 18000, currency: "usd"))
  private static let listPro = DayflowPlanPrices(
    monthly: DayflowOfferPrice(amountCents: 4000, currency: "usd"),
    yearly: DayflowOfferPrice(amountCents: 36000, currency: "usd"))

  private var plusPrices: DayflowPlanPrices { offer?.plus ?? Self.listPlus }
  private var proPrices: DayflowPlanPrices { offer?.pro ?? Self.listPro }

  private var plusPrice: String { Self.monthlyPrice(plusPrices, interval: selectedBillingInterval) }
  private var proPrice: String { Self.monthlyPrice(proPrices, interval: selectedBillingInterval) }

  /// The price per month: the monthly price, or the yearly price over 12.
  private static func monthlyPrice(_ prices: DayflowPlanPrices, interval: DayflowBillingInterval)
    -> String
  {
    switch interval {
    case .monthly:
      return money(cents: prices.monthly.amountCents, currency: prices.monthly.currency)
    case .yearly:
      return money(
        cents: Int((Double(prices.yearly.amountCents) / 12).rounded()),
        currency: prices.yearly.currency)
    }
  }

  /// Whole months the yearly plan saves against twelve monthly payments, rounded down so the badge
  /// never overstates it. Nil when it saves less than a month.
  private static func freeMonths(_ prices: DayflowPlanPrices) -> Int? {
    let monthly = prices.monthly.amountCents
    guard monthly > 0, prices.monthly.currency == prices.yearly.currency else { return nil }
    let months = (12 * monthly - prices.yearly.amountCents) / monthly
    return months >= 1 ? months : nil
  }

  /// Currencies Stripe counts in whole units rather than cents (yen and won among them), so their
  /// amounts are not divided by 100. From Stripe's list of zero-decimal currencies.
  private static let zeroDecimalCurrencies: Set<String> = [
    "bif", "clp", "djf", "gnf", "jpy", "kmf", "krw", "mga", "pyg", "rwf", "ugx", "vnd", "vuv",
    "xaf",
    "xof", "xpf",
  ]

  /// "$15", "$12.50" when there are cents, or "¥1,500" for a zero-decimal currency.
  /// `cents` is Stripe's amount: cents, or whole units for a zero-decimal currency.
  private static func money(cents: Int, currency: String) -> String {
    let isZeroDecimal = zeroDecimalCurrencies.contains(currency.lowercased())
    let amount = isZeroDecimal ? Double(cents) : Double(cents) / 100
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = currency.uppercased()
    let digits = isZeroDecimal || cents % 100 == 0 ? 0 : 2
    formatter.minimumFractionDigits = digits
    formatter.maximumFractionDigits = digits
    return formatter.string(from: NSNumber(value: amount))
      ?? "\(currency.uppercased()) \(Int(amount))"
  }

  // MARK: - Pieces

  /// "Pick a plan, then finish securely in Stripe Checkout…" with the privacy policy link.
  private var checkoutNote: some View {
    (Text(
      "Pick a plan, then finish securely in Stripe Checkout. Cancel any time, no questions asked.")
      + Text("\n")
      + Text("We are committed to protecting your privacy. View our privacy policy ")
      + Text("[here](https://dayflow.so/privacy)").foregroundColor(AccountColors.orange)
      + Text("."))
      .font(.custom("Figtree", size: 14))
      .foregroundColor(SettingsStyle.secondary)
      .tint(AccountColors.orange)
      .fixedSize(horizontal: false, vertical: true)
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

  // MARK: - Actions

  /// Where the person came from, for analytics: "privacy_shield" after the Privacy Shield upgrade
  /// button sent them here (until the plan arrives), otherwise "settings".
  private var analyticsSource: String {
    PrivacyShield.shared.isUpgradeInProgress ? "privacy_shield" : "settings"
  }

  /// `button` says which one: "plus_card", "pro_card" or "header".
  private func signIn(from button: String) {
    AnalyticsService.shared.capture(
      "settings_account_sign_in_clicked",
      ["button": button, "interval": selectedBillingInterval.rawValue, "source": analyticsSource])
    isAuthSheetPresented = true
  }

  /// `plan` is "plus" for Dayflow Plus; nil buys Dayflow Pro.
  private func checkout(plan: String?) {
    let prices = plan == "plus" ? plusPrices : proPrices
    let price = selectedBillingInterval == .yearly ? prices.yearly : prices.monthly
    AnalyticsService.shared.capture(
      "settings_account_checkout_clicked",
      [
        "plan": plan ?? "pro", "interval": selectedBillingInterval.rawValue,
        "source": analyticsSource,
        "variant": offer?.variant ?? "", "offer_loaded": offer != nil,
        "currency": price.currency, "amount_shown": price.amountCents,
        "current_plan": entitlement.plan, "current_plan_status": entitlement.status,
      ])
    Task {
      await authManager.openBillingCheckout(interval: selectedBillingInterval, plan: plan)
    }
  }

  /// `reason` is "manage_billing", "switch_to_pro" or "switch_to_plus".
  private func openBillingPortal(reason: String) {
    AnalyticsService.shared.capture(
      "settings_account_billing_portal_clicked",
      ["reason": reason, "current_plan": entitlement.plan, "source": analyticsSource])
    Task { await authManager.openBillingPortal() }
  }

  private func signOut() {
    AnalyticsService.shared.capture(
      "settings_account_sign_out_clicked", ["current_plan": entitlement.plan])
    Task { await authManager.signOut() }
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
        title: String(localized: "Sign in"),
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
          text: summary?.inviteURL ?? String(localized: "Loading invite link..."),
          color: theme.textPrimary
        )

        ReferralMiniButton(
          title: copiedReferralLink ? String(localized: "Copied") : String(localized: "Copy"),
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
          title: String(localized: "Send"),
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
          content: Text("They sign up and get a **free month of Dayflow Pro!**")
        )
        ReferralStepRow(
          icon: .system("sparkles"),
          content: Text(
            "You earn **1 month of Dayflow Pro (stackable!)**, when they use Dayflow for a week.")
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
        EmptyReferralState(text: String(localized: "No invites yet."))
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
          title: String(localized: "Apply"),
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
      return String(localized: "Refer")
    case .past:
      return String(localized: "Past referrals (\(summary?.invites.count ?? 0))")
    case .apply:
      return String(localized: "Apply referral")
    }
  }

  private func inviteStatusText(_ invite: DayflowReferralInvite) -> String {
    if invite.unlockedAt != nil {
      return String(localized: "Reward earned")
    }
    if invite.claimedAt != nil {
      return String(localized: "\(String(format: "%.1f", invite.usageHours)) / 40 hours recorded")
    }
    return String(localized: "Invite sent")
  }
}

// MARK: - Account page pieces (Figma "Dayflow - minor adjustments")

/// Fixed colors from the design. The plan cards stay light in dark mode, like printed cards.
private enum AccountColors {
  static let orange = Color(hex: "FF882D")
  static let darkButton = Color(hex: "3A2410")
  static let signOutFill = Color(hex: "DFD9D6")
  static let signOutText = Color(hex: "231C17")
  static let cardText = Color(hex: "3C3531")
  static let cardBorder = Color(hex: "EEE7E2")
  static let cardFill = Color(red: 242 / 255, green: 238 / 255, blue: 237 / 255).opacity(0.7)
  static let priceNote = Color(hex: "767676")
  static let billedNote = Color(hex: "626262")
  static let badgeFill = Color(hex: "FFE3D4")
  static let badgeText = Color(hex: "F5720D")
}

/// One line of a plan's feature list: a green check, or a red cross for something it doesn't include.
private struct AccountPlanFeature: Hashable {
  let text: String
  var isIncluded = true

  static let free = [
    AccountPlanFeature(
      text: String(localized: "Timeline, Daily and Weekly with your own AI provider")),
    AccountPlanFeature(text: String(localized: "Recordings stay on this Mac")),
  ]

  private static let flow = AccountPlanFeature(text: String(localized: "Access to Flow"))
  private static let privacyShield = AccountPlanFeature(
    text: String(
      localized: "Access to Dayflow Privacy Shield to redact personal and sensitive information"))
  private static let prioritySupport = AccountPlanFeature(
    text: String(localized: "Priority support"))

  /// Pro's list on the signed-out page, under "Everything in Plus and more".
  /// Priority support is left out here because Plus has it too.
  static let proExtras = [
    AccountPlanFeature(text: String(localized: "Zero setup cloud AI for timeline generation")),
    AccountPlanFeature(
      text: String(localized: "Processed securely and never used to train AI models")),
  ]

  static let pro =
    [
      flow, privacyShield,
      AccountPlanFeature(text: String(localized: "Unlimited access to all features")),
    ]
    + proExtras + [prioritySupport]

  static let plus = [
    flow,
    privacyShield,
    prioritySupport,
    AccountPlanFeature(
      text: String(localized: "Usage based on your own LLM account limits"), isIncluded: false),
  ]
}

private struct AccountFeatureList: View {
  let features: [AccountPlanFeature]
  var spacing: CGFloat = 8
  var iconSpacing: CGFloat = 8

  var body: some View {
    VStack(alignment: .leading, spacing: spacing) {
      ForEach(features, id: \.self) { feature in
        HStack(alignment: .top, spacing: iconSpacing) {
          Image(feature.isIncluded ? "AccountCheck" : "AccountCross")
            .resizable()
            .frame(width: 16, height: 16)
          Text(feature.text)
            .font(.custom("Figtree", size: 14))
            .foregroundColor(AccountColors.cardText)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}

private struct AccountDivider: View {
  var body: some View {
    Rectangle()
      .fill(SettingsStyle.divider)
      .frame(height: 1)
  }
}

private struct AccountSectionTitle: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.custom("Figtree", size: 14))
      .fontWeight(.semibold)
      .foregroundColor(SettingsStyle.text)
  }
}

/// The Yearly / Monthly pill.
private struct AccountIntervalPicker: View {
  @Binding var selection: DayflowBillingInterval

  var body: some View {
    HStack(spacing: 0) {
      segment(String(localized: "Yearly"), .yearly)
      segment(String(localized: "Monthly"), .monthly)
    }
    .padding(1)
    .frame(width: 140, height: 30)
    .background(Capsule().fill(Color(hex: "E7E6E5")))
    .overlay(Capsule().stroke(Color(hex: "D5D5D5"), lineWidth: 0.75))
  }

  private func segment(_ title: String, _ interval: DayflowBillingInterval) -> some View {
    let isSelected = selection == interval
    return Button {
      withAnimation(.easeOut(duration: 0.16)) { selection = interval }
    } label: {
      Text(title)
        .font(.custom("Figtree", size: 12))
        .fontWeight(.medium)
        .foregroundColor(Color(hex: isSelected ? "606060" : "727272"))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
          if isSelected {
            Capsule()
              .fill(Color(hex: "FFD2B9"))
              .overlay(Capsule().stroke(Color(hex: "EAD5CD"), lineWidth: 0.5))
              .shadow(color: Color(hex: "FFECE6"), radius: 1.5)
          }
        }
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }
}

/// The dark brown button: Sign in (compact) and Manage billing (large).
private struct AccountDarkButton: View {
  enum Style {
    case compact
    case large
  }

  let title: String
  let icon: String
  let style: Style
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 7) {
        Image(icon)
          .renderingMode(.template)
          .resizable()
          .frame(width: 11, height: 11)
        Text(title)
          .font(.custom("Figtree", size: style == .compact ? 11 : 12))
          .fontWeight(style == .compact ? .semibold : .medium)
      }
      .foregroundColor(.white)
      .padding(.horizontal, style == .compact ? 15 : 24)
      .frame(height: style == .compact ? 28 : 36)
      .background(
        RoundedRectangle(cornerRadius: style == .compact ? 6 : 8, style: .continuous)
          .fill(AccountColors.darkButton)
          .shadow(color: AccountColors.darkButton.opacity(0.18), radius: 1, y: 1)
      )
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }
}

private struct AccountSignOutButton: View {
  let isBusy: Bool
  let style: AccountDarkButton.Style
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 7) {
        Image("AccountLogOut")
          .renderingMode(.template)
          .resizable()
          .frame(width: 11, height: 11)
        Text("Sign out")
          .font(.custom("Figtree", size: style == .compact ? 11 : 12))
          .fontWeight(.medium)
      }
      .foregroundColor(AccountColors.signOutText.opacity(isBusy ? 0.4 : 1))
      .padding(.horizontal, style == .compact ? 12 : 24)
      .frame(height: style == .compact ? 29 : 36)
      .background(
        RoundedRectangle(cornerRadius: style == .compact ? 6 : 8, style: .continuous)
          .fill(AccountColors.signOutFill)
      )
    }
    .buttonStyle(.plain)
    .disabled(isBusy)
    .pointingHandCursor()
  }
}

/// The orange pill: Get started, Subscribe to Pro, Switch to Plus.
private struct AccountOrangeButton: View {
  let title: String
  var height: CGFloat = 34
  var width: CGFloat? = nil
  var weight: Font.Weight = .medium
  let isBusy: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ZStack {
        if isBusy {
          ProgressView()
            .controlSize(.small)
            .tint(.white)
        } else {
          Text(title)
            .font(.custom("Figtree", size: 16))
            .fontWeight(weight)
            .lineLimit(1)
        }
      }
      .foregroundColor(.white)
      .frame(width: width, height: height)
      .frame(maxWidth: width == nil ? .infinity : nil)
      .background(Capsule().fill(AccountColors.orange))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .disabled(isBusy)
    .pointingHandCursor()
  }
}

private struct AccountFreeMonthsBadge: View {
  let months: Int

  var body: some View {
    Text(
      months == 1 ? String(localized: "1 MONTH FREE") : String(localized: "\(months) MONTHS FREE")
    )
    .font(.custom("Figtree", size: 12))
    .fontWeight(.bold)
    .kerning(0.6)
    .foregroundColor(AccountColors.badgeText)
    .padding(.horizontal, 4)
    .padding(.vertical, 2)
    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(AccountColors.badgeFill))
  }
}

/// The glossy card shape every plan sits in: a soft color image under a white wash.
private struct AccountCardBackground: ViewModifier {
  let image: String
  /// The wash's top and bottom white opacities.
  let wash: (top: Double, bottom: Double)

  func body(content: Content) -> some View {
    content
      .background {
        ZStack {
          AccountColors.cardFill
          Image(image)
            .resizable()
            .scaledToFill()
          LinearGradient(
            colors: [Color.white.opacity(wash.top), Color.white.opacity(wash.bottom)],
            startPoint: .top, endPoint: .bottom)
        }
        // The fill image spills past the card. Clipping hides that but doesn't stop it catching clicks,
        // so without this it covers and blocks the Yearly/Monthly picker above the cards.
        .allowsHitTesting(false)
      }
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(AccountColors.cardBorder, lineWidth: 1)
      )
      .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
  }
}

/// "Current subscription": the plan's name, its renewal date when it has one, and what it includes.
private struct AccountCurrentPlanCard: View {
  let title: String
  let features: [AccountPlanFeature]
  let dateLabel: String
  let date: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(alignment: .center) {
        Text(title)
          .font(.custom("InstrumentSerif-Regular", size: 24))
          .foregroundColor(.black)
        Spacer(minLength: 16)
        if let date {
          HStack(spacing: 8) {
            Text(dateLabel.uppercased())
              .font(.custom("Figtree", size: 12))
              .fontWeight(.semibold)
              .kerning(0.6)
              .foregroundColor(Color(hex: "C0906B"))
            Text(date)
              .font(.custom("Figtree", size: 14))
              .fontWeight(.semibold)
              .foregroundColor(Color(hex: "58524D"))
          }
          .padding(8)
          .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(hex: "FFE5D7")))
        }
      }
      AccountFeatureList(features: features)
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .modifier(AccountCardBackground(image: "AccountCardGlowWide", wash: (0.52, 0.86)))
  }
}

/// A plan to buy or switch to, signed in: features on the left, price and button on the right.
private struct AccountWidePlanCard: View {
  let title: String
  let features: [AccountPlanFeature]
  let price: String
  let interval: DayflowBillingInterval
  /// Months the yearly plan saves; nil hides the badge.
  let freeMonths: Int?
  let buttonTitle: String
  let background: String
  let isBusy: Bool
  let action: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 20) {
      VStack(alignment: .leading, spacing: 20) {
        Text(title)
          .font(.custom("InstrumentSerif-Regular", size: 24))
          .foregroundColor(.black)
        AccountFeatureList(features: features)
          .frame(maxWidth: 441, alignment: .leading)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      VStack(alignment: .trailing, spacing: 0) {
        VStack(alignment: .trailing, spacing: 8) {
          VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
              Text(price)
                .font(.custom("InstrumentSerif-Regular", size: 32))
                .foregroundColor(.black)
              Text("/ month")
                .font(.custom("Figtree", size: 14))
                .foregroundColor(AccountColors.priceNote)
            }
            Text(interval == .yearly ? "billed annually" : "billed monthly")
              .font(.custom("Figtree", size: 14))
              .foregroundColor(AccountColors.billedNote)
          }
          if interval == .yearly, let freeMonths {
            AccountFreeMonthsBadge(months: freeMonths)
          }
        }
        Spacer(minLength: 20)
        AccountOrangeButton(title: buttonTitle, width: 192, isBusy: isBusy, action: action)
      }
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .modifier(AccountCardBackground(image: background, wash: (0.86, 0.3)))
  }
}

/// A plan on the signed-out page: name, price and Get started on top, what it includes below.
private struct AccountTallPlanCard: View {
  let title: String
  let subtitle: String
  let price: String
  let interval: DayflowBillingInterval
  /// Months the yearly plan saves; nil hides the badge.
  let freeMonths: Int?
  let featuresTitle: String
  let features: [AccountPlanFeature]
  let background: String
  let isBusy: Bool
  let action: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // The subtitle sits under the title row, not beside the badge, so it gets the card's full width
      // and both cards' prices line up.
      HStack(alignment: .top) {
        Text(title)
          .font(.custom("InstrumentSerif-Regular", size: 24))
          .foregroundColor(.black)
        Spacer(minLength: 8)
        if interval == .yearly, let freeMonths {
          AccountFreeMonthsBadge(months: freeMonths)
        }
      }
      Text(subtitle)
        .font(.custom("Figtree", size: 14))
        .foregroundColor(AccountColors.billedNote)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 6)

      HStack(alignment: .lastTextBaseline, spacing: 8) {
        Text(price)
          .font(.custom("InstrumentSerif-Regular", size: 40))
          .foregroundColor(.black)
        Text(interval == .yearly ? "/ month, billed annually" : "/ month")
          .font(.custom("Figtree", size: 14))
          .foregroundColor(AccountColors.priceNote)
      }
      .padding(.top, 42)

      AccountOrangeButton(
        title: String(localized: "Get started"), height: 40, weight: .semibold, isBusy: isBusy,
        action: action
      )
      .padding(.top, 20)

      Rectangle()
        .fill(Color.black.opacity(0.08))
        .frame(height: 1)
        .padding(.vertical, 16)

      VStack(alignment: .leading, spacing: 8) {
        Text(featuresTitle)
          .font(.custom("Figtree", size: 14))
          .fontWeight(.medium)
          .foregroundColor(.black)
        AccountFeatureList(features: features, spacing: 4, iconSpacing: 5)
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 21)
    .padding(.top, 23)
    .padding(.bottom, 20)
    // Grows with its feature list instead of clipping it; the row stretches both cards to the taller one.
    .frame(width: 357, alignment: .topLeading)
    .frame(minHeight: 402, maxHeight: .infinity, alignment: .top)
    .modifier(AccountCardBackground(image: background, wash: (0.94, 0.4)))
  }
}
