import Foundation

/// One line of text read off a frame, with its box in pixels from the top-left corner.
/// This is the unit the privacy model works on, the same as `{"text", "box"}` in the
/// Python lab (`~/Documents/dayflow-pii-model`).
struct PIIOCRLine {
  let text: String
  let box: CGRect
}

/// A line's text indexed by Unicode code point, the way Python indexes a `str`.
/// Every position the privacy model and its rules talk about is a code point index,
/// so the Swift port stays character-for-character identical to the Python one.
struct PIILineText {
  let string: String
  let scalars: [Unicode.Scalar]
  let ns: NSString
  /// `scalarAt[u]` is the code point index of UTF-16 offset `u` (one extra entry for the end).
  private let scalarAt: [Int]
  /// `utf16At[i]` is the UTF-16 offset of code point `i` (one extra entry for the end).
  private let utf16At: [Int]

  init(_ string: String) {
    self.string = string
    self.scalars = Array(string.unicodeScalars)
    self.ns = string as NSString
    var scalarAt: [Int] = []
    var utf16At: [Int] = []
    scalarAt.reserveCapacity(ns.length + 1)
    utf16At.reserveCapacity(scalars.count + 1)
    for (index, scalar) in scalars.enumerated() {
      utf16At.append(scalarAt.count)
      for _ in 0..<UTF16.width(scalar) {
        scalarAt.append(index)
      }
    }
    utf16At.append(scalarAt.count)
    scalarAt.append(scalars.count)
    self.scalarAt = scalarAt
    self.utf16At = utf16At
  }

  var count: Int { scalars.count }

  func scalarIndex(utf16 offset: Int) -> Int { scalarAt[offset] }
  func utf16Offset(scalar index: Int) -> Int { utf16At[index] }

  /// The text of code points `start..<end`, like Python's `text[start:end]`.
  func slice(_ start: Int, _ end: Int) -> String {
    let lo = max(0, min(start, count))
    let hi = max(lo, min(end, count))
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars[lo..<hi])
    return String(view)
  }
}

/// A regex match with code point ranges, so it can index straight into a line's labels.
struct PIIMatch {
  let range: Range<Int>
  let groups: [String: Range<Int>]

  var start: Int { range.lowerBound }
  var end: Int { range.upperBound }
}

/// Python `re` semantics on top of NSRegularExpression, in code point indices.
/// The patterns are copied from the Python lab; `(?P<name>` groups are written `(?<name>` here.
final class PIIRegex: @unchecked Sendable {
  private let regex: NSRegularExpression
  private let full: NSRegularExpression
  private let groupNames: [String]

  init(_ pattern: String, caseInsensitive: Bool = false, groupNames: [String] = []) {
    let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
    // These patterns are constants checked by the parity tests, so a bad one is a programming error.
    self.regex = try! NSRegularExpression(pattern: pattern, options: options)
    self.full = try! NSRegularExpression(pattern: "\\A(?:\(pattern))\\z", options: options)
    self.groupNames = groupNames
  }

  /// Every non-overlapping match in `text[from..<to]`, like `pattern.finditer(text, from)`.
  /// The text before `from` is still visible to lookbehinds, as in Python.
  func matches(in text: PIILineText, from: Int = 0, to: Int? = nil) -> [PIIMatch] {
    let lo = text.utf16Offset(scalar: from)
    let hi = text.utf16Offset(scalar: to ?? text.count)
    // From a later position, Python still lets lookbehinds see earlier text but `^` no longer matches.
    let options: NSRegularExpression.MatchingOptions =
      from > 0 ? [.withTransparentBounds, .withoutAnchoringBounds] : []
    return regex.matches(
      in: text.string, options: options, range: NSRange(location: lo, length: hi - lo)
    )
    .map { convert($0, in: text) }
  }

  /// The first match in `text[from..<to]`, like `pattern.search`. With `to`, `$` matches at `to`,
  /// the same as searching the Python slice `text[:to]`.
  func firstMatch(in text: PIILineText, from: Int = 0, to: Int? = nil) -> PIIMatch? {
    let lo = text.utf16Offset(scalar: from)
    let hi = text.utf16Offset(scalar: to ?? text.count)
    guard
      let match = regex.firstMatch(
        in: text.string, options: [], range: NSRange(location: lo, length: hi - lo))
    else { return nil }
    return convert(match, in: text)
  }

  /// A match that starts exactly at `from` and ends by `to`, like `pattern.match(text, from, to)`.
  func matchAtStart(of text: PIILineText, from: Int = 0, to: Int? = nil) -> PIIMatch? {
    let lo = text.utf16Offset(scalar: from)
    let hi = text.utf16Offset(scalar: to ?? text.count)
    guard
      let match = regex.firstMatch(
        in: text.string, options: [.anchored], range: NSRange(location: lo, length: hi - lo))
    else { return nil }
    return convert(match, in: text)
  }

  func search(_ string: String) -> Bool {
    regex.firstMatch(
      in: string, options: [], range: NSRange(location: 0, length: (string as NSString).length))
      != nil
  }

