import AppKit
import Foundation
import SwiftUI

final class FaviconService {
  static let shared = FaviconService()

  private let cache = NSCache<NSString, NSImage>()
  private var inFlight: [String: Task<NSImage?, Never>] = [:]
  private let inFlightLock = NSLock()
  private let hostAliases: [String: String] = [
    "codex.com": "chatgpt.com",
    "codex.so": "chatgpt.com",
  ]

  // MARK: - Hardcoded Favicon Overrides
  // Pattern-based matching (uses contains) - checked before network fetch
  // Order matters: first match wins (more specific patterns go first)
  private let faviconPatterns: [(pattern: String, asset: String)] = [
    // Dayflow
    ("dayflow", "DayflowFavicon"),

    // AI/tools
    ("chat.openai", "ChatGPTLogo"),
    ("chatgpt", "ChatGPTLogo"),
    ("claude", "ClaudeLogo"),
    ("anthropic", "ClaudeLogo"),
    ("gemini", "GeminiLogo"),

    // Common web apps
    ("youtube", "YouTubeFavicon"),
    ("youtu.be", "YouTubeFavicon"),
    ("reddit", "RedditFavicon"),
    ("twitter", "XFavicon"),
    ("x.com", "XFavicon"),
    ("leagueoflegends", "LeagueOfLegendsFavicon"),
    ("league of legends", "LeagueOfLegendsFavicon"),

    // Apple services - specific patterns first
    ("imessage", "iMessageFavicon"),
    ("messages", "MessagesFavicon"),
    ("facetime", "FaceTimeFavicon"),
    ("findmy", "FindMyFavicon"),
    ("find my", "FindMyFavicon"),
    ("icloud.com/mail", "MailFavicon"),
    ("icloud.com/calendar", "CalendarFavicon"),
    ("icloud.com/notes", "NotesFavicon"),
    ("icloud.com/reminders", "RemindersFavicon"),
    ("icloud.com/photos", "PhotosFavicon"),
    ("music.apple", "MusicFavicon"),
    ("tv.apple", "TVFavicon"),
    ("news.apple", "NewsFavicon"),
    ("books.apple", "BooksFavicon"),
    ("podcasts.apple", "PodcastsFavicon"),
    ("maps.apple", "MapsFavicon"),
    ("weather.apple", "WeatherFavicon"),
    ("fitness.apple", "FitnessFavicon"),
    ("health.apple", "HealthFavicon"),
    ("wallet.apple", "WalletFavicon"),
    ("freeform.apple", "FreeformFavicon"),
    ("shortcuts.apple", "ShortcutsFavicon"),
    ("translate.apple", "TranslateFavicon"),
    ("passwords.apple", "PasswordsFavicon"),
    ("apps.apple", "AppStoreFavicon"),

    // Apple iWork suite
    ("keynote", "KeynoteFavicon"),
    ("numbers", "NumbersFavicon"),
    ("pages.apple", "PagesFavicon"),

    // macOS apps - uniquely Apple names (no false positive risk)
    ("safari", "SafariFavicon"),
    ("finder", "FinderFavicon"),
    ("settings", "SettingsFavicon"),
    ("system preferences", "SettingsFavicon"),
    ("system settings", "SettingsFavicon"),
    ("calculator", "CalculatorFavicon"),
    ("preview", "PreviewFavicon"),
    ("contacts", "ContactsFavicon"),
    ("voice memos", "VoiceMemosFavicon"),
    ("voicememos", "VoiceMemosFavicon"),
    ("app store", "AppStoreFavicon"),
    ("appstore", "AppStoreFavicon"),

    // Terminal apps
    ("ghostty", "GhosttyFavicon"),
    ("terminal", "TerminalFavicon"),
    ("iterm", "iTerm2Favicon"),

    // Code editors
    ("xcode", "XCodeFavicon"),
    ("vs code", "VSCodeFavicon"),
    ("vscode", "VSCodeFavicon"),
    ("visual studio code", "VSCodeFavicon"),

    // Browsers
    ("google chrome", "ChromeFavicon"),
    ("chrome", "ChromeFavicon"),
  ]

