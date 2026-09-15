import AppKit
import PlainstCore

/// Typing assistance: Typst completions, snippet placeholders, and automatic pairs.
@MainActor
final class TypingAssistant {
  unowned let editor: TypstEditor
  let popup = CompletionPopup()
  private static let queue = DispatchQueue(label: "io.github.PoteNad.plainst.complete", qos: .userInitiated)
  private var generation = 0
  /// The last completions from Typst, reused while the user keeps typing the same word.
  private var cached: (list: CompletionList, text: String)?
  /// Placeholders left to visit with Tab after accepting a snippet, in document coordinates.
  private(set) var placeholders: [NSRange] = []
  /// Set while pasting or applying an edit, so the text isn't treated as typing.
  var isSuspended = false

  init(editor: TypstEditor) {
    self.editor = editor
    popup.onAccept = { [weak self] completion in self?.accept(completion) }
  }

  private var text: NSString { editor.storage.mutableString }
  private var view: TypstTextView { editor.textView }

  /// Whether a location is inside an equation or embedded code, where Typst code rules apply.
  func isInCode(_ location: Int) -> Bool {
    editor.elements.contains {
      ($0.kind == .math || $0.kind == .code) && $0.range.location < location
        && location <= NSMaxRange($0.range) - ($0.kind == .math ? 1 : 0)
    }
  }

  // MARK: Typing

  /// Handles a typed string before it is inserted. Returns true when the assistant inserted it.
  func handleTyping(_ string: String) -> Bool {
    guard !isSuspended, editor.configuration.autoPair, !view.hasMarkedText() else { return false }
    let selection = view.selectedRange()
    guard
      let edit = AutoPair.edit(
        typing: string, text: text, selection: selection, inCode: isInCode(selection.location))
    else { return false }
    editor.apply(edit, actionName: "Typing")
    return true
  }

  func handleDeleteBackward() -> Bool {
    guard editor.configuration.autoPair,
      let edit = AutoPair.deleteBackward(text: text, selection: view.selectedRange())
    else { return false }
    editor.apply(edit, actionName: "Typing")
    return true
  }

