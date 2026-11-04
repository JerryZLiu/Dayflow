//
//  BrowserPrivacyPreferences.swift
//  Dayflow
//
//  What the user chose to hide in a browser. Everything stored here is a
//  boolean or a category name — never a URL, and never anything read off a
//  page. That restraint is the feature.
//

import Foundation

/// What to do with a browser window Dayflow can't classify: a browser whose
/// private-window markers were never measured, or a window whose tree hadn't
/// populated yet.
enum UnknownBrowserWindowHandling: String, CaseIterable, Identifiable, Sendable {
  /// Keep recording. The default — it never hides something unexpectedly.
  case record
  /// Hide the whole browser whenever Dayflow can't tell.
  case hideBrowser

  var id: String { rawValue }

  var title: String {
    switch self {
    case .record: return String(localized: "Keep recording")
    case .hideBrowser: return String(localized: "Hide the whole browser")
    }
  }
}

enum BrowserPrivacyPreferences {
  private static let hidePrivateWindowsKey = "browserPrivacyHidePrivateWindows"
  private static let blockedCategoriesKey = "browserPrivacyBlockedSiteCategories"
  private static let customDomainsKey = "browserPrivacyCustomBlockedDomains"
  private static let unknownHandlingKey = "browserPrivacyUnknownWindowHandling"

  // MARK: Private browsing windows

  static func hidePrivateWindows(defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: hidePrivateWindowsKey)
  }

  static func setHidePrivateWindows(_ value: Bool, defaults: UserDefaults = .standard) {
    defaults.set(value, forKey: hidePrivateWindowsKey)
  }

  // MARK: Site categories

  static func blockedCategories(defaults: UserDefaults = .standard) -> Set<SiteCategory> {
    let raw = defaults.stringArray(forKey: blockedCategoriesKey) ?? []
    return Set(raw.compactMap(SiteCategory.init(rawValue:)))
  }

  static func setBlockedCategories(
    _ categories: Set<SiteCategory>,
    defaults: UserDefaults = .standard
  ) {
    defaults.set(categories.map(\.rawValue).sorted(), forKey: blockedCategoriesKey)
  }

  // MARK: Custom domains

  /// Domains the user typed in. Hidden whenever any category is on, so the
  /// list reads as "and also these", not as a category of its own.
  static func customBlockedDomains(defaults: UserDefaults = .standard) -> [String] {
    defaults.stringArray(forKey: customDomainsKey) ?? []
  }

  static func setCustomBlockedDomains(
    _ domains: [String],
    defaults: UserDefaults = .standard
  ) {
    defaults.set(normalizedDomains(domains), forKey: customDomainsKey)
  }

  static func normalizedDomains(_ domains: [String]) -> [String] {
    var seen = Set<String>()
    return domains.compactMap { value in
      guard let domain = SiteCategoryCatalog.registrableDomain(forHost: value),
        domain.contains(".")
      else { return nil }
      return seen.insert(domain).inserted ? domain : nil
    }
  }

  // MARK: Unknown windows

  static func unknownWindowHandling(
    defaults: UserDefaults = .standard
  ) -> UnknownBrowserWindowHandling {
    defaults.string(forKey: unknownHandlingKey)
      .flatMap(UnknownBrowserWindowHandling.init(rawValue:)) ?? .record
  }

  static func setUnknownWindowHandling(
    _ handling: UnknownBrowserWindowHandling,
    defaults: UserDefaults = .standard
  ) {
    defaults.set(handling.rawValue, forKey: unknownHandlingKey)
  }

  // MARK: Rollup

  /// Everything the recorder needs in one read, so a capture tick doesn't
  /// touch UserDefaults four times.
  struct Settings: Equatable, Sendable {
    var hidePrivateWindows: Bool
    var blockedCategories: Set<SiteCategory>
    var customDomains: [String]
    var unknownHandling: UnknownBrowserWindowHandling

    /// Nothing to do, so the recorder can skip the accessibility read.
    var isInactive: Bool {
      !hidePrivateWindows && blockedCategories.isEmpty && customDomains.isEmpty
        && unknownHandling == .record
    }
  }

  static func settings(defaults: UserDefaults = .standard) -> Settings {
    Settings(
      hidePrivateWindows: hidePrivateWindows(defaults: defaults),
      blockedCategories: blockedCategories(defaults: defaults),
      customDomains: customBlockedDomains(defaults: defaults),
      unknownHandling: unknownWindowHandling(defaults: defaults)
    )
  }

  /// The decision for one window, given the user's settings. Carries a reason
  /// for the redaction card and for analytics — a category name at most,
  /// never the URL.
  static func decision(
    privacy: BrowserWindowPrivacy,
    urlString: String?,
    settings: Settings
  ) -> BrowserPrivacyDecision {
    if settings.isInactive { return .record }

    if privacy == .privateBrowsing {
      return settings.hidePrivateWindows ? .hide(reason: .privateWindow) : .record
    }

    if privacy == .unknown {
      return settings.unknownHandling == .hideBrowser
        ? .hide(reason: .unclassifiedWindow) : .record
    }

    if SiteCategoryCatalog.matchesAnyCustomDomain(
      urlString: urlString, customDomains: settings.customDomains)
    {
      return .hide(reason: .customSite)
    }

    if let category = SiteCategoryCatalog.category(forURLString: urlString),
      settings.blockedCategories.contains(category)
    {
      return .hide(reason: .category(category))
    }

    return .record
  }
}

enum BrowserPrivacyDecision: Equatable, Sendable {
  case record
  case hide(reason: BrowserPrivacyReason)

  var isHidden: Bool {
    if case .hide = self { return true }
    return false
  }

  var reason: BrowserPrivacyReason? {
    if case .hide(let reason) = self { return reason }
    return nil
  }
}

enum BrowserPrivacyReason: Equatable, Sendable {
  case privateWindow
  case unclassifiedWindow
  case customSite
  case category(SiteCategory)

  /// Shown on the redaction card. Says why without naming the site.
  var detail: String {
    switch self {
    case .privateWindow:
      return String(localized: "This was a private browsing window.")
    case .unclassifiedWindow:
      return String(localized: "Dayflow couldn't tell what this browser window was showing.")
    case .customSite:
      return String(localized: "This site is on your hidden list.")
    case .category(let category):
      return String(localized: "This site is in the \(category.title) category.")
    }
  }

  /// Safe to send to analytics: a reason name, never a URL or a domain.
  var analyticsName: String {
    switch self {
    case .privateWindow: return "private_window"
    case .unclassifiedWindow: return "unclassified_window"
    case .customSite: return "custom_site"
    case .category(let category): return "category_" + category.rawValue
    }
  }
}
