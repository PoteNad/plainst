import AppKit
import PlainstCore

/// Folding sections under headings. A folded section's text stays in the document; only its
/// layout collapses, and moving the cursor into it unfolds it again.
extension TypstEditor {
  /// The heading elements, in document order.
  var headingElements: [OutlineElement] { elements.filter { $0.kind == .heading } }

  /// The text a heading's section covers: from the line after the heading up to the next heading
  /// of the same or a higher level.
  func sectionRange(ofHeadingAt location: Int) -> NSRange? {
    let text = storage.mutableString
    let headings = headingElements
    guard let index = headings.firstIndex(where: { $0.range.location == location }) else { return nil }
    let level = headings[index].number ?? 1
    let start = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
    let next = headings[(index + 1)...].first { ($0.number ?? 1) <= level }
    var end = next.map { text.lineRange(for: NSRange(location: $0.range.location, length: 0)).location } ?? text.length
    // Blank lines before the next heading stay, so a folded section keeps its spacing.
    while end > start, let scalar = UnicodeScalar(text.character(at: end - 1)),
      CharacterSet.whitespacesAndNewlines.contains(scalar)
    {
      end -= 1
    }
    if end < text.length, text.character(at: end) == 0x0A { end += 1 }
    return end > start ? NSRange(location: start, length: end - start) : nil
  }

  /// Recomputes which characters folds hide, and lays out again only what changed.
  func refreshFolds() {
    let starts = Set(headingElements.map(\.range.location))
    foldedHeadings = foldedHeadings.filter { starts.contains($0) && sectionRange(ofHeadingAt: $0) != nil }
    var hidden = IndexSet()
    for heading in foldedHeadings {
      if let section = sectionRange(ofHeadingAt: heading), let range = Range(section) {
        hidden.insert(integersIn: range)
      }
    }
    guard hidden != folded else { return textView.needsDisplay = true }
    let changed = hidden.symmetricDifference(folded)
    folded = hidden
    let text = storage.mutableString
    for range in changed.rangeView where range.lowerBound < text.length {
      let clamped = NSRange(location: range.lowerBound, length: min(range.upperBound, text.length) - range.lowerBound)
      let lines = text.paragraphRange(for: clamped)
      layout.invalidateGlyphs(forCharacterRange: lines, changeInLength: 0, actualCharacterRange: nil)
      layout.invalidateLayout(forCharacterRange: lines, actualCharacterRange: nil)
    }
    textView.needsDisplay = true
    delegate?.typstEditorDisplayDidChange(self)
  }

  /// Whether every character of a line fragment, apart from its final newline, is folded away.
  func isFoldedLine(_ characters: NSRange) -> Bool {
    guard !folded.isEmpty, characters.length > 0 else { return false }
    let end = NSMaxRange(characters)
    let lastIsNewline = storage.mutableString.character(at: end - 1) == 0x0A
    let checkedEnd = lastIsNewline && characters.length > 1 ? end - 1 : end
    return folded.contains(integersIn: characters.location..<checkedEnd)
  }

  /// The heading whose section contains a location, if the location is below a heading.
  func heading(containing location: Int) -> OutlineElement? {
    headingElements.last { $0.range.location <= location }
  }

  // MARK: Commands

  public var foldedHeadingLocations: Set<Int> { foldedHeadings }

  public func isFolded(headingAt location: Int) -> Bool { foldedHeadings.contains(location) }

  /// Folds or unfolds the section under the heading that starts at `location`.
  public func setFolded(_ fold: Bool, headingAt location: Int) {
    guard headingElements.contains(where: { $0.range.location == location }) else { return }
    if fold {
      guard sectionRange(ofHeadingAt: location) != nil else { return NSSound.beep() }
      foldedHeadings.insert(location)
      // Keep the cursor visible: on the heading line when it was inside the section.
      if let section = sectionRange(ofHeadingAt: location),
        NSLocationInRange(textView.selectedRange().location, section)
      {
        let line = storage.mutableString.lineRange(for: NSRange(location: location, length: 0))
        var end = NSMaxRange(line)
        if end > line.location, storage.mutableString.character(at: end - 1) == 0x0A { end -= 1 }
        textView.setSelectedRange(NSRange(location: end, length: 0))
      }
    } else {
      foldedHeadings.remove(location)
    }
    refreshFolds()
  }

  /// View ▸ Fold Section: folds the section the cursor is in.
  public func foldCurrentSection() {
    guard let heading = heading(containing: textView.selectedRange().location) else { return NSSound.beep() }
    setFolded(true, headingAt: heading.range.location)
  }

  /// View ▸ Unfold Section: unfolds the section the cursor is in, or its heading's fold.
  public func unfoldCurrentSection() {
    let location = textView.selectedRange().location
    let folds = headingElements.map(\.range.location).filter {
      foldedHeadings.contains($0) && ($0 <= location)
    }
    guard let heading = folds.last(where: { heading in
      let line = storage.mutableString.lineRange(for: NSRange(location: heading, length: 0))
      return NSLocationInRange(location, line) || (sectionRange(ofHeadingAt: heading).map { NSLocationInRange(location, $0) } ?? false)
    }) else { return NSSound.beep() }
    setFolded(false, headingAt: heading)
  }

  public func unfoldAll() {
    guard !foldedHeadings.isEmpty else { return }
    foldedHeadings.removeAll()
    refreshFolds()
  }

  /// Moving the cursor into folded text unfolds the sections around it.
  func unfoldAroundSelection() {
    let selection = textView.selectedRange()
    guard !folded.isEmpty, folded.contains(selection.location) else { return }
    let containing = foldedHeadings.filter { heading in
      sectionRange(ofHeadingAt: heading).map { NSLocationInRange(selection.location, $0) } ?? false
    }
    guard !containing.isEmpty else { return }
    foldedHeadings.subtract(containing)
    refreshFolds()
  }

