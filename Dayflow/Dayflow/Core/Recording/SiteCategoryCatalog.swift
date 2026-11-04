//
//  SiteCategoryCatalog.swift
//  Dayflow
//
//  Maps a URL to one of a handful of sensitive site categories, using a list
//  of domains bundled with the app. Nothing here touches the network: the
//  whole point of the feature is that a URL never leaves the Mac, is never
//  sent to a categorisation service, and is never written down. Callers get
//  back a category name and nothing else.
//

import Foundation

enum SiteCategory: String, CaseIterable, Identifiable, Sendable {
  case bankingAndFinance
  case health
  case governmentAndTax
  case dating
  case adult
  case cryptoWallets

  var id: String { rawValue }

  var title: String {
    switch self {
    case .bankingAndFinance: return String(localized: "Banking and finance")
    case .health: return String(localized: "Health")
    case .governmentAndTax: return String(localized: "Government and tax")
    case .dating: return String(localized: "Dating")
    case .adult: return String(localized: "Adult")
    case .cryptoWallets: return String(localized: "Crypto wallets")
    }
  }

  var detail: String {
    switch self {
    case .bankingAndFinance:
      return String(localized: "Banks, brokerages, card issuers and payment sites.")
    case .health:
      return String(localized: "Patient portals, pharmacies and medical records.")
    case .governmentAndTax:
      return String(localized: "Tax filing, benefits and government services.")
    case .dating:
      return String(localized: "Dating apps and matchmaking sites.")
    case .adult:
      return String(localized: "Adult sites.")
    case .cryptoWallets:
      return String(localized: "Exchanges and wallet interfaces.")
    }
  }
}

enum SiteCategoryCatalog {
  /// Registrable domains per category. Deliberately short and obvious rather
  /// than exhaustive — the list is a sensible starting point, and the tab
  /// lets people add whatever it misses.
  static let bundledDomains: [SiteCategory: [String]] = [
    .bankingAndFinance: [
      "chase.com", "bankofamerica.com", "wellsfargo.com", "citi.com", "citibank.com",
      "capitalone.com", "usbank.com", "pnc.com", "truist.com", "ally.com",
      "discover.com", "amex.com", "americanexpress.com", "schwab.com", "fidelity.com",
      "vanguard.com", "etrade.com", "robinhood.com", "tdameritrade.com", "interactivebrokers.com",
      "paypal.com", "venmo.com", "wise.com", "revolut.com", "monzo.com",
      "chime.com", "sofi.com", "marcus.com", "navyfederal.org", "hsbc.com",
      "barclays.co.uk", "lloydsbank.com", "natwest.com", "santander.com", "nationwide.co.uk",
      "rbc.com", "td.com", "scotiabank.com", "bmo.com", "cibc.com",
      "mint.com", "creditkarma.com", "experian.com", "equifax.com", "transunion.com",
      "stripe.com", "quickbooks.intuit.com", "xero.com", "brex.com", "ramp.com",
    ],
    .health: [
      "mychart.com", "mychart.org", "epic.com", "onepatient.epic.com", "kaiserpermanente.org",
      "cvs.com", "walgreens.com", "goodrx.com", "zocdoc.com", "teladoc.com",
      "labcorp.com", "questdiagnostics.com", "23andme.com", "ancestry.com", "headspace.com",
      "betterhelp.com", "talkspace.com", "drugs.com", "webmd.com", "mayoclinic.org",
      "nhs.uk", "healthcare.gov", "anthem.com", "cigna.com", "uhc.com",
      "aetna.com", "humana.com", "bcbs.com", "flo.health", "clue.app",
    ],
    .governmentAndTax: [
      "irs.gov", "ssa.gov", "usa.gov", "login.gov", "id.me",
      "turbotax.intuit.com", "hrblock.com", "taxact.com", "freetaxusa.com",
      "gov.uk", "hmrc.gov.uk", "canada.ca", "cra-arc.gc.ca", "ato.gov.au",
      "my.gov.au", "uscis.gov", "travel.state.gov", "dmv.ca.gov", "medicare.gov",
      "benefits.gov", "studentaid.gov", "sam.gov", "impots.gouv.fr", "elster.de",
    ],
    .dating: [
      "tinder.com", "bumble.com", "hinge.co", "okcupid.com", "match.com",
      "pof.com", "grindr.com", "scruff.com", "her.app", "coffeemeetsbagel.com",
      "eharmony.com", "zoosk.com", "badoo.com", "happn.com", "feeld.co",
      "raya.app", "jdate.com", "christianmingle.com", "seeking.com", "ashleymadison.com",
    ],
    .adult: [
      "pornhub.com", "xvideos.com", "xhamster.com", "redtube.com", "youporn.com",
      "onlyfans.com", "fansly.com", "chaturbate.com", "stripchat.com", "cam4.com",
      "brazzers.com", "spankbang.com", "eporner.com", "tube8.com", "adultfriendfinder.com",
      "fetlife.com", "literotica.com", "rule34.xxx", "e-hentai.org", "nhentai.net",
    ],
    .cryptoWallets: [
      "coinbase.com", "binance.com", "binance.us", "kraken.com", "gemini.com",
      "crypto.com", "kucoin.com", "bitstamp.net", "bitfinex.com", "okx.com",
      "metamask.io", "phantom.app", "ledger.com", "trezor.io", "exodus.com",
      "blockchain.com", "uniswap.org", "app.uniswap.org", "etherscan.io", "blockchair.com",
      "rainbow.me", "zapper.xyz", "debank.com", "lido.fi", "aave.com",
    ],
  ]

