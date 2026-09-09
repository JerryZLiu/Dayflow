import Foundation

/// Languages available for the Dayflow interface.
enum AppLanguage: String, CaseIterable, Identifiable {
  case system
  case english
  case simplifiedChinese = "zh-Hans"

  static let storageKey = "appLanguage"

  var id: String { rawValue }

  var locale: Locale {
    switch self {
    case .system:
      return .autoupdatingCurrent
    case .english:
      return Locale(identifier: "en")
    case .simplifiedChinese:
      return Locale(identifier: "zh-Hans")
    }
  }

  var title: String {
    switch self {
    case .system:
      return L10n.tr("System")
    case .english:
      return L10n.tr("English")
    case .simplifiedChinese:
      return L10n.tr("Simplified Chinese")
    }
  }
}

enum L10n {
  static func tr(_ key: String, _ arguments: CVarArg...) -> String {
    let format = localizedBundle.localizedString(forKey: key, value: key, table: nil)
    guard !arguments.isEmpty else { return format }
    return String(format: format, locale: selectedLanguage.locale, arguments: arguments)
  }

  private static var selectedLanguage: AppLanguage {
    guard
      let rawValue = UserDefaults.standard.string(forKey: AppLanguage.storageKey),
      let language = AppLanguage(rawValue: rawValue)
    else {
      return .system
    }
    return language
  }

  private static var localizedBundle: Bundle {
    let languageCode: String
    switch selectedLanguage {
    case .system:
      languageCode = Locale.preferredLanguages.first ?? "en"
    case .english:
      languageCode = "en"
    case .simplifiedChinese:
      languageCode = "zh-Hans"
    }

    for candidate in localizationCandidates(for: languageCode) {
      if let path = Bundle.main.path(forResource: candidate, ofType: "lproj"),
        let bundle = Bundle(path: path)
      {
        return bundle
      }
    }
    return Bundle.main
  }

  private static func localizationCandidates(for identifier: String) -> [String] {
    let normalized = identifier.replacingOccurrences(of: "_", with: "-")
    if normalized.lowercased().hasPrefix("zh") {
      return ["zh-Hans", "zh"]
    }
    if let base = normalized.split(separator: "-").first {
      return [normalized, String(base), "en"]
    }
    return [normalized, "en"]
  }
}
