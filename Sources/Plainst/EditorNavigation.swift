import AppKit
import PlainstCore

/// The heading outline menu and matching-bracket highlights.
extension Editor: NSMenuDelegate {
  // MARK: Outline

  /// A menu of every heading, indented by level, that jumps to the heading chosen.
  func makeOutlineMenu() -> NSMenu {
    let menu = NSMenu(title: "Outline")
    menu.delegate = self
    menu.autoenablesItems = false
    return menu
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    guard menu.title == "Outline" else { return }
    fillOutlineMenu(menu)
  }

  func fillOutlineMenu(_ menu: NSMenu) {
    menu.removeAllItems()
    let headings = DocumentOutline.headings(text: storage.mutableString, elements: elements)
    guard !headings.isEmpty else {
      let empty = NSMenuItem(title: "No Headings", action: nil, keyEquivalent: "")
      empty.isEnabled = false
      menu.addItem(empty)
      let hint = NSMenuItem(title: "Start a line with = to add one.", action: nil, keyEquivalent: "")
      hint.isEnabled = false
      menu.addItem(hint)
      return
    }
    let current = DocumentOutline.currentHeading(
      in: headings, at: textView.selectedRange().location)
    let shallowest = headings.map(\.level).min() ?? 1
    for (position, heading) in headings.enumerated() {
      let title = heading.title.isEmpty ? "Untitled Heading" : heading.title
      let item = NSMenuItem(title: title, action: #selector(jumpToHeading(_:)), keyEquivalent: "")
      item.target = self
      item.indentationLevel = min(heading.level - shallowest, 15)
      item.representedObject = NSValue(range: heading.range)
      item.state = position == current ? .on : .off
      if heading.level == shallowest {
        item.attributedTitle = NSAttributedString(
          string: title, attributes: [.font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)])
      }
      menu.addItem(item)
    }
  }

  /// View ▸ Go to Heading: shows the outline at the cursor, for keyboard users.
  @objc func showOutline(_ sender: Any?) {
    let menu = makeOutlineMenu()
    fillOutlineMenu(menu)
    let caret = textView.selectedRange()
    let glyphs = layout.glyphRange(
      forCharacterRange: NSRange(location: caret.location, length: 0), actualCharacterRange: nil)
    var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
    rect = rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
    let visible = textView.visibleRect
    let point = NSPoint(
      x: min(max(rect.minX, visible.minX + 20), visible.maxX - 40),
      y: min(max(rect.maxY + 4, visible.minY + 20), visible.maxY - 20))
    let selected = menu.items.first { $0.state == .on }
    menu.popUp(positioning: selected, at: point, in: textView)
  }

  @objc func jumpToHeading(_ sender: NSMenuItem) {
    guard let range = (sender.representedObject as? NSValue)?.rangeValue else { return }
    jump(toHeading: range)
  }

  /// Puts the cursor at the end of a heading's text and scrolls the heading near the top.
  func jump(toHeading range: NSRange, focusText: Bool = true) {
    guard NSMaxRange(range) <= storage.length else { return }
    var end = NSMaxRange(range)
    let text = storage.mutableString
    while end > range.location, [0x20, 0x09].contains(text.character(at: end - 1)) { end -= 1 }
    if focusText { window?.makeFirstResponder(textView) }
    textView.setSelectedRange(NSRange(location: end, length: 0))
    scrollToTop(of: range)
  }

  func scrollToTop(of range: NSRange) {
    layout.ensureLayout(forCharacterRange: range)
    let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
    let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
    let clip = scroll.contentView
    var bounds = clip.bounds
    bounds.origin.y = max(0, rect.minY + textView.textContainerOrigin.y - bodySize * 1.5)
    clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
    scroll.reflectScrolledClipView(clip)
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

extension NSFont {
  fileprivate func withWeight(_ weight: NSFont.Weight) -> NSFont {
    let descriptor = fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
    return NSFont(descriptor: descriptor, size: pointSize) ?? self
  }
}