  // MARK: - Dual Pattern Overrides (requires BOTH patterns to match)
  // Used for generic words that need "apple" context to avoid false matches
  private let faviconDualPatterns: [(pattern1: String, pattern2: String, asset: String)] = [
    ("mail", "apple", "MailFavicon"),
    ("calendar", "apple", "CalendarFavicon"),
    ("notes", "apple", "NotesFavicon"),
    ("reminders", "apple", "RemindersFavicon"),
    ("photos", "apple", "PhotosFavicon"),
    ("home", "apple", "HomeFavicon"),
    ("stocks", "apple", "StocksFavicon"),
    ("files", "apple", "FilesFavicon"),
    ("clock", "apple", "ClockFavicon"),
    ("music", "apple", "MusicFavicon"),
    ("tv", "apple", "TVFavicon"),
    ("news", "apple", "NewsFavicon"),
    ("books", "apple", "BooksFavicon"),
    ("podcasts", "apple", "PodcastsFavicon"),
    ("weather", "apple", "WeatherFavicon"),
    ("translate", "apple", "TranslateFavicon"),
  ]

  private init() {
    cache.countLimit = 256
  }

  /// Fetches favicon using raw strings for pattern matching, normalized hosts for network fetch.
  /// - Parameters:
  ///   - primaryRaw: Raw primary string (may contain paths like "developer.apple.com/xcode")
  ///   - secondaryRaw: Raw secondary string
  ///   - primaryHost: Normalized host for network fetch (just domain)
  ///   - secondaryHost: Normalized host for network fetch
  func fetchFavicon(
    primaryRaw: String?, secondaryRaw: String?, primaryHost: String?, secondaryHost: String?
  ) async -> NSImage? {
    if let img = resolveRawFavicon(primaryRaw) { return img }
    if let host = primaryHost, let img = await fetchHost(host) { return img }
    if let img = resolveRawFavicon(secondaryRaw) { return img }
    if let host = secondaryHost, let img = await fetchHost(host) { return img }
    return nil
  }

  func hasRawFaviconOverride(_ raw: String?) -> Bool {
    assetName(forRaw: raw) != nil
  }

  static func normalizedHost(from site: String?) -> String? {
    guard var site, !site.isEmpty else { return nil }
    site = site.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let url = URL(string: site), let host = url.host {
      return host
    }
    if site.contains("://"), let url = URL(string: site), let host = url.host {
      return host
    }
    if site.contains("/"), let url = URL(string: "https://" + site), let host = url.host {
      return host
    }
    if !site.contains(".") {
      return site + ".com"
    }
    return site
  }

  private func resolveRawFavicon(_ raw: String?) -> NSImage? {
    guard let assetName = assetName(forRaw: raw) else { return nil }
    return NSImage(named: assetName)
  }

  private func assetName(forRaw raw: String?) -> String? {
    guard let raw else { return nil }
    return matchPattern(raw) ?? matchDualPattern(raw)
  }

  /// Check raw string against hardcoded patterns (no network fetch)
  private func matchPattern(_ raw: String) -> String? {
    let rawLower = raw.lowercased()
    for (pattern, assetName) in faviconPatterns {
      if rawLower.contains(pattern) {
        return assetName
      }
    }
    return nil
  }

  /// Check raw string against dual patterns (requires BOTH patterns to match)
  private func matchDualPattern(_ raw: String) -> String? {
    let rawLower = raw.lowercased()
    for (pattern1, pattern2, assetName) in faviconDualPatterns {
      if rawLower.contains(pattern1) && rawLower.contains(pattern2) {
        return assetName
      }
    }
    return nil
  }

  private func fetchHost(_ host: String) async -> NSImage? {
    let resolvedHost = resolvedHostAlias(for: host)

    // Pattern matching already done in fetchFavicon() — go straight to cache/network
    let key = resolvedHost as NSString
    if let cached = cache.object(forKey: key) {
      return cached
    }

    // Deduplicate concurrent requests for the same host
    if let existing = existingTask(for: resolvedHost) {
      if let img = await existing.value {
        cache.setObject(img, forKey: key)
      }
      return await existing.value
    }

    // Create a new task for this host and store it in-flight
    let task = Task<NSImage?, Never> { [weak self] in
      guard let self = self else { return nil }
      defer { self.removeTask(for: resolvedHost) }

      // Race Google S2 with direct site favicon (slight head-start to S2)
      let siteURL = self.buildSiteFaviconURL(for: resolvedHost)
      let s2URL = self.buildS2URL(for: resolvedHost)

      let result = await withTaskGroup(of: NSImage?.self) { group -> NSImage? in
        // Aggregator fetch first (preferred default)
        group.addTask { [s2URL] in
          await self.requestURL(s2URL)
        }
        // Direct site fetch with a small delay
        group.addTask { [siteURL] in
          // 150ms head-start for S2
          try? await Task.sleep(nanoseconds: 150_000_000)
          return await self.requestURL(siteURL)
        }

        for await img in group {
          if let img {
            group.cancelAll()
            return img
          }
        }
        return nil
      }

      if let result {
        self.cache.setObject(result, forKey: key)
      } else {
        // Both S2 and direct fetch failed — log to PostHog for visibility
        AnalyticsService.shared.capture("favicon_fetch_failed", ["host": resolvedHost])
      }
      return result
    }

    storeTask(task, for: resolvedHost)
    return await task.value
  }

