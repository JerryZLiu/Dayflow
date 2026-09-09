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
    ("github", "GithubIcon"),
    ("discord", "DiscordGlyph"),

    // Common web apps
    ("youtube", "YouTubeFavicon"),
    ("youtu.be", "YouTubeFavicon"),
    ("reddit", "RedditFavicon"),
    ("twitter", "XFavicon"),
    ("x.com", "XFavicon"),
    ("leagueoflegends", "LeagueOfLegendsFavicon"),
    ("league of legends", "LeagueOfLegendsFavicon"),
    ("meet.google", "GoogleFavicon"),
    ("google meet", "GoogleFavicon"),

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

  func cachedOrRawFavicon(
    primaryRaw: String?,
    secondaryRaw: String?,
    primaryHost: String?,
    secondaryHost: String?
  ) -> NSImage? {
    if let img = resolveRawFavicon(primaryRaw) { return img }
    if let host = primaryHost, let img = cachedHostFavicon(host) { return img }
    if let img = resolveRawFavicon(secondaryRaw) { return img }
    if let host = secondaryHost, let img = cachedHostFavicon(host) { return img }
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

  private func cachedHostFavicon(_ host: String) -> NSImage? {
    let resolvedHost = resolvedHostAlias(for: host)
    return cache.object(forKey: resolvedHost as NSString)
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

  @Environment(\.dayflowTheme) private var theme
  let backgroundColor: Color?

  @State private var image: NSImage?

  init(
    primaryRaw: String?,
    secondaryRaw: String?,
    primaryHost: String?,
    secondaryHost: String?,
    fallbackRaw: String? = nil,
    size: CGFloat,
    cornerRadius: CGFloat = 2,
    backgroundColor: Color? = nil
  ) {
    self.primaryRaw = primaryRaw
    self.secondaryRaw = secondaryRaw
    self.primaryHost = primaryHost
    self.secondaryHost = secondaryHost
    self.fallbackRaw = fallbackRaw
    self.size = size
    self.cornerRadius = cornerRadius
    self.backgroundColor = backgroundColor
    self._image = State(
      initialValue: FaviconService.shared.cachedOrRawFavicon(
        primaryRaw: Self.effectivePrimaryRaw(primaryRaw: primaryRaw, fallbackRaw: fallbackRaw),
        secondaryRaw: secondaryRaw,
        primaryHost: primaryHost,
        secondaryHost: secondaryHost
      )
    )
  }

  var body: some View {
    Group {
      if let image {
        favicon(image)
      } else {
        Color.clear
      }
    }
    .frame(width: size, height: size)
    .task(id: requestKey) {
      let initialImage = FaviconService.shared.cachedOrRawFavicon(
        primaryRaw: effectivePrimaryRaw,
        secondaryRaw: secondaryRaw,
        primaryHost: primaryHost,
        secondaryHost: secondaryHost
      )
      image = initialImage
      guard hasLookupSource else { return }
      image =
        await FaviconService.shared.fetchFavicon(
          primaryRaw: effectivePrimaryRaw,
          secondaryRaw: secondaryRaw,
          primaryHost: primaryHost,
          secondaryHost: secondaryHost
        ) ?? initialImage
    }
  }

  private func favicon(_ image: NSImage) -> some View {
    let isTemplate = ["ChatGPTLogo", "GithubIcon"].contains(image.name() ?? "")
    let backing: Color? =
      isTemplate
      ? nil
      : FaviconContrast.backing(
        for: image, background: backgroundColor ?? theme.panelSolid,
        base: theme.panelSolid
      )
    return Image(nsImage: image)
      .renderingMode(isTemplate ? .template : .original)
      .resizable()
      .interpolation(.high)
      .aspectRatio(contentMode: .fit)
      .foregroundStyle(theme.textPrimary)
      .padding(backing == nil ? 0 : 1)
      .background {
        if let backing {
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(backing)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
    Self.nonEmpty(value)
  }

  private static func effectivePrimaryRaw(primaryRaw: String?, fallbackRaw: String?) -> String? {
    nonEmpty(primaryRaw) ?? nonEmpty(fallbackRaw)
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else {
      return nil
    }
    return trimmed
  }
}

// Analyze each decoded image once. Weak keys let samples leave with the image cache.
@MainActor
private enum FaviconContrast {
  private static let samples = NSMapTable<NSImage, NSArray>(
    keyOptions: .weakMemory, valueOptions: .strongMemory
  )

  static func backing(for image: NSImage, background: Color, base: Color) -> Color? {
    guard let foreground = NSColor(background).usingColorSpace(.deviceRGB),
      let base = NSColor(base).usingColorSpace(.deviceRGB)
    else { return nil }
    let alpha = foreground.alphaComponent
    let backgroundLuminance = luminance(
      foreground.redComponent * alpha + base.redComponent * (1 - alpha),
      foreground.greenComponent * alpha + base.greenComponent * (1 - alpha),
      foreground.blueComponent * alpha + base.blueComponent * (1 - alpha)
    )
    let values = pixelLuminances(image)
    guard !values.isEmpty else { return nil }
    // A substantial majority must disappear before we change the presentation.
    guard readableFraction(values, against: backgroundLuminance) < 0.4 else { return nil }
    let light: CGFloat = 0.88
    let dark: CGFloat = 0.08
    let lightScore = readableFraction(values, against: luminance(light, light, light))
    let darkScore = readableFraction(values, against: luminance(dark, dark, dark))
    return Color(white: lightScore >= darkScore ? light : dark)
  }

  private static func readableFraction(_ values: [CGFloat], against background: CGFloat) -> Double {
    var readable = 0
    for value in values {
      let lighter: CGFloat = max(value, background) + 0.05
      let darker: CGFloat = min(value, background) + 0.05
      if lighter / darker >= 3 { readable += 1 }
    }
    return Double(readable) / Double(values.count)
  }

  private static func luminance(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGFloat {
    func linear(_ value: CGFloat) -> CGFloat {
      value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
  }

  private static func pixelLuminances(_ image: NSImage) -> [CGFloat] {
    if let cached = samples.object(forKey: image) {
      return cached.compactMap { value in
        guard let number = value as? NSNumber else { return nil }
        return CGFloat(number.doubleValue)
      }
    }
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 24, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
      ), let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { return [] }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(
      in: NSRect(x: 0, y: 0, width: 24, height: 24), from: .zero,
      operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    var values: [CGFloat] = []
    for y in 0..<24 {
      for x in 0..<24 {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
          color.alphaComponent >= 0.5
        else { continue }
        values.append(luminance(color.redComponent, color.greenComponent, color.blueComponent))
      }
    }
    samples.setObject(values.map { NSNumber(value: Double($0)) } as NSArray, forKey: image)
    return values
  }
}
