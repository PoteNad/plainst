import AppKit

/// Help ▸ Acknowledgments: the licenses and notices of the software and fonts Plainst includes,
/// read from THIRD_PARTY_NOTICES.md in the app bundle.
@MainActor
final class AcknowledgmentsWindowController: NSWindowController {
  let textView = NSTextView()

  init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = "Acknowledgments"
    window.minSize = NSSize(width: 420, height: 320)
    window.isReleasedWhenClosed = false
    super.init(window: window)

    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = true
    textView.textContainerInset = NSSize(width: 24, height: 20)
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.drawsBackground = true
    textView.backgroundColor = .textBackgroundColor
    scroll.documentView = textView
    window.contentView = scroll
    textView.textStorage?.setAttributedString(Self.render(Self.notices))
    window.center()
  }

  required init?(coder: NSCoder) { fatalError() }

  func show() {
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }

  static var notices: String {
    Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md")
      .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
      ?? "The third-party notices are missing from this copy of Plainst."
  }

  /// Shows the Markdown notices as readable text: headings in bold and license texts in a
  /// monospaced face, without the Markdown punctuation.
  static func render(_ markdown: String) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let body = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    let code = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    func paragraph(before: CGFloat) -> NSParagraphStyle {
      let style = NSMutableParagraphStyle()
      style.paragraphSpacingBefore = before
      return style
    }
    var inCode = false
    for line in markdown.components(separatedBy: "\n") {
      if line.hasPrefix("```") {
        inCode.toggle()
        continue
      }
      var text = line
      var attributes: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: NSColor.labelColor]
      if inCode {
        attributes = [.font: code, .foregroundColor: NSColor.secondaryLabelColor]
      } else if line.hasPrefix("### ") {
        text = String(line.dropFirst(4))
        attributes[.font] = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        attributes[.paragraphStyle] = paragraph(before: 14)
      } else if line.hasPrefix("## ") {
        text = String(line.dropFirst(3))
        attributes[.font] = NSFont.systemFont(ofSize: 17, weight: .bold)
        attributes[.paragraphStyle] = paragraph(before: 22)
      } else if line.hasPrefix("# ") {
        text = String(line.dropFirst(2))
        attributes[.font] = NSFont.systemFont(ofSize: 22, weight: .bold)
      } else {
        text = line.replacingOccurrences(of: "`", with: "")
      }
      result.append(NSAttributedString(string: text + "\n", attributes: attributes))
    }
    return result
  }
}
