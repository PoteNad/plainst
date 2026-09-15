import AppKit
import PlainstCore
import PlainstEditor

/// The heading outline menu.
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
    let headings = typst.headings
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
    let rect = typst.textViewRect(for: NSRange(location: caret.location, length: 0))
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
    guard NSMaxRange(range) <= typst.textLength else { return }
    var end = NSMaxRange(range)
    let text = typst.string
    while end > range.location, [0x20, 0x09].contains(text.character(at: end - 1)) { end -= 1 }
    if focusText { window?.makeFirstResponder(textView) }
    textView.setSelectedRange(NSRange(location: end, length: 0))
    typst.scrollToTop(of: range)
  }


}

extension NSFont {
  fileprivate func withWeight(_ weight: NSFont.Weight) -> NSFont {
    let descriptor = fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
    return NSFont(descriptor: descriptor, size: pointSize) ?? self
  }
}
