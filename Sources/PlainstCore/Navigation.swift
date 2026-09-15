import Foundation

/// A heading in the document's table of contents.
public struct HeadingEntry: Equatable, Sendable {
  public var level: Int
  /// The heading as it reads, without markup, labels, or comments.
  public var title: String
  public var range: NSRange

  public init(level: Int, title: String, range: NSRange) {
    self.level = level
    self.title = title
    self.range = range
  }
}

public enum DocumentOutline {
  /// Every heading in document order, with markup stripped from its title.
  public static func headings(text: NSString, elements: [OutlineElement]) -> [HeadingEntry] {
    var result: [HeadingEntry] = []
    for (index, element) in elements.enumerated() where element.kind == .heading {
      let range = NSIntersectionRange(element.range, NSRange(location: 0, length: text.length))
      var removed = IndexSet()
      element.markers.forEach { removed.insert(integersIn: Range($0) ?? 0..<0) }
      // Elements inside the heading follow it in the outline.
      for inner in elements[(index + 1)...] {
        guard inner.range.location < NSMaxRange(range) else { break }
        switch inner.kind {
        case .label, .comment:
          removed.insert(integersIn: Range(inner.range) ?? 0..<0)
        case .strong, .emph, .raw, .escape, .ref:
          inner.markers.forEach { removed.insert(integersIn: Range($0) ?? 0..<0) }
        default:
          break
        }
      }
      var title = ""
      var location = range.location
      while location < NSMaxRange(range) {
        let composed = text.rangeOfComposedCharacterSequence(at: location)
        if !removed.contains(location) { title += text.substring(with: composed) }
        location = NSMaxRange(composed)
      }
      title = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
      result.append(
        HeadingEntry(level: max(1, element.number ?? 1), title: title, range: element.range))
    }
    return result
  }

  /// The index of the heading whose section contains `location`, if any.
  public static func currentHeading(in headings: [HeadingEntry], at location: Int) -> Int? {
    headings.lastIndex { $0.range.location <= location }
  }
}

/// Finds the partner of a bracket next to the caret.
public enum BracketMatch {
  private static let opening: [unichar: unichar] = [0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D]
  private static let closing: Set<unichar> = [0x29, 0x5D, 0x7D]

  /// The bracket beside `caret` and its partner, searching only inside `limit`.
  ///
  /// The bracket before the caret wins over the one after it. With `skipStrings`, brackets
  /// inside double-quoted strings are ignored, as Typst code and math treat them as text.
  /// Escaped brackets never match.
  public static func pair(in text: NSString, caret: Int, within limit: NSRange, skipStrings: Bool)
    -> (NSRange, NSRange)?
  {
    let limit = NSIntersectionRange(limit, NSRange(location: 0, length: text.length))
    guard limit.length >= 2 else { return nil }
    var partners: [Int: Int] = [:]
    var stack: [(index: Int, close: unichar)] = []
    var inString = false
    var location = limit.location
    let end = NSMaxRange(limit)
    while location < end {
      let character = text.character(at: location)
      if character == 0x5C {
        location += 2
        continue
      }
      if skipStrings && character == 0x22 {
        inString.toggle()
      } else if !inString {
        if let close = opening[character] {
          stack.append((location, close))
        } else if closing.contains(character) {
          if let open = stack.lastIndex(where: { $0.close == character }) {
            partners[stack[open].index] = location
            partners[location] = stack[open].index
            stack.removeSubrange(open...)
          }
        }
      }
      location += 1
    }
    for candidate in [caret - 1, caret] where candidate >= limit.location && candidate < end {
      if let partner = partners[candidate] {
        return (NSRange(location: candidate, length: 1), NSRange(location: partner, length: 1))
      }
    }
    return nil
  }
}
