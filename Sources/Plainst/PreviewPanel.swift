import AppKit
import PlainstCore
import PlainstEditor

/// The typeset document beside the editor. Each page is an image rendered by Typst, and
/// only pages whose content changed are rendered again, so updates never flash.
final class PreviewViewController: NSViewController {
  weak var editor: Editor?
  /// The editor's key for its kept document in the engine.
  var key: UInt64 = 0
  private let scroll = NSScrollView()
  private let pagesView = PreviewPagesView()
  private let notice = NSVisualEffectView()
  private let noticeLabel = NSTextField(labelWithString: "")
  private let placeholder = NSTextField(labelWithString: "Typesetting…")
  private let handle = DividerHandle()
  private static let queue = DispatchQueue(label: "io.github.PoteNad.plainst.preview", qos: .userInitiated)

  private(set) var pages: [PreviewPage] = []
  private var layers: [CALayer] = []
  /// The content and resolution each page layer currently shows.
  private var shown: [(page: PreviewPage, pixelsPerPoint: Double)?] = []
  private(set) var frames: [NSRect] = []
  /// Points on screen per point on the page. Pages are never shown larger than actual size.
  private(set) var scale: CGFloat = 1
  private var renderGeneration = 0
  private var lastLayoutWidth: CGFloat = 0

  static let maximumScale: CGFloat = 1
  private static let margin: CGFloat = 20
  private static let gap: CGFloat = 16

