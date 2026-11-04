import XCTest

@testable import Dayflow

/// Marker matching and domain-to-category matching are pure string logic, so
/// they are tested without a live browser. The marker strings come from an
/// accessibility dump taken on Chrome and Safari on 2026-11-05.
final class BrowserWindowClassifierTests: XCTestCase {

  // MARK: Browser identification

  func testKnownBrowsersMapToFamilies() {
    XCTAssertEqual(BrowserFamily.family(forBundleIdentifier: "com.google.Chrome"), .chromium)
    XCTAssertEqual(BrowserFamily.family(forBundleIdentifier: "com.brave.Browser"), .chromium)
    XCTAssertEqual(BrowserFamily.family(forBundleIdentifier: "com.apple.Safari"), .safari)
    XCTAssertEqual(BrowserFamily.family(forBundleIdentifier: "org.mozilla.firefox"), .firefox)
    XCTAssertEqual(
      BrowserFamily.family(forBundleIdentifier: "company.thebrowser.Browser"),
      .unverifiedChromium)
    XCTAssertNil(BrowserFamily.family(forBundleIdentifier: "com.tinyspeck.slackmacgap"))
    XCTAssertNil(BrowserFamily.family(forBundleIdentifier: nil))
  }

  // MARK: Chrome

  func testChromeIncognitoDetectedFromToolbarButton() {
    // Measured: the incognito button's AXTitle and AXDescription are both
    // exactly "Incognito", in the slot a normal window gives the profile name.
    let signals = BrowserWindowSignals(
      windowTitle: "New Tab - Google Chrome - Jerry",
      controlLabels: ["Incognito", "Incognito"],
      url: "chrome://newtab/"
    )
    XCTAssertEqual(
      BrowserWindowClassifier.classify(family: .chromium, signals: signals), .privateBrowsing)
  }

  func testChromeIncognitoDetectedFromWindowTitle() {
    let signals = BrowserWindowSignals(
      windowTitle: "New Tab - Google Chrome (Incognito)",
      controlLabels: ["Reload", "Back"]
    )
    XCTAssertEqual(
      BrowserWindowClassifier.classify(family: .chromium, signals: signals), .privateBrowsing)
  }

  func testChromeNormalWindowIsNotPrivate() {
    let signals = BrowserWindowSignals(
      windowTitle: "Inbox (12) - mail.google.com - Google Chrome - Jerry",
      controlLabels: ["Jerry", "Reload"],
      locationFieldDescriptions: ["Address and search bar"],
      url: "https://mail.google.com/mail/u/6/#inbox"
    )
    XCTAssertEqual(BrowserWindowClassifier.classify(family: .chromium, signals: signals), .normal)
  }

  func testChromeLocalizedIncognitoLabels() {
    for label in ["Incógnito", "INKOGNITO", "シークレット", "无痕式"] {
      let signals = BrowserWindowSignals(windowTitle: "x", controlLabels: [label])
      XCTAssertEqual(
        BrowserWindowClassifier.classify(family: .chromium, signals: signals),
        .privateBrowsing,
        "expected \(label) to mark a private window")
    }
  }

  func testPageTitledIncognitoDoesNotFalselyMatchALabel() {
    // A page element saying the word is not the toolbar badge: the badge's
    // whole label is the token, a sentence isn't.
    let signals = BrowserWindowSignals(
      windowTitle: "How to use Chrome - Google Chrome - Jerry",
      controlLabels: ["Open an Incognito window"]
    )
    XCTAssertEqual(BrowserWindowClassifier.classify(family: .chromium, signals: signals), .normal)
  }

  // MARK: Safari

  func testSafariPrivateDetectedFromTitle() {
    let signals = BrowserWindowSignals(windowTitle: "Start Page, Private Browsing")
    XCTAssertEqual(
      BrowserWindowClassifier.classify(family: .safari, signals: signals), .privateBrowsing)
  }

  func testSafariPrivateDetectedFromStaticText() {
    let signals = BrowserWindowSignals(windowTitle: "Start Page", staticTexts: ["Private"])
    XCTAssertEqual(
      BrowserWindowClassifier.classify(family: .safari, signals: signals), .privateBrowsing)
  }