  func matchesStart(_ string: String) -> Bool {
    regex.firstMatch(
      in: string, options: [.anchored],
      range: NSRange(location: 0, length: (string as NSString).length)) != nil
  }

  func fullMatch(_ string: String) -> Bool {
    full.firstMatch(
      in: string, options: [], range: NSRange(location: 0, length: (string as NSString).length))
      != nil
  }

  private func convert(_ match: NSTextCheckingResult, in text: PIILineText) -> PIIMatch {
    let range = scalarRange(match.range, in: text)
    var groups: [String: Range<Int>] = [:]
    for name in groupNames {
      let groupRange = match.range(withName: name)
      if groupRange.location != NSNotFound {
        groups[name] = scalarRange(groupRange, in: text)
      }
    }
    return PIIMatch(range: range, groups: groups)
  }

  private func scalarRange(_ range: NSRange, in text: PIILineText) -> Range<Int> {
    text.scalarIndex(utf16: range.location)..<text.scalarIndex(utf16: range.location + range.length)
  }
}

/// Python `str` helpers the rules use, defined on code points.
enum PIIPython {
  static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.isWhitespace
  }

  static func isAlpha(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
      return true
    default:
      return false
    }
  }

  static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.numericType {
    case .decimal?, .digit?:
      return true
    default:
      return false
    }
  }

  static func isNumeric(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.numericType != nil
  }

  static func isAlnum(_ scalar: Unicode.Scalar) -> Bool {
    isAlpha(scalar) || isNumeric(scalar)
  }

  static func isUpper(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.isUppercase
  }

  static func isLower(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.isLowercase
  }

  /// `s.isdigit()`: non-empty and every code point a digit.
  static func isAllDigits(_ string: String) -> Bool {
    !string.isEmpty && string.unicodeScalars.allSatisfy(isDigit)
  }

  /// `s.strip()` with no argument.
  static func strip(_ string: String) -> String {
    let scalars = Array(string.unicodeScalars)
    var lo = 0
    var hi = scalars.count
    while lo < hi && isSpace(scalars[lo]) { lo += 1 }
    while hi > lo && isSpace(scalars[hi - 1]) { hi -= 1 }
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars[lo..<hi])
    return String(view)
  }

  /// `s.strip(chars)`.
  static func strip(_ string: String, _ chars: String) -> String {
    let set = Set(chars.unicodeScalars)
    let scalars = Array(string.unicodeScalars)
    var lo = 0
    var hi = scalars.count
    while lo < hi && set.contains(scalars[lo]) { lo += 1 }
    while hi > lo && set.contains(scalars[hi - 1]) { hi -= 1 }
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars[lo..<hi])
    return String(view)
  }

  /// `s.rstrip()` with no argument.
  static func rstrip(_ string: String) -> String {
    var scalars = Array(string.unicodeScalars)
    while let last = scalars.last, isSpace(last) { scalars.removeLast() }
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars)
    return String(view)
  }

  /// `s.split()` with no argument: runs of non-whitespace.
  static func split(_ string: String) -> [String] {
    var words: [String] = []
    var current = String.UnicodeScalarView()
    for scalar in string.unicodeScalars {
      if isSpace(scalar) {
        if !current.isEmpty {
          words.append(String(current))
          current = String.UnicodeScalarView()
        }
      } else {
        current.append(scalar)
      }
    }
    if !current.isEmpty { words.append(String(current)) }
    return words
  }

  /// `s.lower()`.
  static func lower(_ string: String) -> String {
    string.lowercased()
  }

  static func scalarCount(_ string: String) -> Int {
    string.unicodeScalars.count
  }

  /// The first `n` code points, like `s[:n]`.
  static func prefix(_ string: String, _ n: Int) -> String {
    var view = String.UnicodeScalarView()
    view.append(contentsOf: string.unicodeScalars.prefix(n))
    return String(view)
  }

  /// The last `n` code points, like `s[-n:]`.
  static func suffix(_ string: String, _ n: Int) -> String {
    var view = String.UnicodeScalarView()
    view.append(contentsOf: string.unicodeScalars.suffix(n))
    return String(view)
  }

  /// Code point index of the first occurrence of `needle`, like `s.index(needle)`.
  static func index(of needle: String, in haystack: String) -> Int? {
    let hay = Array(haystack.unicodeScalars)
    let pin = Array(needle.unicodeScalars)
    guard pin.count <= hay.count else { return nil }
    if pin.isEmpty { return 0 }
    for start in 0...(hay.count - pin.count) where Array(hay[start..<(start + pin.count)]) == pin {
      return start
    }
    return nil
  }

  /// Code point index of the last occurrence of `needle`, like `s.rindex(needle)`.
  static func lastIndex(of needle: String, in haystack: String) -> Int? {
    let hay = Array(haystack.unicodeScalars)
    let pin = Array(needle.unicodeScalars)
    guard pin.count <= hay.count else { return nil }
    if pin.isEmpty { return hay.count }
    for start in stride(from: hay.count - pin.count, through: 0, by: -1)
    where Array(hay[start..<(start + pin.count)]) == pin {
      return start
    }
    return nil
  }
}