  override func loadView() {
    let root = NSView()
    scroll.documentView = pagesView
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.drawsBackground = true
    scroll.backgroundColor = .underPageBackgroundColor
    scroll.automaticallyAdjustsContentInsets = false
    pagesView.wantsLayer = true
    pagesView.onClick = { [weak self] point in self?.clicked(at: point) }
    pagesView.onAppearanceChange = { [weak self] in
      guard let self else { return }
      self.layers.forEach(self.style)
    }
    pagesView.setAccessibilityRole(.group)
    pagesView.setAccessibilityLabel("Typeset preview. Click text to find it in the editor.")

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

    for view in [scroll, placeholder, notice, noticeLabel, handle] {
      view.translatesAutoresizingMaskIntoConstraints = false
    }
    root.addSubview(scroll)
    root.addSubview(placeholder)
    root.addSubview(notice)
    root.addSubview(handle)
    notice.addSubview(noticeLabel)
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      placeholder.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      placeholder.centerYAnchor.constraint(equalTo: root.centerYAnchor),
      notice.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
      notice.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      notice.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 10),
      noticeLabel.topAnchor.constraint(equalTo: notice.topAnchor, constant: 5),
      noticeLabel.bottomAnchor.constraint(equalTo: notice.bottomAnchor, constant: -5),
      noticeLabel.leadingAnchor.constraint(equalTo: notice.leadingAnchor, constant: 10),
      noticeLabel.trailingAnchor.constraint(equalTo: notice.trailingAnchor, constant: -10),
      handle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 3),
      handle.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
      handle.widthAnchor.constraint(equalToConstant: 5),
      handle.heightAnchor.constraint(equalToConstant: 36),
    ])
    noticeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view = root
  }

  var hasDocument: Bool { !pages.isEmpty }
  var renderedPageCount: Int { shown.compactMap { $0 }.count }

  override func viewDidLayout() {
    super.viewDidLayout()
    let width = scroll.contentSize.width
    guard width != lastLayoutWidth else { return }
    lastLayoutWidth = width
    layoutPages()
    // Old images stretch while resizing; sharper ones follow once the size settles.
    requestRenders(after: 0.2)
  }


  /// Shows the pages of the latest good document and notes when it is out of date.
  func update(pages newPages: [PreviewPage], errors: Int) {
    _ = view
    if newPages != pages {
      pages = newPages
      while layers.count < pages.count {
        let layer = CALayer()
        style(layer)
        pagesView.layer?.addSublayer(layer)
        layers.append(layer)
        shown.append(nil)
      }
      while layers.count > pages.count {
        layers.removeLast().removeFromSuperlayer()
        shown.removeLast()
      }
      layoutPages()
      requestRenders(after: 0)
    }
    placeholder.isHidden = !pages.isEmpty
    placeholder.stringValue = errors > 0 ? "Fix the errors to see the typeset document." : "Typesetting…"
    notice.isHidden = errors == 0 || pages.isEmpty
    noticeLabel.stringValue = "Showing the last version without errors (\(errors) \(errors == 1 ? "error" : "errors") now)"
  }

  private func style(_ layer: CALayer) {
    var border = NSColor.black.withAlphaComponent(0.12).cgColor
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
      border = NSColor.separatorColor.cgColor
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.backgroundColor = .white
    layer.borderColor = border
    layer.borderWidth = 0.5
    layer.contentsGravity = .resize
    layer.magnificationFilter = .linear
    layer.minificationFilter = .trilinear
    layer.shadowColor = .black
    layer.shadowOpacity = 0.18
    layer.shadowRadius = 3
    layer.shadowOffset = CGSize(width: 0, height: -1)
    CATransaction.commit()
  }

  private func layoutPages() {
    let width = scroll.contentSize.width
    let widest = pages.map(\.size.width).max() ?? 595
    scale = max(0.05, min(Self.maximumScale, (width - Self.margin * 2) / widest))
    var y = Self.margin
    frames = pages.map { page in
      let size = NSSize(width: (page.size.width * scale).rounded(), height: (page.size.height * scale).rounded())
      let frame = NSRect(x: ((width - size.width) / 2).rounded(), y: y, width: size.width, height: size.height)
      y += size.height + Self.gap
      return frame
    }
    let height = max(pages.isEmpty ? 0 : y - Self.gap + Self.margin, scroll.contentSize.height)
    pagesView.setFrameSize(NSSize(width: width, height: height))
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (layer, frame) in zip(layers, frames) {
      layer.frame = frame
      layer.shadowPath = CGPath(rect: layer.bounds, transform: nil)
    }
    CATransaction.commit()
  }

  /// Renders pages that changed or are shown at a new size, nearest to the visible area first.
  private func requestRenders(after delay: TimeInterval) {
    renderGeneration += 1
    let generation = renderGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self, generation == self.renderGeneration, !self.pages.isEmpty else { return }
      let pixelsPerPoint = Double(self.scale * (self.view.window?.backingScaleFactor ?? 2))
      let visible = self.pagesView.visibleRect
      let work = self.pages.indices
        .filter { index in
          guard let current = self.shown[index] else { return true }
          return current.page != self.pages[index] || abs(current.pixelsPerPoint - pixelsPerPoint) > 0.01
        }
        .sorted { abs(self.frames[$0].midY - visible.midY) < abs(self.frames[$1].midY - visible.midY) }
      guard !work.isEmpty else { return }
      let key = self.key
      let pages = self.pages
      Self.queue.async {
        for index in work {
          guard
            let image = Engine.renderPage(
              key: key, index: index, page: pages[index], pixelsPerPoint: pixelsPerPoint)
          else { continue }
          DispatchQueue.main.async {
            MainActor.assumeIsolated {
              guard index < self.pages.count, self.pages[index] == pages[index] else { return }
              CATransaction.begin()
              CATransaction.setDisableActions(true)
              self.layers[index].contents = image
              CATransaction.commit()
              self.shown[index] = (pages[index], pixelsPerPoint)
            }
          }
        }
      }
    }
  }

  private func clicked(at point: NSPoint) {
    guard let index = frames.firstIndex(where: { $0.contains(point) }) else { return }
    let frame = frames[index]
    let onPage = CGPoint(x: (point.x - frame.minX) / scale, y: (point.y - frame.minY) / scale)
    editor?.jumpFromPreview(page: index, point: onPage)
  }

  /// Where a point on a page is shown, in the preview's scrolling coordinates.
  func location(page: Int, point: CGPoint) -> NSPoint? {
    guard frames.indices.contains(page) else { return nil }
    return NSPoint(x: frames[page].minX + point.x * scale, y: frames[page].minY + point.y * scale)
  }

  /// Scrolls so a point on a page is comfortably in view, if it isn't already.
  func reveal(page: Int, point: CGPoint) {
    guard let target = location(page: page, point: point) else { return }
    let visible = pagesView.visibleRect
    let comfortable = visible.insetBy(dx: 0, dy: min(60, visible.height / 4))
    guard target.y < comfortable.minY || target.y > comfortable.maxY else { return }
    let clip = scroll.contentView
    var bounds = clip.bounds
    bounds.origin.y = target.y - visible.height / 3
    let origin = clip.constrainBoundsRect(bounds).origin
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.25
      clip.animator().setBoundsOrigin(origin)
    } completionHandler: { [scroll] in
      MainActor.assumeIsolated { scroll.reflectScrolledClipView(scroll.contentView) }
    }
  }

  #if PLAINST_CHECKS
    var visibleArea: NSRect { pagesView.visibleRect }

    func image(ofPage index: Int) -> AnyObject? { layers.indices.contains(index) ? layers[index].contents as AnyObject? : nil }

    /// Clicks a point on a page as the user would, for checks.
    func click(page: Int, point: CGPoint) {
      guard let location = location(page: page, point: point) else { return }
      clicked(at: location)
    }
  #endif
}

/// The scrolling page area; clicks report their location to find the source.
final class PreviewPagesView: NSView {
  var onClick: ((NSPoint) -> Void)?
  var onAppearanceChange: (() -> Void)?

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    onAppearanceChange?()
  }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    guard event.clickCount == 1 else { return }
    onClick?(convert(event.locationInWindow, from: nil))
  }
}

/// A grip on the preview's edge that shows the divider beside it can be dragged.
private final class DividerHandle: NSView {
  override var wantsUpdateLayer: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = 2.5
    setAccessibilityElement(false)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func updateLayer() {
    layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
  }

  // The split view underneath handles the drag.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A split view controller whose dividers are easy to grab, especially the preview's.
final class EditorSplitViewController: NSSplitViewController {
  /// The item whose leading divider gets the grip.
  weak var previewItem: NSSplitViewItem?

  override func splitView(
    _ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect,
    ofDividerAt dividerIndex: Int
  ) -> NSRect {
    let rect = super.splitView(
      splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
    if let previewItem, splitViewItems.firstIndex(of: previewItem) == dividerIndex + 1 {
      // Cover the grip drawn just inside the preview.
      return rect.union(NSRect(x: drawnRect.minX - 5, y: drawnRect.minY, width: drawnRect.width + 14, height: drawnRect.height))
    }
    return rect.union(drawnRect.insetBy(dx: -4, dy: 0))
  }
}
