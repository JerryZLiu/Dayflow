//
//  DailyBriefLinkImages.swift
//  Dayflow
//
//  Finds the picture a web page shows when it's shared (og:image or
//  twitter:image) and saves a copy in the brief's images folder. The reading
//  and news sections show it next to each link. The model reads pages as text
//  and often misses the picture, so the app looks for it itself.
//
//  Many share pictures are title cards: the headline set on a plain background.
//  Next to the card's own text they repeat it, so a picture without words is
//  preferred when the page offers both. Pictures inside the article aren't
//  used: on real pages they were often another story's picture.
//
//  Blocking, like the rest of the brief run: call it off the main thread.
//

import CoreGraphics
import Foundation
import ImageIO
import Vision

enum DailyBriefLinkImages {
  struct Link: Sendable {
    /// The article or page.
    let pageURL: String
    /// A picture the model reported for it, tried after the page's own.
    let hintImageURL: String?
  }

  private static let pageTimeout: TimeInterval = 12
  private static let maxPageBytes = 3_000_000
  private static let maxImageBytes = 12_000_000
  private static let savedMaxPixelSize = 1200
  /// Smaller pictures are icons or avatars.
  private static let minWidth = 400
  private static let minHeight = 200
  /// Width over height. Square pictures are almost always logos, and very wide ones are banners.
  private static let aspectRange = 1.2...3.2
  /// A picture with at least this share of its area covered by words counts as a title card.
  /// On real pages, photos measured 0 and title cards 0.05 to 0.12.
  private static let titleCardTextShare = 0.03
  /// Some sites refuse requests that don't look like a browser.
  private static let userAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
    + "Version/17.0 Safari/605.1.15"

  struct SavedPicture: Sendable {
    let file: String
    /// The picture is a headline set on a background, kept because the page had nothing else.
    let isTitleCard: Bool
  }

  /// Saves one picture per link into `directory` and returns page URL → saved picture.
  /// Links with no usable picture are left out. All links are fetched at once.
  static func save(_ links: [Link], into directory: URL) -> [String: SavedPicture] {
    var pictures: [String: SavedPicture] = [:]
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: links.count) { index in
      let link = links[index]
      guard let picture = savePicture(for: link, into: directory) else { return }
      lock.withLock { pictures[link.pageURL] = picture }
    }
    return pictures
  }

  private static func savePicture(for link: Link, into directory: URL) -> SavedPicture? {
    guard let pageURL = URL(string: link.pageURL) else { return nil }
    var candidates = shareImageURLs(on: pageURL)
    if let hint = link.hintImageURL, let hintURL = URL(string: hint) {
      candidates.append(hintURL)
    }

    // The first picture without words wins. A title card is kept only when there's nothing else.
    var titleCard: CGImage?
    var chosen: CGImage?
    for candidate in candidates.prefix(4) {
      guard let data = fetch(candidate, maxBytes: maxImageBytes), let picture = usablePicture(data)
      else { continue }
      if textShare(of: picture) < titleCardTextShare {
        chosen = picture
        break
      }
      titleCard = titleCard ?? picture
    }

    let file = "link-\(stableHash(link.pageURL)).jpg"
    guard let picture = chosen ?? titleCard,
      writeJPEG(picture, to: directory.appendingPathComponent(file))
    else { return nil }
    return SavedPicture(file: file, isTitleCard: chosen == nil)
  }

  // MARK: - Finding the picture

  /// The page's share pictures, best first.
  private static func shareImageURLs(on pageURL: URL) -> [URL] {
    guard let data = fetch(pageURL, maxBytes: maxPageBytes) else { return [] }
    let html = String(decoding: data, as: UTF8.self)
    let names = ["og:image:secure_url", "og:image", "twitter:image", "twitter:image:src"]

    var urls: [URL] = []
    for name in names {
      guard let content = metaContent(named: name, in: html),
        let url = URL(string: content, relativeTo: pageURL)?.absoluteURL,
        let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
        !urls.contains(url)
      else { continue }
      urls.append(url)
    }
    return urls
  }

  /// The `content` of `<meta property="name" ...>` (or `name="name"`), with the
  /// attributes in either order.
  private static func metaContent(named name: String, in html: String) -> String? {
    let escaped = NSRegularExpression.escapedPattern(for: name)
    let key = #"(?:property|name)\s*=\s*["']"# + escaped + #"["']"#
    let content = #"content\s*=\s*["']([^"']+)["']"#
    let patterns = [
      "<meta[^>]*" + key + "[^>]*" + content,
      "<meta[^>]*" + content + "[^>]*" + key,
    ]
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
        let match = regex.firstMatch(
          in: html, range: NSRange(html.startIndex..., in: html)),
        let range = Range(match.range(at: 1), in: html)
      else { continue }
      let value = html[range]
        .replacingOccurrences(of: "&amp;", with: "&")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !value.isEmpty { return value }
    }
    return nil
  }

  // MARK: - Network

  /// A plain GET that waits for the answer. nil on any error, a non-200 status, or too many bytes.
  private static func fetch(_ url: URL, maxBytes: Int) -> Data? {
    var request = URLRequest(url: url, timeoutInterval: pageTimeout)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("text/html,image/*;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

    let response = FetchedData()
    let done = DispatchSemaphore(value: 0)
    let task = URLSession.shared.dataTask(with: request) { data, urlResponse, _ in
      if let data, (urlResponse as? HTTPURLResponse)?.statusCode == 200, data.count <= maxBytes {
        response.data = data
      }
      done.signal()
    }
    task.resume()
    if done.wait(timeout: .now() + pageTimeout + 3) == .timedOut {
      task.cancel()
      return nil
    }
    return response.data
  }

  /// Carries the answer out of the request's callback. It's written once, before the
  /// semaphore is signaled, and read only after the wait returns.
  private final class FetchedData: @unchecked Sendable {
    var data: Data?
  }

  // MARK: - Checking and saving

  /// The picture, downsized, when it's big and wide enough to be a real picture and not
  /// a logo. nil otherwise.
  private static func usablePicture(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
      width >= minWidth, height >= minHeight,
      aspectRange.contains(Double(width) / Double(height))
    else { return nil }

    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: savedMaxPixelSize,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  /// How much of the picture is covered by words, from 0 to 1, using on-device text recognition.
  private static func textShare(of image: CGImage) -> Double {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .fast
    try? VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).reduce(0) {
      $0 + Double($1.boundingBox.width * $1.boundingBox.height)
    }
  }

  private static func writeJPEG(_ image: CGImage, to url: URL) -> Bool {
    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.jpeg" as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    return CGImageDestinationFinalize(destination)
  }

  /// The same text always gives the same name (Swift's hashValue changes every launch).
  private static func stableHash(_ text: String) -> String {
    let hash = text.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
      ($0 ^ UInt64($1)) &* 1_099_511_628_211
    }
    return String(hash, radix: 16)
  }
}
