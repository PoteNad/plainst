import Foundation

/// A single replacement plus where the selection should end up afterwards.
public struct TextEdit: Equatable, Sendable {
  public var range: NSRange
  public var replacement: String
  public var selection: NSRange

  public init(range: NSRange, replacement: String, selection: NSRange) {
    self.range = range
    self.replacement = replacement
    self.selection = selection
  }

  /// Applies the edit to a string, for tests and previews.
  public func applied(to text: String) -> String {
    (text as NSString).replacingCharacters(in: range, with: replacement)
  }
}

/// Formatting commands expressed as plain-text edits, so every command writes ordinary Typst.
public enum Formatting {
  public enum Inline: Sendable {
    case strong, emph, code

    var delimiter: String {
      switch self {
      case .strong: "*"
      case .emph: "_"
      case .code: "`"
      }
    }

    var kind: OutlineElement.Kind {
      switch self {
      case .strong: .strong
      case .emph: .emph
      case .code: .raw
      }
    }
  }

  /// Wraps the selection in delimiters, or removes them when the selection is already formatted.
  public static func toggle(
    _ inline: Inline, text: NSString, selection: NSRange, elements: [OutlineElement]
  ) -> TextEdit {
    let enclosing = elements.last { element in
      element.kind == inline.kind && !element.block && element.markers.count == 2
        && element.range.location <= selection.location
        && NSMaxRange(selection) <= NSMaxRange(element.range)
    }
    if let element = enclosing {
      let open = element.markers[0]
      let close = element.markers[1]
      let innerRange = NSRange(
        location: NSMaxRange(open), length: max(0, close.location - NSMaxRange(open)))
      let inner = text.substring(with: innerRange)
      let location = max(element.range.location, selection.location - open.length)
      let length = min(selection.length, (inner as NSString).length)
      return TextEdit(
        range: element.range, replacement: inner,
        selection: NSRange(location: location, length: length))
    }

    var range = selection
    let whitespace = CharacterSet.whitespacesAndNewlines
    while range.length > 0,
      let scalar = UnicodeScalar(text.character(at: range.location)), whitespace.contains(scalar)
    {
      range.location += 1
      range.length -= 1
    }
    while range.length > 0,
      let scalar = UnicodeScalar(text.character(at: NSMaxRange(range) - 1)),
      whitespace.contains(scalar)
    {
      range.length -= 1
    }
    let d = inline.delimiter
    let selected = text.substring(with: range)
    return TextEdit(
      range: range, replacement: d + selected + d,
      selection: NSRange(location: range.location + 1, length: range.length))
  }

  /// The full lines touched by the selection.
  static func lines(_ text: NSString, _ selection: NSRange) -> NSRange {
    var range = selection
    // A selection ending at the start of a line does not include that line.
    if range.length > 0, NSMaxRange(range) <= text.length,
      text.character(at: NSMaxRange(range) - 1) == 0x0A
    {
      range.length -= 1
    }
    return text.lineRange(for: range)
  }

  /// Rewrites each selected line with `transform`, keeping line endings intact.
  static func rewriteLines(
    _ text: NSString, _ selection: NSRange, _ transform: ([String]) -> [String]
  ) -> TextEdit {
    let range = lines(text, selection)
    var block = text.substring(with: range)
    let trailingNewline = block.hasSuffix("\n")
    if trailingNewline { block.removeLast() }
    let original = block.components(separatedBy: "\n")
    let replaced = transform(original).joined(separator: "\n") + (trailingNewline ? "\n" : "")
    let newLength = (replaced as NSString).length - (trailingNewline ? 1 : 0)
    let selectionResult: NSRange
    if original.count == 1 {
      // Keep the caret in place relative to the end of the line.
      let delta = (replaced as NSString).length - range.length
      let location = max(range.location, min(selection.location + delta, range.location + newLength))
      selectionResult = NSRange(location: location, length: selection.length == 0 ? 0 : max(0, min(selection.length, newLength)))
    } else {
      selectionResult = NSRange(location: range.location, length: newLength)
    }
    return TextEdit(range: range, replacement: replaced, selection: selectionResult)
  }

  private static func split(_ line: String) -> (indent: String, marker: String?, body: String) {
    let indent = String(line.prefix { $0 == " " || $0 == "\t" })
    let rest = String(line.dropFirst(indent.count))
    if let match = rest.range(of: #"^(=+|-|\+|\d+\.|/)( |$)"#, options: .regularExpression) {
      let marker = String(rest[match]).trimmingCharacters(in: .whitespaces)
      return (indent, marker, String(rest[match.upperBound...]))
    }
    return (indent, nil, rest)
  }

