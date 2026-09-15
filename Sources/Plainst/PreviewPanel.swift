import AppKit
import PDFKit

/// The typeset document beside the editor, refreshed as Typst compiles.
final class PreviewViewController: NSViewController {
  let pdfView = PDFView()
  private let notice = NSVisualEffectView()
  private let noticeLabel = NSTextField(labelWithString: "")
  private let placeholder = NSTextField(labelWithString: "Typesetting…")
  private var shownData: Data?

  override func loadView() {
    let root = NSView()
    pdfView.autoScales = true
    pdfView.displayMode = .singlePageContinuous
    pdfView.displaysPageBreaks = true
    pdfView.pageShadowsEnabled = true
    pdfView.backgroundColor = .underPageBackgroundColor
    pdfView.setAccessibilityLabel("Typeset preview")

    notice.material = .popover
    notice.blendingMode = .withinWindow
    notice.state = .active
    notice.wantsLayer = true
    notice.layer?.cornerRadius = 8
    notice.isHidden = true
    noticeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    noticeLabel.textColor = .secondaryLabelColor
    noticeLabel.lineBreakMode = .byTruncatingTail
    placeholder.font = .systemFont(ofSize: NSFont.systemFontSize)
    placeholder.textColor = .tertiaryLabelColor

    root.addSubview(pdfView)
    root.addSubview(placeholder)
    root.addSubview(notice)
    notice.addSubview(noticeLabel)
    for view in [pdfView, placeholder, notice, noticeLabel] {
      view.translatesAutoresizingMaskIntoConstraints = false
    }
    NSLayoutConstraint.activate([
      pdfView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
      pdfView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      pdfView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      pdfView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      placeholder.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      placeholder.centerYAnchor.constraint(equalTo: root.centerYAnchor),
      notice.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
      notice.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      notice.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 10),
      noticeLabel.topAnchor.constraint(equalTo: notice.topAnchor, constant: 5),
      noticeLabel.bottomAnchor.constraint(equalTo: notice.bottomAnchor, constant: -5),
      noticeLabel.leadingAnchor.constraint(equalTo: notice.leadingAnchor, constant: 10),
      noticeLabel.trailingAnchor.constraint(equalTo: notice.trailingAnchor, constant: -10),
    ])
    noticeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view = root
  }

  var hasDocument: Bool { pdfView.document != nil }

  /// Shows a new PDF, keeping the reader's place, and notes when it is out of date.
  func show(pdf data: Data?, errors: Int) {
    _ = view
    if let data, data != shownData, let document = PDFDocument(data: data) {
      let place = currentPlace()
      let scale = pdfView.autoScales ? nil : pdfView.scaleFactor
      pdfView.document = document
      if let scale { pdfView.scaleFactor = scale }
      if let place, let page = document.page(at: min(place.page, document.pageCount - 1)) {
        pdfView.go(to: PDFDestination(page: page, at: place.point))
      }
      shownData = data
    }
    placeholder.isHidden = pdfView.document != nil
    if errors > 0 {
      placeholder.stringValue = "Fix the errors to see the typeset document."
      noticeLabel.stringValue =
        pdfView.document == nil
        ? "" : "Showing the last version without errors (\(errors) \(errors == 1 ? "error" : "errors") now)"
      notice.isHidden = pdfView.document == nil
    } else {
      placeholder.stringValue = "Typesetting…"
      notice.isHidden = true
    }
  }

  /// The top-left of the visible area as a page index and a point on that page.
  private func currentPlace() -> (page: Int, point: NSPoint)? {
    guard let document = pdfView.document, let destination = pdfView.currentDestination,
      let page = destination.page
    else { return nil }
    return (document.index(for: page), destination.point)
  }
}