  /// Keeps folds on their headings as text is inserted or removed before them.
  func foldsWillChange(range: NSRange, replacementLength length: Int) {
    guard !foldedHeadings.isEmpty else { return }
    let delta = length - range.length
    foldedHeadings = Set(foldedHeadings.compactMap { heading in
      if heading >= NSMaxRange(range) && !(range.length == 0 && heading == range.location) {
        return heading + delta
      }
      // Editing the heading line itself leaves its section unfolded.
      let line = storage.mutableString.lineRange(for: NSRange(location: heading, length: 0))
      return NSIntersectionRange(line, range).length > 0 || NSLocationInRange(range.location, line) ? nil : heading
    })
  }

  // MARK: Drawing and clicks

  /// The chevron beside a heading, in text view coordinates.
  func foldControlRect(forHeadingAt location: Int) -> NSRect? {
    guard let used = headingLineRect(at: location) else { return nil }
    let origin = textView.textContainerOrigin
    let size: CGFloat = 16
    return NSRect(
      x: (origin.x - size - 4).rounded(), y: (origin.y + used.midY - size / 2).rounded(), width: size, height: size)
  }

  /// The "⋯" after a folded heading, which unfolds it when clicked.
  func foldedMarkerRect(forHeadingAt location: Int) -> NSRect? {
    guard let used = headingLineRect(at: location) else { return nil }
    let origin = textView.textContainerOrigin
    let height = NSFont.smallSystemFontSize + 6
    return NSRect(x: origin.x + used.maxX + 8, y: (origin.y + used.midY - height / 2).rounded(), width: 26, height: height)
  }

  /// The used rect of a heading's last line, measured at its last character, since the markers
  /// at its start may be hidden.
  private func headingLineRect(at location: Int) -> NSRect? {
    let text = storage.mutableString
    guard location < text.length else { return nil }
    let line = text.lineRange(for: NSRange(location: location, length: 0))
    var last = NSMaxRange(line) - 1
    while last > line.location, [0x0A, 0x0D].contains(text.character(at: last)) { last -= 1 }
    let glyph = layout.glyphIndexForCharacter(at: max(line.location, last))
    guard glyph < layout.numberOfGlyphs else { return nil }
    return layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
  }

  /// The heading whose line is under a point, including the margin to its left.
  func heading(at point: NSPoint) -> Int? {
    let origin = textView.textContainerOrigin
    for heading in headingElements where heading.range.location < storage.length {
      if folded.contains(heading.range.location) { continue }
      let glyph = layout.glyphIndexForCharacter(at: heading.range.location)
      guard glyph < layout.numberOfGlyphs else { continue }
      let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).offsetBy(dx: origin.x, dy: origin.y)
      if point.y >= line.minY, point.y < line.maxY, point.x >= origin.x - 28 { return heading.range.location }
    }
    return nil
  }

  /// Draws the chevrons in the margin and the "⋯" after folded headings. The text view calls it
  /// while drawing its background, before it clips drawing to the text column.
  func drawFoldControls(in dirtyRect: NSRect) {
    let text = storage.mutableString
    for heading in headingElements where !folded.contains(heading.range.location) {
      let location = heading.range.location
      let isFolded = foldedHeadings.contains(location)
      guard isFolded || hoveredHeading == location, sectionRange(ofHeadingAt: location) != nil,
        let rect = foldControlRect(forHeadingAt: location), rect.insetBy(dx: 0, dy: -8).intersects(dirtyRect)
      else { continue }
      let tint: NSColor = hoveredHeading == location ? .labelColor : .secondaryLabelColor
      let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
      if let symbol = NSImage(
        systemSymbolName: isFolded ? "chevron.right" : "chevron.down",
        accessibilityDescription: isFolded ? "Unfold" : "Fold")?.withSymbolConfiguration(configuration)
      {
        symbol.draw(
          in: NSRect(
            x: (rect.midX - symbol.size.width / 2).rounded(), y: (rect.midY - symbol.size.height / 2).rounded(),
            width: symbol.size.width, height: symbol.size.height),
          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
      }
      if isFolded, let marker = foldedMarkerRect(forHeadingAt: location), text.length > 0 {
        let path = NSBezierPath(roundedRect: marker, xRadius: marker.height / 2, yRadius: marker.height / 2)
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        path.fill()
        let dots = NSAttributedString(
          string: "⋯",
          attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold), .foregroundColor: NSColor.secondaryLabelColor])
        let size = dots.size()
        dots.draw(at: NSPoint(x: marker.midX - size.width / 2, y: marker.midY - size.height / 2))
      }
    }
  }

  /// Toggles a fold when a chevron or a folded section's "⋯" is clicked.
  func handleFoldClick(at point: NSPoint) -> Bool {
    for heading in headingElements where !folded.contains(heading.range.location) {
      let location = heading.range.location
      let shown = foldedHeadings.contains(location) || hoveredHeading == location
      if shown, let rect = foldControlRect(forHeadingAt: location), rect.insetBy(dx: -4, dy: -4).contains(point),
        sectionRange(ofHeadingAt: location) != nil
      {
        setFolded(!foldedHeadings.contains(location), headingAt: location)
        return true
      }
      if foldedHeadings.contains(location), let marker = foldedMarkerRect(forHeadingAt: location),
        marker.insetBy(dx: -2, dy: -2).contains(point)
      {
        setFolded(false, headingAt: location)
        return true
      }
    }
    return false
  }
}