  /// Makes the selected lines headings of `level`, or body text when `level` is 0.
  public static func setHeading(level: Int, text: NSString, selection: NSRange) -> TextEdit {
    rewriteLines(text, selection) { lines in
      lines.map { line in
        let parts = split(line)
        guard level > 0 else { return parts.marker?.hasPrefix("=") == true ? parts.body : line }
        return String(repeating: "=", count: level) + " " + parts.body
      }
    }
  }

  public enum ListStyle: Sendable {
    case bullet, numbered

    var marker: String { self == .bullet ? "-" : "+" }
  }

  /// Turns the selected lines into list items, or back into paragraphs.
  public static func toggleList(_ style: ListStyle, text: NSString, selection: NSRange) -> TextEdit {
    rewriteLines(text, selection) { lines in
      let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      let isMatch = { (marker: String?) -> Bool in
        guard let marker else { return false }
        return style == .bullet ? marker == "-" : (marker == "+" || marker.hasSuffix("."))
      }
      let removing = !content.isEmpty && content.allSatisfy { isMatch(split($0).marker) }
      return lines.map { line in
        let parts = split(line)
        if removing { return parts.indent + parts.body }
        if line.trimmingCharacters(in: .whitespaces).isEmpty && lines.count > 1 { return line }
        return parts.indent + style.marker + " " + parts.body
      }
    }
  }

  /// Inserts an equation around the selection.
  public static func insertEquation(block: Bool, text: NSString, selection: NSRange) -> TextEdit {
    let selected = text.substring(with: selection)
    guard block else {
      let caret = selection.length == 0
        ? NSRange(location: selection.location + 1, length: 0)
        : NSRange(location: selection.location + 1, length: selection.length)
      return TextEdit(range: selection, replacement: "$" + selected + "$", selection: caret)
    }
    let before = selection.location > 0 ? text.character(at: selection.location - 1) : 0x0A
    let after = NSMaxRange(selection) < text.length ? text.character(at: NSMaxRange(selection)) : 0x0A
    let prefix = before == 0x0A ? "" : "\n"
    let suffix = after == 0x0A ? "" : "\n"
    let body = "$ " + selected + " $"
    let location = selection.location + (prefix as NSString).length + 2
    return TextEdit(
      range: selection, replacement: prefix + body + suffix,
      selection: NSRange(location: location, length: selection.length))
  }

  /// Continues a list when Return is pressed at the end of an item, or ends it on an empty item.
  public static func newline(text: NSString, selection: NSRange) -> TextEdit? {
    guard selection.length == 0 else { return nil }
    let line = text.lineRange(for: selection)
    var content = text.substring(with: line)
    if content.hasSuffix("\n") { content.removeLast() }
    let parts = split(content)
    guard let marker = parts.marker, !marker.hasPrefix("=") else { return nil }
    let markerEnd = line.location + (parts.indent as NSString).length + (marker as NSString).length
    guard selection.location > markerEnd else { return nil }
    if parts.body.trimmingCharacters(in: .whitespaces).isEmpty {
      let range = NSRange(location: line.location, length: (content as NSString).length)
      return TextEdit(
        range: range, replacement: "", selection: NSRange(location: line.location, length: 0))
    }
    var next = marker
    if marker.hasSuffix("."), let number = Int(marker.dropLast()) { next = "\(number + 1)." }
    let insertion = "\n" + parts.indent + next + " "
    return TextEdit(
      range: selection, replacement: insertion,
      selection: NSRange(location: selection.location + (insertion as NSString).length, length: 0))
  }

  /// How many columns a run of spaces and tabs spans, with tab stops every `width` columns.
  public static func columns(of indent: some StringProtocol, width: Int) -> Int {
    let width = max(1, width)
    return indent.reduce(0) { column, character in
      character == "\t" ? (column / width + 1) * width : column + 1
    }
  }

  /// Removes up to one indentation level of `width` columns from the start of a line.
  private static func outdented(_ line: String, width: Int) -> String {
    var removed = 0
    var index = line.startIndex
    while index < line.endIndex, removed < width, line[index] == " " || line[index] == "\t" {
      removed = line[index] == "\t" ? (removed / width + 1) * width : removed + 1
      index = line.index(after: index)
    }
    return String(line[index...])
  }

  /// Indents or outdents list items by `width` spaces, or returns nil when no line is a list item.
  public static func indentList(text: NSString, selection: NSRange, outdent: Bool, width: Int = 2)
    -> TextEdit?
  {
    let range = lines(text, selection)
    let block = text.substring(with: range)
    let items = block.split(separator: "\n", omittingEmptySubsequences: false)
    let isList = items.contains { split(String($0)).marker.map { !$0.hasPrefix("=") } ?? false }
    guard isList else { return nil }
    let width = max(1, width)
    return rewriteLines(text, selection) { lines in
      lines.map { line in
        guard split(line).marker.map({ !$0.hasPrefix("=") }) == true else { return line }
        return outdent ? outdented(line, width: width) : String(repeating: " ", count: width) + line
      }
    }
  }

