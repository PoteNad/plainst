import Foundation

/// A suggestion from Typst's IDE support.
public struct Completion: Equatable, Sendable {
  public enum Kind: String, Sendable {
    case syntax, function, type, parameter, constant, path, package, label, font, symbol
  }

  public var kind: Kind
  public var label: String
  /// The text to insert, possibly with `${placeholder}` snippet markers.
  public var apply: String
  public var detail: String
  /// The character a symbol completion stands for.
  public var symbol: String?

  public init(kind: Kind, label: String, apply: String, detail: String, symbol: String?) {
    self.kind = kind
    self.label = label
    self.apply = apply
    self.detail = detail
    self.symbol = symbol
  }
}

public struct CompletionList: Equatable, Sendable {
  /// Where the completed text starts; it runs to the cursor.
  public var from: Int
  public var items: [Completion]
}

public struct TypstSymbol: Equatable, Hashable, Sendable {
  public var name: String
  public var value: String
}

/// Text ready to insert from a completion snippet, with the placeholders to visit in order.
public struct ExpandedSnippet: Equatable, Sendable {
  public var text: String
  /// Placeholder ranges relative to the start of `text`, in UTF-16 offsets.
  public var placeholders: [NSRange]

  /// Text without placeholders.
  public init(plain text: String) {
    self.text = text
    placeholders = []
  }

  /// Expands `${}` and `${name}` markers: each becomes its name (or nothing) and a placeholder.
  public init(_ snippet: String) {
    var output = ""
    var placeholders: [NSRange] = []
    var index = snippet.startIndex
    while index < snippet.endIndex {
      if snippet[index...].hasPrefix("${"),
        let close = snippet[index...].firstIndex(of: "}")
      {
        let name = snippet[snippet.index(index, offsetBy: 2)..<close]
        let start = (output as NSString).length
        output += name
        placeholders.append(NSRange(location: start, length: (String(name) as NSString).length))
        index = snippet.index(after: close)
      } else {
        output.append(snippet[index])
        index = snippet.index(after: index)
      }
    }
    text = output
    self.placeholders = placeholders
  }
}

/// Automatic closing of brackets, quotes and dollar signs.
public enum AutoPair {
  static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "$": "$", "\"": "\""]

  /// The edit for typing `character` at an empty selection, or nil to insert it normally.
  ///
  /// - `inCode`: whether the cursor is inside an equation or embedded code, where quotes pair.
  public static func edit(typing character: String, text: NSString, selection: NSRange, inCode: Bool)
    -> TextEdit?
  {
    guard character.count == 1, let typed = character.first else { return nil }
    let location = selection.location
    let next: unichar? = NSMaxRange(selection) < text.length ? text.character(at: NSMaxRange(selection)) : nil
    let previous: unichar? = location > 0 ? text.character(at: location - 1) : nil
    let nextCharacter = next.flatMap { UnicodeScalar($0) }.map { Character($0) }

    // Wrap a selection in a pair.
    if selection.length > 0, let close = pairs[typed], typed != "\"" || inCode {
      let inner = text.substring(with: selection)
      return TextEdit(
        range: selection, replacement: String(typed) + inner + String(close),
        selection: NSRange(location: location + 1, length: selection.length))
    }
    guard selection.length == 0 else { return nil }

    // Step over a closing character that was inserted automatically.
    if let nextCharacter, nextCharacter == typed, [")", "]", "}", "$", "\""].contains(typed) {
      return TextEdit(
        range: NSRange(location: location, length: 0), replacement: "",
        selection: NSRange(location: location + 1, length: 0))
    }

    guard let close = pairs[typed] else { return nil }
    if typed == "\"" && !inCode { return nil }
    // Escaped characters stay literal.
    if previous == 0x5C { return nil }
    // Only pair before whitespace, punctuation, or the end of the line.
    if let nextCharacter, nextCharacter.isLetter || nextCharacter.isNumber { return nil }
    // A dollar sign right after a word is probably closing an equation typed by hand.
    if typed == "$", let previous, let scalar = UnicodeScalar(previous),
      CharacterSet.alphanumerics.contains(scalar), !inCode
    {
      return nil
    }
    if typed == "$" && inCode { return nil }
    return TextEdit(
      range: NSRange(location: location, length: 0), replacement: String(typed) + String(close),
      selection: NSRange(location: location + 1, length: 0))
  }

  /// Deleting backward between an empty pair removes both characters.
  public static func deleteBackward(text: NSString, selection: NSRange) -> TextEdit? {
    guard selection.length == 0, selection.location > 0, selection.location < text.length else {
      return nil
    }
    let before = text.character(at: selection.location - 1)
    let after = text.character(at: selection.location)
    guard let open = UnicodeScalar(before).map(Character.init), let close = pairs[open],
      String(close).utf16.first == after
    else { return nil }
    return TextEdit(
      range: NSRange(location: selection.location - 1, length: 2), replacement: "",
      selection: NSRange(location: selection.location - 1, length: 0))
  }
}
