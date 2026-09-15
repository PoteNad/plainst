import AppKit
import PlainstCore

/// Something drawn in place of source characters, measured for layout.
struct ReplacementMetrics {
  enum Content {
    case image(NSImage)
    case text(NSAttributedString)
  }

  var content: Content
  var size: CGSize
  /// Distance from the top of the drawing to the text baseline.
  var baseline: CGFloat
}

/// Supplies what the layout manager needs to hide markup and draw replacements.
@MainActor
protocol ReplacementSource: AnyObject {
  var concealing: Bool { get }
  var presentation: Presentation { get }
  var replacementKeys: [Int] { get }
  func metrics(forReplacementAt index: Int) -> ReplacementMetrics?
  func drawDecorations(forGlyphRange glyphs: NSRange, at origin: NSPoint)
}

/// Draws rendered equations and list markers over the space reserved for them.
final class WritingLayoutManager: NSLayoutManager {
  weak var replacements: ReplacementSource?

  override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
    // Decorations go underneath AppKit's background drawing, which includes the selection
    // highlight; drawing them afterwards would hide selected text inside equation fields.
    nonisolated(unsafe) let manager = self
    MainActor.assumeIsolated {
      manager.replacements?.drawDecorations(forGlyphRange: glyphsToShow, at: origin)
    }
    super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
  }

  override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
    super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
    nonisolated(unsafe) let manager = self
    MainActor.assumeIsolated { manager.drawReplacements(forGlyphRange: glyphsToShow, at: origin) }
  }

  @MainActor
  private func drawReplacements(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
    guard let source = replacements, source.concealing else { return }
    let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
    let keys = source.replacementKeys
    var index = keys.lowerBound(characters.location)
    while index < keys.count, keys[index] < NSMaxRange(characters) {
      let character = keys[index]
      index += 1
      guard let metrics = source.metrics(forReplacementAt: character) else { continue }
      let glyph = glyphIndexForCharacter(at: character)
      guard glyph < numberOfGlyphs else { continue }
      let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      let location = self.location(forGlyphAt: glyph)
      let x = origin.x + line.minX + location.x
      let baseline = origin.y + line.minY + location.y
      let rect = NSRect(
        x: x, y: baseline - metrics.baseline, width: metrics.size.width,
        height: metrics.size.height)
      switch metrics.content {
      case .image(let image):
        image.draw(
          in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
          hints: nil)
      case .text(let text):
        text.draw(at: rect.origin)
      }
    }
  }
}

extension Array where Element == Int {
  /// The index of the first element not less than `value` in a sorted array.
  func lowerBound(_ value: Int) -> Int {
    var low = 0
    var high = count
    while low < high {
      let mid = (low + high) / 2
      if self[mid] < value { low = mid + 1 } else { high = mid }
    }
    return low
  }
}

/// The text view inside a ``TypstEditor``. Configure the editor rather than this view.
public final class TypstTextView: NSTextView {
  weak var editor: TypstEditor?

  override public func magnify(with event: NSEvent) {
    guard let editor else { return super.magnify(with: event) }
    editor.setZoom(editor.zoomPercent + Int((event.magnification * 100).rounded()))
  }

  private var hoverTracking: NSTrackingArea?

  override public func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTracking { removeTrackingArea(hoverTracking) }
    let area = NSTrackingArea(
      rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self)
    addTrackingArea(area)
    hoverTracking = area
  }

  override public func mouseMoved(with event: NSEvent) {
    super.mouseMoved(with: event)
    editor?.mouseMoved(to: convert(event.locationInWindow, from: nil))
  }

  override public func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    editor?.mouseMoved(to: nil)
  }

  override public func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if let editor, editor.handleClick(at: point, event: event) { return }
    let belowText = isBelowText(point)
    editor?.isTrackingMouse = true
    super.mouseDown(with: event)
    editor?.isTrackingMouse = false
    // TextKit 1 maps clicks on the empty last line, or below all text, to the line above.
    // Put the cursor at the end instead, as TextEdit does.
    if belowText, selectedRange().length == 0, !event.modifierFlags.contains(.shift) {
      setSelectedRange(NSRange(location: textStorage?.length ?? 0, length: 0))
    }
    // Apply reveal and preview changes held back while the button was down.
    editor?.selectionChanged()
  }

  /// Whether a point is on the empty line after a final newline or below the last line.
  func isBelowText(_ point: NSPoint) -> Bool {
    guard let layoutManager, let storage = textStorage else { return false }
    let length = storage.length
    guard length > 0 else { return false }
    layoutManager.ensureLayout(forCharacterRange: NSRange(location: length - 1, length: 1))
    let y = point.y - textContainerOrigin.y
    let extra = layoutManager.extraLineFragmentRect
    if !extra.isEmpty { return y >= extra.minY }
    let lastGlyph = layoutManager.glyphIndexForCharacter(at: length - 1)
    let lastLine = layoutManager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
    return y >= lastLine.maxY
  }

  override public func insertText(_ string: Any, replacementRange: NSRange) {
    guard let editor, let typed = (string as? String) ?? (string as? NSAttributedString)?.string,
      replacementRange.location == NSNotFound || replacementRange == selectedRange()
    else { return super.insertText(string, replacementRange: replacementRange) }
    if editor.assistant.handleTyping(typed) { return }
    editor.lastTyped = typed
    super.insertText(string, replacementRange: replacementRange)
  }

  /// ⌥⎋ and Edit ▸ Show Completions ask Typst for suggestions at the cursor.
  override public func complete(_ sender: Any?) {
    guard let editor else { return super.complete(sender) }
    editor.assistant.request(explicit: true)
  }

  override public func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
    // Paste only text, normalising line endings like the file loader does.
    guard let value = pboard.string(forType: .string) else { return false }
    editor?.assistant.isSuspended = true
    defer { editor?.assistant.isSuspended = false }
    insertText(
      value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"),
      replacementRange: selectedRange())
    return true
  }

  override public var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
}