  func testSafariPrivateDetectedFromSearchFieldDescription() {
    let signals = BrowserWindowSignals(
      windowTitle: "Start Page",
      locationFieldDescriptions: ["smart search field in a private window"]
    )
    XCTAssertEqual(
      BrowserWindowClassifier.classify(family: .safari, signals: signals), .privateBrowsing)
  }

  func testSafariNormalWindowIsNotPrivate() {
    let signals = BrowserWindowSignals(
      windowTitle: "Example Domain",
      locationFieldDescriptions: ["smart search field"],
      url: "https://example.com"
    )
    XCTAssertEqual(BrowserWindowClassifier.classify(family: .safari, signals: signals), .normal)
  }

  // MARK: Firefox

  func testFirefoxPrivateDetectedFromTitleSuffix() {
    let signals = BrowserWindowSignals(
      windowTitle: "Example Domain — Mozilla Firefox Private Browsing")
    XCTAssertEqual(
      BrowserWindowClassifier.classify(family: .firefox, signals: signals), .privateBrowsing)
  }

  func testFirefoxNormalWindowIsNotPrivate() {
    let signals = BrowserWindowSignals(windowTitle: "Example Domain — Mozilla Firefox")
    XCTAssertEqual(BrowserWindowClassifier.classify(family: .firefox, signals: signals), .normal)
  }

  // MARK: Unknown

  func testUnverifiedBrowserIsUnknown() {
    let signals = BrowserWindowSignals(windowTitle: "Something", controlLabels: ["Incognito"])
    XCTAssertEqual(
      BrowserWindowClassifier.classify(family: .unverifiedChromium, signals: signals), .unknown)
  }

  func testNoFamilyIsUnknown() {
    XCTAssertEqual(
      BrowserWindowClassifier.classify(family: nil, signals: BrowserWindowSignals()), .unknown)
  }

  func testEmptyTreeIsUnknownRatherThanNormal() {
    XCTAssertEqual(
      BrowserWindowClassifier.classify(family: .chromium, signals: BrowserWindowSignals()),
      .unknown)
  }
}

final class SiteCategoryCatalogTests: XCTestCase {

  func testRegistrableDomainStripsSubdomainsAndScheme() {
    XCTAssertEqual(
      SiteCategoryCatalog.registrableDomain(forURLString: "https://secure.chase.com/web/auth"),
      "chase.com")
    XCTAssertEqual(
      SiteCategoryCatalog.registrableDomain(forURLString: "chase.com"), "chase.com")
    XCTAssertEqual(
      SiteCategoryCatalog.registrableDomain(forHost: "www.Example.COM."), "example.com")
    XCTAssertEqual(
      SiteCategoryCatalog.registrableDomain(forHost: "user@host.example.com:8443"),
      "example.com")
  }

  func testRegistrableDomainHandlesTwoPartSuffixes() {
    XCTAssertEqual(
      SiteCategoryCatalog.registrableDomain(forURLString: "https://www.barclays.co.uk/login"),
      "barclays.co.uk")
    XCTAssertEqual(
      SiteCategoryCatalog.registrableDomain(forHost: "my.service.gov.uk"), "service.gov.uk")
  }

  func testRegistrableDomainRejectsEmptyInput() {
    XCTAssertNil(SiteCategoryCatalog.registrableDomain(forURLString: nil))
    XCTAssertNil(SiteCategoryCatalog.registrableDomain(forURLString: ""))
  }

  func testCategoryLookupMatchesSubdomains() {
    XCTAssertEqual(
      SiteCategoryCatalog.category(forURLString: "https://secure.chase.com/web/auth/dashboard"),
      .bankingAndFinance)
    XCTAssertEqual(
      SiteCategoryCatalog.category(forURLString: "https://www.irs.gov/payments"),
      .governmentAndTax)
    XCTAssertEqual(
      SiteCategoryCatalog.category(forURLString: "https://app.coinbase.com/assets"),
      .cryptoWallets)
  }

  func testOrdinarySiteHasNoCategory() {
    XCTAssertNil(SiteCategoryCatalog.category(forURLString: "https://news.ycombinator.com/"))
    XCTAssertNil(SiteCategoryCatalog.category(forURLString: "https://github.com/anthropics"))
  }

