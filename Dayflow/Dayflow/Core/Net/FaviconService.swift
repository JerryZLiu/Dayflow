import Foundation
import AppKit

final class FaviconService {
    static let shared = FaviconService()

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private let inFlightLock = NSLock()

    private init() {
        cache.countLimit = 256
    }

    func fetchFavicon(primary: String?, secondary: String?) async -> NSImage? {
        if let host = primary, let img = await fetchHost(host) { return img }
        if let host = secondary, let img = await fetchHost(host) { return img }
        return nil
    }

    private func fetchHost(_ host: String) async -> NSImage? {
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
