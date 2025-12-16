import Foundation
import AppKit

final class FaviconService {
    static let shared = FaviconService()

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private let inFlightLock = NSLock()

    // MARK: - Hardcoded Favicon Overrides
    // Pattern-based matching (uses contains) - checked before network fetch
    // Order matters: first match wins (more specific patterns go first)
    private let faviconPatterns: [(pattern: String, asset: String)] = [
        // Dayflow
        ("dayflow", "DayflowFavicon"),

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
    func fetchFavicon(primaryRaw: String?, secondaryRaw: String?, primaryHost: String?, secondaryHost: String?) async -> NSImage? {
        print("[FaviconService] 🔍 Fetching favicon - primaryRaw: '\(primaryRaw ?? "nil")' primaryHost: '\(primaryHost ?? "nil")'")

        // First, try single pattern matching against raw strings (preserves paths like /xcode)
        if let raw = primaryRaw, let img = matchPattern(raw) { return img }
        if let raw = secondaryRaw, let img = matchPattern(raw) { return img }

        // Then try dual pattern matching (requires both patterns, e.g., "mail" + "apple")
        if let raw = primaryRaw, let img = matchDualPattern(raw) { return img }
        if let raw = secondaryRaw, let img = matchDualPattern(raw) { return img }

        // Fall back to network fetch using normalized hosts
        if let host = primaryHost, let img = await fetchHost(host) { return img }
        if let host = secondaryHost, let img = await fetchHost(host) { return img }
        return nil
    }

    /// Check raw string against hardcoded patterns (no network fetch)
    private func matchPattern(_ raw: String) -> NSImage? {
        let rawLower = raw.lowercased()
        for (pattern, assetName) in faviconPatterns {
            if rawLower.contains(pattern) {
                if let img = NSImage(named: assetName) {
                    print("[FaviconService] ✅ Pattern matched '\(raw)' → '\(pattern)' → asset '\(assetName)'")
                    return img
                } else {
                    print("[FaviconService] ⚠️ Pattern matched but asset NOT FOUND: '\(raw)' → '\(pattern)' → '\(assetName)'")
                }
            }
        }
        return nil
    }

    /// Check raw string against dual patterns (requires BOTH patterns to match)
    private func matchDualPattern(_ raw: String) -> NSImage? {
        let rawLower = raw.lowercased()
        for (pattern1, pattern2, assetName) in faviconDualPatterns {
            if rawLower.contains(pattern1) && rawLower.contains(pattern2) {
                if let img = NSImage(named: assetName) {
                    print("[FaviconService] ✅ Dual pattern matched '\(raw)' → '\(pattern1)' + '\(pattern2)' → asset '\(assetName)'")
                    return img
                } else {
                    print("[FaviconService] ⚠️ Dual pattern matched but asset NOT FOUND: '\(raw)' → '\(pattern1)' + '\(pattern2)' → '\(assetName)'")
                }
            }
        }
        return nil
    }

    private func fetchHost(_ host: String) async -> NSImage? {
        // Pattern matching already done in fetchFavicon() — go straight to cache/network
        let key = host as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        // Deduplicate concurrent requests for the same host
        if let existing = existingTask(for: host) {
            if let img = await existing.value {
                cache.setObject(img, forKey: key)
            }
            return await existing.value
        }

        // Create a new task for this host and store it in-flight
        let task = Task<NSImage?, Never> { [weak self] in
            guard let self = self else { return nil }
            defer { self.removeTask(for: host) }

            // Race Google S2 with direct site favicon (slight head-start to S2)
            let siteURL = self.buildSiteFaviconURL(for: host)
            let s2URL = self.buildS2URL(for: host)

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
                AnalyticsService.shared.capture("favicon_fetch_failed", ["host": host])
            }
            return result
        }

        storeTask(task, for: host)
        return await task.value
    }

    private func buildS2URL(for host: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "www.google.com"
        comps.path = "/s2/favicons"
        comps.queryItems = [
            // Use domain to avoid requiring scheme; sz kept modest since UI scales to 16
            URLQueryItem(name: "domain", value: host),
            URLQueryItem(name: "sz", value: "64")
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
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else { return nil }
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
