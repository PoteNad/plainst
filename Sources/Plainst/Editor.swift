import AppKit
import PlainstCore
import PlainstEditor

/// A document window: a Typst editor with the toolbar, status bar, outline, preview and symbols.
@MainActor
final class Editor: NSWindowController, NSMenuItemValidation, NSWindowDelegate, NSToolbarDelegate,
  TypstEditorDelegate
{
  let typst: TypstEditor
  var textView: TypstTextView { typst.textView }
  var text: String { typst.text }
  var mode: EditorMode { typst.mode }
  var elements: [OutlineElement] { typst.elements }
  var engineKey: UInt64 { typst.engineKey }
  var zoomPercent: Int { typst.zoomPercent }
  private let position = NSTextField(labelWithString: "")
  private let details = NSTextField(labelWithString: "")
  /// The word or character count; clicking it chooses which.
  private let count = NSButton(title: "", target: nil, action: nil)
  private let problems = NSButton(title: "", target: nil, action: nil)
  private let statusBar = NSVisualEffectView()
  private lazy var statusHeight = statusBar.heightAnchor.constraint(equalToConstant: 24)

  private weak var note: PlainstDocument?
  private var inFullScreenTransition = false
  private(set) var statusVisible = UserDefaults.standard.bool(forKey: PreferenceKey.status)
  let symbols = SymbolsViewController()
  private var symbolsItem: NSSplitViewItem!
  let outlineSidebar = OutlineSidebarController()
  private var outlineItem: NSSplitViewItem!
  private var sidebarOutlineVersion = -1
  let previewPane = PreviewViewController()
  private var previewSyncGeneration = 0
  private var previewItem: NSSplitViewItem!

  init(document: PlainstDocument) {
    self.note = document
    typst = TypstEditor(
      text: document.file.text, mode: AppPreferences.defaultMode,
      configuration: AppPreferences.editorConfiguration)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 920, height: 720),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false
    )
    super.init(window: window)
    window.delegate = self
    window.minSize = NSSize(width: 460, height: 300)
    window.tabbingIdentifier = "io.github.PoteNad.plainst.document"
    window.tabbingMode = .preferred
    // Every window opens centred at a comfortable size rather than cascading from a saved spot.
    shouldCascadeWindows = false
    // A native toolbar with the view switcher at the trailing edge, like Pages' inspector buttons.
    let toolbar = NSToolbar(identifier: "PlainstDocumentToolbar")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    // The buttons are icons with tooltips; text labels crowd the title and the view switch.
    if #available(macOS 15.0, *) { toolbar.allowsDisplayModeCustomization = false }
    window.toolbar = toolbar
    window.toolbarStyle = .unified
    statusBar.material = .headerView
    statusBar.blendingMode = .withinWindow
    statusBar.state = .followsWindowActiveState
    for label in [position, details] {
      label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
      label.textColor = .secondaryLabelColor
      label.lineBreakMode = .byTruncatingTail
    }
    details.alignment = .right
    count.isBordered = false
    count.target = self
    count.action = #selector(chooseCount(_:))
    count.toolTip = "Choose whether to count words or characters"
    count.setAccessibilityLabel("Count")
    problems.isBordered = false
    problems.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    problems.target = self
    problems.action = #selector(showProblems(_:))
    problems.isHidden = true
    problems.setAccessibilityLabel("Typst problems")

    let root = NSView()
    // The document sits beside a collapsible symbols inspector, like Pages' Format panel.
    let documentController = NSViewController()
    documentController.view = root
    symbols.editor = self
    let split = EditorSplitViewController()
    // Headings sit in a sidebar, like Preview's table of contents.
    outlineSidebar.editor = self
    outlineItem = NSSplitViewItem(sidebarWithViewController: outlineSidebar)
    outlineItem.canCollapse = true
    outlineItem.minimumThickness = 180
    outlineItem.maximumThickness = 340
    outlineItem.isCollapsed = (isAutomatedCheck || !UserDefaults.standard.bool(forKey: PreferenceKey.outlineVisible))
    split.addSplitViewItem(outlineItem)
    split.addSplitViewItem(NSSplitViewItem(viewController: documentController))
    // The typeset preview sits between the text and the symbols, like a second page view.
    previewPane.editor = self
    previewPane.key = engineKey
    previewItem = NSSplitViewItem(viewController: previewPane)
    split.previewItem = previewItem
    split.onPreviewDividerDoubleClick = { [weak self] in self?.fitPreviewToPage() }
    previewItem.canCollapse = true
    previewItem.minimumThickness = 260
    previewItem.holdingPriority = .init(rawValue: 255)
    previewItem.isCollapsed = (isAutomatedCheck || !UserDefaults.standard.bool(forKey: PreferenceKey.previewVisible))
    split.addSplitViewItem(previewItem)
    symbolsItem = NSSplitViewItem(inspectorWithViewController: symbols)
    symbolsItem.canCollapse = true
    symbolsItem.minimumThickness = 268
    symbolsItem.maximumThickness = 380
    symbolsItem.isCollapsed = (isAutomatedCheck || !UserDefaults.standard.bool(forKey: PreferenceKey.symbolsVisible))
    split.addSplitViewItem(symbolsItem)
    if !isAutomatedCheck { split.splitView.autosaveName = "PlainstEditorSplit" }
    window.contentViewController = split
    placeWindow()
    if previewVisible { DispatchQueue.main.async { [weak self] in self?.layoutPreview() } }
    let scroll = typst.scrollView
    root.addSubview(scroll)
    root.addSubview(statusBar)
    statusBar.addSubview(position)
    statusBar.addSubview(problems)
    statusBar.addSubview(count)
    statusBar.addSubview(details)
    for view in [scroll, statusBar, position, details, problems, count] {
      view.translatesAutoresizingMaskIntoConstraints = false
    }
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
      scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
      statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      statusHeight,
      position.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 8),
      position.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
      problems.leadingAnchor.constraint(equalTo: position.trailingAnchor, constant: 14),
      problems.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
      count.leadingAnchor.constraint(greaterThanOrEqualTo: problems.trailingAnchor, constant: 12),
      count.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
      details.leadingAnchor.constraint(equalTo: count.trailingAnchor, constant: 10),
      details.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -8),
      details.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
    ])
    position.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    setStatusVisible(statusVisible)
    document.file.text = ""
    typst.collectsPages = previewVisible
    typst.delegate = self
    updateStatus()

    NotificationCenter.default.addObserver(
      self, selector: #selector(defaultsDidChange), name: .editorDefaultsDidChange, object: nil)
    window.makeFirstResponder(textView)
  }

  required init?(coder: NSCoder) { fatalError() }

  /// Centres the window on the active screen, at the size the user last gave a window, or
  /// sized to fit comfortably within the screen before they have resized one.
  private func placeWindow() {
    guard let window else { return }
    let screen = (NSApp.keyWindow ?? NSApp.mainWindow)?.screen ?? NSScreen.main
    guard let visible = screen?.visibleFrame else { return window.center() }
    var size: NSSize
    if let saved = Self.windowDefaults.string(forKey: PreferenceKey.windowSize).map(NSSizeFromString),
      saved.width > 0, saved.height > 0
    {
      size = saved
    } else {
      // Windows that open with the preview showing start wide enough for the text and a page.
      let width = contentWidth(outline: outlineVisible, preview: previewVisible, symbols: symbolsVisible)
      size = NSSize(
        width: min(width, visible.width * (previewVisible ? 0.9 : 0.8)).rounded(),
        height: min(740, visible.height * 0.85).rounded())
    }
    var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
    frame.size.width = min(frame.width, visible.width)
    frame.size.height = min(frame.height, visible.height)
    window.setFrame(
      NSRect(
        x: (visible.midX - frame.width / 2).rounded(), y: (visible.midY - frame.height / 2).rounded(),
        width: frame.width, height: frame.height), display: false)
  }

  // Reopened documents also come back centred, not wherever their window was last left.
  func window(_ window: NSWindow, didDecodeRestorableState state: NSCoder) {
    placeWindow()
  }

  // Resizing by dragging, zooming, or tiling sets the size new windows open at. Full screen
  // doesn't, and neither does placing a window before it is shown.
  func windowDidResize(_ notification: Notification) { rememberWindowSize() }

  func windowWillEnterFullScreen(_ notification: Notification) { inFullScreenTransition = true }

  func windowDidExitFullScreen(_ notification: Notification) { inFullScreenTransition = false }

  private func rememberWindowSize() {
    guard !inFullScreenTransition, let window, window.isVisible,
      !window.styleMask.contains(.fullScreen)
    else { return }
    let size = window.contentRect(forFrameRect: window.frame).size
    Self.windowDefaults.set(NSStringFromSize(size), forKey: PreferenceKey.windowSize)
  }

  /// Where the window size is kept. Automated checks use a store of their own, so they
  /// exercise saving without changing the user's windows.
  static let windowDefaults: UserDefaults = {
    #if PLAINST_CHECKS
      if AppChecks.isChecking, let checks = UserDefaults(suiteName: "io.github.PoteNad.plainst.checks") {
        checks.removeObject(forKey: PreferenceKey.windowSize)
        return checks
      }
    #endif
    return .standard
  }()

  func loadText(_ text: String) { typst.loadText(text) }

  func insertMath(_ code: String, snippet: Bool) { typst.insertMath(code, snippet: snippet) }

  // MARK: Editor events

  func typstEditorTextDidChange(_ editor: TypstEditor) {
    note?.syncEditedIndicator()
    updateStatus()
  }

  func typstEditorSelectionDidChange(_ editor: TypstEditor) {
    updateStatus()
    updateOutlineSidebar()
    if previewVisible { syncPreview(after: 0.15) }
  }

  func typstEditorDisplayDidChange(_ editor: TypstEditor) {
    viewGroup?.selectedIndex = EditorMode.allCases.firstIndex(of: mode) ?? 0
    updateStatus()
  }

  func typstEditor(_ editor: TypstEditor, didCompile result: CompileResult, pages: [PreviewPage]?) {
    if let pages, previewVisible {
      previewPane.update(pages: pages, errors: result.errors.count)
    }
    if previewVisible { syncPreview(after: 0) }
    updateStatus()
  }

  func undoManager(for editor: TypstEditor) -> UndoManager? { note?.undoManager }

  // MARK: Preview

  /// Scrolls the preview to where the cursor's text is typeset, once the cursor rests.
  func syncPreview(after delay: TimeInterval) {
    previewSyncGeneration += 1
    let generation = previewSyncGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self, generation == self.previewSyncGeneration, self.previewVisible,
        self.window?.firstResponder === self.textView
      else { return }
      let text = self.text
      let cursor = self.textView.selectedRange().location
      let key = self.engineKey
      TypstEditor.engineQueue.async {
        let positions = Engine.previewPositions(key: key, text: text, cursor: cursor)
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            guard generation == self.previewSyncGeneration, let first = positions.first else { return }
            self.previewPane.reveal(page: first.page, point: first.point)
          }
        }
      }
    }
  }

  /// Puts the cursor on the text under a click in the preview and points it out.
  func jumpFromPreview(page: Int, point: CGPoint) {
    guard let offset = Engine.sourceOffset(key: engineKey, page: page, point: point) else { return }
    let location = min(offset, typst.textLength)
    window?.makeFirstResponder(textView)
    previewSyncGeneration += 1
    textView.setSelectedRange(NSRange(location: location, length: 0))
    textView.scrollRangeToVisible(NSRange(location: location, length: 0))
    DispatchQueue.main.async { [weak self] in
      guard let self, location < self.typst.textLength else { return }
      // Layout may change as markup around the cursor is revealed, so point afterwards.
      let word = self.textView.selectionRange(
        forProposedRange: NSRange(location: location, length: 0), granularity: .selectByWord)
      let range = word.length > 0 && word.length < 40 ? word : NSRange(location: location, length: 1)
      self.textView.scrollRangeToVisible(range)
      self.textView.showFindIndicator(for: range)
    }
  }

  func updateOutlineSidebar() {
    guard outlineVisible else { return }
    let caret = textView.selectedRange().location
    if sidebarOutlineVersion != typst.outlineVersion {
      sidebarOutlineVersion = typst.outlineVersion
      outlineSidebar.update(headings: typst.headings, caret: caret)
    } else {
      outlineSidebar.follow(caret: caret)
    }
  }

  func updateStatus() {
    guard statusVisible else { return }
    let selection = textView.selectedRange()
    let place = typst.lineAndColumn(at: selection.location)
    position.stringValue = "Ln \(place.line), Col \(place.column)"
    let diagnostics = typst.diagnostics
    let errors = diagnostics.filter(\.isError).count
    let warnings = diagnostics.count - errors
    if errors > 0 {
      problems.isHidden = false
      problems.attributedTitle = statusTitle(
        "⚠︎ \(errors) \(errors == 1 ? "error" : "errors")", color: .systemRed)
    } else if warnings > 0 {
      problems.isHidden = false
      problems.attributedTitle = statusTitle(
        "\(warnings) \(warnings == 1 ? "warning" : "warnings")", color: .systemOrange)
    } else {
      problems.isHidden = true
    }
    problems.toolTip = diagnostics.first.map(\.message)
    count.attributedTitle = statusTitle(countText(for: selection), color: .secondaryLabelColor)
    var parts: [String] = []
    let pages = typst.pageCount
    if errors == 0, typst.lastCompiledText != nil {
      parts.append("\(pages) \(pages == 1 ? "page" : "pages")")
    }
    if let file = note?.file {
      // Like PoteNad, mixed line endings say so instead of naming one style.
      if file.hasMixedLineEndings {
        parts.append("Mixed")
      } else if file.lineEnding != .lf {
        parts.append(file.lineEnding.displayName)
      }
      if file.encoding != .utf8 { parts.append(file.encoding.displayName) }
    }
    parts.append("\(zoomPercent)%")
    details.stringValue = parts.joined(separator: "   ")
  }

  /// "368 words", or "12 of 368 words" while text is selected; characters when chosen instead.
  func countText(for selection: NSRange) -> String {
    let characters = UserDefaults.standard.string(forKey: PreferenceKey.statusCount) == "characters"
    let total = characters ? typst.characterCount : typst.wordCount
    let unit = characters ? (total == 1 ? "character" : "characters") : (total == 1 ? "word" : "words")
    let format = { (value: Int) in value.formatted() }
    guard selection.length > 0, NSMaxRange(selection) <= typst.textLength else {
      return "\(format(total)) \(unit)"
    }
    let selected = typst.string.substring(with: selection)
    let part = characters ? selected.count : Formatting.wordCount(selected)
    return "\(format(part)) of \(format(total)) \(characters ? "characters" : "words")"
  }

  @objc private func chooseCount(_ sender: NSButton) {
    let characters = UserDefaults.standard.string(forKey: PreferenceKey.statusCount) == "characters"
    let menu = NSMenu()
    for (title, value) in [("Words", "words"), ("Characters", "characters")] {
      let item = NSMenuItem(title: title, action: #selector(setCount(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = value
      item.state = (value == "characters") == characters ? .on : .off
      menu.addItem(item)
    }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
  }

  @objc private func setCount(_ sender: NSMenuItem) {
    UserDefaults.standard.set(sender.representedObject as? String, forKey: PreferenceKey.statusCount)
    // Every window shows the same kind of count.
    NotificationCenter.default.post(name: .editorDefaultsDidChange, object: nil)
  }

  private func statusTitle(_ string: String, color: NSColor) -> NSAttributedString {
    NSAttributedString(
      string: string,
      attributes: [
        .foregroundColor: color, .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
      ])
  }

  @objc private func showProblems(_ sender: NSButton) {
    let menu = NSMenu()
    for diagnostic in typst.diagnostics {
      var title = diagnostic.message
      if let range = diagnostic.range {
        title = "Ln \(typst.lineAndColumn(at: range.location).line): " + title
      }
      let item = NSMenuItem(title: title, action: #selector(jumpToProblem(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = diagnostic.range.map { NSValue(range: $0) }
      item.toolTip = diagnostic.hints.joined(separator: "\n")
      item.image = NSImage(
        systemSymbolName: diagnostic.isError ? "xmark.octagon" : "exclamationmark.triangle",
        accessibilityDescription: nil)
      menu.addItem(item)
    }
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
  }

  @objc private func jumpToProblem(_ sender: NSMenuItem) {
    guard let range = (sender.representedObject as? NSValue)?.rangeValue,
      NSMaxRange(range) <= typst.textLength
    else { return }
    window?.makeFirstResponder(textView)
    textView.setSelectedRange(range)
    textView.scrollRangeToVisible(range)
  }

  private func setStatusVisible(_ visible: Bool) {
    statusVisible = visible
    statusBar.isHidden = !visible
    statusHeight.constant = visible ? 24 : 0
    updateStatus()
  }

  // MARK: Commands

  private static let viewItem = NSToolbarItem.Identifier("view")
  private static let symbolsToolbarItem = NSToolbarItem.Identifier("symbols")
  private static let outlineToolbarItem = NSToolbarItem.Identifier("outline")

  var outlineVisible: Bool { !outlineItem.isCollapsed }

  @objc func toggleOutline(_ sender: Any?) {
    let show = outlineItem.isCollapsed
    if show {
      sidebarOutlineVersion = typst.outlineVersion
      outlineSidebar.update(headings: typst.headings, caret: textView.selectedRange().location)
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      outlineItem.animator().isCollapsed = !show
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated { if show { self?.layoutPreview() } }
    }
    if !isAutomatedCheck { UserDefaults.standard.set(show, forKey: PreferenceKey.outlineVisible) }
  }
  private static let previewToolbarItem = NSToolbarItem.Identifier("preview")

  var previewVisible: Bool { !previewItem.isCollapsed }

  @objc func togglePreview(_ sender: Any?) {
    let show = previewItem.isCollapsed
    if show {
      // The preview shares the window instead of resizing it, like a sidebar.
      previewItem.isCollapsed = false
      DispatchQueue.main.async { [weak self] in self?.layoutPreview() }
    } else {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        previewItem.animator().isCollapsed = true
      }
    }
    if !isAutomatedCheck { UserDefaults.standard.set(show, forKey: PreferenceKey.previewVisible) }
    typst.collectsPages = show
    if show {
      typst.scheduleCompile(delay: 0)
    }
  }

  /// The text width new windows leave beside a full-size preview page.
  private static let textBesidePreview: CGFloat = 480
  /// The narrowest the text gets so the preview can show a full-size page.
  private static let narrowestTextBesidePreview: CGFloat = 320

  /// The window content width that fits the text with the given panels open, with a full-size
  /// page in the preview. New windows open this wide; panels never resize a window after that.
  private func contentWidth(outline: Bool, preview: Bool, symbols: Bool) -> CGFloat {
    var width = preview ? Self.textBesidePreview + previewPane.fittingWidth : 1040
    if outline { width += max(outlineItem.minimumThickness, outlineItem.viewController.view.frame.width) }
    if symbols { width += max(symbolsItem.minimumThickness, symbolsItem.viewController.view.frame.width) }
    return width.rounded(.up)
  }

  /// Gives the preview a full-size page when there is room, like double-clicking its divider,
  /// and otherwise as much as it can have while the text stays readable.
  private func layoutPreview() {
    guard previewVisible, let split = window?.contentViewController as? NSSplitViewController,
      let item = split.splitViewItems.firstIndex(of: previewItem), item > 0
    else { return }
    split.splitView.layoutSubtreeIfNeeded()
    let panes = split.splitView.arrangedSubviews
    guard panes.count == split.splitViewItems.count else { return }
    let start = outlineVisible ? panes[0].frame.maxX : 0
    let end = symbolsVisible ? panes[panes.count - 1].frame.minX : split.splitView.bounds.width
    let space = end - start
    let previewWidth = min(
      previewPane.fittingWidth,
      max(previewItem.minimumThickness, (space - Self.narrowestTextBesidePreview).rounded()))
    split.splitView.setPosition((end - previewWidth).rounded(), ofDividerAt: item - 1)
  }

  var symbolsVisible: Bool { !symbolsItem.isCollapsed }

  /// Sizes the preview to show its pages at full size with the least margin, keeping room
  /// for the text beside it.
  func fitPreviewToPage() {
    guard previewVisible, let split = window?.contentViewController as? NSSplitViewController,
      let item = split.splitViewItems.firstIndex(of: previewItem), item > 0
    else { return }
    let panes = split.splitView.arrangedSubviews
    guard panes.count == split.splitViewItems.count else { return }
    let start = outlineVisible ? panes[0].frame.maxX : 0
    let end = panes[item].frame.maxX
    let position = max(start + Self.narrowestTextBesidePreview, end - previewPane.fittingWidth)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      context.allowsImplicitAnimation = true
      split.splitView.setPosition(position.rounded(), ofDividerAt: item - 1)
      split.splitView.layoutSubtreeIfNeeded()
    }
  }

  /// Automated checks must leave the user's saved window and sidebar state alone.
  private var isAutomatedCheck: Bool {
    #if PLAINST_CHECKS
      AppChecks.isChecking
    #else
      false
    #endif
  }

  @objc func toggleSymbols(_ sender: Any?) {
    let show = symbolsItem.isCollapsed
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      symbolsItem.animator().isCollapsed = !show
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated { if show { self?.layoutPreview() } }
    }
    if !isAutomatedCheck { UserDefaults.standard.set(show, forKey: PreferenceKey.symbolsVisible) }
    if show { symbols.focusSearch() } else { window?.makeFirstResponder(textView) }
  }
  private var viewGroup: NSToolbarItemGroup?

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [
      Self.outlineToolbarItem, .sidebarTrackingSeparator, .flexibleSpace, Self.viewItem,
      Self.previewToolbarItem, Self.symbolsToolbarItem,
    ]
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    if itemIdentifier == Self.outlineToolbarItem {
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.image = NSImage(systemSymbolName: "list.bullet.indent", accessibilityDescription: "Outline")
      item.label = "Outline"
      item.paletteLabel = "Outline"
      item.toolTip = "Show or hide the headings, and jump to one (⌃⌘S)"
      item.target = self
      item.action = #selector(toggleOutline(_:))
      item.isBordered = true
      return item
    }
    if itemIdentifier == Self.previewToolbarItem {
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: "Preview")
      item.label = "Preview"
      item.paletteLabel = "Preview"
      item.toolTip = "Show or hide the typeset document, as it will export to PDF (⌥⌘P)"
      item.target = self
      item.action = #selector(togglePreview(_:))
      item.isBordered = true
      return item
    }
    if itemIdentifier == Self.symbolsToolbarItem {
      let item = NSToolbarItem(itemIdentifier: itemIdentifier)
      item.image = NSImage(systemSymbolName: "sum", accessibilityDescription: "Symbols")
      item.label = "Symbols"
      item.paletteLabel = "Symbols"
      item.toolTip = "Show or hide symbols and math structures (⌥⌘T)"
      item.target = self
      item.action = #selector(toggleSymbols(_:))
      item.isBordered = true
      return item
    }
    guard itemIdentifier == Self.viewItem else { return nil }
    let images = [
      NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: "Writing")!,
      NSImage(
        systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: "Source")!,
    ]
    let group = NSToolbarItemGroup(
      itemIdentifier: itemIdentifier, images: images, selectionMode: .selectOne,
      labels: EditorMode.allCases.map(\.title), target: self, action: #selector(changeView(_:)))
    group.label = "View"
    group.paletteLabel = "View"
    // Each button describes the view it switches to; a group-wide tooltip would hide these.
    let tips = [
      "Writing: formatted text and rendered math (⌘1)",
      "Source: the Typst file exactly as it is saved (⌘2)",
    ]
    for (item, tip) in zip(group.subitems, tips) { item.toolTip = tip }
    if let control = group.view as? NSSegmentedControl {
      for (segment, tip) in tips.enumerated() { control.setToolTip(tip, forSegment: segment) }
    }
    group.selectedIndex = EditorMode.allCases.firstIndex(of: mode) ?? 0
    viewGroup = group
    return group
  }

  @objc private func changeView(_ sender: NSToolbarItemGroup) {
    guard EditorMode.allCases.indices.contains(sender.selectedIndex) else { return }
    setMode(EditorMode.allCases[sender.selectedIndex])
    window?.makeFirstResponder(textView)
  }

  func setMode(_ newMode: EditorMode) { typst.setMode(newMode) }

  @objc func showWriting(_ sender: Any?) { setMode(.writing) }
  @objc func showSource(_ sender: Any?) { setMode(.source) }

  @objc func toggleBold(_ sender: Any?) { typst.toggle(.strong, actionName: "Bold") }
  @objc func toggleItalic(_ sender: Any?) { typst.toggle(.emph, actionName: "Italic") }
  @objc func toggleCode(_ sender: Any?) { typst.toggle(.code, actionName: "Code") }

  @objc func makeHeading(_ sender: NSMenuItem) { typst.setHeading(level: sender.tag) }

  @objc func toggleBulletedList(_ sender: Any?) {
    typst.toggleList(.bullet, actionName: "Bulleted List")
  }

  @objc func toggleNumberedList(_ sender: Any?) {
    typst.toggleList(.numbered, actionName: "Numbered List")
  }

  @objc func insertInlineEquation(_ sender: Any?) { typst.insertEquation(block: false) }
  @objc func insertDisplayEquation(_ sender: Any?) { typst.insertEquation(block: true) }

  /// Format ▸ Document Style: the font, size, and justification the document sets for itself.
  @objc func showDocumentStyle(_ sender: Any?) {
    guard let window else { return }
    let style = typst.documentStyle
    let alert = NSAlert()
    alert.messageText = "Document Style"
    alert.informativeText =
      "Choose the font, size, and justification for this document. Plainst writes them as #set rules at the top of the file, so the PDF uses them too."
    alert.addButton(withTitle: "Apply")
    alert.addButton(withTitle: "Cancel")

    let family = NSPopUpButton()
    family.addItem(withTitle: "Default (\(DocumentStyle.defaultFont))")
    family.menu?.addItem(.separator())
    for name in Engine.fontFamilies { family.addItem(withTitle: name) }
    if let current = style.font {
      if let item = family.itemArray.first(where: { $0.title.caseInsensitiveCompare(current) == .orderedSame }) {
        family.select(item)
      } else {
        // A font Typst doesn't have still shows, so applying keeps it.
        family.addItem(withTitle: current)
        family.selectItem(withTitle: current)
      }
    }
    let number = NumberFormatter()
    number.numberStyle = .decimal
    number.minimum = 4
    number.maximum = 96
    number.maximumFractionDigits = 2
    let size = NSTextField(string: style.size.map { number.string(from: NSNumber(value: $0)) ?? "" } ?? "")
    size.placeholderString = number.string(from: NSNumber(value: DocumentStyle.defaultSize))
    size.formatter = number
    size.widthAnchor.constraint(equalToConstant: 64).isActive = true
    let points = NSStackView(views: [size, NSTextField(labelWithString: "pt")])
    points.spacing = 6
    let justify = NSButton(checkboxWithTitle: "Justify paragraphs", target: nil, action: nil)
    justify.state = style.justify == true ? .on : .off
    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "Font:"), family],
      [NSTextField(labelWithString: "Size:"), points],
      [NSGridCell.emptyContentView, justify],
    ])
    grid.rowSpacing = 8
    grid.columnSpacing = 8
    grid.column(at: 0).xPlacement = .trailing
    grid.rowAlignment = .firstBaseline
    grid.frame.size = grid.fittingSize
    alert.accessoryView = grid
    alert.window.initialFirstResponder = family

    alert.beginSheetModal(for: window) { [weak self] response in
      MainActor.assumeIsolated {
        guard let self, response == .alertFirstButtonReturn else { return }
        let chosen = family.indexOfSelectedItem <= 0 ? nil : family.titleOfSelectedItem
        let points = size.stringValue.isEmpty ? nil : number.number(from: size.stringValue)?.doubleValue
        self.typst.setDocumentStyle(font: chosen, size: points, justify: justify.state == .on)
      }
    }
  }

  @objc func foldSection(_ sender: Any?) { typst.foldCurrentSection() }
  @objc func unfoldSection(_ sender: Any?) { typst.unfoldCurrentSection() }
  @objc func unfoldAll(_ sender: Any?) { typst.unfoldAll() }

  @objc func increaseIndent(_ sender: Any?) { typst.indent(outdent: false) }
  @objc func decreaseIndent(_ sender: Any?) { typst.indent(outdent: true) }

  @objc func zoomIn(_ sender: Any?) { setZoom(zoomPercent + 10) }
  @objc func zoomOut(_ sender: Any?) { setZoom(zoomPercent - 10) }
  @objc func zoomReset(_ sender: Any?) { setZoom(100) }

  func setZoom(_ percent: Int) { typst.setZoom(percent) }

  @objc func toggleStatus(_ sender: Any?) { setStatusVisible(!statusVisible) }

  @objc func showFind(_ sender: Any?) { performFind(.showFindInterface) }
  @objc func showReplace(_ sender: Any?) { performFind(.showReplaceInterface) }
  @objc func findNext(_ sender: Any?) { performFind(.nextMatch) }
  @objc func findPrevious(_ sender: Any?) { performFind(.previousMatch) }

  private func performFind(_ action: NSTextFinder.Action) {
    let item = NSMenuItem()
    item.tag = action.rawValue
    textView.performTextFinderAction(item)
  }

  @objc func goToLine(_ sender: Any?) {
    let alert = NSAlert()
    alert.messageText = "Go to Line"
    alert.addButton(withTitle: "Go")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(string: String(typst.lineAndColumn(at: textView.selectedRange().location).line))
    field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    guard let line = Int(field.stringValue), let start = typst.location(ofLine: line) else {
      NSSound.beep()
      return
    }
    let range = NSRange(location: start, length: 0)
    textView.setSelectedRange(range)
    textView.scrollRangeToVisible(range)
  }

  @objc private func defaultsDidChange(_ notification: Notification) {
    setStatusVisible(UserDefaults.standard.bool(forKey: PreferenceKey.status))
    typst.configuration = AppPreferences.editorConfiguration
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(showWriting(_:)):
      menuItem.state = mode == .writing ? .on : .off
    case #selector(showSource(_:)):
      menuItem.state = mode == .source ? .on : .off
    case #selector(unfoldAll(_:)):
      return !typst.foldedHeadingLocations.isEmpty
    case #selector(foldSection(_:)):
      return typst.elements.contains { $0.kind == .heading }
    case #selector(toggleStatus(_:)):
      menuItem.state = statusVisible ? .on : .off
    case #selector(toggleSymbols(_:)):
      menuItem.title = symbolsVisible ? "Hide Symbols" : "Show Symbols"
    case #selector(toggleOutline(_:)):
      menuItem.title = outlineVisible ? "Hide Outline" : "Show Outline"
    case #selector(togglePreview(_:)):
      menuItem.title = previewVisible ? "Hide Preview" : "Show Preview"
    case #selector(zoomIn(_:)):
      return zoomPercent < 400
    case #selector(zoomOut(_:)):
      return zoomPercent > 50
    default:
      break
    }
    return true
  }

}
