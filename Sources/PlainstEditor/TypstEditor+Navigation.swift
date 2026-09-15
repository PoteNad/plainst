import AppKit
import PlainstCore

extension TypstEditor {
  /// The live text. Copy it, or use ``text``, before handing it to other threads.
  public var string: NSString { storage.mutableString }

  /// The length of the text in UTF-16 code units, as `NSRange` counts it.
  public var textLength: Int { storage.length }

  /// The document's headings, with markup stripped from their titles.
  public var headings: [HeadingEntry] {
    DocumentOutline.headings(text: storage.mutableString, elements: elements)
  }

  /// Where a range of text is drawn, in the text view's coordinates.
  public func textViewRect(for range: NSRange) -> NSRect {
    let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
    return rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
  }

  /// Scrolls so `range` sits near the top of the visible text.
  public func scrollToTop(of range: NSRange) {
    layout.ensureLayout(forCharacterRange: range)
    let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
    let clip = scrollView.contentView
    var bounds = clip.bounds
    bounds.origin.y = max(0, rect.minY + textView.textContainerOrigin.y - bodySize * 1.5)
    clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
    scrollView.reflectScrolledClipView(clip)
  }

  // MARK: Matching brackets

  /// Highlights the bracket beside the cursor and its partner, within the equation, code or
  /// paragraph the cursor is in.
  func updateBracketHighlight() {
    let full = NSRange(location: 0, length: storage.length)
    if let previous = highlightedBrackets {
      highlightedBrackets = nil
      for range in [previous.0, previous.1] where NSMaxRange(range) <= full.length {
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
      }
    }
    let caret = textView.selectedRange()
    guard caret.length == 0, storage.length > 0, !textView.hasMarkedText() else { return }
    let text = storage.mutableString
    let code = elements.last {
      [.math, .code, .raw].contains($0.kind) && $0.range.location < caret.location
        && caret.location <= NSMaxRange($0.range)
    }
    let limit = code?.range ?? text.paragraphRange(for: NSRange(location: min(caret.location, text.length), length: 0))
    guard code?.kind != .raw,
      let pair = BracketMatch.pair(
        in: text, caret: caret.location, within: limit, skipStrings: code != nil)
    else { return }
    // Brackets hidden in the Writing view have nothing to highlight.
    if concealing && (presentation.hidden.contains(pair.0.location) || presentation.hidden.contains(pair.1.location)) {
      return
    }
    let color = NSColor.controlAccentColor.withAlphaComponent(0.35)
    for range in [pair.0, pair.1] {
      layout.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
    }
    highlightedBrackets = pair
  }

  // MARK: Indentation guides

  /// Draws a faint line at the start of each indentation level on indented lines.
  func drawIndentGuides(forCharacters characters: NSRange, at origin: NSPoint) {
    guard configuration.showsIndentGuides, storage.length > 0 else { return }
    let text = storage.mutableString
    let width = configuration.tabWidth
    let end = min(NSMaxRange(characters), text.length)
    var location = text.lineRange(for: NSRange(location: min(characters.location, text.length), length: 0)).location
    NSColor.separatorColor.setFill()
    while location < end {
      let line = text.lineRange(for: NSRange(location: location, length: 0))
      defer { location = NSMaxRange(line) }
      // The leading spaces and tabs, and the column where each character starts.
      var starts: [(index: Int, column: Int)] = []
      var column = 0
      var index = line.location
      while index < NSMaxRange(line) {
        let character = text.character(at: index)
        guard character == 0x20 || character == 0x09 else { break }
        starts.append((index, column))
        column = character == 0x09 ? (column / width + 1) * width : column + 1
        index += 1
      }
      // Only lines with content after the indentation get guides.
      guard index < NSMaxRange(line), ![0x0A, 0x0D].contains(text.character(at: index)) else { continue }
      let levels = column / width
      guard levels > 0, !(concealing && mathBlock(containing: line.location) != nil) else { continue }
      let firstGlyph = layout.glyphIndexForCharacter(at: line.location)
      let lastGlyph = layout.glyphIndexForCharacter(at: max(line.location, NSMaxRange(line) - 1))
      guard lastGlyph < layout.numberOfGlyphs else { continue }
      let top = layout.lineFragmentUsedRect(forGlyphAt: firstGlyph, effectiveRange: nil).minY
      let bottom = layout.lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil).maxY
      let contentX = layout.location(forGlyphAt: layout.glyphIndexForCharacter(at: index)).x
      for level in 0..<levels {
        let target = level * width
        guard let start = starts.last(where: { $0.column <= target }),
          !(concealing && presentation.hidden.contains(start.index))
        else { continue }
        let glyph = layout.glyphIndexForCharacter(at: start.index)
        let x = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX
          + layout.location(forGlyphAt: glyph).x
        guard x < contentX + layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX - 1 else { continue }
        NSRect(x: (origin.x + x).rounded() + 0.5, y: origin.y + top, width: 1, height: bottom - top).fill()
      }
    }
  }

  // MARK: Document style

  /// Looks at the document's style rules again once typing pauses, and restyles the Writing
  /// view if the font, size, or justification changed.
  func scheduleStyleRefresh() {
    styleGeneration += 1
    let generation = styleGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      guard let self, generation == self.styleGeneration else { return }
      self.refreshDocumentStyle()
    }
  }

  func refreshDocumentStyle() {
    let style = Engine.documentStyle(text)
    let old = documentStyle
    documentStyle = style
    if style.font != old.font || style.size != old.size || style.justify != old.justify {
      restyleEverything()
    }
  }

  /// Sets the document's font and text size by writing its `#set text(...)` rule. Nil returns
  /// that value to Typst's default.
  public func setDocumentFont(_ family: String?, size: Double?) {
    let family = family.flatMap { $0.caseInsensitiveCompare(DocumentStyle.defaultFont) == .orderedSame ? nil : $0 }
    let size = size.flatMap { abs($0 - DocumentStyle.defaultSize) < 0.001 ? nil : $0 }
    guard
      let edit = Formatting.setTextStyle(
        font: family, size: size, text: storage.mutableString, style: Engine.documentStyle(text),
        selection: textView.selectedRange())
    else { return }
    apply(edit, actionName: "Document Font")
    refreshDocumentStyle()
  }

  /// Sets the document's font, size, and justification in one undoable step.
  public func setDocumentStyle(font: String?, size: Double?, justify: Bool) {
    textView.undoManager?.beginUndoGrouping()
    setDocumentFont(font, size: size)
    setJustified(justify)
    textView.undoManager?.endUndoGrouping()
    textView.undoManager?.setActionName("Document Style")
  }

  /// Turns justified paragraphs on or off by writing the document's `#set par(...)` rule.
  public func setJustified(_ justify: Bool) {
    guard
      let edit = Formatting.setJustified(
        justify, text: storage.mutableString, style: Engine.documentStyle(text),
        selection: textView.selectedRange())
    else { return }
    apply(edit, actionName: justify ? "Justify Paragraphs" : "Don't Justify Paragraphs")
    refreshDocumentStyle()
  }
}
