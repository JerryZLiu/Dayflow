//
//  AccessibilityLogCondenser.swift
//  Dayflow
//
//  Turns the raw accessibility log for a stretch of time into a short text
//  record that card generation reads next to the screenshots: window
//  switches, the new on-screen text, and what the user typed, sent, clicked
//  and ran. A busy 15 minutes of raw log is around 700 KB; the condensed
//  record keeps every name, message and link in about a sixth of that.
//
//  The work is one pass over the events, in order:
//    - Screen reads drop interface chrome (button labels seen in earlier
//      windows, like counts, video controls, menus) and anything already
//      written in the same 15-minute window, including text contained in
//      longer text written earlier and long text whose pieces were all seen.
//    - Chat apps (Messages, Slack, Claude) get speaker labels, and links keep
//      their destination only where it adds something.
//    - Typing collapses to the last draft per field, and each Return is
//      checked against the screen right after it: sent, still in the box,
//      or queued.
//
//  This is a port of the Python condenser (opus7) used in the card
//  generation benchmarks; it should produce the same text for the same log.
//

import Foundation

enum AccessibilityLogCondenser {
  /// Fewer events than this is a stretch where the recorder was barely
  /// running; the record would say almost nothing.
  static let minimumEvents = 20

  /// The largest record sent with a batch, in UTF-8 bytes. The median busy
  /// batch condenses to about 125 KB; past this, screen text is left out but
  /// every action line is kept (see `trimmed`). Bytes rather than characters
  /// because Codex gets the prompt as a command-line argument, and macOS caps
  /// all arguments together at 1 MB.
  static let maxBytes = 200_000

  /// The condensed record for `[start, end)`, or nil when there is no log for
  /// that time (the recorder is off, or wasn't running).
  static func condensedLog(from start: Date, to end: Date) -> String? {
    let events = loadEvents(from: start, to: end)
    guard events.count >= minimumEvents else { return nil }
    let text = trimmed(condense(events, userName: NSFullUserName()))
    return text.isEmpty ? nil : text
  }

  /// Reads the events in `[start, end)` from the log files. Lines that
  /// can't be read (a line cut short by a full disk or a crash) are skipped.
  static func loadEvents(from start: Date, to end: Date) -> [AccessibilityLogEvent] {
    let decoder = AccessibilityLogEvent.decoder()
    var events: [AccessibilityLogEvent] = []
    for url in AccessibilityLogStore.shared.logFiles(from: start, to: end) {
      guard let data = try? Data(contentsOf: url) else { continue }
      for line in data.split(separator: 0x0A) {
        guard let event = try? decoder.decode(AccessibilityLogEvent.self, from: line),
          event.time >= start, event.time < end
        else { continue }
        events.append(event)
      }
    }
    // A stable sort, so events with the same time keep the order they were written in.
    return events.enumerated()
      .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
      .map(\.element)
  }

  /// The condensed text for events already in time order.
  static func condense(_ events: [AccessibilityLogEvent], userName: String) -> String {
    let firstName =
      userName.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
    let condenser = Condenser(titleJunk: CondenserPatterns.titleJunk(profileName: firstName))
    return condenser.run(events)
  }

  /// Keeps a record under `maxBytes`. Lines that start with a time (window
  /// switches, typing, sends, clicks) are kept first; the indented
  /// screen-text lines under them are kept in order until the budget runs
  /// out. In the rare stretch where the action lines alone are too big, the
  /// end of the record is cut off.
  static func trimmed(_ text: String, maxBytes: Int = maxBytes) -> String {
    guard text.utf8.count > maxBytes else { return text }
    let lines = text.components(separatedBy: "\n")
    let actionBytes = lines.filter { !$0.hasPrefix("  ") }.reduce(0) { $0 + $1.utf8.count + 1 }
    // Room for the closing note that says how much was left out.
    let noteRoom = 100
    var screenBudget = maxBytes - noteRoom - actionBytes
    var kept: [String] = []
    var leftOut = 0
    for line in lines {
      if !line.hasPrefix("  ") {
        kept.append(line)
      } else if line.utf8.count + 1 <= screenBudget {
        kept.append(line)
        screenBudget -= line.utf8.count + 1
      } else {
        leftOut += 1
      }
    }

    let note = "(\(leftOut) more lines of screen text left out to keep this log short)"
    var budget = maxBytes - noteRoom
    var result: [String] = []
    for line in kept {
      guard line.utf8.count + 1 <= budget else { break }
      result.append(line)
      budget -= line.utf8.count + 1
    }
    if result.count < kept.count {
      result.append("(the rest of this stretch is left out to keep this log short)")
    } else if leftOut > 0 {
      result.append(note)
    }
    return result.joined(separator: "\n")
  }
}

// MARK: - Screen items

/// One line of a screen-text snapshot or diff, e.g.
/// `+ [12] button "Send" (focused) = "value" placeholder="Message" <https://…>`.
private struct ScreenItem {
  /// `+` for an added line, `~` for a changed one, nil in a full snapshot.
  var mark: String?
  var id: String
  var role: String
  var label: String
  var states: String
  var value: String
  var placeholder: String?
  var url: String
  /// Set when several short pieces were joined into one: "words" for a
  /// sentence split one word per element, "values" for a row of prices.
  var run: String?

  static func parse(_ body: String?) -> [ScreenItem] {
    guard let body else { return [] }
    return body.components(separatedBy: "\n").compactMap { line in
      guard let groups = CondenserPatterns.screenLine.matchAtStart(line), let role = groups[3]
      else { return nil }
      return ScreenItem(
        mark: groups[1], id: groups[2] ?? "", role: role, label: groups[4] ?? "",
        states: groups[5] ?? "", value: groups[6] ?? "", placeholder: groups[7],
        url: groups[8] ?? "")
    }
  }
}

// MARK: - Patterns and word lists

private enum CondenserPatterns {
  static let screenLine = PatternMatcher(
    #"^\s*(?:([~+]) )?\s*\[(\d+)\] (\w+)(?: "(.*?)")?(?: \(([a-z,]*)\))?(?: = "(.*)")?(?: placeholder="(.*?)")?(?: <(.*)>)?\s*$"#
  )

  static let controlRoles: Set<String> = [
    "button", "checkbox", "radiobutton", "popupbutton", "menuitem", "menubutton",
    "slider", "tab", "disclosuretriangle", "incrementor", "colorwell", "switch",
  ]
  static let dropRoles: Set<String> = [
    "listmarker", "toolbar", "menu", "menubar", "list", "window", "scrollarea",
    "splitgroup", "tabgroup", "outline", "table", "browser", "image", "progressindicator",
    "busyindicator", "levelindicator", "valueindicator", "matte", "ruler",
  ]
  static let browsers: Set<String> = ["Google Chrome", "Safari", "Arc", "Firefox", "Dia", "Comet"]
  static let addressFields: Set<String> = [
    "Address and search bar", "Address bar", "Search or enter address",
  ]
  static let terminals: Set<String> = [
    "Ghostty", "Terminal", "iTerm2", "Warp", "kitty", "Alacritty",
  ]
  static let noteApps: Set<String> = ["Notes", "TextEdit", "Obsidian", "Bear"]
  static let chatApps: Set<String> = ["Messages", "Slack", "Claude", "ChatGPT", "Grok Bot"]
  static let uiWords: Set<String> = [
    "copy", "fork from here", "read aloud", "pin as chapter", "add reaction…", "forward message…",
    "add to-do", "more actions", "message actions", "emoji", "mention someone", "attach", "close",
    "show formatting", "record video clip", "like", "reply", "repost", "share post", "bookmark",
    "grok actions", "more", "stop", "send", "new tab", "reload", "back", "forward",
  ]
  /// Status words that belong to the row before them (sidebar sessions, task rows).
  static let rowStatus: Set<String> = [
    "Running", "Unread response", "Unread", "Failed", "Completed", "Queued", "Waiting", "Paused",
    "Has draft",
  ]
  /// Status words that belong to the row after them (Claude's task checklist).
  static let nextStatus: Set<String> = ["in progress", "not done", "done"]

