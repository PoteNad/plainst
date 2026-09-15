import AppKit
import PlainstCore

/// A floating list of Typst completions below the cursor.
@MainActor
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
  private let panel: NSPanel
  private let table = NSTableView()
  private let scroll = NSScrollView()
  private(set) var items: [Completion] = []
  var onAccept: ((Completion) -> Void)?

  var isVisible: Bool { panel.isVisible }
  var contentView: NSView? { panel.contentView }

  override init() {
    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    super.init()
    panel.isFloatingPanel = true
    panel.hasShadow = true
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hidesOnDeactivate = true
    panel.becomesKeyOnlyIfNeeded = true

    let background = NSVisualEffectView()
    background.material = .popover
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = 8
    background.layer?.masksToBounds = true
    panel.contentView = background

    let column = NSTableColumn(identifier: .init("completion"))
    table.addTableColumn(column)
    table.headerView = nil
    table.rowHeight = 26
    table.intercellSpacing = NSSize(width: 0, height: 0)
    table.style = .plain
    table.backgroundColor = .clear
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.action = #selector(clicked)
    table.setAccessibilityLabel("Completions")
    scroll.documentView = table
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.frame = background.bounds.insetBy(dx: 0, dy: 4)
    scroll.autoresizingMask = [.width, .height]
    background.addSubview(scroll)
  }

  /// Shows `items` below the screen rectangle of the cursor.
  func show(_ items: [Completion], below caret: NSRect, in window: NSWindow) {
    guard !items.isEmpty else { return hide() }
    let selected = self.items.isEmpty ? nil : self.items[max(0, table.selectedRow)].label
    self.items = items
    table.reloadData()
    let row = selected.flatMap { label in items.firstIndex { $0.label == label } } ?? 0
    table.selectRowIndexes([row], byExtendingSelection: false)
    table.scrollRowToVisible(row)

    let height = CGFloat(min(items.count, 8)) * table.rowHeight + 8
    var frame = NSRect(x: caret.minX - 32, y: caret.minY - height - 4, width: 380, height: height)
    if let screen = window.screen?.visibleFrame {
      if frame.minY < screen.minY { frame.origin.y = caret.maxY + 4 }
      frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
    }
    panel.setFrame(frame, display: true)
    if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
    panel.orderFront(nil)
  }

  func hide() {
    guard panel.isVisible || panel.parent != nil else { return }
    panel.parent?.removeChildWindow(panel)
    panel.orderOut(nil)
    items = []
  }

  func moveSelection(by offset: Int) {
    guard !items.isEmpty else { return }
    let row = min(max(0, table.selectedRow + offset), items.count - 1)
    table.selectRowIndexes([row], byExtendingSelection: false)
    table.scrollRowToVisible(row)
  }

  func acceptSelection() {
    guard items.indices.contains(table.selectedRow) else { return }
    onAccept?(items[table.selectedRow])
  }

  @objc private func clicked() {
    guard items.indices.contains(table.clickedRow) else { return }
    onAccept?(items[table.clickedRow])
  }

  func numberOfRows(in tableView: NSTableView) -> Int { items.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let item = items[row]
    let cell = (tableView.makeView(withIdentifier: .init("cell"), owner: nil) as? CompletionCell)
      ?? CompletionCell()
    cell.identifier = .init("cell")
    cell.configure(item)
    return cell
  }
}

private final class CompletionCell: NSTableCellView {
  private let glyph = NSTextField(labelWithString: "")
  private let icon = NSImageView()
  private let label = NSTextField(labelWithString: "")
  private let detail = NSTextField(labelWithString: "")

  init() {
    super.init(frame: .zero)
    glyph.alignment = .center
    glyph.font = .systemFont(ofSize: 15)
    icon.contentTintColor = .secondaryLabelColor
    label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    label.lineBreakMode = .byTruncatingTail
    detail.font = .systemFont(ofSize: 11)
    detail.textColor = .secondaryLabelColor
    detail.lineBreakMode = .byTruncatingTail
    for view in [glyph, icon, label, detail] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    NSLayoutConstraint.activate([
      glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      glyph.widthAnchor.constraint(equalToConstant: 24),
      glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
      icon.centerXAnchor.constraint(equalTo: glyph.centerXAnchor),
      icon.centerYAnchor.constraint(equalTo: centerYAnchor),
      label.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 6),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      detail.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
      detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
      detail.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

  func configure(_ item: Completion) {
    label.stringValue = item.label
    detail.stringValue = item.detail
    if let symbol = item.symbol {
      glyph.stringValue = symbol
      glyph.isHidden = false
      icon.isHidden = true
    } else {
      glyph.isHidden = true
      icon.isHidden = false
      let name: String
      switch item.kind {
      case .function: name = "function"
      case .parameter: name = "slider.horizontal.3"
      case .constant: name = "number"
      case .type: name = "t.square"
      case .label: name = "tag"
      case .font: name = "textformat"
      default: name = "chevron.left.forwardslash.chevron.right"
      }
      icon.image = NSImage(systemSymbolName: name, accessibilityDescription: item.kind.rawValue)
    }
    setAccessibilityLabel([item.label, item.symbol, item.detail].compactMap { $0 }.joined(separator: ", "))
  }
}
