import Foundation

/// Turns a frame's OCR lines into privacy model inputs. A port of `piigen/features.py`
/// (with prev_line, next_line and wide on, table_header off, as r38 was trained) and of
/// `rules.context_for` from the Python lab. Any change here has to match Python exactly,
/// or the model sees inputs it was never trained on.
///
/// Each line becomes one or more 496-position windows:
/// `[context] SEP [two lines above, lowercased] SEP [line] SEP [two lines below] PAD...`
enum PIIEncoder {
  static let lineLength = 192
  static let contextLength = 47
  static let wideLength = 127
  static let sequenceLength = 496  // 47 + 1 + 192 + (127 + 1) * 2
  static let pageWords = 256
  static let pageBuckets = 1024

  static let pad: Int32 = 0
  static let sep: Int32 = 1
  static let unknown: Int32 = 2

  /// Printable ASCII, then the extra symbols the model knows. Id = position + 3.
  private static let alphabet: [Unicode.Scalar] = {
    var scalars = (32...126).map { Unicode.Scalar(UInt8($0)) }
    scalars.append(contentsOf: "•·€£¥−–—…（）＊・°±×÷§¶©®™‘’“”«»¢¤₹₩₽".unicodeScalars)
    return scalars
  }()

  private static let charID: [Unicode.Scalar: Int32] = {
    var ids: [Unicode.Scalar: Int32] = [:]
    for (index, scalar) in alphabet.enumerated() {
      ids[scalar] = Int32(index + 3)
    }
    return ids
  }()

  /// One window of one line, ready for the model.
  struct Example {
    let line: Int
    /// Code points `start..<end` of the line that this window covers.
    let start: Int
    let end: Int
    /// Position of the window's first line character in `ids`.
    let offset: Int
    let ids: [Int32]
    let segments: [Int32]
    /// Positions up to and including the last non-padding id.
    var usedLength: Int {
      (ids.lastIndex(where: { $0 != pad }) ?? -1) + 1
    }
  }

  struct Page {
    let examples: [Example]
    let bag: [Int32]
  }

  static func encode(_ text: String) -> [Int32] {
    text.unicodeScalars.map { charID[$0] ?? unknown }
  }

  /// Hashed lowercase words on the page: `crc32(word) % 1023 + 1`, deduplicated, sorted, cut to 256, padded with 0.
  static func pageWordIDs(_ lines: [PIIOCRLine]) -> [Int32] {
    let joined = PIIPython.lower(lines.map(\.text).joined(separator: " "))
    var ids = Set<Int32>()
    var word: [UInt8] = []
    func flush() {
      if word.count >= 3 {
        ids.insert(Int32(crc32(word) % UInt32(pageBuckets - 1) + 1))
      }
      word.removeAll(keepingCapacity: true)
    }
    for scalar in joined.unicodeScalars {
      if scalar.value >= 97 && scalar.value <= 122 {
        word.append(UInt8(scalar.value))
      } else {
        flush()
      }
    }
    flush()
    let sorted = ids.sorted().prefix(pageWords)
    return Array(sorted) + Array(repeating: 0, count: pageWords - sorted.count)
  }

  /// The nearest short label-like line (4 words or fewer) directly above or to the left, lowercased.
  static func context(for lines: [PIIOCRLine], index: Int) -> String {
    let box = lines[index].box
    let x = Double(box.origin.x)
    let y = Double(box.origin.y)
    let w = Double(box.size.width)
    let h = Double(box.size.height)
    var best = ""
    var bestGap = Double.infinity
    for (j, other) in lines.enumerated() {
      if j == index || PIIPython.split(other.text).count > 4 { continue }
      let ox = Double(other.box.origin.x)
      let oy = Double(other.box.origin.y)
      let ow = Double(other.box.size.width)
      let oh = Double(other.box.size.height)
      let horizontalOverlap = min(x + w, ox + ow) - max(x, ox)
      let gapAbove = y - (oy + oh)
      let gapLeft = x - (ox + ow)
      if 0 < gapAbove && gapAbove < 2.5 * h && horizontalOverlap > -h && gapAbove < bestGap {
        best = other.text
        bestGap = gapAbove
      } else if abs(oy - y) < 0.6 * h && 0 < gapLeft && gapLeft < 12 * h && gapLeft < bestGap {
        best = other.text
        bestGap = gapLeft
      }
    }
    return PIIPython.lower(best)
  }

  /// Token and segment ids for one window (segments: 0 context, 2 lines above, 1 the line, 3 lines below).
  static func buildInput(context: String, text: String, above: String, below: String) -> (
    ids: [Int32], segments: [Int32]
  ) {
    var ids = encode(PIIPython.prefix(context, contextLength)) + [sep]
    var segments = [Int32](repeating: 0, count: ids.count)

    let before: [Int32] =
      above.isEmpty ? [sep] : encode(PIIPython.suffix(above, wideLength)) + [sep]
    ids += before
    segments += [Int32](repeating: 2, count: before.count)

    let line = encode(PIIPython.prefix(text, lineLength))
    ids += line
    segments += [Int32](repeating: 1, count: line.count)

    let tail = [sep] + encode(PIIPython.prefix(below, wideLength))
    ids += tail
    segments += [Int32](repeating: 3, count: tail.count)

    let padding = sequenceLength - ids.count
    return (
      ids + [Int32](repeating: pad, count: padding),
      segments + [Int32](repeating: 0, count: padding)
    )
  }

  /// Every window of every line on the page.
  static func page(_ lines: [PIIOCRLine]) -> Page {
    let bag = pageWordIDs(lines)
    var examples: [Example] = []
    for (index, line) in lines.enumerated() {
      let context = context(for: lines, index: index)
      let above = PIIPython.lower(
        lines[max(0, index - 2)..<index].map(\.text).joined(separator: " | "))
      let below = lines[(index + 1)..<min(lines.count, index + 3)].map(\.text).joined(
        separator: " | ")
      let text = PIILineText(line.text)
      for (start, end) in windows(text.count) {
        let input = buildInput(
          context: context, text: text.slice(start, end), above: above, below: below)
        let offset = input.segments.firstIndex(of: 1) ?? input.ids.count
        examples.append(
          Example(
            line: index, start: start, end: end, offset: offset, ids: input.ids,
            segments: input.segments))
      }
    }
    return Page(examples: examples, bag: bag)
  }

  /// Code point ranges of a line, each at most 192 long. An empty line still gets one empty window.
  static func windows(_ length: Int) -> [(Int, Int)] {
    stride(from: 0, to: max(length, 1), by: lineLength).map { ($0, min(length, $0 + lineLength)) }
  }

  private static let crcTable: [UInt32] = (0..<256).map { n in
    var c = UInt32(n)
    for _ in 0..<8 {
      c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
    }
    return c
  }

  /// zlib's crc32.
  static func crc32(_ bytes: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in bytes {
      crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }
    return crc ^ 0xFFFF_FFFF
  }
}
