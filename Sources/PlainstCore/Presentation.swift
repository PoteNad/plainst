import Foundation

/// How the editor shows the document. Both modes edit the same text.
public enum EditorMode: String, CaseIterable, Sendable {
  case writing
  case source

  public var title: String {
    switch self {
    case .writing: "Writing"
    case .source: "Source"
    }
  }
}

/// Character-level styling derived from the outline.
public struct TextStyle: OptionSet, Hashable, Sendable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let bold = TextStyle(rawValue: 1 << 0)
  public static let italic = TextStyle(rawValue: 1 << 1)
  /// Inline raw text.
  public static let code = TextStyle(rawValue: 1 << 2)
  /// Typst code Plainst preserves but does not format, such as `#set`.
  public static let unsupported = TextStyle(rawValue: 1 << 3)
  public static let comment = TextStyle(rawValue: 1 << 4)
  /// Delimiters and other markup characters.
  public static let marker = TextStyle(rawValue: 1 << 5)
  public static let link = TextStyle(rawValue: 1 << 6)
  /// An equation shown as its source.
  public static let mathSource = TextStyle(rawValue: 1 << 7)
  public static let rawBlock = TextStyle(rawValue: 1 << 8)
  /// A label such as `<intro>` that names the element before it.
  public static let label = TextStyle(rawValue: 1 << 9)
  /// A reference such as `@intro`.
  public static let reference = TextStyle(rawValue: 1 << 10)
}

/// Paragraph-level styling. Every character of a line shares one value.
public struct ParagraphKind: Hashable, Sendable {
  public var heading = 0
  public var centered = false
  public var rawBlock = false
  /// For list items, the text before the item's content as it is displayed.
  public var listPrefix: String?
  /// Whether the line belongs to a display equation drawn as a card in the Writing view.
  public var mathCard: MathCardStyle = .none

  public init(
    heading: Int = 0, centered: Bool = false, rawBlock: Bool = false, listPrefix: String? = nil,
    mathCard: MathCardStyle = .none
  ) {
    self.heading = heading
    self.centered = centered
    self.rawBlock = rawBlock
    self.listPrefix = listPrefix
    self.mathCard = mathCard
  }
}

public enum MathCardStyle: Hashable, Sendable {
  case none
  /// The card shows the rendered equation.
  case rendered
  /// The card shows the equation's source in an input field.
  case source
}

/// A display equation that sits on its own lines, drawn as a card in the Writing view.
public struct MathBlock: Equatable, Sendable {
  /// The equation, including its dollar signs.
  public var range: NSRange
  /// The whole lines the equation occupies.
  public var lines: NSRange
  public var rendered: Bool
  public var active: Bool
}

public struct StyleRun: Equatable, Sendable {
  public var range: NSRange
  public var style: TextStyle
  public var heading: Int
  public var paragraph: ParagraphKind

  public init(range: NSRange, style: TextStyle, heading: Int, paragraph: ParagraphKind) {
    self.range = range
    self.style = style
    self.heading = heading
    self.paragraph = paragraph
  }
}

/// Something drawn in place of a run of source characters in the Writing view.
public enum Replacement: Hashable, Sendable {
  case text(String)
  /// An equation, rendered at `scale` times the body text size.
  case math(source: String, block: Bool, scale: CGFloat)
}

/// Everything the Writing or Source view needs to draw the current text.
public struct Presentation: Equatable, Sendable {
  public var runs: [StyleRun] = []
  /// Characters drawn with no width, such as concealed delimiters.
  public var hidden = IndexSet()
  /// Replacements keyed by the first character they cover; the rest of their range is hidden.
  public var replacements: [Int: Replacement] = [:]
  /// The equation containing the selection, if any.
  public var activeMath: OutlineElement?
  /// Display equations drawn as cards, in document order.
  public var mathBlocks: [MathBlock] = []
  /// Inline equations shown as source in the Writing view.
  public var inlineMathSources: [NSRange] = []

  public init() {}

  static let bullets = ["•", "‣", "–"]