  /// Window-title endings that say nothing about the page: Chrome's tab
  /// states and the Chrome profile name.
  static func titleJunk(profileName: String) -> PatternMatcher {
    var endings =
      #"Audio playing|Camera and microphone recording|Camera recording|Microphone recording|"#
      + #"High memory usage - [\d.]+ [MG]B|Memory usage - [\d.]+ [MG]B|Network sharing|Google Chrome"#
    if !profileName.isEmpty {
      let name = NSRegularExpression.escapedPattern(for: profileName)
      endings += "|" + name + "|" + name + #" \(Personal\)"#
    }
    return PatternMatcher("( - (" + endings + "))+$")
  }

  static let metric = PatternMatcher(
    #"^[\s\d.,:kKmM%·/|()+\-–—]*(?:(?:replies|reply|reposts?|likes?|bookmarks?|views?|reactions?|"#
      + #"react with[^,]*|comments?|shares?|minutes?|hours?|seconds?|ago|days?|weeks?|AM|PM|"#
      + #"Today|Yesterday|at|Like|Reply|Repost|View post analytics|Share|Bookmark|emoji)[\s\d.,:kKmM%·/|()+\-–—]*)*$"#,
    caseInsensitive: true)
  static let tracking = PatternMatcher(
    #"([?&])(utm_[a-z]+|ved|ei|sa|usg|sca_esv|sxsrf|oq|gs_lcrp|sourceid|ie|uact|fbclid|gclid|"#
      + #"si|ref_src|ref|source|aqs|rlz|bih|biw|dpr|client|iflsig|gs_lp|sclient|ust|opi|"#
      + #"g_st|pli|hl|zx|no_sw_cr)=[^&#]*"#,
    caseInsensitive: true)
  /// Ticking counters and relative times ("12 likes", "5 minutes ago"), masked
  /// so a post doesn't count as new each time a number changes.
  static let counter = PatternMatcher(
    #"\b\d[\d.,]*[km]?\s*(replies|reply|reposts?|likes?|bookmarks?|views?|reactions?|comments?|"#
      + #"votes?|retweets?|quotes?|shares?|upvotes?|points?|(seconds?|minutes?|mins?|hours?|hrs?|days?|weeks?|months?) ago|[smhd] ago)\b"#
      + #"|\b(\d+|an?) (seconds?|minutes?|hours?|days?) ago\b|\b\d+[smhd]\b(?= ·| ago)|(\d[\d.,]*[km]?)(?= (likes|views|replies|reposts))"#
  )
  static let elapsed = PatternMatcher(#"\b(\d+h )?\d+m \d+s\b|\b\d+s\b|\b\d+m\b"#)
  static let durationOnly = PatternMatcher(
    #"^(\d+h )?(\d+m )?\d+[sm]$|^[\d.]+k? tokens$|^\d+%$|^\d+(\.\d+)?k?$"#)
  static let metricPhrase = PatternMatcher(
    #"\b\d[\d.,]*[KkMm]? (replies|reply|reposts?|likes?|bookmarks?|views?|votes?|comments?)\b,?( ·)?"#
  )
  static let dateToken = PatternMatcher(
    #"\b(Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*,? |\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]* \d{1,2},?( \d{4})?|\b\d{1,2} (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\b"#
  )
  /// Short table cells and list values ("$0.50 per million", "0.92", "8,900"),
  /// joined to the label before them.
  static let value = PatternMatcher(
    #"^[$€£]\s?\d[\d.,]*\s?[kKmMbB]?( (per|/) .{1,20})?$|^\d[\d,]*\.\d+%?$|^\d{1,3}(,\d{3})+( \w+)?$|^\d+(\.\d+)?%$"#
  )
  /// Only joins a row that already has a value.
  static let plainValue = PatternMatcher(#"^\d+(\.\d+)?[kKmM]?$"#)
  /// Chat date dividers and bare message times.
  static let divider = PatternMatcher(
    #"^((Today|Yesterday|(Mon|Tues|Wednes|Thurs|Fri|Satur|Sun)day|(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\w* \d{1,2}(, \d{4})?),? )?(at )?\d{1,2}:\d\d(:\d\d)?\s?[AP]M$|^(Today|Yesterday)$"#
  )
  static let claudeUI = PatternMatcher(
    #"^(More options for |Message \d+$|Open .* in Background tasks$|.*, rename session$|Show message actions)"#
  )
  /// Assistant and send status lines; when one flips back to a text seen
  /// earlier it is written again.
  static let statusLine = PatternMatcher(
    #"^((Claude|ChatGPT|Gemini|Grok|Copilot) (is responding|is thinking|finished the response|stopped)|"#
      + #"(Thinking|Generating|Searching|Stopped|Sending|Sent|Delivered|Read|Failed)\b.{0,30}$)"#
  )
  static let messageBubble = PatternMatcher(
    #"^(Your iMessage|Your Text Message|Your SMS|[^,]{1,60}), (.*), (\d{1,2}:\d\d\s?[AP]M)$"#)
  static let ownBubble = PatternMatcher(
    #"^(Your iMessage|Your Text Message|Your SMS), (.*), (\d{1,2}:\d\d\s?[AP]M)$"#)
  static let reaction = PatternMatcher(#", (You|[^,]{1,40}) reacted with [^,]+$"#)
  static let replyDecoration = PatternMatcher(
    #"^(Reply Preview|Reply…), |, [^,]{1,40} (liked|loved|laughed at|emphasized|disliked|questioned) this$"#
  )
  static let nonTextBubble = PatternMatcher(
    #"^(Sticker|Includes picture|Image|Photo|Attachment|\d+ (images?|photos?|videos?)\b)"#)
  static let sendFailure = PatternMatcher(
    #"Message Send Failure|Not Delivered|failed to send|couldn.t be sent"#)
  static let slackReactions = PatternMatcher(#"\.? ?\d+ reactions?\.?$"#)
  static let slackPermalink = PatternMatcher(#"/archives/[A-Z0-9]+/p\d+"#)
  static let slackTimestampLabel = PatternMatcher(
    #"^(Today|Yesterday|\w+day|\w+ \d+)(st|nd|rd|th)? at |^\d"#)
  static let xStatus = PatternMatcher(#"x\.com/[^/]+/status/\d+$"#)
  static let chatHeading = PatternMatcher(#"^(You said|Claude responded): "#)
  static let messageGroup = PatternMatcher(#"^Message \d+$"#)
  static let clockTime = PatternMatcher(#"\d:\d\d\s?[AP]M"#)
  static let memoryTab = PatternMatcher(#" - (Memory usage|High memory usage)"#)
  static let gmailUnread = PatternMatcher(#"^unread, "#)
  static let focusedField = PatternMatcher(
    #"\] (textarea|textfield)(?: "(.*?)")?(?: \(([a-z,]*)\))?(?: = "(.*)")?(?: placeholder=".*")?\s*$"#
  )
  static let ignoredClickTarget = PatternMatcher(
    #"^(webarea|dockitem|group "(Chat messages|Messages)")"#)
  static let whitespaceRun = PatternMatcher(#"\s+"#)
  static let doubleSpace = PatternMatcher(#"\s{2,}"#)
  static let whitespace = PatternMatcher(#"\s"#)
  static let threeLetters = PatternMatcher(#"[A-Za-z]{3}"#)
  static let digit = PatternMatcher(#"\d"#)
  static let endsWithDigit = PatternMatcher(#"\d$"#)
  static let upToThreeDigits = PatternMatcher(#"\d{1,3}"#)
  static let continuation = PatternMatcher(#"^[,.;:?!)]"#)
  static let sentenceEnd = PatternMatcher(#"[.!?:]$"#)
  static let sentenceBreak = PatternMatcher(#"(?<=[.!?])\s+(?=[A-Z“"(])"#)
  static let shingleWord = PatternMatcher(#"[a-z0-9#]+"#)
  static let googleRedirect = PatternMatcher(
    #"https?://www\.google\.[a-z.]+/url\?(?:.*&)?q=([^&]+)"#)
  static let trailingQuerySeparators = PatternMatcher(#"[?&]+$"#)
  static let repeatedAmpersands = PatternMatcher(#"&&+"#)
  static let statusSubpage = PatternMatcher(
    #"(/status/\d+)/(analytics|photo/\d+|likes|retweets|quotes)$"#)
  static let mapsTail = PatternMatcher(#"(/maps/(place|dir)/[^@]*?)/(@|data=).*$"#)
  static let urlBase = PatternMatcher(#"^(https?://[^/?#]+)([^?#]*)"#)
  static let urlHost = PatternMatcher(#"^[^/]+"#)
}

// MARK: - Text helpers

/// Thin wrapper over NSRegularExpression with the handful of operations the
/// condenser needs.
private struct PatternMatcher {
  let regex: NSRegularExpression

  init(_ pattern: String, caseInsensitive: Bool = false) {
    // `.` matches any character but a newline in the Python condenser; on its
    // own NSRegularExpression also stops at \r and U+2028, which do show up in
    // screen text. Text is split on newlines before matching.
    var options: NSRegularExpression.Options = [.dotMatchesLineSeparators]
    if caseInsensitive { options.insert(.caseInsensitive) }
    // The patterns are fixed strings, so a failure here is a programming error.
    regex = try! NSRegularExpression(pattern: pattern, options: options)
  }

  private func fullRange(_ text: String) -> NSRange {
    NSRange(text.startIndex..<text.endIndex, in: text)
  }

  /// True when the pattern matches anywhere in the text.
  func search(_ text: String) -> Bool {
    regex.firstMatch(in: text, range: fullRange(text)) != nil
  }

  /// True when the pattern matches at the start of the text.
  func matchesStart(_ text: String) -> Bool {
    regex.firstMatch(in: text, options: [.anchored], range: fullRange(text)) != nil
  }

  /// True when the pattern matches the whole text.
  func matchesWhole(_ text: String) -> Bool {
    guard let match = regex.firstMatch(in: text, options: [.anchored], range: fullRange(text))
    else { return false }
    return match.range.length == (text as NSString).length
  }

  /// The groups of a match at the start of the text; index 0 is the whole match.
  func matchAtStart(_ text: String) -> [String?]? {
    guard let match = regex.firstMatch(in: text, options: [.anchored], range: fullRange(text))
    else { return nil }
    return groups(of: match, in: text)
  }

  /// The groups of the first match anywhere in the text.
  func firstMatch(_ text: String) -> [String?]? {
    guard let match = regex.firstMatch(in: text, range: fullRange(text)) else { return nil }
    return groups(of: match, in: text)
  }

  func count(in text: String) -> Int {
    regex.numberOfMatches(in: text, range: fullRange(text))
  }

  func allMatches(_ text: String) -> [String] {
    regex.matches(in: text, range: fullRange(text)).compactMap { match in
      Range(match.range, in: text).map { String(text[$0]) }
    }
  }

  /// Replaces every match. `template` uses `$1` for groups.
  func replace(_ text: String, with template: String) -> String {
    regex.stringByReplacingMatches(in: text, range: fullRange(text), withTemplate: template)
  }

  /// The pieces between matches.
  func split(_ text: String) -> [String] {
    var pieces: [String] = []
    var pieceStart = text.startIndex
    for match in regex.matches(in: text, range: fullRange(text)) {
      guard let range = Range(match.range, in: text) else { continue }
      pieces.append(String(text[pieceStart..<range.lowerBound]))
      pieceStart = range.upperBound
    }
    pieces.append(String(text[pieceStart...]))
    return pieces
  }

  private func groups(of match: NSTextCheckingResult, in text: String) -> [String?] {
    (0..<match.numberOfRanges).map { index in
      Range(match.range(at: index), in: text).map { String(text[$0]) }
    }
  }
}

/// Lengths and slices count Unicode scalars, the way the Python condenser
/// counts characters, so the limits below cut in the same places.
extension String {
  fileprivate var scalarCount: Int { unicodeScalars.count }

  fileprivate func scalarPrefix(_ count: Int) -> String {
    String(String.UnicodeScalarView(unicodeScalars.prefix(count)))
  }

  fileprivate func droppingScalars(first count: Int) -> String {
    String(String.UnicodeScalarView(unicodeScalars.dropFirst(count)))
  }

  fileprivate func droppingScalars(last count: Int) -> String {
    String(String.UnicodeScalarView(unicodeScalars.dropLast(count)))
  }

  /// Whitespace as Python's `strip()` sees it. Foundation's set also holds
  /// the zero-width space, which screen text uses as an invisible separator.
  fileprivate static let whitespace = CharacterSet(
    charactersIn:
      "\t\n\u{0B}\u{0C}\r\u{1C}\u{1D}\u{1E}\u{1F} \u{85}\u{A0}\u{1680}"
      + "\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}"
      + "\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}")

  fileprivate var trimmed: String { trimmingCharacters(in: Self.whitespace) }

  fileprivate func trimmingTrailingWhitespace() -> String {
    var scalars = unicodeScalars
    while let last = scalars.last, Self.whitespace.contains(last) {
      scalars.removeLast()
    }
    return String(scalars)
  }

  fileprivate func trimmingTrailingSlashes() -> String {
    var text = self
    while text.hasSuffix("/") { text.removeLast() }
    return text
  }

  fileprivate func trimming(_ characters: String) -> String {
    trimmingCharacters(in: CharacterSet(charactersIn: characters))
  }

  /// Substring test where an empty needle is always found.
  fileprivate func includes(_ needle: String) -> Bool {
    needle.isEmpty || range(of: needle, options: .literal) != nil
  }

  /// The text, or nil when it is empty.
  fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}

/// Lowercases and collapses text so the same line reads the same each time:
/// curly quotes straightened, whitespace collapsed, and (with `maskNumbers`)
/// ticking counters and elapsed times replaced by `#`. Prices and clock times
/// are left alone.
private func normalized(_ text: String, maskNumbers: Bool = true) -> String {
  var text = text.replacingOccurrences(of: "⏎", with: " ")
    .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
    .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
  text = CondenserPatterns.whitespaceRun.replace(text, with: " ").trimmed.lowercased()
  if maskNumbers {
    text = CondenserPatterns.counter.replace(text, with: "#")
    text = CondenserPatterns.elapsed.replace(text, with: "#")
  }
  return text
}

/// Splits long text into lines, and lines over 400 characters into sentences.
private func textSegments(_ text: String) -> [String] {
  var parts: [String] = []
  for rawLine in text.components(separatedBy: " ⏎ ") {
    let line = rawLine.trimmed
    if line.scalarCount > 400 {
      parts += CondenserPatterns.sentenceBreak.split(line).filter { !$0.trimmed.isEmpty }
    } else if !line.isEmpty {
      parts.append(line)
    }
  }
  return parts
}

/// Five-word shingles of normalized text, for spotting long text whose words
/// were all written before in a different order or wrapping.
private func shingles(_ key: String) -> Set<Int> {
  let words = CondenserPatterns.shingleWord.allMatches(key)
  guard words.count >= 8 else { return [] }
  return Set((0...(words.count - 5)).map { words[$0..<($0 + 5)].joined(separator: " ").hashValue })
}

/// Link URLs (not page URLs): map coordinates and long opaque tails dropped.
private func shortURL(_ url: String) -> String {
  var url = CondenserPatterns.mapsTail.replace(url, with: "$1")
  if url.scalarCount > 160 {
    var base = url
    if let groups = CondenserPatterns.urlBase.matchAtStart(url) {
      base = (groups[1] ?? "") + (groups[2] ?? "")
    }
    url = base.scalarCount > 140 ? base.scalarPrefix(140) + "…" : base + "?…"
  }
  return url
}

/// Unwraps Google redirect links and strips tracking parameters.
private func cleanURL(_ url: String) -> String {
  guard !url.isEmpty else { return url }
  var url = url
  if let groups = CondenserPatterns.googleRedirect.matchAtStart(url), let target = groups[1] {
    url = target.removingPercentEncoding ?? target
  }
  url = CondenserPatterns.tracking.replace(url, with: "$1")
  url = CondenserPatterns.trailingQuerySeparators.replace(url, with: "")
    .replacingOccurrences(of: "?&", with: "?")
  url = CondenserPatterns.repeatedAmpersands.replace(url, with: "&")
  url = CondenserPatterns.statusSubpage.replace(url, with: "$1")
  return url
}

/// How alike two strings are, from 0 to 1, by the Ratcliff/Obershelp method
/// (the same measure as Python's difflib ratio).
private func similarity(_ a: String, _ b: String) -> Double {
  let a = Array(a.unicodeScalars)
  let b = Array(b.unicodeScalars)
  guard !a.isEmpty || !b.isEmpty else { return 1 }

  func matchingCount(_ aLow: Int, _ aHigh: Int, _ bLow: Int, _ bHigh: Int) -> Int {
    // Longest common run, earliest in `a`, then earliest in `b`.
    var best = (i: aLow, j: bLow, size: 0)
    var previous = [Int](repeating: 0, count: bHigh - bLow + 1)
    for i in aLow..<aHigh {
      var current = [Int](repeating: 0, count: bHigh - bLow + 1)
      for j in bLow..<bHigh where a[i] == b[j] {
        let size = previous[j - bLow] + 1
        current[j - bLow + 1] = size
        if size > best.size {
          best = (i - size + 1, j - size + 1, size)
        }
      }
      previous = current
    }
    guard best.size > 0 else { return 0 }
    return best.size
      + matchingCount(aLow, best.i, bLow, best.j)
      + matchingCount(best.i + best.size, aHigh, best.j + best.size, bHigh)
  }

  return 2 * Double(matchingCount(0, a.count, 0, b.count)) / Double(a.count + b.count)
}

/// Rejoins a sentence that a chat app split around inline code or links:
/// "run", "claude", ", type", "/login", ", and Dayflow will …". A piece that
/// starts with punctuation continues the one before it, and so does a short
/// piece sitting between an unfinished sentence and such a continuation.
private func gluingInlinePieces(_ items: [ScreenItem]) -> [ScreenItem] {
  func isPlain(_ item: ScreenItem) -> Bool {
    item.role == "statictext" && item.url.isEmpty && item.label.isEmpty
      && !item.value.trimmed.isEmpty
  }
  func continues(_ item: ScreenItem) -> Bool {
    isPlain(item) && CondenserPatterns.continuation.matchesStart(item.value)
  }

  var out: [ScreenItem] = []
  for (index, item) in items.enumerated() {
    let next = index + 1 < items.count ? items[index + 1] : nil
    if let previous = out.last, isPlain(previous), isPlain(item),
      continues(item)
        || (item.value.scalarCount <= 25
          && !CondenserPatterns.sentenceEnd.search(previous.value)
          && next.map(continues) == true)
    {
      out[out.count - 1].value =
        previous.value.trimmingTrailingWhitespace() + " " + item.value.trimmed
      continue
    }
    out.append(item)
  }
  return out
}

/// Joins runs of short text pieces that belong to one sentence or one row:
/// pages that animate a reply one word per element, and price rows split into
/// "Discounted Fare", "4,100", "miles", "+", "$", "6". Written apart, each
/// piece is dropped as a repeat of the same word seen earlier, and the
/// sentence or the price falls apart. Runs right after table rows are left
/// alone.
private func mergingShortRuns(_ items: [ScreenItem]) -> [ScreenItem] {
  var out: [ScreenItem] = []
  var run: [ScreenItem] = []
  var afterRow = false

  func isPiece(_ item: ScreenItem) -> Bool {
    item.role == "statictext" && item.url.isEmpty && item.label.isEmpty
      && item.value.scalarCount <= 25
  }

  func closeRun() {
    let texts = run.map(\.value).filter { !$0.trimmed.isEmpty }
    let words = texts.filter { CondenserPatterns.threeLetters.search($0) }
    let bare = texts.filter { !$0.trimmed.contains(" ") }.count
    var isStream =
      texts.count >= 6 && Double(bare) >= 0.8 * Double(texts.count) && words.count >= 3
    // Markdown inline code split around backticks.
    isStream = isStream || (texts.count >= 3 && texts.contains("`"))
    let isValues =
      texts.count >= 3 && !words.isEmpty && texts.contains { CondenserPatterns.digit.search($0) }
      && !afterRow
    if (isStream || isValues) && !afterRow {
      var lead = run[0]
      lead.value = texts.joined(separator: " ")
      lead.run = isValues ? "values" : "words"
      if isValues, let last = out.last, last.role == "popupbutton", !last.label.isEmpty {
        // "Delta Main: Discounted Fare 4,100 miles ..."
        lead.value = last.label + ": " + lead.value
      }
      out.append(lead)
    } else {
      out += run
    }
    run.removeAll()
  }

  for item in items {
    if isPiece(item) {
      run.append(item)
      continue
    }
    if !run.isEmpty { closeRun() }
    if item.role == "row" {
      afterRow = true
    } else if !["cell", "column", "table"].contains(item.role) {
      afterRow = false
    }
    out.append(item)
  }
  if !run.isEmpty { closeRun() }
  return out
}

// MARK: - Condenser

/// What has been written in one 15-minute window, for deciding what is new.
private final class CondenserWindow {
  let start: Date
  var lines: [String] = []
  /// Normalized texts and segments already written.
  var seen = Set<String>()
  var shingles = Set<Int>()
  var urls = Set<String>()
  /// Every normalized text written, newline-separated, for containment checks.
  private var blob: [UInt8] = []

  init(start: Date) {
    self.start = start
  }

  func addToBlob(_ key: String) {
    blob.append(contentsOf: key.utf8)
    blob.append(0x0A)
  }

  /// True when `key` appears inside text already written in this window.
  func blobContains(_ key: String) -> Bool {
    let needle = Array(key.utf8)
    guard !needle.isEmpty else { return true }
    guard needle.count <= blob.count else { return false }
    return blob.withUnsafeBytes { haystack in
      needle.withUnsafeBytes { needleBytes in
        memmem(haystack.baseAddress, haystack.count, needleBytes.baseAddress, needleBytes.count)
          != nil
      }
    }
  }
}

private struct FieldKey: Hashable {
  let app: String
  let field: String
}

private struct SpeakerTag: Equatable {
  let who: String
  let message: Int?
}

/// A Return press waiting for the screen reads right after it, which say
/// whether the text was sent.
private struct PendingSubmit {
  let time: Date
  let app: String
  let field: String
  let text: String
  var reads: [String]
  let seenBefore: Set<String>
  let draft: String
  let window: CondenserWindow
  let lineIndex: Int
}

private final class Condenser {
  private let titleJunk: PatternMatcher
  private let windowMinutes = 15
  /// Short control labels count as interface vocabulary once they have shown
  /// up in this many earlier windows.
  private let vocabularyWindows = 2

  private var window: CondenserWindow?
  private var windows: [CondenserWindow] = []
  private var currentApp: String?
  private var currentTitle: String?
  /// App and 20-second slot of the last "screen:" header.
  private var lastHeader: (app: String, slot: Int)?
  /// Last text read from each field, for terminals whose field holds the whole buffer.
  private var fieldValue: [FieldKey: String] = [:]
  /// Typing not yet written, in the order the fields were first typed into.
  private var pendingTyping: [(key: FieldKey, time: Date, text: String)] = []
  private var pendingSubmits: [PendingSubmit] = []
  /// Last speaker label written per app.
  private var speaker: [String: SpeakerTag] = [:]
  /// Latest page per app: title and URL.
  private var pages: [String: (title: String, url: String)] = [:]
  /// Windows each (app, control label) appeared in.
  private var vocabulary: [String: Set<Date>] = [:]
  /// Text last seen in each input box.
  private var box: [FieldKey: String] = [:]
  /// Field labels and placeholders per app; text equal to one means the field is empty.
  private var placeholders: [String: Set<String>] = [:]
  /// Last attachment shown in each app's composer.
  private var attached: [String: String] = [:]
  /// Text each element last showed, for status lines changed in place.
  private var elementText: [String: String] = [:]
  /// Highest Claude message number written per (app, session).
  private var highestMessage: [String: Int] = [:]
  /// Lines written per (app, session, message number).
  private var messageLines: [String: Set<String>] = [:]
  /// Texts reported queued and not yet seen as sent, per app.
  private var queued: [String: [String]] = [:]

  private let clockFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()
  private let bubbleTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "h:mm a"
    return formatter
  }()

  init(titleJunk: PatternMatcher) {
    self.titleJunk = titleJunk
  }

  func run(_ events: [AccessibilityLogEvent]) -> String {
    for event in events {
      handle(event)
    }
    closeWindow()
    return windows.flatMap(\.lines).joined(separator: "\n").trimmed
  }

  // MARK: Window bookkeeping

  private func clock(_ date: Date) -> String {
    clockFormatter.string(from: date)
  }

  /// The window for `time`, opening a new one at each 15-minute boundary.
  @discardableResult
  private func windowFor(_ time: Date) -> CondenserWindow {
    let calendar = Calendar.current
    var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: time)
    parts.minute = (parts.minute ?? 0) / windowMinutes * windowMinutes
    let start = calendar.date(from: parts) ?? time

    if let window, window.start == start { return window }
    closeWindow()
    let newWindow = CondenserWindow(start: start)
    window = newWindow
    windows.append(newWindow)
    lastHeader = nil
    speaker = [:]
    if let currentApp, !currentApp.isEmpty {
      newWindow.lines.append(clock(time) + " (in " + currentApp + ": " + (currentTitle ?? "") + ")")
    }
    return newWindow
  }

  private func closeWindow() {
    guard window != nil else { return }
    flushTyping()
    resolveSubmits(after: nil, force: true)
  }

  private func emit(_ line: String) {
    window?.lines.append(line)
  }

  // MARK: Deciding what is new

  /// The part of `text` not yet written in this window, or nil when all of it
  /// was. `exact`: only an identical line counts as a repeat (chat bubbles,
  /// whose text also shows up inside the conversation list preview).
  private func newText(_ text: String, exact: Bool = false) -> String? {
    guard let window else { return text }
    let key = normalized(text)
    if window.seen.contains(key) { return nil }
    if exact {
      window.seen.insert(key)
      window.addToBlob(key)
      return text
    }
    if key.scalarCount >= 4 && window.blobContains(key) {
      window.seen.insert(key)
      return nil
    }
    let keyShingles = shingles(key)
    if keyShingles.count >= 4 {
      let have = keyShingles.filter { window.shingles.contains($0) }.count
      let needed = (keyShingles.count >= 40 ? 0.9 : 1.0) * Double(keyShingles.count)
      if Double(have) >= needed {
        window.seen.insert(key)
        return nil
      }
    }
    if text.scalarCount >= 120 {
      var kept: [String] = []
      for segment in textSegments(text) {
        let segmentKey = normalized(segment)
        if segmentKey.scalarCount < 3 { continue }
        if window.seen.contains(segmentKey) { continue }
        if segmentKey.scalarCount >= 25 && window.blobContains(segmentKey) { continue }
        let segmentShingles = shingles(segmentKey)
        if segmentShingles.count >= 4 && segmentShingles.isSubset(of: window.shingles) { continue }
        window.shingles.formUnion(segmentShingles)
        window.seen.insert(segmentKey)
        kept.append(segment)
      }
      window.seen.insert(key)
      if kept.isEmpty { return nil }
      let out = kept.joined(separator: " ⏎ ")
      window.addToBlob(normalized(out))
      return out
    }
    window.seen.insert(key)
    window.shingles.formUnion(keyShingles)
    window.addToBlob(key)
    return text
  }

  // MARK: Screen reads

  private func screen(_ event: AccessibilityLogEvent) {
    let app = event.app ?? ""
    let items = ScreenItem.parse(event.diff?.nonEmpty ?? event.tree)
    let title = titleJunk.replace(event.window ?? "", with: "")
    if !title.isEmpty && currentApp == nil {
      // The log starts mid-session with no window event: name the window being read.
      currentApp = app
      currentTitle = title
      emit(clock(event.time) + " (in " + app + ": " + title + ")")
    } else if !title.isEmpty && app == currentApp && title != currentTitle {
      // The title changed without a window event (tab switch, page load in place).
      currentTitle = title
      emit(clock(event.time) + " → " + app + ": " + title)
    }

    let rendered = renderItems(app: app, items: items)
    guard !rendered.isEmpty else { return }
    let slot = Int(event.time.timeIntervalSince1970) / 20
    if lastHeader?.app != app || lastHeader?.slot != slot {
      emit(clock(event.time) + " " + app + " screen:")
      lastHeader = (app, slot)
    }
    for line in rendered {
      emit("  " + line)
    }
  }

  private func renderItems(app: String, items rawItems: [ScreenItem]) -> [String] {
    typealias P = CondenserPatterns
    guard let window else { return [] }
    var out: [String] = []
    var lastContent: Int?  // index in out of the last content line, for attaching permalinks
    var pendingSpeaker: String?
    var messageNumber: Int?  // Claude app: number of the message group being read
    var groupSpeaker: String?  // Claude app: speaker of that group ("?" = no heading yet)
    var row: (label: String, index: Int?, cells: [String])?  // value cells joining their label
    var lastLabel: (text: String, index: Int?)?  // last content text in this read, even if repeated
    var nextStatus: String?
    var anchor = ""  // last button or heading; a row of values repeats only under the same one
    var table: String?  // nil, "start", "row" (next text labels a row), "cells", or "flat"
    var tableLabels = Set<String>()
    let items = mergingShortRuns(gluingInlinePieces(rawItems))

    func flushRow() {
      if let current = row, !current.cells.isEmpty {
        let full = current.label + " | " + current.cells.joined(separator: " | ")
        let alreadySeen = window.seen.contains(
          normalized(current.label + " " + current.cells.joined(separator: " ")))
        if !alreadySeen, let new = newText(full) {
          if let index = current.index, index < out.count, out[index] == current.label {
            out[index] = new
          } else {
            out.append(new)
          }
        }
      }
      row = nil
    }

    func sessionKey() -> String {
      app + "\u{1}" + (pages[app]?.title ?? "")
    }

    for item in items {
      let role = item.role
      let label = item.label
      let value = item.value
      var url = cleanURL(item.url)
      if let placeholder = item.placeholder?.nonEmpty {
        placeholders[app, default: []].insert(placeholder)
      }
      if (role == "textarea" || role == "textfield") && !label.isEmpty {
        placeholders[app, default: []].insert(label)
        if item.states.contains("focused") && !value.isEmpty {
          box[FieldKey(app: app, field: label)] = value  // the last text the box showed
        }
      }
      if app == "Claude" && role == "group" {
        if label == "Currently streaming message" {
          groupSpeaker = "CLAUDE"
          continue
        }
        if P.messageGroup.matchesStart(label) {
          groupSpeaker = "?"
          messageNumber = Int(label.split(separator: " ")[1])
          continue
        }
        if ["Environment", "Background tasks", "Sessions"].contains(label) {
          groupSpeaker = nil
          messageNumber = nil
        }
      }
      if app == "Claude" && role == "webarea" {
        groupSpeaker = nil
        messageNumber = nil
      }
      let labelAndValue = [label, value].filter { !$0.isEmpty }.joined(separator: " = ")
      let lowered = labelAndValue.lowercased().trimmed
      var isBubble = false

      let youSaidButton = "Show message actions for You said: "
      if role == "button" && (app == "Claude" || P.browsers.contains(app))
        && label.hasPrefix(youSaidButton)
      {
        // claude.ai puts this button after the user's message text, with no heading before it.
        let said = normalized(
          label.droppingScalars(first: youSaidButton.scalarCount), maskNumbers: false
        ).scalarPrefix(40)
        if !said.isEmpty, let index = lastContent,
          normalized(out[index], maskNumbers: false).hasPrefix(said),
          !(index > 0 && out[index - 1].hasPrefix("--- YOU"))
        {
          out.insert("--- YOU:", at: index)
          lastContent = index + 1
          speaker[app] = SpeakerTag(who: "YOU", message: nil)
          pendingSpeaker = "--- CLAUDE:"
        }
        continue
      }
      if (role == "button" || role == "heading") && !label.isEmpty && label.scalarCount < 80 {
        anchor = label
      }
      if P.chatApps.contains(app)
        && (lowered.contains("attached link, ") || lowered.hasPrefix("attachment"))
      {
        attached[app] = labelAndValue
      }

      // Tables: each row is written as "label | cell | cell".
      if role == "table" {
        flushRow()
        table = "start"
        tableLabels = []
        continue
      }
      if role == "row" {  // a diff can add rows without repeating the table line
        flushRow()
        table = "row"
        continue
      }
      if let tableState = table, ["statictext", "cell", "text"].contains(role), url.isEmpty {
        let isShort = labelAndValue.scalarCount > 0 && labelAndValue.scalarCount < 60
        if !isShort {
          flushRow()
          table = nil
        } else if tableLabels.contains(normalized(labelAndValue)) && tableState != "flat" {
          flushRow()
          table = "flat"  // the same table again as loose text
          continue
        } else if tableState == "flat" {
          continue
        } else if tableState == "cells" && row != nil {
          row?.cells.append(labelAndValue)
          continue
        } else if tableState == "row" || tableState == "start" {
          tableLabels.insert(normalized(labelAndValue))
          flushRow()
          let new = newText(labelAndValue)
          if let new {
            out.append(new)
            lastContent = out.count - 1
          }
          row = (labelAndValue, new != nil ? lastContent : nil, [])
          table = "cells"
          continue
        }
      } else if table != nil && !["row", "cell", "column", "group"].contains(role) {
        flushRow()
        table = nil
      }

      // Value cells and row statuses join the label before them.
      if ["statictext", "cell", "text", "button", "link"].contains(role) && url.isEmpty,
        let previousLabel = lastLabel, labelAndValue.scalarCount < 40,
        (P.value.matchesStart(labelAndValue) && !P.counter.search(labelAndValue))
          || P.rowStatus.contains(labelAndValue.trimmed)
          || (row.map { !$0.cells.isEmpty } == true && P.plainValue.matchesStart(labelAndValue))
      {
        if row == nil || row?.label != previousLabel.text {
          flushRow()
          row = (previousLabel.text, previousLabel.index, [])
        }
        row?.cells.append(labelAndValue)
        continue
      }
      if role == "statictext" && P.nextStatus.contains(lowered) {
        nextStatus = labelAndValue
        continue
      }
      if P.chatApps.contains(app) && (role == "statictext" || role == "heading")
        && P.divider.matchesStart(labelAndValue)
      {
        flushRow()
        if let new = newText("-- " + labelAndValue + " --") { out.append(new) }
        continue
      }
      if app == "Messages" && (role == "group" || role == "statictext")
        && label.hasPrefix("Message, ")
      {
        continue  // the composer's mirror of the text box; drafts and sends come from the field
      }
      if P.dropRoles.contains(role) && label.isEmpty { continue }
      var text = labelAndValue
      if text.isEmpty && url.isEmpty { continue }
      if ["menuitem", "radiobutton", "checkbox"].contains(role) && item.states.contains("disabled")
      {
        text += " (disabled)"  // an option the user can't pick says something (no access, plan limit)
      }

      // Page identity.
      if role == "webarea" {
        if url.hasPrefix("about:") || url.hasPrefix("file:") || url.hasPrefix("chrome:") {
          continue
        }
        pages[app] = (label, url)
        var line = url.isEmpty ? "PAGE " + label : "PAGE " + label + " <" + url + ">"
        if app == "Claude" && label.hasSuffix(" - Claude Code") {
          line = "SESSION " + label.droppingScalars(last: 14) + " <" + url + ">"
        }
        if newText(line) != nil { out.append(line) }
        continue
      }

      // Interface chrome.
      if role == "window" { continue }
      if role == "statictext" && value.isEmpty && label.isEmpty { continue }
      if P.metric.matchesStart(text) && url.isEmpty { continue }
      let isSelected = item.states.contains("selected")
      if P.controlRoles.contains(role) && P.uiWords.contains(text.lowercased()) { continue }
      if role == "slider" { continue }
      // Short text is interface vocabulary once it has shown up in two earlier
      // windows: sidebar entries, panel labels, buttons. A new one (a choice
      // button such as "Plan the fix") is kept.
      if P.controlRoles.contains(role) && role != "popupbutton" && role != "combobox"
        && text.scalarCount < 80 && !isSelected && !P.clockTime.search(text)
      {
        let vocabularyKey = app + "\u{1}" + normalized(text)
        var seenIn = vocabulary[vocabularyKey] ?? []
        let isKnown = seenIn.subtracting([window.start]).count >= vocabularyWindows
        seenIn.insert(window.start)
        vocabulary[vocabularyKey] = seenIn
        if isKnown { continue }
      }
      if P.durationOnly.matchesStart(text) { continue }
      if P.dateToken.count(in: text) >= 4
        && Double(P.dateToken.replace(text, with: "").trimming(" ,?").scalarCount)
          < 0.3 * Double(text.scalarCount)
      {
        continue  // date-picker grids
      }
      if app == "Claude" && P.claudeUI.matchesStart(text) { continue }
      if role == "heading" && !value.isEmpty && value.allSatisfy(\.isNumber) {
        text = label
      }
      if role == "radiobutton" && P.memoryTab.search(text) { continue }
      if role == "textfield" && P.addressFields.contains(label) {
        if value.isEmpty { continue }
        text = "address bar = " + shortURL(cleanURL(value))
      }
      if P.uiWords.contains(text.lowercased()) { continue }

      if P.browsers.contains(app) {
        // Gmail list rows show up as "unread, Sender , Subject , time , snippet".
        text = P.gmailUnread.replace(text, with: "[unread] ")
      }
      if text.scalarCount >= 20 && app != "Slack" {
        text = P.metricPhrase.replace(text, with: "")
          .replacingOccurrences(of: " Verified account", with: "")
        text = P.doubleSpace.replace(text, with: " ").trimming(" ,·")
      }

      // Per-app rewriting.
      if app == "Messages" && ["group", "button", "statictext", "link"].contains(role) {
        if let groups = P.messageBubble.matchAtStart(text),
          ["group", "button", "link"].contains(role)
        {
          let sender = groups[1] ?? ""
          let who = sender.hasPrefix("Your ") ? "Me" : sender
          let body = P.reaction.replace(groups[2] ?? "", with: "")
          text = who + ": " + body + " (" + (groups[3] ?? "") + ")"
          isBubble = true
        } else if role == "statictext" && text.contains(", Unread, ") {
          text = "[unread] " + text.replacingOccurrences(of: ", Pinned", with: "")
        }
      }
      if P.sendFailure.search(text) {
        text = "[SEND FAILED] " + text
      }
      if app == "Slack" {
        text = P.slackReactions.replace(text, with: "")
        if role == "link" && !url.isEmpty && P.slackPermalink.search(url)
          && P.slackTimestampLabel.matchesStart(label)
        {
          if let index = lastContent, !out[index].contains("<") {
            out[index] += " <" + url + ">"
          }
          continue
        }
      }
      if P.browsers.contains(app) && role == "link" && !url.isEmpty && P.xStatus.search(url)
        && P.metric.matchesStart(label.components(separatedBy: ".").first ?? "")
      {
        if let index = lastContent, !out[index].contains("<") {
          out[index] += " <" + url + ">"
        }
        continue
      }
      if role == "heading" && (app == "Claude" || P.browsers.contains(app)),
        let groups = P.chatHeading.matchAtStart(label)
      {
        groupSpeaker = groups[1] == "You said" ? "YOU" : "CLAUDE"
        let said = label.droppingScalars(first: (groups[0] ?? "").scalarCount).trimmed
        if groupSpeaker == "YOU" && !said.isEmpty {
          let saidStart = normalized(said, maskNumbers: false).scalarPrefix(40)
          if !saidStart.isEmpty,
            let index = queued[app]?.firstIndex(where: { $0.includes(saidStart) })
          {
            queued[app]?.remove(at: index)
            out.append("(queued message now sent: \"" + said + "\")")
          }
          if window.seen.contains(normalized(said)) && newText("you said: " + said) != nil {
            // The text was already written (as an option chip or a draft), so
            // its body line will be dropped as a repeat; record that the user sent it.
            speaker[app] = SpeakerTag(who: "YOU", message: messageNumber)
            out.append(messageNumber.map { "--- YOU (message \($0)):" } ?? "--- YOU:")
            out.append(said)
          }
        }
        continue
      }
      if app == "Claude" && role == "button" && label.hasPrefix("Show message actions") {
        continue
      }

      // Links: label plus destination.
      var line: String
      if role == "link" && !url.isEmpty {
        let page = pages[app]?.url ?? ""
        let bareURL = (url.components(separatedBy: "://").last ?? "").trimmingTrailingSlashes()
        if url == page || url.hasPrefix("javascript:") || url == "#" {
          url = ""
        } else if !text.isEmpty && text.includes(bareURL) {
          url = ""
        }
        if !url.isEmpty { url = shortURL(url) }
        line = url.isEmpty ? text : text + " <" + url + ">"
      } else {
        line = text
      }
      if ["textarea", "textfield", "combobox", "searchfield"].contains(role)
        && item.states.contains("focused")
      {
        if value.isEmpty { continue }
        line = "[input focused] " + line
        groupSpeaker = nil
      }
      if role == "link" && P.browsers.contains(app) && !url.isEmpty
        && isRedundantLink(text: text, url: url)
      {
        continue
      }
      if let status = nextStatus {
        line = "[" + status + "] " + line
        nextStatus = nil
      }
      if !line.isEmpty && role != "popupbutton" {
        flushRow()
        lastLabel = (line, nil)
      }

      var new: String?
      if item.run == "values" {
        new = newText(line + " @" + anchor) != nil ? line : nil
      } else {
        new = newText(
          line,
          exact: isBubble || role == "popupbutton" || (item.mark == "~" && line.scalarCount < 60))
        let elementKey = app + "\u{1}" + item.id
        let previous = elementText[elementKey]
        elementText[elementKey] = line
        if new == nil && item.mark == "~", let previous, !previous.isEmpty, previous != line,
          P.statusLine.matchesStart(line)
        {
          new = line  // a status that changed back to text seen earlier ("Claude finished the response")
        }
        if let number = messageNumber, groupSpeaker == "YOU" {
          // In the user's newest message, a line repeats only within that
          // message: a reply that quotes an earlier answer still needs its own text.
          let session = sessionKey()
          if number >= (highestMessage[session] ?? 0) - 1 {
            let messageKey = session + "\u{1}" + String(number)
            var mine = messageLines[messageKey] ?? []
            let key = normalized(line)
            if new == nil && !mine.contains(key) && !mine.contains(where: { $0.includes(key) }) {
              new = line
            }
            mine.insert(key)
            messageLines[messageKey] = mine
          }
        }
      }

      guard let new, !new.isEmpty else { continue }
      if app == "Claude" && groupSpeaker == nil {
        speaker[app] = nil
      }
      if let group = groupSpeaker, app == "Claude" || P.browsers.contains(app) {
        // A message group with no "You said" heading is Claude's (streaming or tool output).
        let who = group == "?" ? "CLAUDE" : group
        let tag = SpeakerTag(who: who, message: messageNumber)
        if speaker[app] != tag {
          speaker[app] = tag
          pendingSpeaker = "--- " + who + ":"
          if let number = messageNumber {
            let session = sessionKey()
            let top = highestMessage[session] ?? 0
            if number < top - 1 {
              pendingSpeaker =
                "--- \(who) (message \(number), earlier, scrolled back into view):"
            } else {
              pendingSpeaker = "--- \(who) (message \(number)):"
            }
            highestMessage[session] = max(top, number)
          }
        }
      }
      if let speakerLine = pendingSpeaker {
        out.append(speakerLine)
        pendingSpeaker = nil
      }
      out.append(new)
      lastContent = out.count - 1
      if let previousLabel = lastLabel, previousLabel.text == line {
        lastLabel = (line, lastContent)
      }
    }
    flushRow()
    return out
  }

  /// A link adds nothing when its label is already written and its URL is a
  /// profile or section page (one path segment), or the URL was written.
  private func isRedundantLink(text: String, url: String) -> Bool {
    guard let window else { return false }
    let bareURL = url.components(separatedBy: "://").last ?? ""
    if window.urls.contains(bareURL) { return true }
    let path = CondenserPatterns.urlHost.replace(
      bareURL.components(separatedBy: "?").first ?? "", with: ""
    ).trimming("/")
    if !path.contains("/") {
      let key = normalized(text)
      if key.isEmpty || window.blobContains(key) || key.scalarCount < 30 { return true }
    }
    window.urls.insert(bareURL)
    return false
  }

  // MARK: Actions

  /// Writes every draft still waiting, in the order the fields were first typed into.
  private func flushTyping() {
    let drafts = pendingTyping
    pendingTyping.removeAll()
    for draft in drafts {
      let new = addedText(for: draft.key, text: draft.text)
      if !new.trimmed.isEmpty {
        emit(
          clock(draft.time) + " you typed in " + draft.key.app + " \"" + draft.key.field
            + "\" (draft): \"" + new + "\"")
      }
    }
  }

  private func removePendingTyping(_ key: FieldKey) -> (time: Date, text: String)? {
    guard let index = pendingTyping.firstIndex(where: { $0.key == key }) else { return nil }
    let entry = pendingTyping.remove(at: index)
    return (entry.time, entry.text)
  }

  private func setPendingTyping(_ key: FieldKey, time: Date, text: String) {
    if let index = pendingTyping.firstIndex(where: { $0.key == key }) {
      pendingTyping[index] = (key, time, text)
    } else {
      pendingTyping.append((key, time, text))
    }
  }

  /// For fields that hold a whole buffer (terminals), only what was added.
  private func addedText(for key: FieldKey, text: String) -> String {
    let previous = fieldValue[key]
    fieldValue[key] = text
    if let previous, previous.scalarCount > 200 {
      let previousLines = Set(previous.components(separatedBy: " ⏎ ").map { normalized($0) })
      let added = text.components(separatedBy: " ⏎ ").filter {
        !previousLines.contains(normalized($0))
      }
      return added.suffix(40).joined(separator: " ⏎ ")
    }
    return text
  }

  /// Gives each waiting Return the screen reads from the 2.2 seconds after
  /// it, then writes its line once that time has passed.
  private func resolveSubmits(after event: AccessibilityLogEvent?, force: Bool = false) {
    var keep: [PendingSubmit] = []
    for var submit in pendingSubmits {
      if let event, event.app == submit.app, event.kind == "diff" || event.kind == "snapshot",
        event.time.timeIntervalSince(submit.time) <= 2.2
      {
        submit.reads.append(event.diff?.nonEmpty ?? event.tree?.nonEmpty ?? "")
      }
      if force || event == nil || event!.time.timeIntervalSince(submit.time) > 2.2 {
        if let line = submitLine(submit) {
          if let window, submit.window === window, submit.lineIndex <= window.lines.count {
            window.lines.insert(line, at: submit.lineIndex)
          } else {
            emit(line)
          }
        }
      } else {
        keep.append(submit)
      }
    }
    pendingSubmits = keep
  }

  /// Messages: the user's own new bubble that appeared after Return. The
  /// submit event's text is often stale or missing, so the bubble is the
  /// better record of what was sent.
  private func sentBubble(
    app: String, reads: [String], seenBefore: Set<String>, typed: String, time: Date
  ) -> String? {
    guard app == "Messages" else { return nil }
    typealias P = CondenserPatterns
    // Only a bubble stamped with the minute of the Return (or the next) can be
    // the one just sent; older bubbles come back with new element ids when the
    // thread re-renders.
    let minutes: Set<String> = [
      bubbleTimeFormatter.string(from: time),
      bubbleTimeFormatter.string(from: time.addingTimeInterval(60)),
    ]
    var candidates: [String] = []
    for body in reads {
      for item in ScreenItem.parse(body) {
        guard ["group", "button", "link"].contains(item.role),
          let groups = P.ownBubble.matchAtStart(item.label)
        else { continue }
        let stamp = groups[3] ?? ""
        let shown = P.reaction.replace(groups[2] ?? "", with: "")  // as renderItems writes it
        if seenBefore.contains(normalized("Me: " + shown + " (" + stamp + ")")) { continue }
        if !minutes.contains(P.whitespace.replace(stamp, with: " ").uppercased()) { continue }
        let message = P.replyDecoration.replace(shown, with: "").trimmed
        if !message.isEmpty && !candidates.contains(message) {
          candidates.append(message)
        }
      }
    }
    if !typed.isEmpty {
      // A sticker, photo or attachment bubble is not the text that was in the box.
      candidates = candidates.filter { !P.nonTextBubble.matchesStart($0) }
    }
    guard let last = candidates.last else { return nil }
    if candidates.count == 1 || typed.isEmpty { return last }
    let typedKey = normalized(typed, maskNumbers: false)
    return candidates.max {
      similarity(normalized($0, maskNumbers: false), typedKey)
        < similarity(normalized($1, maskNumbers: false), typedKey)
    }
  }

  private func submitLine(_ submit: PendingSubmit) -> String? {
    typealias P = CondenserPatterns
    let time = clock(submit.time)
    let app = submit.app
    let field = submit.field
    let key = FieldKey(app: app, field: field)
    if let bubble = sentBubble(
      app: app, reads: submit.reads, seenBefore: submit.seenBefore,
      typed: submit.text.nonEmpty ?? submit.draft, time: submit.time)
    {
      fieldValue[key] = ""
      return time + " you SENT in " + app + " \"" + field + "\": \"" + bubble + "\""
    }
    var text = submit.text
    if text.trimmed.isEmpty && !submit.draft.trimmed.isEmpty && !P.terminals.contains(app) {
      text = submit.draft  // Return read back nothing; the last draft is what was in the field
    }
    let shown = text.isEmpty ? "" : addedText(for: key, text: text)
    if P.addressFields.contains(field) {
      return time + " you went to (in " + app + "): \"" + shown + "\""
    }

    let body = submit.reads.joined(separator: "\n")
    let bodyLines = body.components(separatedBy: "\n")
    let addedLines = bodyLines.filter { $0.trimmed.hasPrefix("+") }
    let lastLine = text.components(separatedBy: " ⏎ ").last ?? ""
    let typedStart = normalized(lastLine.trimmed.scalarPrefix(60), maskNumbers: false)

    var isStillInBox = false
    var wasCleared = false
    for line in bodyLines {
      guard let groups = P.focusedField.firstMatch(line), let states = groups[3]?.nonEmpty,
        states.contains("focused")
      else { continue }
      if let fieldText = groups[4]?.nonEmpty {
        if !typedStart.isEmpty && normalized(fieldText, maskNumbers: false).includes(typedStart) {
          isStillInBox = true
        }
      } else {
        wasCleared = true
      }
    }
    let youSaid =
      !typedStart.isEmpty
      && addedLines.contains {
        $0.contains("heading \"You said: ")
          && normalized($0, maskNumbers: false).includes(typedStart.scalarPrefix(40))
      }
    let isQueued =
      body.contains("Cancel and edit message") && body.contains("Send now") && !youSaid
    let appeared =
      !typedStart.isEmpty
      && addedLines.filter { !$0.contains("focused") }.contains { line in
        let pieces = line.components(separatedBy: "]")
        let afterId = pieces.count > 1 ? pieces[1] : ""
        return normalized(line, maskNumbers: false).includes(typedStart)
          && !afterId.scalarPrefix(10).contains("textarea")
      }

    var status = "pressed Return (outcome not seen)"
    if isStillInBox {
      status = "pressed Return, text still in box (not sent)"
    } else if isQueued {
      status =
        "QUEUED (shown with Send now / Cancel, the assistant was still answering the previous message)"
    } else if appeared || wasCleared || youSaid {
      status = "SENT (box cleared" + (appeared ? ", message shown)" : ")")
    }
    if isQueued && !text.isEmpty {
      queued[app, default: []].append(normalized(text, maskNumbers: false))
    }

    if text.isEmpty {
      if P.terminals.contains(app) || P.noteApps.contains(app) { return nil }
      if let attachment = attached.removeValue(forKey: app) {
        return time + " you pressed Return in " + app + " \"" + field + "\" with " + attachment
          + " (text not read)"
      }
      return time + " you pressed Return in " + app
        + (field != "field" ? " \"" + field + "\"" : "") + " (text not read)"
    }
    if P.terminals.contains(app) {
      return time + " you ran in " + app + ": \"" + shown + "\""
    }
    if P.noteApps.contains(app) {
      return nil  // Return is a line break; the typed text is recorded separately
    }
    return time + " you " + status + " in " + app + " \"" + field + "\": \"" + shown + "\""
  }

  // MARK: Events

  private func handle(_ event: AccessibilityLogEvent) {
    typealias P = CondenserPatterns
    let kind = event.kind
    let app = event.app ?? ""
    if kind == "session_start" || kind == "session_stop" { return }
    let window = windowFor(event.time)
    if !pendingSubmits.isEmpty { resolveSubmits(after: event) }
    let time = clock(event.time)
    if event.blocked == true {
      emit(time + " " + app + ": blocked app, nothing recorded")
      return
    }

    switch kind {
    case "window":
      let title = titleJunk.replace(event.window ?? "", with: "")
      if app != currentApp || title != currentTitle {
        currentApp = app
        currentTitle = title
        emit(time + " → " + app + ": " + title)
      }

    case "snapshot", "diff":
      screen(event)

    case "text":
      let key = FieldKey(app: app, field: event.field?.nonEmpty ?? "field")
      let text = event.text ?? ""
      let appPlaceholders = placeholders[app] ?? []
      if P.upToThreeDigits.matchesWhole(text) && P.endsWithDigit.search(key.field)
        && !appPlaceholders.contains(key.field)
      {
        return  // a counter or heading level read as a field value, not typing
      }
      if text.trimmed.isEmpty || text == key.field || appPlaceholders.contains(text) {
        let pending = removePendingTyping(key)
        if pending.map({ !$0.text.trimmed.isEmpty }) == true
          || !(fieldValue[key] ?? "").trimmed.isEmpty || !(box[key] ?? "").trimmed.isEmpty
        {
          fieldValue[key] = ""
          box[key] = ""
          emit(time + " you cleared " + app + " \"" + key.field + "\" (draft deleted, not sent)")
        }
        return
      }
      setPendingTyping(key, time: event.time, text: text)

    case "submit":
      let field = event.field?.nonEmpty ?? "field"
      let key = FieldKey(app: app, field: field)
      let draft =
        removePendingTyping(key)?.text ?? box[key]?.nonEmpty ?? fieldValue[key]?.nonEmpty ?? ""
      box[key] = ""
      pendingSubmits.append(
        PendingSubmit(
          time: event.time, app: app, field: field, text: event.text ?? "", reads: [],
          seenBefore: window.seen, draft: draft, window: window, lineIndex: window.lines.count))

    case "click", "drag", "context_menu":
      flushTyping()
      var target = event.target?.nonEmpty ?? "(unknown)"
      if target.contains("(no label)") || target == "(unknown)" { return }
      if P.ignoredClickTarget.matchesStart(target) { return }
      if target.scalarCount > 160 { target = target.scalarPrefix(160) + "…" }
      let verb =
        ["click": "clicked", "drag": "dragged", "context_menu": "context menu"][kind] ?? kind
      emit(time + " you " + verb + " in " + app + ": " + target)

    case "shortcut":
      let keys = event.keys ?? ""
      if ["⌘\t", "⌘ ", "⌘⇧\t", "⌘`"].contains(keys) { return }
      if ["⌘V", "⌘C", "⌘X", "⌘W", "⌘T", "⌘R", "⌘Z"].contains(keys) { flushTyping() }
      emit(time + " you pressed " + keys + " in " + app)

    default:
      return  // escape and anything newer say nothing worth writing
    }
  }
}