/// Keeps the text column centred at a comfortable reading width.
public final class TypstScrollView: NSScrollView {
  public internal(set) var columnWidth: CGFloat = 680 { didSet { tile() } }
  /// The smallest space left on each side of the column.
  public internal(set) var minimumMargin: CGFloat = 24 { didSet { tile() } }

  override public func tile() {
    super.tile()
    guard let text = documentView as? NSTextView else { return }
    let available = contentSize.width
    let side = max(minimumMargin, ((available - columnWidth) / 2).rounded(.down))
    if text.textContainerInset.width != side {
      text.textContainerInset = NSSize(width: side, height: 28)
    }
    text.minSize = NSSize(width: available, height: contentSize.height)
    let size = NSSize(width: available, height: max(contentSize.height, text.frame.height))
    if text.frame.size != size { text.setFrameSize(size) }
    text.textContainer?.size = NSSize(
      width: max(40, available - side * 2), height: CGFloat.greatestFiniteMagnitude)
  }
}

/// Shows how the equation being edited renders: floating below an inline equation, or
/// embedded without a border inside a display equation's card.
final class MathPreviewView: NSView {
  private let imageView = NSImageView()
  private let message = NSTextField(wrappingLabelWithString: "")
  var isEmbedded = false {
    didSet {
      guard isEmbedded != oldValue else { return }
      layer?.shadowOpacity = isEmbedded ? 0 : 0.12
      layer?.borderWidth = isEmbedded ? 0 : 1
      needsDisplay = true
    }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.borderWidth = 1
    shadow = NSShadow()
    layer?.shadowOpacity = 0.12
    layer?.shadowRadius = 6
    layer?.shadowOffset = CGSize(width: 0, height: -2)
    imageView.imageScaling = .scaleNone
    imageView.imageAlignment = .alignCenter
    message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    message.textColor = .secondaryLabelColor
    addSubview(imageView)
    addSubview(message)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Equation preview")
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    layer?.backgroundColor = isEmbedded ? nil : NSColor.textBackgroundColor.cgColor
    layer?.borderColor = NSColor.separatorColor.cgColor
  }

  /// Shows a rendered image or a status message and returns the size the view needs.
  func show(image: NSImage?, text: String?, isError: Bool, maxWidth: CGFloat) -> NSSize {
    let padding: CGFloat = 12
    imageView.image = image
    imageView.isHidden = image == nil
    message.stringValue = text ?? ""
    message.isHidden = text == nil
    message.textColor = isError ? .systemRed : .secondaryLabelColor
    var width: CGFloat = 0
    var height: CGFloat = padding
    if let image {
      let size = image.size
      imageView.frame = NSRect(x: padding, y: height, width: min(size.width, maxWidth - padding * 2), height: size.height)
      width = max(width, imageView.frame.width)
      height += size.height
    }
    if text != nil {
      if image != nil { height += 6 }
      message.preferredMaxLayoutWidth = maxWidth - padding * 2
      let fitting = message.sizeThatFits(NSSize(width: maxWidth - padding * 2, height: 1000))
      message.frame = NSRect(x: padding, y: height, width: min(maxWidth - padding * 2, max(fitting.width, 60)), height: fitting.height)
      width = max(width, message.frame.width)
      height += fitting.height
    }
    let total = max(width + padding * 2, 80)
    // Centre narrow content inside the minimum width.
    imageView.frame.origin.x = ((total - imageView.frame.width) / 2).rounded()
    if !isEmbedded { message.frame.origin.x = padding }
    return NSSize(width: total, height: height + padding)
  }
}