  public static func headingScale(_ level: Int) -> CGFloat {
    switch level {
    case 1: 1.4
    case 2: 1.2
    default: 1
    }
  }

  /// Builds the presentation for `text`.
  ///
  /// - Parameter canRenderMath: Whether an equation already has a rendered image. Equations
  ///   without one stay visible as source so nothing ever disappears.
  public static func make(
    text: NSString, elements: [OutlineElement], selection: NSRange, mode: EditorMode,
    canRenderMath: (Replacement) -> Bool = { _ in false }
  ) -> Presentation {
    var result = Presentation()
    let length = text.length
    guard length > 0 else { return result }
    var styles = [TextStyle](repeating: [], count: length)
    var headings = [UInt8](repeating: 0, count: length)
    var lineKinds: [Int: ParagraphKind] = [:]
    let writing = mode == .writing

    func clamp(_ range: NSRange) -> Range<Int> {
      let lower = min(max(0, range.location), length)
      let upper = min(max(lower, NSMaxRange(range)), length)
      return lower..<upper
    }
    func add(_ style: TextStyle, _ range: NSRange) {
      for i in clamp(range) { styles[i].insert(style) }
    }
    func hide(_ range: NSRange) {
      let r = clamp(range)
      if !r.isEmpty { result.hidden.insert(integersIn: r) }
    }
    func replace(_ range: NSRange, with replacement: Replacement) {
      let r = clamp(range)
      guard !r.isEmpty else { return }
      result.replacements[r.lowerBound] = replacement
      if r.count > 1 { result.hidden.insert(integersIn: (r.lowerBound + 1)..<r.upperBound) }
    }
    func lineStart(_ location: Int) -> Int {
      text.lineRange(for: NSRange(location: min(location, length), length: 0)).location
    }
    func isActive(_ range: NSRange) -> Bool {
      let end = NSMaxRange(range)
      if selection.length == 0 {
        return selection.location >= range.location && selection.location <= end
      }
      return selection.location <= end && NSMaxRange(selection) >= range.location
    }
    func onlyWhitespace(_ range: Range<Int>) -> Bool {
      for i in range {
        let c = text.character(at: i)
        if c != 0x20 && c != 0x09 && c != 0x0A && c != 0x0D { return false }
      }
      return true
    }

    var listStack: [NSRange] = []
    for element in elements {
      let range = element.range
      switch element.kind {
      case .heading:
        let level = max(1, min(6, element.number ?? 1))
        for i in clamp(range) { headings[i] = UInt8(level) }
        lineKinds[lineStart(range.location), default: ParagraphKind()].heading = level
        element.markers.forEach { add(.marker, $0) }
        if writing && !isActive(range) { element.markers.forEach(hide) }

      case .strong, .emph:
        add(element.kind == .strong ? .bold : .italic, range)
        element.markers.forEach { add(.marker, $0) }
        if writing && !isActive(range) { element.markers.forEach(hide) }

      case .raw:
        add(element.block ? .rawBlock : .code, range)
        element.markers.forEach { add(.marker, $0) }
        if element.block {
          let lines = text.lineRange(for: range)
          var location = lines.location
          while location < NSMaxRange(lines) {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            lineKinds[line.location, default: ParagraphKind()].rawBlock = true
            location = NSMaxRange(line)
          }
        }
        if writing && !isActive(range) { element.markers.forEach(hide) }

      case .link:
        add(.link, range)
      case .label:
        add(.label, range)
      case .ref:
        add(.reference, range)
      case .code:
        add(.unsupported, range)
      case .comment:
        add(.comment, range)
      case .linebreak:
        add(.marker, range)
      case .escape:
        element.markers.forEach { add(.marker, $0) }
        if writing && !isActive(range) { element.markers.forEach(hide) }

      case .shorthand:
        if writing, let replacement = element.text, !isActive(range) {
          replace(range, with: .text(replacement))
        }

      case .term:
        if let content = element.content { add(.bold, content) }
        element.markers.forEach { add(.marker, $0) }
        if writing && !isActive(range) { element.markers.forEach(hide) }

      case .list, .enum:
        while let last = listStack.last, NSMaxRange(last) <= range.location {
          listStack.removeLast()
        }
        let depth = listStack.count
        listStack.append(range)
        guard let marker = element.markers.first else { continue }
        add(.marker, marker)
        let start = lineStart(range.location)
        let indent = text.substring(with: NSRange(location: start, length: max(0, marker.location - start)))
        let markerActive = isActive(NSRange(location: start, length: NSMaxRange(marker) - start))
        var displayed = text.substring(with: marker)
        if writing && !markerActive {
          displayed = element.kind == .list ? bullets[depth % bullets.count] : "\(element.number ?? 1)."
          replace(marker, with: .text(displayed))
        }
        lineKinds[start, default: ParagraphKind()].listPrefix = indent + displayed + " "

      case .math:
        let headingLevel = Int(headings[clamp(range).lowerBound])
        let replacement = Replacement.math(
          source: text.substring(with: range), block: element.block,
          scale: headingScale(headingLevel))
        let active = isActive(range)
        if active { result.activeMath = element }
        let rendered = writing && !active && canRenderMath(replacement)
        let lines = text.lineRange(for: range)
        let card =
          writing && element.block && onlyWhitespace(lines.location..<range.location)
          && onlyWhitespace(NSMaxRange(range)..<NSMaxRange(lines))
        if rendered {
          replace(range, with: replacement)
        } else {
          add(.mathSource, range)
          if writing && !card { result.inlineMathSources.append(range) }
        }
        if card {
          result.mathBlocks.append(
            MathBlock(range: range, lines: lines, rendered: rendered, active: active))
          var location = lines.location
          while location < NSMaxRange(lines) {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            lineKinds[line.location, default: ParagraphKind()].mathCard = rendered ? .rendered : .source
            lineKinds[line.location, default: ParagraphKind()].centered = rendered
            location = max(NSMaxRange(line), location + 1)
          }
        }
      }
    }

    // Coalesce characters into runs, keeping paragraph styles uniform per line.
    var location = 0
    var runs: [StyleRun] = []
    while location < length {
      let line = text.lineRange(for: NSRange(location: location, length: 0))
      let kind = lineKinds[line.location] ?? ParagraphKind()
      var i = line.location
      let end = NSMaxRange(line)
      while i < end {
        let style = styles[i]
        let heading = Int(headings[i])
        var j = i + 1
        while j < end && styles[j] == style && Int(headings[j]) == heading { j += 1 }
        if let last = runs.last, NSMaxRange(last.range) == i, last.style == style,
          last.heading == heading, last.paragraph == kind
        {
          runs[runs.count - 1].range.length += j - i
        } else {
          runs.append(
            StyleRun(
              range: NSRange(location: i, length: j - i), style: style, heading: heading,
              paragraph: kind))
        }
        i = j
      }
      location = max(end, location + 1)
    }
    result.runs = runs
    return result
  }
}

extension Presentation {
  /// The smallest range covering every run that differs between two presentations
  /// of texts with the given lengths, in the new text's coordinates.
  public static func changedRange(old: [StyleRun], new: [StyleRun], newLength: Int) -> NSRange? {
    var prefix = 0
    while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
    if prefix == old.count && prefix == new.count { return nil }
    let oldLength = old.last.map { NSMaxRange($0.range) } ?? 0
    var suffix = 0
    while suffix < old.count - prefix, suffix < new.count - prefix {
      let a = old[old.count - 1 - suffix]
      let b = new[new.count - 1 - suffix]
      guard a.style == b.style, a.heading == b.heading, a.paragraph == b.paragraph,
        a.range.length == b.range.length,
        oldLength - a.range.location == newLength - b.range.location
      else { break }
      suffix += 1
    }
    let start = prefix < new.count ? new[prefix].range.location : newLength
    let end = suffix > 0 ? new[new.count - suffix].range.location : newLength
    let lower = prefix > 0 ? min(start, NSMaxRange(new[prefix - 1].range)) : 0
    return NSRange(location: lower, length: max(0, max(end, lower) - lower))
  }
}
