import AppKit
import PlainstCore

/// The document's headings as a table of contents in the sidebar, like Preview's.
@MainActor
final class OutlineSidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
  /// A heading and the headings nested under it.
  final class Node {
    let entry: HeadingEntry
    var children: [Node] = []
    init(_ entry: HeadingEntry) { self.entry = entry }
  }

  weak var editor: Editor?
  let outlineView = NSOutlineView()
  private let scroll = NSScrollView()
  private let empty = NSTextField(wrappingLabelWithString: "")
  private(set) var roots: [Node] = []
  private var flat: [Node] = []
  private var entries: [HeadingEntry] = []
  /// Set while the selection follows the cursor, so it doesn't jump back to the heading.
  private var isFollowing = false

  override func loadView() {
    let root = NSView()
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("heading"))
    outlineView.addTableColumn(column)
    outlineView.outlineTableColumn = column
    outlineView.headerView = nil
    outlineView.style = .sourceList
    outlineView.rowSizeStyle = .default
    outlineView.indentationPerLevel = 12
    outlineView.floatsGroupRows = false
    outlineView.dataSource = self
    outlineView.delegate = self
    outlineView.target = self
    outlineView.action = #selector(clicked(_:))
    outlineView.setAccessibilityLabel("Headings")
    scroll.documentView = outlineView
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true

    empty.stringValue = "No Headings\nStart a line with = to add a heading."
    empty.alignment = .center
    empty.textColor = .secondaryLabelColor
    empty.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

    for view in [scroll, empty] {
      view.translatesAutoresizingMaskIntoConstraints = false
      root.addSubview(view)
    }
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      empty.centerYAnchor.constraint(equalTo: root.centerYAnchor),
      empty.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
      empty.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
    ])
    view = root
  }

  /// Rebuilds the tree when the headings change, then selects the cursor's section.
  func update(headings: [HeadingEntry], caret: Int) {
    _ = view
    if headings.map({ [$0.level, $0.range.location, $0.range.length] }) != entries.map({ [$0.level, $0.range.location, $0.range.length] })
      || headings.map(\.title) != entries.map(\.title)
    {
      entries = headings
      roots = []
      flat = []
      var stack: [Node] = []
      for heading in headings {
        let node = Node(heading)
        while let last = stack.last, last.entry.level >= heading.level { stack.removeLast() }
        if let parent = stack.last { parent.children.append(node) } else { roots.append(node) }
        stack.append(node)
        flat.append(node)
      }
      outlineView.reloadData()
      outlineView.expandItem(nil, expandChildren: true)
      empty.isHidden = !headings.isEmpty
    }
    follow(caret: caret)
  }

  /// Selects the heading whose section contains the cursor.
  func follow(caret: Int) {
    guard let index = DocumentOutline.currentHeading(in: entries, at: caret) else {
      outlineView.deselectAll(nil)
      return
    }
    let row = outlineView.row(forItem: flat[index])
    guard row >= 0, outlineView.selectedRow != row else { return }
    isFollowing = true
    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    outlineView.scrollRowToVisible(row)
    isFollowing = false
  }

  @objc private func clicked(_ sender: Any?) {
    guard let node = outlineView.item(atRow: outlineView.clickedRow) as? Node else { return }
    editor?.jump(toHeading: node.entry.range)
  }

  func outlineViewSelectionDidChange(_ notification: Notification) {
    // Arrow keys move through the headings too.
    guard !isFollowing, view.window?.firstResponder === outlineView,
      let node = outlineView.item(atRow: outlineView.selectedRow) as? Node
    else { return }
    editor?.jump(toHeading: node.entry.range, focusText: false)
  }

  // MARK: Data source

  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    (item as? Node)?.children.count ?? roots.count
  }

  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    (item as? Node)?.children[index] ?? roots[index]
  }

  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    !((item as? Node)?.children.isEmpty ?? true)
  }

  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
    guard let node = item as? Node else { return nil }
    let identifier = NSUserInterfaceItemIdentifier("HeadingCell")
    let cell =
      outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
          label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
          label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
          label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
      }()
    let title = node.entry.title.isEmpty ? "Untitled Heading" : node.entry.title
    cell.textField?.stringValue = title
    cell.textField?.font = .systemFont(
      ofSize: NSFont.systemFontSize, weight: node.entry.level == (entries.map(\.level).min() ?? 1) ? .semibold : .regular)
    cell.toolTip = title
    return cell
  }
}