  /// Registrable domain -> category, built once.
  private static let domainIndex: [String: SiteCategory] = {
    var index: [String: SiteCategory] = [:]
    for (category, domains) in bundledDomains {
      for domain in domains {
        guard let key = registrableDomain(forHost: domain) else { continue }
        index[key] = category
      }
    }
    return index
  }()

  /// Which bundled category a URL belongs to, or nil. Takes the URL by value
  /// and returns only the category — nothing retains or logs the URL.
  static func category(forURLString urlString: String?) -> SiteCategory? {
    guard let domain = registrableDomain(forURLString: urlString) else { return nil }
    return domainIndex[domain]
  }

  static func matchesAnyCustomDomain(
    urlString: String?,
    customDomains: [String]
  ) -> Bool {
    guard !customDomains.isEmpty,
      let domain = registrableDomain(forURLString: urlString)
    else { return false }

    return customDomains.contains { candidate in
      guard let normalized = registrableDomain(forHost: candidate) else { return false }
      return normalized == domain
    }
  }

  static func registrableDomain(forURLString urlString: String?) -> String? {
    guard let urlString, !urlString.isEmpty else { return nil }
    let withScheme =
      urlString.contains("://") ? urlString : "https://" + urlString
    guard let host = URLComponents(string: withScheme)?.host else {
      return registrableDomain(forHost: urlString)
    }
    return registrableDomain(forHost: host)
  }

  /// A small public-suffix approximation: the last two labels, or the last
  /// three when the last two are a known two-part suffix like "co.uk". Good
  /// enough to decide whether two hosts are the same site, which is all the
  /// match needs.
  static func registrableDomain(forHost host: String) -> String? {
    var cleaned = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let schemeRange = cleaned.range(of: "://") {
      cleaned = String(cleaned[schemeRange.upperBound...])
    }
    if let slash = cleaned.firstIndex(of: "/") {
      cleaned = String(cleaned[..<slash])
    }
    if let at = cleaned.lastIndex(of: "@") {
      cleaned = String(cleaned[cleaned.index(after: at)...])
    }
    if let colon = cleaned.firstIndex(of: ":") {
      cleaned = String(cleaned[..<colon])
    }
    while cleaned.hasSuffix(".") { cleaned.removeLast() }
    guard !cleaned.isEmpty else { return nil }

    let labels = cleaned.split(separator: ".").map(String.init)
    guard labels.count >= 2 else {
      // A bare host like "localhost" has no registrable domain to speak of.
      return labels.count == 1 ? labels[0] : nil
    }

    let lastTwo = labels.suffix(2).joined(separator: ".")
    if labels.count >= 3, twoPartSuffixes.contains(lastTwo) {
      return labels.suffix(3).joined(separator: ".")
    }
    return lastTwo
  }

  private static let twoPartSuffixes: Set<String> = [
    "co.uk", "org.uk", "gov.uk", "ac.uk", "me.uk", "net.uk", "sch.uk", "nhs.uk",
    "co.jp", "or.jp", "ne.jp", "ac.jp", "go.jp",
    "com.au", "net.au", "org.au", "gov.au", "edu.au", "id.au",
    "co.nz", "net.nz", "org.nz", "govt.nz", "ac.nz",
    "com.br", "net.br", "org.br", "gov.br",
    "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
    "com.hk", "org.hk", "gov.hk",
    "com.sg", "edu.sg", "gov.sg",
    "com.mx", "gob.mx", "com.ar", "gob.ar", "com.co", "gov.co",
    "co.in", "net.in", "org.in", "gov.in", "ac.in",
    "co.kr", "or.kr", "go.kr",
    "co.za", "org.za", "gov.za",
    "com.tr", "gov.tr", "com.tw", "gov.tw", "com.my", "gov.my",
    "gc.ca", "qc.ca", "on.ca",
    "co.il", "org.il", "gov.il",
  ]
}