  /// Handles keys while the completion list is open or a snippet has placeholders left.
  func handleCommand(_ selector: Selector) -> Bool {
    if popup.isVisible {
      switch selector {
      case #selector(NSResponder.moveUp(_:)):
        popup.moveSelection(by: -1)
        return true
      case #selector(NSResponder.moveDown(_:)):
        popup.moveSelection(by: 1)
        return true
      case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
        popup.acceptSelection()
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        dismiss()
        return true
      default:
        break
      }
    }
    if selector == #selector(NSResponder.insertTab(_:)), !placeholders.isEmpty {
      let next = placeholders.removeFirst()
      guard NSMaxRange(next) <= text.length else {
        placeholders.removeAll()
        return false
      }
      view.setSelectedRange(next)
      return true
    }
    if selector == #selector(NSResponder.cancelOperation(_:)), !placeholders.isEmpty {
      placeholders.removeAll()
      return true
    }
    return false
  }

  // MARK: Completions

  /// Called after the text changes because of typing.
  func textDidChange(typed: String?) {
    guard editor.configuration.completions, let typed, !isSuspended else {
      if typed == nil { dismiss() }
      return
    }
    let caret = view.selectedRange()
    guard caret.length == 0 else { return dismiss() }
    let character = typed.last ?? " "
    let isWordCharacter = character.isLetter || character.isNumber || character == "_" || character == "-"
    let inCode = isInCode(caret.location)
    if popup.isVisible, isWordCharacter {
      return request(explicit: false)
    }
    if character == "#" && !inCode {
      return request(explicit: false)
    }
    // A reference to a label: "@" at the start of a word, not inside an email address.
    if character == "@" && !inCode && wordLength(before: caret.location - 1) == 0 {
      return request(explicit: false)
    }
    if inCode && (character == "." || (isWordCharacter && wordLength(before: caret.location) >= 2)) {
      return request(explicit: false)
    }
    dismiss()
  }

  private func wordLength(before location: Int) -> Int {
    var start = location
    while start > 0, let scalar = UnicodeScalar(text.character(at: start - 1)),
      CharacterSet.alphanumerics.contains(scalar)
    {
      start -= 1
    }
    return location - start
  }

  func selectionDidChange() {
    let caret = view.selectedRange()
    if popup.isVisible, let cached, caret.length > 0 || caret.location < cached.list.from {
      dismiss()
    }
    if let last = placeholders.last, caret.location > NSMaxRange(last) + 1 {
      placeholders.removeAll()
    }
  }

  /// Moves snippet placeholders for an edit that replaces `range` with `length` characters.
  ///
  /// This uses the exact change from the text view: the text storage's edited range can be wider
  /// when attributes are fixed up in the same edit.
  func textWillChange(range: NSRange, replacementLength length: Int) {
    guard !placeholders.isEmpty else { return }
    let delta = length - range.length
    placeholders = placeholders.map { placeholder in
      var placeholder = placeholder
      if range.location >= placeholder.location && NSMaxRange(range) <= NSMaxRange(placeholder) {
        // Typing inside a placeholder, or at its edge, grows or shrinks it.
        placeholder.length = max(0, placeholder.length + delta)
      } else if NSMaxRange(range) <= placeholder.location {
        placeholder.location += delta
      } else if NSMaxRange(placeholder) <= range.location {
        // Edits after a placeholder leave it where it is.
      } else if range.location <= placeholder.location {
        // The edit covers the placeholder's start: what remains follows the new text.
        let remaining = max(0, NSMaxRange(placeholder) - NSMaxRange(range))
        placeholder = NSRange(location: range.location + length, length: remaining)
      } else {
        // The edit covers the placeholder's end: its start stays.
        placeholder.length = range.location - placeholder.location
      }
      return placeholder
    }
  }

  func dismiss() {
    generation += 1
    popup.hide()
  }

  /// Remembers snippet placeholders to visit with Tab, in document coordinates.
  func setPlaceholders(_ ranges: [NSRange]) { placeholders = ranges }

  /// Asks Typst for completions at the cursor and shows them when they arrive.
  func request(explicit: Bool) {
    let caret = view.selectedRange()
    guard caret.length == 0, editor.textView.window != nil else { return dismiss() }
    let snapshot = editor.text
    // Keep filtering the previous results while the word being completed grows.
    if !explicit, let cached, popup.isVisible, caret.location >= cached.list.from,
      cached.text.hasPrefix((snapshot as NSString).substring(to: cached.list.from)),
      !query(for: cached.list, caret: caret.location).contains(".")
    {
      return present(cached.list, caret: caret.location)
    }
    generation += 1
    let generation = self.generation
    let location = caret.location
    let key = editor.engineKey
    Self.queue.async { [weak self] in
      let list = Engine.completions(snapshot, cursor: location, explicit: explicit, key: key)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self, generation == self.generation, self.editor.text == snapshot,
            self.view.selectedRange() == NSRange(location: location, length: 0)
          else { return }
          self.cached = (list, snapshot)
          self.present(list, caret: location)
        }
      }
    }
  }

  private func query(for list: CompletionList, caret: Int) -> String {
    guard list.from <= caret, caret <= text.length else { return "" }
    return text.substring(with: NSRange(location: list.from, length: caret - list.from))
  }

  private func present(_ list: CompletionList, caret: Int) {
    let exact = query(for: list, caret: caret)
    let typed = exact.lowercased()
    // Matches with the same capitalization come first, then any prefix, then any substring.
    let ranked: [(Int, Completion)] = list.items.compactMap { item in
      let label = item.label.lowercased()
      if typed.isEmpty || item.label.hasPrefix(exact) { return (0, item) }
      if label.hasPrefix(typed) { return (1, item) }
      if label.contains(typed) { return (2, item) }
      return nil
    }
    let items = ranked.enumerated().sorted { a, b in
      if a.element.0 != b.element.0 { return a.element.0 < b.element.0 }
      if a.element.1.label.count != b.element.1.label.count, !typed.isEmpty {
        return a.element.1.label.count < b.element.1.label.count
      }
      return a.offset < b.offset
    }.prefix(100).map(\.element.1)
    // Nothing left to suggest once the word is already complete.
    guard let window = editor.textView.window, !items.isEmpty,
      !(items.count == 1 && items[0].label.lowercased() == typed)
    else { return popup.hide() }
    let caretRect = view.firstRect(
      forCharacterRange: NSRange(location: list.from, length: 0), actualRange: nil)
    popup.show(Array(items), below: caretRect, in: window)
  }

  private func accept(_ completion: Completion) {
    guard let cached else { return dismiss() }
    let caret = view.selectedRange().location
    let from = min(cached.list.from, caret)
    let snippet = ExpandedSnippet(completion.apply)
    dismiss()
    let range = NSRange(location: from, length: caret - from)
    let first = snippet.placeholders.first.map {
      NSRange(location: from + $0.location, length: $0.length)
    }
    let end = NSRange(location: from + (snippet.text as NSString).length, length: 0)
    editor.apply(
      TextEdit(range: range, replacement: snippet.text, selection: first ?? end),
      actionName: "Completion")
    placeholders = snippet.placeholders.dropFirst().map {
      NSRange(location: from + $0.location, length: $0.length)
    }
    if !snippet.placeholders.isEmpty {
      // After the last placeholder, Tab moves past the inserted text.
      placeholders.append(end)
    }
  }
}

