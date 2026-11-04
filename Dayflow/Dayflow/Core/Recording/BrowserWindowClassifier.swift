//
//  BrowserWindowClassifier.swift
//  Dayflow
//
//  Decides whether a browser window is a private-browsing window, from the
//  labels its accessibility tree exposes. Pure string logic: no accessibility
//  calls here, so it can be tested without a live browser.
//
//  Every marker string below is localized by the browser, so they live in a
//  per-browser table rather than being compared inline. A browser we don't
//  recognise, or a window whose markers don't match any locale we know,
//  comes back as `.unknown` or `.normal` respectively — the caller decides
//  what to do with that, which is what the "if we can't tell, hide the whole
//  browser" setting is for.
//

import Foundation

/// The browser engines whose private-window markers we know about.
enum BrowserFamily: String, Sendable {
  case chromium
  case safari
  case firefox
  /// Chromium-derived browsers whose private-window marker nobody has
  /// published (Arc, Dia). They reportedly expose a private-window
  /// accessibility identifier; until someone measures it, these classify as
  /// unknown rather than guessing wrong in either direction.
  case unverifiedChromium

  private static let bundleIdentifiers: [String: BrowserFamily] = [
    // Chromium, measured on Chrome 2026-11-05.
    "com.google.chrome": .chromium,
    "com.google.chrome.beta": .chromium,
    "com.google.chrome.dev": .chromium,
    "com.google.chrome.canary": .chromium,
    "org.chromium.chromium": .chromium,
    "com.brave.browser": .chromium,
    "com.brave.browser.beta": .chromium,
    "com.brave.browser.nightly": .chromium,
    "com.microsoft.edgemac": .chromium,
    "com.microsoft.edgemac.beta": .chromium,
    "com.microsoft.edgemac.dev": .chromium,
    "com.vivaldi.vivaldi": .chromium,
    "com.operasoftware.opera": .chromium,
    "com.operasoftware.operagx": .chromium,
    "ru.yandex.desktop.yandex-browser": .chromium,
    "com.naver.whale": .chromium,
    "com.coccoc.coccoc": .chromium,

    // Safari.
    "com.apple.safari": .safari,
    "com.apple.safaritechnologypreview": .safari,

    // Gecko.
    "org.mozilla.firefox": .firefox,
    "org.mozilla.firefoxdeveloperedition": .firefox,
    "org.mozilla.nightly": .firefox,
    "org.mozilla.librewolf": .firefox,
    "io.gitlab.librewolf-community.librewolf": .firefox,
    "app.zen-browser.zen": .firefox,

    // Known browsers, unknown markers.
    "company.thebrowser.browser": .unverifiedChromium,
    "company.thebrowser.dia": .unverifiedChromium,
    "com.sigmaos.sigmaos.macos": .unverifiedChromium,
    "com.perplexity.comet": .unverifiedChromium,
  ]

  /// Nil when the app isn't a browser we know about at all, in which case
  /// browser privacy doesn't apply to it.
  static func family(forBundleIdentifier identifier: String?) -> BrowserFamily? {
    guard let identifier, !identifier.isEmpty else { return nil }
    return bundleIdentifiers[identifier.lowercased()]
  }

  static var isKnownBrowser: (String?) -> Bool {
    { family(forBundleIdentifier: $0) != nil }
  }
}

/// The labels read off one browser window. Each field is optional because a
/// browser only exposes some of them, and a busy window may expose none.
struct BrowserWindowSignals: Equatable, Sendable {
  /// The window's `AXTitle`.
  var windowTitle: String?
  /// `AXTitle` / `AXDescription` of toolbar controls. Chrome's incognito
  /// badge lives here, in the slot a normal window gives the profile button.
  var controlLabels: [String] = []
  /// `AXValue` of static text in the window chrome. Safari's "Private" pill.
  var staticTexts: [String] = []
  /// `AXDescription` of the address / smart search field. Safari's says
  /// "smart search field in a private window" instead of "smart search field".
  var locationFieldDescriptions: [String] = []
  /// The active tab's full URL, from the window's `AXURL`.
  var url: String?
}

enum BrowserWindowPrivacy: String, Sendable {
  /// Markers for a private window matched.
  case privateBrowsing
  /// A browser we know, with no private-window marker in sight.
  case normal
  /// A browser whose markers we have never measured, or a window that
  /// exposed no labels at all.
  case unknown
}

/// The localized strings each browser uses to mark a private window.
struct BrowserPrivateMarkers: Sendable {
  /// Tokens that appear as a separated piece of the window title, e.g. the
  /// "(Incognito)" in Chrome's title or the ", Private Browsing" in Safari's.
  let titleTokens: [String]
  /// Tokens that appear as the whole label of a toolbar control or a piece
  /// of static text.
  let labelTokens: [String]
  /// Tokens that appear inside the location field's description.
  let fieldDescriptionTokens: [String]

  static func markers(for family: BrowserFamily) -> BrowserPrivateMarkers? {
    switch family {
    case .chromium: return chromium
    case .safari: return safari
    case .firefox: return firefox
    case .unverifiedChromium: return nil
    }
  }

