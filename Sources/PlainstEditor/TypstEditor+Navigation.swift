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
}
