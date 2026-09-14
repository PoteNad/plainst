import AppKit
import PlainstCore

@MainActor
final class Editor: NSWindowController, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate,
  @preconcurrency NSLayoutManagerDelegate, NSMenuItemValidation, NSWindowDelegate, NSToolbarDelegate,
  ReplacementSource
{
  let storage = NSTextStorage()
  let layout = WritingLayoutManager()
  let container = NSTextContainer()
  let textView: WritingTextView
  let scroll = EditorScrollView()
  let preview = MathPreviewView()
  private let position = NSTextField(labelWithString: "")
  private let details = NSTextField(labelWithString: "")
  private let problems = NSButton(title: "", target: nil, action: nil)
  private let statusBar = NSVisualEffectView()
  private lazy var statusHeight = statusBar.heightAnchor.constraint(equalToConstant: 24)
  static let engineQueue = DispatchQueue(label: "io.github.PoteNad.plainst.compile", qos: .utility)

  private weak var note: PlainstDocument?
  private(set) var mode: EditorMode
  private(set) var zoomPercent = 100
  private(set) var statusVisible = UserDefaults.standard.bool(forKey: PreferenceKey.status)
  private(set) var elements: [OutlineElement] = []
  private(set) var presentation = Presentation()
  private(set) var replacementKeys: [Int] = []
  private(set) var diagnostics: [Diagnostic] = []
  private(set) var pages = 0
  private(set) var lastCompiledText: String?
  private var index = LineIndex()
  private var isLoading = false
  private var pendingConcealment: (hidden: IndexSet, replacements: [Int: Replacement])?
  private var pendingRestyle: NSRange?
  private var compileGeneration = 0
  private var refreshScheduled = false
  private var attributeCache: [AttributeKey: [NSAttributedString.Key: Any]] = [:]
  private var mathColor: UInt32 = 0xFF
  private var backingScale: CGFloat = 2
  private var lastPreview: (location: Int, image: NSImage)?
  /// What the current presentation was built from, to skip redundant rebuilds.
  private var outlineVersion = 0
  private var presentedOutline = -1
  private var presentedSelection = NSRange(location: NSNotFound, length: 0)
  /// The line under which the equation preview is shown, and the space reserved for it.
  private var previewLine: NSRange?
  private var previewSpace: CGFloat = 0
  private var wordCount = 0

  var concealing: Bool { mode == .writing }
  /// View points per Typst point, so the Writing view keeps the PDF's proportions.
  var typstScale: CGFloat { 1.5 * CGFloat(zoomPercent) / 100 }
  var bodySize: CGFloat { Engine.typstTextSize * typstScale }
  var sourceSize: CGFloat { 13 * CGFloat(zoomPercent) / 100 }

  private struct AttributeKey: Hashable {
    var style: TextStyle
    var heading: Int
    var paragraph: ParagraphKind
  }

  init(document: PlainstDocument) {
    self.note = document
    mode = AppPreferences.defaultMode
    storage.addLayoutManager(layout)
    layout.addTextContainer(container)
    textView = WritingTextView(
      frame: NSRect(x: 0, y: 0, width: 900, height: 640), textContainer: container)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 920, height: 720),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    super.init(window: window)
    window.delegate = self
    window.minSize = NSSize(width: 460, height: 300)
    window.tabbingIdentifier = "io.github.PoteNad.plainst.document"
    window.tabbingMode = .preferred
    window.center()
    window.setFrameAutosaveName("PlainstDocumentWindow")
    // A native toolbar with the view switcher at the trailing edge, like Pages' inspector buttons.
    let toolbar = NSToolbar(identifier: "PlainstDocumentToolbar")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    window.toolbar = toolbar
    window.toolbarStyle = .unified
    layout.delegate = self
    layout.replacements = self
    layout.allowsNonContiguousLayout = true
    textView.editor = self
    textView.delegate = self
    storage.delegate = self
    textView.isRichText = false
    textView.importsGraphics = false
    textView.usesFontPanel = false
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
    textView.allowsUndo = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isAutomaticLinkDetectionEnabled = false
    textView.isAutomaticDataDetectionEnabled = false
    textView.isAutomaticTextCompletionEnabled = false
    textView.isGrammarCheckingEnabled = false
    textView.isContinuousSpellCheckingEnabled = UserDefaults.standard.bool(
      forKey: PreferenceKey.checkSpelling)
    updateWritingToolsBehavior()
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.minSize = .zero
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.drawsBackground = true
    textView.backgroundColor = .textBackgroundColor
    container.widthTracksTextView = false
    container.lineFragmentPadding = 0
    textView.addSubview(preview)
    preview.isHidden = true

    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    scroll.drawsBackground = true
    scroll.backgroundColor = .textBackgroundColor
    scroll.documentView = textView

    statusBar.material = .headerView
    statusBar.blendingMode = .withinWindow
    statusBar.state = .followsWindowActiveState
    for label in [position, details] {
      label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
      label.textColor = .secondaryLabelColor
      label.lineBreakMode = .byTruncatingTail
    }
    details.alignment = .right
    problems.isBordered = false
    problems.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    problems.target = self
    problems.action = #selector(showProblems(_:))
    problems.isHidden = true
    problems.setAccessibilityLabel("Typst problems")

    let root = NSView()
    window.contentView = root
    root.addSubview(scroll)
    root.addSubview(statusBar)
    statusBar.addSubview(position)
    statusBar.addSubview(problems)
    statusBar.addSubview(details)
    for view in [scroll, statusBar, position, details, problems] {
      view.translatesAutoresizingMaskIntoConstraints = false
    }
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: root.topAnchor),
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
      details.leadingAnchor.constraint(greaterThanOrEqualTo: problems.trailingAnchor, constant: 12),
      details.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -8),
      details.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
    ])
    position.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    setStatusVisible(statusVisible)
    refreshEnvironment()
    loadText(document.file.text)
    document.file.text = ""

    NotificationCenter.default.addObserver(
      self, selector: #selector(defaultsDidChange), name: .editorDefaultsDidChange, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(mathDidRender), name: MathImages.didRender, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(layoutDidChange), name: NSView.frameDidChangeNotification,
      object: textView)
    window.makeFirstResponder(textView)
  }

  required init?(coder: NSCoder) { fatalError() }

  // MARK: Text

  func loadText(_ text: String) {
    isLoading = true
    storage.setAttributedString(NSAttributedString(string: text, attributes: plainAttributes()))
    isLoading = false
    index.rebuild(storage.mutableString)
    elements = Engine.outline(text)
    restyleEverything()
    textView.undoManager?.removeAllActions()
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    scheduleCompile(delay: 0)
  }

  /// An immutable snapshot of the text. `NSTextStorage.string` can reflect later edits,
  /// which is unsafe to hand to background work.
  var text: String { storage.mutableString.copy() as! String }

  func textStorage(
    _ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
    range editedRange: NSRange, changeInLength delta: Int
  ) {
    guard editedMask.contains(.editedCharacters), !isLoading else { return }
    elements = Engine.outline(text)
    outlineVersion += 1
    // Move the previous concealment into the new text's coordinates so only real changes
    // outside the edited range need their glyphs regenerated.
    let oldRange = NSRange(location: editedRange.location, length: editedRange.length - delta)
    var hidden = presentation.hidden
    hidden.remove(integersIn: oldRange.location..<NSMaxRange(oldRange))
    hidden.shift(startingAt: NSMaxRange(oldRange), by: delta)
    var replacements: [Int: Replacement] = [:]
    for (key, value) in presentation.replacements {
      if key < oldRange.location {
        replacements[key] = value
      } else if key >= NSMaxRange(oldRange) {
        replacements[key + delta] = value
      }
    }
    pendingConcealment = (hidden, replacements)
    if pendingRestyle != nil {
      // Deferred styling from an earlier edit is now in stale coordinates; redo everything.
      pendingRestyle = NSRange(location: 0, length: textStorage.length)
    }
    let caret = NSRange(location: NSMaxRange(editedRange), length: 0)
    apply(makePresentation(selection: caret), inEditing: true, extra: editedRange)
  }

  func textStorage(
    _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
    range editedRange: NSRange, changeInLength delta: Int
  ) {
    if editedMask.contains(.editedCharacters) {
      if isLoading {
        index.rebuild(textStorage.mutableString)
      } else {
        index.update(textStorage.mutableString, editedRange: editedRange, delta: delta)
      }
      if pendingRestyle != nil {
        // Programmatic edits don't send textDidChange, so make sure deferred styling lands.
        DispatchQueue.main.async { [weak self] in self?.flushPendingRestyle() }
      }
    }
  }

  func undoManager(for view: NSTextView) -> UndoManager? { note?.undoManager }

  func textDidChange(_ notification: Notification) {
    flushPendingRestyle()
    note?.syncEditedIndicator()
    if let pending = pendingConcealment {
      pendingConcealment = nil
      invalidateConcealment(hidden: pending.hidden, replacements: pending.replacements)
    }
    updatePreview()
    updateStatus()
    scheduleCompile()
  }

  func textViewDidChangeSelection(_ notification: Notification) {
    if !storage.editedMask.isEmpty {
      DispatchQueue.main.async { [weak self] in self?.selectionChanged() }
    } else {
      selectionChanged()
    }
  }

  private func selectionChanged() {
    flushPendingRestyle()
    guard !textView.hasMarkedText() else { return }
    refreshPresentation()
    updateStatus()
  }

  func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    let selection = textView.selectedRange()
    let inCode = elements.contains {
      ($0.kind == .raw || $0.kind == .math) && $0.range.location < selection.location
        && selection.location < NSMaxRange($0.range)
    }
    guard !inCode else { return false }
    let text = storage.mutableString as NSString
    switch commandSelector {
    case #selector(NSResponder.insertNewline(_:)):
      if let edit = Formatting.newline(text: text, selection: selection) {
        apply(edit, actionName: "Typing")
        return true
      }
    case #selector(NSResponder.insertTab(_:)):
      if let edit = Formatting.indentList(text: text, selection: selection, outdent: false) {
        apply(edit, actionName: "Increase Indent")
        return true
      }
    case #selector(NSResponder.insertBacktab(_:)):
      if let edit = Formatting.indentList(text: text, selection: selection, outdent: true) {
        apply(edit, actionName: "Decrease Indent")
        return true
      }
    default:
      break
    }
    return false
  }

  /// Applies a formatting edit through the text view so it can be undone.
  func apply(_ edit: TextEdit, actionName: String) {
    guard textView.isEditable, NSMaxRange(edit.range) <= storage.length else {
      NSSound.beep()
      return
    }
    guard textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else {
      return
    }
    storage.replaceCharacters(in: edit.range, with: edit.replacement)
    textView.didChangeText()
    textView.undoManager?.setActionName(actionName)
    let length = storage.length
    let location = min(max(0, edit.selection.location), length)
    textView.setSelectedRange(
      NSRange(location: location, length: min(edit.selection.length, length - location)))
    textView.scrollRangeToVisible(textView.selectedRange())
  }

  // MARK: Presentation

  private func makePresentation(selection: NSRange) -> Presentation {
    presentedSelection = selection
    presentedOutline = outlineVersion
    var missing: [MathKey] = []
    let result = Presentation.make(
      text: storage.mutableString, elements: elements, selection: selection, mode: mode
    ) { replacement in
      guard let key = mathKey(for: replacement) else { return false }
      switch MathImages.shared.entry(key) {
      case .rendered: return true
      case .failed: return false
      case nil:
        missing.append(key)
        return false
      }
    }
    missing.forEach { MathImages.shared.request($0) }
    return result
  }

  /// Recomputes concealment for the current selection and updates only what changed.
  private func refreshPresentation(force: Bool = false) {
    let selection = textView.selectedRange()
    guard force || selection != presentedSelection || outlineVersion != presentedOutline else {
      updatePreview()
      return
    }
    let new = makePresentation(selection: selection)
    if new != presentation {
      let hidden = presentation.hidden
      let replacements = presentation.replacements
      apply(new, inEditing: false, extra: nil)
      invalidateConcealment(hidden: hidden, replacements: replacements)
    }
    updatePreview()
  }

  private func apply(_ new: Presentation, inEditing: Bool, extra: NSRange?, everything: Bool = false) {
    let old = presentation
    presentation = new
    replacementKeys = new.replacements.keys.sorted()
    let length = storage.length
    var range = everything
      ? NSRange(location: 0, length: length)
      : Presentation.changedRange(old: old.runs, new: new.runs, newLength: length)
    if let extra {
      range = range.map { NSUnionRange($0, extra) } ?? extra
    }
    guard let target = range, target.length > 0 else { return }
    if inEditing {
      // Changing attributes outside the typed characters would widen the edit, and AppKit
      // then moves the cursor to the end of the widened range (for example, past a closing
      // `$`). Style only the new characters now and the rest once the edit has finished.
      pendingRestyle = pendingRestyle.map { NSUnionRange($0, target) } ?? target
      if let extra { setAttributes(from: new.runs, in: NSIntersectionRange(target, extra)) }
    } else {
      storage.beginEditing()
      setAttributes(from: new.runs, in: target)
      storage.endEditing()
    }
  }

  private func setAttributes(from runs: [StyleRun], in target: NSRange) {
    guard target.length > 0 else { return }
    var runIndex = firstRun(atOrAfter: target.location, in: runs)
    while runIndex < runs.count, runs[runIndex].range.location < NSMaxRange(target) {
      let run = runs[runIndex]
      let overlap = NSIntersectionRange(run.range, target)
      if overlap.length > 0 { storage.setAttributes(attributes(for: run), range: overlap) }
      runIndex += 1
    }
  }

  /// Applies styling deferred from the last edit, once the text storage is no longer editing.
  private func flushPendingRestyle() {
    guard let pending = pendingRestyle, storage.editedMask.isEmpty else { return }
    pendingRestyle = nil
    let length = storage.length
    let target = NSIntersectionRange(pending, NSRange(location: 0, length: length))
    guard target.length > 0 else { return }
    storage.beginEditing()
    setAttributes(from: presentation.runs, in: target)
    storage.endEditing()
  }

  private func firstRun(atOrAfter location: Int, in runs: [StyleRun]) -> Int {
    var low = 0
    var high = runs.count
    while low < high {
      let mid = (low + high) / 2
      if NSMaxRange(runs[mid].range) <= location { low = mid + 1 } else { high = mid }
    }
    return low
  }

  private func invalidateConcealment(hidden: IndexSet, replacements: [Int: Replacement]) {
    var changed = hidden.symmetricDifference(presentation.hidden)
    for (key, value) in replacements where presentation.replacements[key] != value {
      changed.insert(key)
    }
    for key in presentation.replacements.keys where replacements[key] == nil { changed.insert(key) }
    guard !changed.isEmpty else { return }
    let text = storage.mutableString
    let length = text.length
    var pending: NSRange?
    for range in changed.rangeView {
      guard range.lowerBound < length else { continue }
      let clamped = NSRange(location: range.lowerBound, length: min(range.upperBound, length) - range.lowerBound)
      let paragraph = text.paragraphRange(for: clamped)
      if let current = pending, NSMaxRange(current) >= paragraph.location {
        pending = NSUnionRange(current, paragraph)
      } else {
        if let current = pending { invalidateLayout(current) }
        pending = paragraph
      }
    }
    if let current = pending { invalidateLayout(current) }
  }

  private func invalidateLayout(_ range: NSRange) {
    layout.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
    layout.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
    textView.needsDisplay = true
  }

  /// Restyles and relays out the whole document, for mode, zoom and appearance changes.
  func restyleEverything() {
    attributeCache.removeAll()
    textView.typingAttributes = plainAttributes()
    scroll.columnWidth = mode == .writing
      ? (453.5 / Engine.typstTextSize * bodySize).rounded()
      : (sourceSize * 0.61 * 92).rounded()
    presentation = Presentation()
    apply(makePresentation(selection: textView.selectedRange()), inEditing: false, extra: nil, everything: true)
    invalidateLayout(NSRange(location: 0, length: storage.length))
    updatePreview()
    updateStatus()
  }

  @objc private func mathDidRender(_ notification: Notification) {
    guard !refreshScheduled else { return }
    refreshScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.refreshScheduled = false
      self.refreshPresentation(force: true)
    }
  }

  @objc private func layoutDidChange(_ notification: Notification) { updatePreview() }

  /// Picks up colour and resolution changes that affect rendered equations.
  func refreshEnvironment() {
    let appearance = textView.effectiveAppearance
    let color = MathImages.packedColor(.textColor, appearance: appearance)
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    guard color != mathColor || scale != backingScale else { return }
    mathColor = color
    backingScale = scale
    if storage.length > 0 { restyleEverything() }
  }

  func windowDidChangeBackingProperties(_ notification: Notification) { refreshEnvironment() }

  func mathKey(for replacement: Replacement) -> MathKey? {
    guard case .math(let source, let block, let scale) = replacement else { return nil }
    return MathKey(
      source: source, block: block, emSize: Int((bodySize * scale * 100).rounded()),
      backingScale: Int((backingScale * 100).rounded()), color: mathColor)
  }

  func metrics(forReplacementAt index: Int) -> ReplacementMetrics? {
    guard index < storage.length, let replacement = presentation.replacements[index] else {
      return nil
    }
    switch replacement {
    case .text(let string):
      let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont
        ?? Typefaces.serif(size: bodySize, bold: false, italic: false)
      let drawn = NSAttributedString(
        string: string, attributes: [.font: font, .foregroundColor: NSColor.textColor])
      return ReplacementMetrics(
        content: .text(drawn),
        size: CGSize(width: drawn.size().width, height: font.ascender - font.descender),
        baseline: font.ascender)
    case .math:
      guard let key = mathKey(for: replacement),
        case .rendered(let image, let size, let baseline) = MathImages.shared.entry(key)
      else { return nil }
      return ReplacementMetrics(content: .image(image), size: size, baseline: baseline)
    }
  }

  // MARK: Attributes

  func plainAttributes() -> [NSAttributedString.Key: Any] {
    attributes(for: StyleRun(range: NSRange(), style: [], heading: 0, paragraph: ParagraphKind()))
  }

  private func attributes(for run: StyleRun) -> [NSAttributedString.Key: Any] {
    let key = AttributeKey(style: run.style, heading: run.heading, paragraph: run.paragraph)
    if let cached = attributeCache[key] { return cached }
    let style = run.style
    var result: [NSAttributedString.Key: Any] = [:]
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    var color = NSColor.textColor

    switch mode {
    case .writing:
      let size = bodySize * Presentation.headingScale(run.heading)
      let font: NSFont
      if run.paragraph.mathCard == .source {
        // Equation source inside a card's input field.
        font = Typefaces.editorMono(size: bodySize * 0.85)
        color = .labelColor
      } else if style.contains(.mathSource) {
        font = Typefaces.editorMono(size: size * 0.8)
        color = .systemIndigo
      } else if style.contains(.unsupported) || style.contains(.comment) {
        font = Typefaces.editorMono(size: size * 0.78, italic: style.contains(.comment))
        color = style.contains(.comment) ? .tertiaryLabelColor : .secondaryLabelColor
      } else if style.contains(.code) || style.contains(.rawBlock) {
        font = Typefaces.typstMono(
          size: size * 0.8, bold: style.contains(.bold), italic: style.contains(.italic))
      } else {
        font = Typefaces.serif(
          size: size, bold: style.contains(.bold) || run.heading > 0,
          italic: style.contains(.italic))
      }
      if style.contains(.marker) { color = .tertiaryLabelColor }
      result[.font] = font
      let lineSize = bodySize * Presentation.headingScale(run.paragraph.heading)
      paragraph.minimumLineHeight = (lineSize * 1.32).rounded()
      if run.paragraph.heading > 0 { paragraph.paragraphSpacingBefore = (bodySize * 0.5).rounded() }
      if run.paragraph.centered { paragraph.alignment = .center }
      if run.paragraph.mathCard == .source {
        let card = cardMetrics
        paragraph.firstLineHeadIndent = card.inset + card.fieldX
        paragraph.headIndent = card.inset + card.fieldX
        paragraph.tailIndent = -(card.inset + card.fieldX)
        paragraph.minimumLineHeight = (bodySize * 1.25).rounded()
      }
      if let prefix = run.paragraph.listPrefix {
        let body = Typefaces.serif(size: bodySize, bold: false, italic: false)
        paragraph.headIndent = (prefix as NSString).size(withAttributes: [.font: body]).width
      }
    case .source:
      let bold = style.contains(.bold) || run.heading > 0
      result[.font] = Typefaces.editorMono(
        size: sourceSize, bold: bold, italic: style.contains(.italic) || style.contains(.comment))
      if style.contains(.mathSource) {
        color = .systemIndigo
      } else if style.contains(.comment) {
        color = .secondaryLabelColor
      } else if style.contains(.unsupported) {
        color = .systemPink
      } else if style.contains(.code) || style.contains(.rawBlock) {
        color = .systemBrown
      } else if style.contains(.link) {
        color = .linkColor
      }
      if style.contains(.marker) { color = .secondaryLabelColor }
      paragraph.minimumLineHeight = (sourceSize * 1.5).rounded()
    }
    result[.foregroundColor] = color
    result[.paragraphStyle] = paragraph
    attributeCache[key] = result
    return result
  }

  // MARK: Layout

  func layoutManager(
    _ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
    properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
    characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont,
    forGlyphRange glyphRange: NSRange
  ) -> Int {
    guard concealing, !(presentation.hidden.isEmpty && presentation.replacements.isEmpty) else {
      return 0
    }
    let count = glyphRange.length
    var modified = false
    var properties = [NSLayoutManager.GlyphProperty](repeating: [], count: count)
    for i in 0..<count {
      let character = charIndexes[i]
      var property = props[i]
      if presentation.replacements[character] != nil {
        property = .controlCharacter
        modified = true
      } else if presentation.hidden.contains(character) {
        property = .null
        modified = true
      }
      properties[i] = property
    }
    guard modified else { return 0 }
    properties.withUnsafeBufferPointer {
      layoutManager.setGlyphs(
        glyphs, properties: $0.baseAddress!, characterIndexes: charIndexes, font: aFont,
        forGlyphRange: glyphRange)
    }
    return count
  }

  func layoutManager(
    _ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
    forControlCharacterAt charIndex: Int
  ) -> NSLayoutManager.ControlCharacterAction {
    if concealing, presentation.replacements[charIndex] != nil { return .whitespace }
    return action
  }

  func layoutManager(
    _ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int,
    for textContainer: NSTextContainer, proposedLineFragment proposedRect: NSRect,
    glyphPosition: NSPoint, characterIndex charIndex: Int
  ) -> NSRect {
    guard concealing, let metrics = metrics(forReplacementAt: charIndex) else { return .zero }
    return NSRect(
      x: glyphPosition.x, y: glyphPosition.y - metrics.baseline, width: metrics.size.width,
      height: metrics.size.height)
  }

  func layoutManager(
    _ layoutManager: NSLayoutManager,
    shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
    lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
    baselineOffset: UnsafeMutablePointer<CGFloat>, in textContainer: NSTextContainer,
    forGlyphRange glyphRange: NSRange
  ) -> Bool {
    let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    guard characters.length > 0, NSMaxRange(characters) <= storage.length else { return false }
    var extraTop: CGFloat = 0
    var extraBottom: CGFloat = 0
    // Leave room under the equation being edited for its preview.
    if let line = previewLine, previewSpace > 0, NSLocationInRange(NSMaxRange(line) - 1, characters) {
      extraBottom += previewSpace
    }
    var ascent = baselineOffset.pointee
    var descent = lineFragmentRect.pointee.height - ascent
    var changed = false
    if concealing {
      let keys = replacementKeys
      var keyIndex = keys.lowerBound(characters.location)
      if keyIndex >= keys.count || keys[keyIndex] >= NSMaxRange(characters),
        isConcealedLine(characters)
      {
        // Collapse lines that contain nothing but concealed markup, such as code fences.
        lineFragmentRect.pointee.size.height = 0
        lineFragmentUsedRect.pointee.size.height = 0
        baselineOffset.pointee = 0
        return true
      }
      while keyIndex < keys.count, keys[keyIndex] < NSMaxRange(characters) {
        let key = keys[keyIndex]
        keyIndex += 1
        guard let metrics = metrics(forReplacementAt: key) else { continue }
        if metrics.baseline > ascent {
          ascent = metrics.baseline
          changed = true
        }
        if metrics.size.height - metrics.baseline > descent {
          descent = metrics.size.height - metrics.baseline
          changed = true
        }
      }
      // Display equations sit in cards with padding around the equation or its source field.
      if let block = mathBlock(containing: characters.location) {
        let card = cardMetrics
        if block.rendered {
          extraTop += card.gap + card.pad
          extraBottom += card.pad + card.caption + card.gap
        } else {
          if NSLocationInRange(block.lines.location, characters) {
            extraTop += card.gap + card.pad + card.field
          }
          if NSLocationInRange(NSMaxRange(block.lines) - 1, characters) {
            extraBottom += card.field + card.pad + card.gap
          }
        }
      }
    }
    guard changed || extraTop > 0 || extraBottom > 0 else { return false }
    let content = (ascent + descent).rounded(.up)
    lineFragmentRect.pointee.size.height = content + extraTop + extraBottom
    // The used rect covers only the text, which keeps the cursor and selection text-sized.
    lineFragmentUsedRect.pointee.origin.y = lineFragmentRect.pointee.minY + extraTop
    lineFragmentUsedRect.pointee.size.height = content
    baselineOffset.pointee = ascent + extraTop
    return true
  }

  /// Whether every character of a line, apart from its newline, is concealed markup.
  private func isConcealedLine(_ characters: NSRange) -> Bool {
    let hidden = presentation.hidden
    guard !hidden.isEmpty else { return false }
    let end = NSMaxRange(characters)
    let lastIsNewline = storage.mutableString.character(at: end - 1) == 0x0A
    let checkedEnd = lastIsNewline && characters.length > 1 ? end - 1 : end
    return hidden.contains(integersIn: characters.location..<checkedEnd)
  }

  // MARK: Equation cards

  struct CardMetrics {
    /// Space between the card and the text around it.
    var gap: CGFloat
    /// Space between the card's edge and its content.
    var pad: CGFloat
    /// Extra space under a rendered equation for the edit hint.
    var caption: CGFloat
    /// Horizontal space between the card's edge and the source field.
    var inset: CGFloat
    /// Space between the source field's border and the text inside it.
    var field: CGFloat
    var fieldX: CGFloat
    var previewGap: CGFloat
  }

  var cardMetrics: CardMetrics {
    let em = bodySize
    return CardMetrics(
      gap: (em * 0.45).rounded(), pad: (em * 0.8).rounded(), caption: (em * 0.45).rounded(),
      inset: (em * 0.9).rounded(), field: (em * 0.55).rounded(), fieldX: (em * 0.7).rounded(),
      previewGap: (em * 0.7).rounded())
  }

  private var hoveredBlock: Int?

  func mathBlock(containing location: Int) -> MathBlock? {
    let blocks = presentation.mathBlocks
    var low = 0
    var high = blocks.count
    while low < high {
      let mid = (low + high) / 2
      if NSMaxRange(blocks[mid].lines) <= location { low = mid + 1 } else { high = mid }
    }
    guard low < blocks.count, NSLocationInRange(location, blocks[low].lines) else { return nil }
    return blocks[low]
  }

  /// The card and, for equations shown as source, the input field, in text container coordinates.
  private func cardGeometry(_ block: MathBlock) -> (card: NSRect, field: NSRect?)? {
    guard NSMaxRange(block.lines) <= storage.length, block.lines.length > 0 else { return nil }
    let first = layout.lineFragmentRect(
      forGlyphAt: layout.glyphIndexForCharacter(at: block.lines.location), effectiveRange: nil)
    let last = layout.lineFragmentRect(
      forGlyphAt: layout.glyphIndexForCharacter(at: NSMaxRange(block.lines) - 1), effectiveRange: nil)
    let metrics = cardMetrics
    let width = container.size.width
    let card = NSRect(
      x: 0, y: first.minY + metrics.gap, width: width,
      height: max(0, last.maxY - metrics.gap - first.minY - metrics.gap))
    guard !block.rendered else { return (card, nil) }
    var bottom = last.maxY - metrics.gap - metrics.pad
    if let line = previewLine, previewSpace > 0, NSLocationInRange(NSMaxRange(line) - 1, block.lines) {
      bottom -= previewSpace
    }
    let top = first.minY + metrics.gap + metrics.pad
    let field = NSRect(
      x: metrics.inset, y: top, width: max(0, width - metrics.inset * 2), height: max(0, bottom - top))
    return (card, field)
  }

  /// Draws equation cards and highlights behind inline equation source.
  func drawDecorations(forGlyphRange glyphs: NSRange, at origin: NSPoint) {
    guard concealing else { return }
    let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    let accent = NSColor.controlAccentColor
    let em = bodySize
    for block in presentation.mathBlocks where NSIntersectionRange(block.lines, characters).length > 0 {
      guard let geometry = cardGeometry(block) else { continue }
      let card = geometry.card.offsetBy(dx: origin.x, dy: origin.y)
      let hovered = hoveredBlock == block.range.location
      let path = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: em * 0.55, yRadius: em * 0.55)
      accent.withAlphaComponent(block.active ? 0.07 : hovered ? 0.08 : 0.045).setFill()
      path.fill()
      accent.withAlphaComponent(block.active || hovered ? 0.45 : 0.22).setStroke()
      path.lineWidth = 1
      path.stroke()
      if let field = geometry.field?.offsetBy(dx: origin.x, dy: origin.y) {
        let fieldPath = NSBezierPath(roundedRect: field, xRadius: em * 0.35, yRadius: em * 0.35)
        NSColor.textBackgroundColor.setFill()
        fieldPath.fill()
        if block.active {
          fieldPath.lineWidth = 2
          accent.setStroke()
        } else {
          fieldPath.lineWidth = 1
          NSColor.separatorColor.setStroke()
        }
        fieldPath.stroke()
      } else if hovered {
        let caption = NSAttributedString(
          string: "Click to edit",
          attributes: [
            .font: NSFont.systemFont(ofSize: max(10, em * 0.62)),
            .foregroundColor: NSColor.secondaryLabelColor,
          ])
        let size = caption.size()
        caption.draw(at: NSPoint(x: card.maxX - size.width - em * 0.8, y: card.maxY - size.height - em * 0.35))
      }
    }
    for range in presentation.inlineMathSources where NSIntersectionRange(range, characters).length > 0 {
      let glyphRange = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      layout.enumerateEnclosingRects(
        forGlyphRange: glyphRange, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
        in: container
      ) { rect, _ in
        let pill = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -3, dy: 1)
        accent.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
      }
    }
  }

  /// Places the cursor in an equation when its card is clicked outside the source field.
  func handleClick(at point: NSPoint, event: NSEvent) -> Bool {
    guard concealing, event.clickCount == 1, event.modifierFlags.intersection([.shift, .command]).isEmpty,
      let block = block(at: point)
    else { return false }
    if let field = cardGeometry(block)?.field?.offsetBy(
      dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y), field.contains(point)
    {
      return false
    }
    // Put the cursor at the end of the equation's content, before its closing dollar sign.
    let text = storage.mutableString
    var end = NSMaxRange(block.range) - 1
    while end > block.range.location + 1, [0x20, 0x09, 0x0A].contains(text.character(at: end - 1)) {
      end -= 1
    }
    window?.makeFirstResponder(textView)
    textView.setSelectedRange(NSRange(location: end, length: 0))
    return true
  }

  private func block(at point: NSPoint) -> MathBlock? {
    let origin = textView.textContainerOrigin
    let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
    guard local.y >= 0 else { return nil }
    let glyph = layout.glyphIndex(for: local, in: container)
    guard glyph < layout.numberOfGlyphs else { return nil }
    let character = layout.characterIndexForGlyph(at: glyph)
    for candidate in [character, character - 1, character + 1] where candidate >= 0 {
      if let block = mathBlock(containing: candidate), let card = cardGeometry(block)?.card,
        card.contains(local)
      {
        return block
      }
    }
    return nil
  }

  func mouseMoved(to point: NSPoint?) {
    let block = point.flatMap { self.block(at: $0) }
    let hovered = block.flatMap { $0.rendered ? $0.range.location : nil }
    if hovered != nil { NSCursor.pointingHand.set() }
    guard hovered != hoveredBlock else { return }
    hoveredBlock = hovered
    textView.needsDisplay = true
  }

  // MARK: Equation preview

  func updatePreview() {
    guard let math = presentation.activeMath, NSMaxRange(math.range) <= storage.length,
      math.range.length > 0, window?.firstResponder === textView,
      textView.selectedRange().length == 0
    else {
      preview.isHidden = true
      reservePreviewSpace(nil, height: 0)
      return
    }
    let source = storage.mutableString.substring(with: math.range)
    guard let key = mathKey(for: .math(source: source, block: math.block, scale: 1)) else { return }
    var image: NSImage?
    var message: String?
    var isError = false
    switch MathImages.shared.request(key) {
    case .rendered(let rendered, _, _):
      image = rendered
      lastPreview = (math.range.location, rendered)
    case .failed(let error):
      message = error
      isError = !error.contains("empty")
      if !isError { message = "Type an equation between the dollar signs." }
    case nil:
      if let last = lastPreview, last.location == math.range.location {
        image = last.image
      } else {
        message = "Rendering…"
      }
    }
    let maxWidth = max(160, container.size.width)
    let origin = textView.textContainerOrigin
    if let block = mathBlock(containing: math.range.location), block.range == math.range {
      // Inside a card, the preview sits centred under the source field.
      preview.isEmbedded = true
      let metrics = cardMetrics
      let size = preview.show(
        image: image, text: message, isError: isError, maxWidth: maxWidth - metrics.inset * 2)
      let line = storage.mutableString.lineRange(
        for: NSRange(location: NSMaxRange(block.lines) - 1, length: 0))
      reservePreviewSpace(line, height: size.height + metrics.previewGap)
      guard let field = cardGeometry(block)?.field else { return }
      preview.frame = NSRect(
        x: origin.x + ((container.size.width - size.width) / 2).rounded(),
        y: origin.y + field.maxY + (metrics.previewGap / 2).rounded(), width: size.width,
        height: size.height)
      preview.isHidden = false
      preview.needsDisplay = true
      return
    }
    preview.isEmbedded = false
    let size = preview.show(image: image, text: message, isError: isError, maxWidth: maxWidth)
    let line = storage.mutableString.lineRange(
      for: NSRange(location: max(math.range.location, NSMaxRange(math.range) - 1), length: 0))
    reservePreviewSpace(line, height: size.height + 14)
    let glyphs = layout.glyphRange(forCharacterRange: math.range, actualCharacterRange: nil)
    let bounds = layout.boundingRect(forGlyphRange: glyphs, in: container)
    let lastGlyph = max(glyphs.location, NSMaxRange(glyphs) - 1)
    let used = layout.lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil)
    var x = origin.x + bounds.minX
    x = min(x, origin.x + container.size.width - size.width)
    x = max(origin.x, x)
    preview.frame = NSRect(x: x, y: origin.y + used.maxY + 4, width: size.width, height: size.height)
    preview.isHidden = false
    preview.needsDisplay = true
  }

  private func reservePreviewSpace(_ line: NSRange?, height: CGFloat) {
    guard line != previewLine || abs(height - previewSpace) > 0.5 else { return }
    let old = previewLine
    previewLine = line
    previewSpace = line == nil ? 0 : height
    for range in [old, line].compactMap({ $0 }) where NSMaxRange(range) <= storage.length {
      layout.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
    }
    textView.needsDisplay = true
  }


  // MARK: Compilation and status

  func scheduleCompile(delay: TimeInterval = 0.35) {
    compileGeneration += 1
    let generation = compileGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self, generation == self.compileGeneration else { return }
      let text = self.text
      Self.engineQueue.async {
        let result = Engine.compile(text, pdf: false)
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            guard generation == self.compileGeneration else { return }
            self.showCompileResult(result, for: text)
          }
        }
      }
    }
  }

  private func showCompileResult(_ result: CompileResult, for text: String) {
    lastCompiledText = text
    diagnostics = result.diagnostics
    pages = result.pages
    wordCount = Formatting.wordCount(text)
    let full = NSRange(location: 0, length: storage.length)
    layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
    layout.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
    if text == self.text {
      for diagnostic in diagnostics {
        guard var range = diagnostic.range, storage.length > 0 else { continue }
        range.location = min(range.location, storage.length - 1)
        range.length = max(1, min(range.length, storage.length - range.location))
        layout.addTemporaryAttributes(
          [
            .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
            .underlineColor: diagnostic.isError ? NSColor.systemRed : NSColor.systemOrange,
          ], forCharacterRange: range)
      }
    }
    updateStatus()
  }

  func updateStatus() {
    guard statusVisible else { return }
    let selection = textView.selectedRange()
    let place = index.position(min(selection.location, storage.length))
    position.stringValue = "Ln \(place.line), Col \(place.column)"
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
    var parts: [String] = []
    parts.append("\(wordCount) \(wordCount == 1 ? "word" : "words")")
    if errors == 0, lastCompiledText != nil {
      parts.append("\(pages) \(pages == 1 ? "page" : "pages")")
    }
    if let file = note?.file {
      if file.lineEnding != .lf { parts.append(file.lineEnding.displayName) }
      if file.encoding != .utf8 { parts.append(file.encoding.displayName) }
    }
    parts.append("\(zoomPercent)%")
    details.stringValue = parts.joined(separator: "   ")
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
    for diagnostic in diagnostics {
      var title = diagnostic.message
      if let range = diagnostic.range {
        title = "Ln \(index.position(min(range.location, storage.length)).line): " + title
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
      NSMaxRange(range) <= storage.length
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
  private var viewGroup: NSToolbarItemGroup?

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.flexibleSpace, Self.viewItem]
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
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
    group.toolTip = "Switch between Writing and Source"
    group.subitems[0].toolTip = "Writing — formatted text and rendered math (⌘1)"
    group.subitems[1].toolTip = "Source — the Typst file exactly as saved (⌘2)"
    group.selectedIndex = EditorMode.allCases.firstIndex(of: mode) ?? 0
    viewGroup = group
    return group
  }

  @objc private func changeView(_ sender: NSToolbarItemGroup) {
    guard EditorMode.allCases.indices.contains(sender.selectedIndex) else { return }
    setMode(EditorMode.allCases[sender.selectedIndex])
    window?.makeFirstResponder(textView)
  }

  func setMode(_ newMode: EditorMode) {
    guard newMode != mode else { return }
    let selection = textView.selectedRange()
    mode = newMode
    viewGroup?.selectedIndex = EditorMode.allCases.firstIndex(of: newMode) ?? 0
    restyleEverything()
    textView.setSelectedRange(selection)
    textView.scrollRangeToVisible(selection)
  }

  @objc func showWriting(_ sender: Any?) { setMode(.writing) }
  @objc func showSource(_ sender: Any?) { setMode(.source) }

  private var editableText: NSString { storage.mutableString }

  @objc func toggleBold(_ sender: Any?) { toggle(.strong, name: "Bold") }
  @objc func toggleItalic(_ sender: Any?) { toggle(.emph, name: "Italic") }
  @objc func toggleCode(_ sender: Any?) { toggle(.code, name: "Code") }

  private func toggle(_ inline: Formatting.Inline, name: String) {
    apply(
      Formatting.toggle(
        inline, text: editableText, selection: textView.selectedRange(), elements: elements),
      actionName: name)
  }

  @objc func makeHeading(_ sender: NSMenuItem) {
    apply(
      Formatting.setHeading(
        level: sender.tag, text: editableText, selection: textView.selectedRange()),
      actionName: sender.tag == 0 ? "Body Text" : "Heading")
  }

  @objc func toggleBulletedList(_ sender: Any?) {
    apply(
      Formatting.toggleList(.bullet, text: editableText, selection: textView.selectedRange()),
      actionName: "Bulleted List")
  }

  @objc func toggleNumberedList(_ sender: Any?) {
    apply(
      Formatting.toggleList(.numbered, text: editableText, selection: textView.selectedRange()),
      actionName: "Numbered List")
  }

  @objc func insertInlineEquation(_ sender: Any?) {
    apply(
      Formatting.insertEquation(
        block: false, text: editableText, selection: textView.selectedRange()),
      actionName: "Equation")
  }

  @objc func insertDisplayEquation(_ sender: Any?) {
    apply(
      Formatting.insertEquation(
        block: true, text: editableText, selection: textView.selectedRange()),
      actionName: "Display Equation")
  }

  @objc func increaseIndent(_ sender: Any?) { indent(outdent: false) }
  @objc func decreaseIndent(_ sender: Any?) { indent(outdent: true) }

  private func indent(outdent: Bool) {
    guard let edit = Formatting.indentList(
      text: editableText, selection: textView.selectedRange(), outdent: outdent)
    else {
      NSSound.beep()
      return
    }
    apply(edit, actionName: outdent ? "Decrease Indent" : "Increase Indent")
  }

  @objc func zoomIn(_ sender: Any?) { setZoom(zoomPercent + 10) }
  @objc func zoomOut(_ sender: Any?) { setZoom(zoomPercent - 10) }
  @objc func zoomReset(_ sender: Any?) { setZoom(100) }

  func setZoom(_ percent: Int) {
    let clamped = min(400, max(50, percent))
    guard clamped != zoomPercent else { return }
    zoomPercent = clamped
    restyleEverything()
    textView.scrollRangeToVisible(textView.selectedRange())
  }

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
    let field = NSTextField(string: String(index.position(textView.selectedRange().location).line))
    field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    guard let line = Int(field.stringValue), line > 0, line <= index.starts.count else {
      NSSound.beep()
      return
    }
    let range = NSRange(location: index.starts[line - 1], length: 0)
    textView.setSelectedRange(range)
    textView.scrollRangeToVisible(range)
  }

  @objc private func defaultsDidChange(_ notification: Notification) {
    setStatusVisible(UserDefaults.standard.bool(forKey: PreferenceKey.status))
    textView.isContinuousSpellCheckingEnabled = UserDefaults.standard.bool(
      forKey: PreferenceKey.checkSpelling)
    updateWritingToolsBehavior()
    DispatchQueue.main.async { [weak self] in self?.refreshEnvironment() }
  }

  private func updateWritingToolsBehavior() {
    if #available(macOS 15.0, *) {
      textView.allowedWritingToolsResultOptions = .plainText
    }
    if #available(macOS 15.2, *) {
      textView.writingToolsBehavior = AppPreferences.writingToolsEnabled ? .default : .none
    } else if #available(macOS 15.0, *) {
      textView.writingToolsBehavior = .none
    }
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(showWriting(_:)):
      menuItem.state = mode == .writing ? .on : .off
    case #selector(showSource(_:)):
      menuItem.state = mode == .source ? .on : .off
    case #selector(toggleStatus(_:)):
      menuItem.state = statusVisible ? .on : .off
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

extension WritingTextView {
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    editor?.refreshEnvironment()
  }
}