  func testCustomDomainMatchingIsSubdomainAware() {
    XCTAssertTrue(
      SiteCategoryCatalog.matchesAnyCustomDomain(
        urlString: "https://portal.acme-health.org/records",
        customDomains: ["acme-health.org"]))
    XCTAssertFalse(
      SiteCategoryCatalog.matchesAnyCustomDomain(
        urlString: "https://example.com", customDomains: ["acme-health.org"]))
    XCTAssertFalse(
      SiteCategoryCatalog.matchesAnyCustomDomain(urlString: nil, customDomains: ["example.com"]))
  }
}

final class BrowserPrivacyDecisionTests: XCTestCase {

  private func settings(
    hidePrivate: Bool = false,
    categories: Set<SiteCategory> = [],
    custom: [String] = [],
    unknown: UnknownBrowserWindowHandling = .record
  ) -> BrowserPrivacyPreferences.Settings {
    BrowserPrivacyPreferences.Settings(
      hidePrivateWindows: hidePrivate,
      blockedCategories: categories,
      customDomains: custom,
      unknownHandling: unknown
    )
  }

  func testEverythingOffRecords() {
    let decision = BrowserPrivacyPreferences.decision(
      privacy: .privateBrowsing, urlString: "https://chase.com", settings: settings())
    XCTAssertEqual(decision, .record)
  }

  func testPrivateWindowHiddenWhenEnabled() {
    let decision = BrowserPrivacyPreferences.decision(
      privacy: .privateBrowsing, urlString: nil, settings: settings(hidePrivate: true))
    XCTAssertEqual(decision, .hide(reason: .privateWindow))
  }

  func testPrivateWindowRecordedWhenOnlyCategoriesAreOn() {
    let decision = BrowserPrivacyPreferences.decision(
      privacy: .privateBrowsing,
      urlString: "https://chase.com",
      settings: settings(categories: [.bankingAndFinance]))
    XCTAssertEqual(decision, .record)
  }

  func testBlockedCategoryHidesOrdinaryWindow() {
    let decision = BrowserPrivacyPreferences.decision(
      privacy: .normal,
      urlString: "https://secure.chase.com/web/auth",
      settings: settings(categories: [.bankingAndFinance]))
    XCTAssertEqual(decision, .hide(reason: .category(.bankingAndFinance)))
  }

  func testUnblockedCategoryIsRecorded() {
    let decision = BrowserPrivacyPreferences.decision(
      privacy: .normal,
      urlString: "https://secure.chase.com/web/auth",
      settings: settings(categories: [.dating]))
    XCTAssertEqual(decision, .record)
  }

  func testOrdinarySiteIsRecorded() {
    let decision = BrowserPrivacyPreferences.decision(
      privacy: .normal,
      urlString: "https://news.ycombinator.com",
      settings: settings(categories: Set(SiteCategory.allCases)))
    XCTAssertEqual(decision, .record)
  }

  func testCustomDomainHides() {
    let decision = BrowserPrivacyPreferences.decision(
      privacy: .normal,
      urlString: "https://portal.acme-health.org/x",
      settings: settings(custom: ["acme-health.org"]))
    XCTAssertEqual(decision, .hide(reason: .customSite))
  }

  func testUnknownWindowFollowsTheUsersChoice() {
    XCTAssertEqual(
      BrowserPrivacyPreferences.decision(
        privacy: .unknown, urlString: nil, settings: settings(hidePrivate: true)),
      .record)
    XCTAssertEqual(
      BrowserPrivacyPreferences.decision(
        privacy: .unknown, urlString: nil,
        settings: settings(hidePrivate: true, unknown: .hideBrowser)),
      .hide(reason: .unclassifiedWindow))
  }

  func testReasonAnalyticsNamesCarryNoURL() {
    XCTAssertEqual(BrowserPrivacyReason.privateWindow.analyticsName, "private_window")
    XCTAssertEqual(BrowserPrivacyReason.customSite.analyticsName, "custom_site")
    XCTAssertEqual(
      BrowserPrivacyReason.category(.health).analyticsName, "category_health")
  }

  func testNormalizedDomainsDropsJunkAndDuplicates() {
    let cleaned = BrowserPrivacyPreferences.normalizedDomains([
      " https://WWW.Example.com/path ", "example.com", "notadomain", "",
    ])
    XCTAssertEqual(cleaned, ["example.com"])
  }
}
