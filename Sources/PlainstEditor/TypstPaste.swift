import AppKit
import PlainstCore

/// Turns formatted text, such as a copied web page or word-processor document, into Typst markup.
public enum TypstPaste {
  /// Typst markup for formatted text, or nil when it carries no formatting worth keeping, so it
  /// can be pasted as plain text instead. `indent` is the number of spaces per list level.
  public static func markup(from source: NSAttributedString, indent: Int = 2) -> String? {
    let text = source.string as NSString
    guard text.length > 0 else { return nil }
    let body = bodySize(of: source)
    var blocks: [(markup: String, isListItem: Bool)] = []
    var formatted = false

    text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byParagraphs) {
      _, range, _, _ in
      guard range.length > 0 else { return }
      let style = source.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
      var content = range
      // Lists: HTML and RTF import put a marker such as "\t•\t" before each item's text.
      if let lists = style?.textLists, let list = lists.last {
        let line = text.substring(with: range)
        if line.hasPrefix("\t"), let second = line.dropFirst().firstIndex(of: "\t") {
          let markerLength = (String(line[..<line.index(after: second)]) as NSString).length
          content = NSRange(location: range.location + markerLength, length: range.length - markerLength)
        }
        let numbered = list.markerFormat.rawValue.contains("decimal") || list.markerFormat.rawValue.contains("roman")
          || list.markerFormat.rawValue.contains("alpha")
        let prefix = String(repeating: " ", count: max(0, lists.count - 1) * indent) + (numbered ? "+ " : "- ")
        blocks.append((prefix + inline(source, content, heading: false), true))
        formatted = true
        return
      }
      if let level = headingLevel(source, range, body: body) {
        blocks.append((String(repeating: "=", count: level) + " " + inline(source, range, heading: true), false))
        formatted = true
        return
      }
      let line = inline(source, range, heading: false, formatted: &formatted)
      if !line.trimmingCharacters(in: .whitespaces).isEmpty { blocks.append((line, false)) }
    }
    guard formatted, !blocks.isEmpty else { return nil }
    var output = ""
    for (index, block) in blocks.enumerated() {
      if index > 0 { output += blocks[index - 1].isListItem && block.isListItem ? "\n" : "\n\n" }
      output += block.markup
    }
    return output
  }

  /// The most common font size, weighted by characters, which ordinary paragraphs use.
  private static func bodySize(of source: NSAttributedString) -> CGFloat {
    var sizes: [CGFloat: Int] = [:]
    source.enumerateAttribute(.font, in: NSRange(location: 0, length: source.length)) { value, range, _ in
      if let font = value as? NSFont { sizes[font.pointSize.rounded(), default: 0] += range.length }
    }
    return sizes.max { $0.value < $1.value }?.key ?? NSFont.systemFontSize
  }

  /// A short, bold paragraph set larger than the body text reads as a heading.
  private static func headingLevel(_ source: NSAttributedString, _ range: NSRange, body: CGFloat) -> Int? {
    guard range.length <= 200, let font = source.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
    else { return nil }
    var allBold = true
    source.enumerateAttribute(.font, in: range) { value, _, stop in
      if let font = value as? NSFont, !font.fontDescriptor.symbolicTraits.contains(.bold) {
        allBold = false
        stop.pointee = true
      }
    }
    let ratio = font.pointSize / max(1, body)
    guard ratio >= 1.1, allBold || ratio >= 1.4 else { return nil }
    return ratio >= 1.7 ? 1 : ratio >= 1.3 ? 2 : 3
  }

  private static func inline(_ source: NSAttributedString, _ range: NSRange, heading: Bool) -> String {
    var ignored = false
    return inline(source, range, heading: heading, formatted: &ignored)
  }

  private struct RunStyle: Equatable {
    var bold = false
    var italic = false
    var code = false
    var link: URL?
  }

  /// A paragraph's text with bold, italic, code, and links as Typst markup.
  private static func inline(
    _ source: NSAttributedString, _ range: NSRange, heading: Bool, formatted: inout Bool
  ) -> String {
    var runs: [(style: RunStyle, text: String)] = []
    source.enumerateAttributes(in: range) { attributes, run, _ in
      var style = RunStyle()
      if let font = attributes[.font] as? NSFont {
        let traits = font.fontDescriptor.symbolicTraits
        style.code = traits.contains(.monoSpace)
        style.bold = traits.contains(.bold) && !heading && !style.code
        style.italic = traits.contains(.italic) && !style.code
      }
      if let link = attributes[.link] as? URL {
        style.link = link
      } else if let link = attributes[.link] as? String {
        style.link = URL(string: link)
      }
      let piece = (source.string as NSString).substring(with: run).replacingOccurrences(of: "\u{2028}", with: "\n")
      if let last = runs.last, last.style == style {
        runs[runs.count - 1].text += piece
      } else {
        runs.append((style, piece))
      }
    }

    var output = ""
    for run in runs {
      // Whitespace at a run's edges stays outside its markup, where Typst expects it.
      let leading = String(run.text.prefix { $0 == " " || $0 == "\t" })
      let trailing = String(run.text.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
      let core = String(run.text.dropFirst(leading.count).dropLast(min(trailing.count, max(0, run.text.count - leading.count))))
      guard !core.isEmpty else {
        output += run.text
        continue
      }
      var markup: String
      if run.style.code, !core.contains("`"), !core.contains("\n") {
        markup = "`" + core + "`"
        formatted = true
      } else {
        markup = escape(core, atLineStart: output.isEmpty || output.hasSuffix("\n"))
        if run.style.italic {
          markup = "_" + markup + "_"
          formatted = true
        }
        if run.style.bold {
          markup = "*" + markup + "*"
          formatted = true
        }
      }
      if let link = run.style.link, let scheme = link.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
        let address = link.absoluteString
        markup = core == address
          ? address
          : "#link(\"\(address.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\")[\(markup)]"
        formatted = true
      }
      output += leading + markup + trailing
    }
    // Line breaks inside a paragraph stay line breaks.
    return output.replacingOccurrences(of: "\n", with: " \\\n")
  }

  /// Escapes characters Typst would read as markup, so the text appears as it was copied.
  static func escape(_ text: String, atLineStart: Bool) -> String {
    var result = ""
    var previous: Character?
    var lineStart = atLineStart
    let characters = Array(text)
    for (index, character) in characters.enumerated() {
      let next = index + 1 < characters.count ? characters[index + 1] : nil
      switch character {
      case "\\", "*", "_", "`", "#", "$", "@", "<", "[", "]", "~":
        result += "\\" + String(character)
      case "/" where (next == "/" || next == "*") && previous != ":":
        // "//" and "/*" would start a comment.
        result += "\\/"
      case "=" where lineStart && (next == " " || next == nil), "-" where lineStart && (next == " " || next == nil),
        "+" where lineStart && (next == " " || next == nil), "/" where lineStart && (next == " " || next == nil):
        result += "\\" + String(character)
      default:
        result.append(character)
      }
      if character == "\n" {
        lineStart = true
      } else if character != " " {
        lineStart = false
      }
      previous = character
    }
    return result
  }
}