extension TypstEditor {
  /// Inserts a symbol name or math snippet at the cursor. Inside an equation it goes in as is;
  /// elsewhere it is wrapped in dollar signs. A selection fills the snippet's first placeholder.
  public func insertMath(_ code: String, snippet isSnippet: Bool) {
    guard textView.isEditable else { return }
    textView.window?.makeFirstResponder(textView)
    let text = storage.mutableString
    let selection = textView.selectedRange()
    let inMath = elements.contains {
      $0.kind == .math && $0.range.location < selection.location
        && NSMaxRange(selection) < NSMaxRange($0.range)
    }
    var source = code
    if isSnippet, selection.length > 0, let open = source.range(of: "${"),
      let close = source[open.upperBound...].firstIndex(of: "}")
    {
      // The selected text becomes the first placeholder, like wrapping it in a function.
      source.replaceSubrange(open.lowerBound...close, with: "${\(text.substring(with: selection))}")
    }
    let snippet = isSnippet ? ExpandedSnippet(source) : ExpandedSnippet(plain: code)
    func isWordCharacter(_ location: Int) -> Bool {
      guard location >= 0, location < text.length, let scalar = UnicodeScalar(text.character(at: location))
      else { return false }
      return CharacterSet.alphanumerics.contains(scalar)
    }
    var body = snippet.text
    var offset = 0
    if inMath {
      if isWordCharacter(selection.location - 1) {
        body = " " + body
        offset = 1
      }
      if isWordCharacter(NSMaxRange(selection)) { body += " " }
    } else {
      body = "$" + body + "$"
      offset = 1
    }
    let start = selection.location + offset
    let placeholders = snippet.placeholders.map { NSRange(location: start + $0.location, length: $0.length) }
    let end = NSRange(location: start + (snippet.text as NSString).length + (inMath ? 0 : 1), length: 0)
    apply(
      TextEdit(range: selection, replacement: body, selection: placeholders.first ?? end),
      actionName: isSnippet ? "Insert Structure" : "Insert Symbol")
    assistant.setPlaceholders(placeholders.isEmpty ? [] : Array(placeholders.dropFirst()) + [end])
  }
}