  /// Chrome's incognito word across the locales it ships. The toolbar button
  /// carries it as both `AXTitle` and `AXDescription`; the window title
  /// carries it in parentheses.
  static let chromium = BrowserPrivateMarkers(
    titleTokens: incognitoWords,
    labelTokens: incognitoWords,
    fieldDescriptionTokens: []
  )

  static let safari = BrowserPrivateMarkers(
    titleTokens: privateBrowsingPhrases,
    labelTokens: privateWords,
    fieldDescriptionTokens: privateWindowPhrases
  )

  static let firefox = BrowserPrivateMarkers(
    titleTokens: privateBrowsingPhrases,
    labelTokens: privateBrowsingPhrases,
    fieldDescriptionTokens: privateBrowsingPhrases
  )

  private static let incognitoWords = [
    "incognito", "in incognito", "incógnito", "modo incógnito",
    "navigation privée", "navigation privee", "inkognito", "anonimowy",
    "anônima", "janela anônima", "navegação anônima", "navegacao anonima",
    "privé", "prive", "incognitomodus", "инкогнито", "режим инкогнито",
    "シークレット", "シークレット モード", "无痕式", "无痕", "無痕式", "無痕",
    "시크릿", "시크릿 모드", "gizli", "anonymní", "anonymni", "анонімний",
    "incognitotila", "incognito-tila",
  ]

  private static let privateWords = [
    "private", "privat", "privada", "privado", "privée", "privee", "privé",
    "prive", "privata", "частный доступ", "プライベート", "无痕浏览", "無痕瀏覽",
    "개인정보 보호", "yksityinen", "prywatne",
  ]

  private static let privateBrowsingPhrases = [
    "private browsing", "privates surfen", "navegación privada",
    "navegacion privada", "navegação privada", "navegacao privada",
    "navigation privée", "navigation privee", "navigazione privata",
    "privé navigeren", "prive navigeren", "частный доступ",
    "プライベートブラウズ", "无痕浏览", "無痕瀏覽", "개인정보 보호 브라우징",
    "yksityinen selaus", "przeglądanie prywatne", "przegladanie prywatne",
    "gizli gezinti",
  ]

  private static let privateWindowPhrases = [
    "in a private window", "private window", "privates fenster",
    "ventana privada", "janela privada", "fenêtre privée", "fenetre privee",
    "finestra privata", "privévenster", "privevenster", "プライベートウインドウ",
    "无痕浏览窗口", "無痕瀏覽視窗", "개인정보 보호 윈도우",
  ]
}

enum BrowserWindowClassifier {
  /// Separators browsers put between the page title and the window's own
  /// labels. Splitting on these keeps "Private Browsing" from matching a
  /// page that merely mentions the phrase mid-sentence.
  private static let titleSeparators = CharacterSet(charactersIn: "()[]—–-,|·•\u{2014}\u{2013}")

  static func classify(
    family: BrowserFamily?,
    signals: BrowserWindowSignals
  ) -> BrowserWindowPrivacy {
    guard let family else { return .unknown }
    guard let markers = BrowserPrivateMarkers.markers(for: family) else { return .unknown }

    let labels = signals.controlLabels + signals.staticTexts
    if labels.contains(where: { matchesWholeLabel($0, markers.labelTokens) }) {
      return .privateBrowsing
    }

    if signals.locationFieldDescriptions.contains(where: {
      containsToken($0, markers.fieldDescriptionTokens)
    }) {
      return .privateBrowsing
    }

    if let title = signals.windowTitle, matchesTitle(title, markers.titleTokens) {
      return .privateBrowsing
    }

    // No markers anywhere and no labels at all: the tree hadn't populated, so
    // say so rather than claiming the window is ordinary.
    if signals.windowTitle == nil, labels.isEmpty, signals.locationFieldDescriptions.isEmpty {
      return .unknown
    }
    return .normal
  }

  /// A title matches when one of its separated pieces is, or ends with, a
  /// marker token. The suffix case is Firefox, whose title reads
  /// "<page> — Mozilla Firefox Private Browsing".
  static func matchesTitle(_ title: String, _ tokens: [String]) -> Bool {
    let pieces = title.components(separatedBy: titleSeparators)
      .map(normalize)
      .filter { !$0.isEmpty }
    guard !pieces.isEmpty else { return false }

    let normalizedTokens = tokens.map(normalize)
    return pieces.contains { piece in
      normalizedTokens.contains { token in
        !token.isEmpty && (piece == token || piece.hasSuffix(" " + token))
      }
    }
  }

  /// A control label matches only when the whole label is a marker — Chrome's
  /// incognito button is titled exactly "Incognito", and matching loosely
  /// would catch any page element that happens to say the word.
  static func matchesWholeLabel(_ label: String, _ tokens: [String]) -> Bool {
    let normalized = normalize(label)
    guard !normalized.isEmpty else { return false }
    return tokens.map(normalize).contains(normalized)
  }

  static func containsToken(_ text: String, _ tokens: [String]) -> Bool {
    let normalized = normalize(text)
    guard !normalized.isEmpty else { return false }
    return tokens.map(normalize).contains { !$0.isEmpty && normalized.contains($0) }
  }

  /// Case- and accent-insensitive, with runs of whitespace collapsed, so one
  /// token covers a browser that capitalizes or spaces its label differently.
  static func normalize(_ value: String) -> String {
    value
      .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}
