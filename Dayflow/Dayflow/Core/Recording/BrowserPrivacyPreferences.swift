//
//  BrowserPrivacyPreferences.swift
//  Dayflow
//
//  What the user chose to hide in a browser. Everything stored here is a
//  boolean or a category name — never a URL, and never anything read off a
//  page. That restraint is the feature.
//

import Foundation

enum BrowserPrivacyPreferences {
  private static let hidePrivateWindowsKey = "browserPrivacyHidePrivateWindows"
  private static let blockedCategoriesKey = "browserPrivacyBlockedSiteCategories"
  private static let customDomainsKey = "browserPrivacyCustomBlockedDomains"

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

  // MARK: Rollup

  /// Everything the recorder needs in one read, so a capture tick doesn't
  /// touch UserDefaults four times.
  struct Settings: Equatable, Sendable {
    var hidePrivateWindows: Bool
    var blockedCategories: Set<SiteCategory>
    var customDomains: [String]

    /// Nothing to do, so the recorder can skip the accessibility read.
    var isInactive: Bool {
      !hidePrivateWindows && blockedCategories.isEmpty && customDomains.isEmpty
    }
  }

  static func settings(defaults: UserDefaults = .standard) -> Settings {
    Settings(
      hidePrivateWindows: hidePrivateWindows(defaults: defaults),
      blockedCategories: blockedCategories(defaults: defaults),
      customDomains: customBlockedDomains(defaults: defaults)
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

    // A window Dayflow can't classify is always recorded. (An "If Dayflow can't tell" setting that
    // could hide the whole browser was removed; its old saved value is ignored.)
    if privacy == .unknown {
      return .record
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
  case customSite
  case category(SiteCategory)

  /// Shown on the redaction card. Says why without naming the site.
  var detail: String {
    switch self {
    case .privateWindow:
      return String(localized: "This was a private browsing window.")
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
    case .customSite: return "custom_site"
    case .category(let category): return "category_" + category.rawValue
    }
  }
}
