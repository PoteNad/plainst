import AppKit
import PlainstCore

extension TypstEditor {
  /// The character under a point in the text view, only when the point is over its glyph.
  func characterIndex(at point: NSPoint) -> Int? {
    guard layout.numberOfGlyphs > 0 else { return nil }
    let origin = textView.textContainerOrigin
    let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
    var fraction: CGFloat = 0
    let glyph = layout.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: &fraction)
    let bounds = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
    guard bounds.insetBy(dx: -1, dy: -2).contains(local) else { return nil }
    return layout.characterIndexForGlyph(at: glyph)
  }

  func linkTarget(at point: NSPoint) -> LinkTarget? {
    characterIndex(at: point).flatMap {
      Links.target(at: $0, text: storage.mutableString, elements: elements)
    }
  }

  /// ⌘-click: opens a link in the browser, or moves to the label a reference names.
  func openLink(at point: NSPoint) -> Bool {
    guard let target = linkTarget(at: point) else { return false }
    open(target)
    return true
  }

  public func open(_ target: LinkTarget) {
    switch target {
    case .url(let url):
      NSWorkspace.shared.open(url)
    case .label(let range):
      textView.window?.makeFirstResponder(textView)
      textView.setSelectedRange(NSRange(location: range.location, length: 0))
      scrollToTop(of: range)
      DispatchQueue.main.async { [weak self] in self?.textView.showFindIndicator(for: range) }
    }
  }

  /// The hint shown while the pointer rests on a link or reference.
  func linkHint(at point: NSPoint) -> String? {
    switch linkTarget(at: point) {
    case .url(let url): "⌘-click to open \(url.absoluteString)"
    case .label: "⌘-click to go to the label"
    case nil: nil
    }
  }
}
