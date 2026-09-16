import Foundation

/// Where a link or reference in the document leads.
public enum LinkTarget: Equatable, Sendable {
  case url(URL)
  /// The label a reference names, as its range in the text.
  case label(NSRange)
}

public enum Links {
  /// The link or reference at a location, if there is one and it leads somewhere.
  public static func target(at location: Int, text: NSString, elements: [OutlineElement]) -> LinkTarget? {
    for element in elements where [.link, .hyperlink, .ref].contains(element.kind) {
      let range = NSIntersectionRange(element.range, NSRange(location: 0, length: text.length))
      guard location >= range.location, location < NSMaxRange(range) else { continue }
      let source = text.substring(with: range)
      switch element.kind {
      case .link:
        return url(source).map(LinkTarget.url)
      case .hyperlink:
        return address(inCall: source).flatMap(url).map(LinkTarget.url)
      default:
        // `@name`, possibly followed by a supplement in brackets.
        let name = source.dropFirst().prefix { $0.isLetter || $0.isNumber || "_-.:".contains($0) }
        let wanted = "<\(name.hasSuffix(".") ? String(name.dropLast()) : String(name))>"
        return elements.first { $0.kind == .label && text.substring(with: $0.range) == wanted }
          .map { LinkTarget.label($0.range) }
      }
    }
    return nil
  }

  /// The address in a `#link("…")` call, with its string escapes undone.
  static func address(inCall source: String) -> String? {
    guard let open = source.range(of: "(\"") else { return nil }
    var result = ""
    var escaped = false
    for character in source[open.upperBound...] {
      if escaped {
        result.append(character)
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == "\"" {
        return result
      } else {
        result.append(character)
      }
    }
    return nil
  }

  private static let schemes: Set<String> = ["http", "https", "mailto"]

  static func url(_ string: String) -> URL? {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
      let scheme = url.scheme?.lowercased(), schemes.contains(scheme)
    else { return nil }
    return url
  }

  /// Pasting a web or mail address over selected text on one line links that text:
  /// `#link("address")[text]`. Returns nil for any other paste.
  public static func pasteEdit(pasting pasted: String, text: NSString, selection: NSRange, inCode: Bool)
    -> TextEdit?
  {
    guard selection.length > 0, !inCode, let url = url(pasted) else { return nil }
    let selected = text.substring(with: selection)
    guard !selected.contains("\n"), !selected.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    let quoted = url.absoluteString.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    let replacement = "#link(\"\(quoted)\")[\(selected)]"
    return TextEdit(
      range: selection, replacement: replacement,
      selection: NSRange(location: selection.location + (replacement as NSString).length, length: 0))
  }
}