  /// Indents or outdents every selected line by one level of `width` spaces. Blank lines in a
  /// multi-line selection are left alone. Returns nil when outdenting changes nothing.
  public static func indentLines(text: NSString, selection: NSRange, outdent: Bool, width: Int)
    -> TextEdit?
  {
    let width = max(1, width)
    var changed = false
    let edit = rewriteLines(text, selection) { lines in
      lines.map { line in
        if outdent {
          let result = outdented(line, width: width)
          changed = changed || result != line
          return result
        }
        if lines.count > 1 && line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
        changed = true
        return String(repeating: " ", count: width) + line
      }
    }
    return changed ? edit : nil
  }

  /// Replaces the selection with spaces that reach the next indentation stop.
  public static func softTab(text: NSString, selection: NSRange, width: Int) -> TextEdit {
    let width = max(1, width)
    let lineStart = text.lineRange(for: NSRange(location: selection.location, length: 0)).location
    let before = text.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
    let spaces = width - columns(of: before, width: width) % width
    return TextEdit(
      range: selection, replacement: String(repeating: " ", count: spaces),
      selection: NSRange(location: selection.location + spaces, length: 0))
  }

  // MARK: Document style

  /// Sets the document's font and text size by rewriting its last `#set text(...)` rule, or by
  /// adding one at the top. A nil value removes that argument, returning to Typst's default;
  /// a rule left with no arguments is removed. Other arguments stay exactly as written.
  public static func setTextStyle(
    font: String?, size: Double?, text: NSString, style: DocumentStyle, selection: NSRange
  ) -> TextEdit? {
    rewriteRule(
      "text", style.textRule, other: style.parRule,
      values: [("font", font.map(quoted)), ("size", size.map(pointsLiteral))], text: text,
      selection: selection)
  }

  /// Turns justified paragraphs on or off with the document's `#set par(...)` rule.
  public static func setJustified(_ justify: Bool, text: NSString, style: DocumentStyle, selection: NSRange)
    -> TextEdit?
  {
    rewriteRule(
      "par", style.parRule, other: style.textRule, values: [("justify", justify ? "true" : nil)],
      text: text, selection: selection)
  }

  private static func quoted(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
  }

  private static func pointsLiteral(_ points: Double) -> String {
    let rounded = (points * 100).rounded() / 100
    return (rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)) + "pt"
  }

  private static func rewriteRule(
    _ target: String, _ rule: DocumentStyle.Rule?, other: DocumentStyle.Rule?,
    values: [(name: String, value: String?)], text: NSString, selection: NSRange
  ) -> TextEdit? {
    let names = Set(values.map(\.name))
    let kept = (rule?.arguments ?? []).filter { !names.contains($0.name ?? "") }.map { text.substring(with: $0.range) }
    let added = values.compactMap { item in item.value.map { "\(item.name): \($0)" } }
    let arguments = kept + added
    let body = "#set \(target)(" + arguments.joined(separator: ", ") + ")"

    let range: NSRange
    let replacement: String
    if let rule {
      if arguments.isEmpty {
        // Remove the rule, and its line when nothing else is on it.
        let line = text.lineRange(for: rule.range)
        let onItsOwn = text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
          == text.substring(with: rule.range)
        range = onItsOwn ? line : rule.range
        replacement = ""
      } else {
        range = rule.range
        replacement = body
      }
    } else {
      guard !added.isEmpty else { return nil }
      // New rules go at the top, beside the other style rule when there is one.
      let location = other.map { NSMaxRange(text.lineRange(for: $0.range)) } ?? 0
      let atLineStart = location == 0 || text.character(at: location - 1) == 0x0A
      range = NSRange(location: location, length: 0)
      let next = location < text.length ? text.character(at: location) : 0x0A
      replacement = (atLineStart ? "" : "\n") + body + "\n" + (other == nil && next != 0x0A && next != 0x23 ? "\n" : "")
    }
    // Keep the cursor on the same text.
    let delta = (replacement as NSString).length - range.length
    var caret = selection
    if caret.location >= NSMaxRange(range) {
      caret.location += delta
    } else if caret.location > range.location {
      caret = NSRange(location: range.location + (replacement as NSString).length, length: 0)
    }
    return TextEdit(range: range, replacement: replacement, selection: caret)
  }

  /// Counts words the way a reader would, ignoring markup punctuation.
  public static func wordCount(_ text: String) -> Int {
    var count = 0
    text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) { _, _, _, _ in
      count += 1
    }
    return count
  }
}