  private func resolvedHostAlias(for host: String) -> String {
    hostAliases[host.lowercased()] ?? host
  }

  private func buildS2URL(for host: String) -> URL? {
    var comps = URLComponents()
    comps.scheme = "https"
    comps.host = "www.google.com"
    comps.path = "/s2/favicons"
    comps.queryItems = [
      // Use domain to avoid requiring scheme; sz kept modest since UI scales to 16
      URLQueryItem(name: "domain", value: host),
      URLQueryItem(name: "sz", value: "64"),
    ]
    return comps.url
  }

  private func buildSiteFaviconURL(for host: String) -> URL? {
    var comps = URLComponents()
    comps.scheme = "https"
    comps.host = host
    comps.path = "/favicon.ico"
    return comps.url
  }

  private func requestURL(_ url: URL?) async -> NSImage? {
    guard let url = url else { return nil }
    var req = URLRequest(url: url)
    req.timeoutInterval = 4
    req.setValue("image/*", forHTTPHeaderField: "Accept")
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 4
    config.timeoutIntervalForResource = 6
    let session = URLSession(configuration: config)
    do {
      let (data, resp) = try await session.data(for: req)
      guard let http = resp as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else {
        return nil
      }
      if let img = NSImage(data: data), img.size.width > 0, img.size.height > 0 {
        return img
      }
    } catch {
      return nil
    }
    return nil
  }

  private func existingTask(for host: String) -> Task<NSImage?, Never>? {
    inFlightLock.lock()
    let task = inFlight[host]
    inFlightLock.unlock()
    return task
  }

  private func storeTask(_ task: Task<NSImage?, Never>, for host: String) {
    inFlightLock.lock()
    inFlight[host] = task
    inFlightLock.unlock()
  }

  private func removeTask(for host: String) {
    inFlightLock.lock()
    inFlight[host] = nil
    inFlightLock.unlock()
  }
}

struct FaviconImageView: View {
  let primaryRaw: String?
  let secondaryRaw: String?
  let primaryHost: String?
  let secondaryHost: String?
  let fallbackRaw: String?
  let size: CGFloat
  let cornerRadius: CGFloat

  @State private var image: NSImage?

  init(
    primaryRaw: String?,
    secondaryRaw: String?,
    primaryHost: String?,
    secondaryHost: String?,
    fallbackRaw: String? = nil,
    size: CGFloat,
    cornerRadius: CGFloat = 2
  ) {
    self.primaryRaw = primaryRaw
    self.secondaryRaw = secondaryRaw
    self.primaryHost = primaryHost
    self.secondaryHost = secondaryHost
    self.fallbackRaw = fallbackRaw
    self.size = size
    self.cornerRadius = cornerRadius
  }

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      } else {
        Color.clear
      }
    }
    .frame(width: size, height: size)
    .task(id: requestKey) {
      image = nil
      guard hasLookupSource else { return }
      image = await FaviconService.shared.fetchFavicon(
        primaryRaw: effectivePrimaryRaw,
        secondaryRaw: secondaryRaw,
        primaryHost: primaryHost,
        secondaryHost: secondaryHost
      )
    }
  }

  private var effectivePrimaryRaw: String? {
    nonEmpty(primaryRaw) ?? nonEmpty(fallbackRaw)
  }

  private var hasLookupSource: Bool {
    effectivePrimaryRaw != nil || nonEmpty(secondaryRaw) != nil
      || nonEmpty(primaryHost) != nil || nonEmpty(secondaryHost) != nil
  }

  private var requestKey: String {
    [
      effectivePrimaryRaw,
      nonEmpty(secondaryRaw),
      nonEmpty(primaryHost),
      nonEmpty(secondaryHost),
    ]
    .map { $0 ?? "" }
    .joined(separator: "|")
  }

  private func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else {
      return nil
    }
    return trimmed
  }
}
