import AppKit
import PlainstCore

/// What an app hosting a ``TypstEditor`` hears about as the user works.
@MainActor
public protocol TypstEditorDelegate: AnyObject {
  /// The text changed because of an edit, not because new text was loaded.
  func typstEditorTextDidChange(_ editor: TypstEditor)
  /// The cursor or selection moved, including while text is typed.
  func typstEditorSelectionDidChange(_ editor: TypstEditor)
  /// The mode, zoom or configuration changed and the text was restyled.
  func typstEditorDisplayDidChange(_ editor: TypstEditor)
  /// Typst finished compiling the text. `pages` is nil unless ``TypstEditor/collectsPages`` was set.
  func typstEditor(_ editor: TypstEditor, didCompile result: CompileResult, pages: [PreviewPage]?)
  /// The undo manager for edits, such as a document's.
  func undoManager(for editor: TypstEditor) -> UndoManager?
}

extension TypstEditorDelegate {
  public func typstEditorTextDidChange(_ editor: TypstEditor) {}
  public func typstEditorSelectionDidChange(_ editor: TypstEditor) {}
  public func typstEditorDisplayDidChange(_ editor: TypstEditor) {}
  public func typstEditor(_ editor: TypstEditor, didCompile result: CompileResult, pages: [PreviewPage]?) {}
  public func undoManager(for editor: TypstEditor) -> UndoManager? { nil }
}

/// Options an app chooses for a ``TypstEditor``.
public struct TypstEditorConfiguration: Equatable, Sendable {
  /// How large Writing text appears at 100% zoom, relative to Typst's proportions.
  public var writingSize: CGFloat
  /// The Source view's font family, or an empty string for the system monospaced font.
  public var sourceFontName: String
  public var sourceFontSize: CGFloat
  /// Suggest Typst completions while typing.
  public var completions: Bool
  /// Pair brackets, quotes and markup, and wrap selections.
  public var autoPair: Bool
  /// Show a rendering below the equation being edited.
  public var equationPreviews: Bool
  public var checkSpelling: Bool
  /// Allow Apple Writing Tools, limited to plain text.
  public var writingTools: Bool
  /// Columns per indentation level, used by Tab, list nesting, and tab characters.
  public var tabWidth: Int
  /// Draw a faint line at each indentation level of indented lines.
  public var showsIndentGuides: Bool

  public init(
    writingSize: CGFloat = 1, sourceFontName: String = "", sourceFontSize: CGFloat = 13,
    completions: Bool = true, autoPair: Bool = true, equationPreviews: Bool = true,
    checkSpelling: Bool = false, writingTools: Bool = false, tabWidth: Int = 4,
    showsIndentGuides: Bool = true
  ) {
    self.writingSize = writingSize
    self.sourceFontName = sourceFontName
    self.sourceFontSize = sourceFontSize
    self.completions = completions
    self.autoPair = autoPair
    self.equationPreviews = equationPreviews
    self.checkSpelling = checkSpelling
    self.writingTools = writingTools
    self.tabWidth = max(1, tabWidth)
    self.showsIndentGuides = showsIndentGuides
  }
}

/// A Typst text editor: a text view that shows formatting and rendered math while writing,
/// or the exact source, with Typst's completions, diagnostics and typing assistance.
///
/// Add ``scrollView`` to a window and set ``delegate`` to follow changes. The editor never
/// changes the text except through the user's edits and the commands it is sent.
@MainActor
public final class TypstEditor: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate,
  @preconcurrency NSLayoutManagerDelegate, ReplacementSource
{
  public weak var delegate: TypstEditorDelegate?
  let storage = NSTextStorage()
  let layout = WritingLayoutManager()
  let container = NSTextContainer()
  public let textView: TypstTextView
  /// The scrolling view to place in a window; it keeps the text in a centred column.
  public let scrollView = TypstScrollView()
  let preview = MathPreviewView()
  /// Compilation runs here, one document at a time.
  public static let engineQueue = DispatchQueue(label: "io.github.PoteNad.plainst.compile", qos: .utility)

  public var configuration: TypstEditorConfiguration {
    didSet {
      guard configuration != oldValue else { return }
      applyConfiguration(restyle: true)
    }
  }
  public private(set) var mode: EditorMode
  public private(set) var zoomPercent = 100
  /// Also collect page sizes after each compile, for a preview of the typeset document.
  public var collectsPages = false

  public private(set) var elements: [OutlineElement] = []
  private(set) var presentation = Presentation()
  private(set) var replacementKeys: [Int] = []
  public private(set) var diagnostics: [Diagnostic] = []
  public private(set) var pageCount = 0
  /// The text of the last compile, or nil before the first one finishes.
  public private(set) var lastCompiledText: String?
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
  /// Changes whenever ``elements`` changes.
  public private(set) var outlineVersion = 0
  private var presentedOutline = -1
  private var presentedSelection = NSRange(location: NSNotFound, length: 0)
  /// The line under which the equation preview is shown, and the space reserved for it.
  private var previewLine: NSRange?
  private var previewSpace: CGFloat = 0
  public private(set) var wordCount = 0
  /// Identifies this editor's compiled document in the engine, for label completions and
  /// preview pages.
  public let engineKey: UInt64 = {
    TypstEditor.nextEngineKey += 1
    return TypstEditor.nextEngineKey
  }()
  private static var nextEngineKey: UInt64 = 0
  /// The bracket beside the cursor and its partner, while highlighted.
  var highlightedBrackets: (NSRange, NSRange)?
  /// Problems drawn at the end of their lines, one per line, once typing pauses.
  private(set) var annotations: [Annotation] = []

  struct Annotation {
    var location: Int
    var diagnostic: Diagnostic
    var extra: Int
  }
  /// Completions, snippet placeholders and automatic pairs.
  lazy var assistant = TypingAssistant(editor: self)
  /// The text most recently typed, so completions know what triggered a change.
  var lastTyped: String?

  var concealing: Bool { mode == .writing }
  /// View points per Typst point, so the Writing view keeps the PDF's proportions.
  var typstScale: CGFloat { 1.5 * configuration.writingSize * CGFloat(zoomPercent) / 100 }
  var bodySize: CGFloat { Engine.typstTextSize * typstScale }
  var sourceSize: CGFloat { configuration.sourceFontSize * CGFloat(zoomPercent) / 100 }

  private struct AttributeKey: Hashable {
    var style: TextStyle
    var heading: Int
    var paragraph: ParagraphKind
  }

  public init(
    text: String = "", mode: EditorMode = .writing, configuration: TypstEditorConfiguration = .init()
  ) {
    self.mode = mode
    self.configuration = configuration
    storage.addLayoutManager(layout)
    layout.addTextContainer(container)
    textView = TypstTextView(
      frame: NSRect(x: 0, y: 0, width: 900, height: 640), textContainer: container)
    super.init()
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
    applyConfiguration(restyle: false)
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

    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = true
    scrollView.backgroundColor = .textBackgroundColor
    scrollView.documentView = textView
    refreshEnvironment()
    loadText(text)
    NotificationCenter.default.addObserver(
      self, selector: #selector(mathDidRender), name: MathImages.didRender, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(layoutDidChange), name: NSView.frameDidChangeNotification,
      object: textView)
  }

  deinit { Engine.forget(key: engineKey) }

  private func applyConfiguration(restyle: Bool) {
    textView.isContinuousSpellCheckingEnabled = configuration.checkSpelling
    if #available(macOS 15.0, *) {
      textView.allowedWritingToolsResultOptions = .plainText
    }
    if #available(macOS 15.2, *) {
      textView.writingToolsBehavior = configuration.writingTools ? .default : .none
    } else if #available(macOS 15.0, *) {
      textView.writingToolsBehavior = .none
    }
    guard restyle else { return }
    if !configuration.autoPair || !configuration.completions { assistant.dismiss() }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.refreshEnvironment()
      // Text sizes and the Source font may have changed.
      self.restyleEverything()
    }
  }

  // MARK: Text

  /// Replaces the text without recording an undo action, and puts the cursor at the start.
  public func loadText(_ text: String) {
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
  public var text: String { storage.mutableString.copy() as! String }

  public func textStorage(
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

  public func textStorage(
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

  public func undoManager(for view: NSTextView) -> UndoManager? { delegate?.undoManager(for: self) }

  public func textView(
    _ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?
  ) -> Bool {
    if let replacementString {
      assistant.textWillChange(
        range: affectedCharRange, replacementLength: (replacementString as NSString).length)
    }
    return true
  }

  public func textDidChange(_ notification: Notification) {
    flushPendingRestyle()
    if let pending = pendingConcealment {
      pendingConcealment = nil
      invalidateConcealment(hidden: pending.hidden, replacements: pending.replacements)
    }
    updatePreview()
    clearAnnotations()
    scheduleCompile()
    let typed = lastTyped
    lastTyped = nil
    assistant.textDidChange(typed: typed)
    delegate?.typstEditorTextDidChange(self)
  }

  public func textViewDidChangeSelection(_ notification: Notification) {
    if !storage.editedMask.isEmpty {
      DispatchQueue.main.async { [weak self] in self?.selectionChanged() }
    } else {
      selectionChanged()
    }
  }

  /// True while AppKit tracks a mouse press in the text view.
  var isTrackingMouse = false

  func selectionChanged() {
    flushPendingRestyle()
    delegate?.typstEditorSelectionDidChange(self)
    // Changing layout under the pointer during a click, double-click or drag makes AppKit
    // select the wrong text, so wait until the button is released.
    assistant.selectionDidChange()
    guard !textView.hasMarkedText(), !isTrackingMouse else { return }
    refreshPresentation()
    updateBracketHighlight()
  }

  public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    if assistant.handleCommand(commandSelector) { return true }
    if commandSelector == #selector(NSResponder.deleteBackward(_:)), assistant.handleDeleteBackward() {
      return true
    }
    let selection = textView.selectedRange()
    let inCode = elements.contains {
      ($0.kind == .raw || $0.kind == .math) && $0.range.location < selection.location
        && selection.location < NSMaxRange($0.range)
    }
    let text = storage.mutableString as NSString
    // Tab indents by the configured width everywhere, including equations and code.
    switch commandSelector {
    case #selector(NSResponder.insertTab(_:)):
      let spansLines = text.substring(with: selection).contains("\n")
      if !inCode, !spansLines,
        let edit = Formatting.indentList(
          text: text, selection: selection, outdent: false, width: configuration.tabWidth)
      {
        apply(edit, actionName: "Increase Indent")
      } else if spansLines {
        indent(outdent: false)
      } else {
        apply(Formatting.softTab(text: text, selection: selection, width: configuration.tabWidth), actionName: "Typing")
      }
      return true
    case #selector(NSResponder.insertBacktab(_:)):
      indent(outdent: true)
      return true
    default:
      break
    }
    guard !inCode else { return false }
    switch commandSelector {
    case #selector(NSResponder.insertNewline(_:)):
      if let edit = Formatting.newline(text: text, selection: selection) {
        apply(edit, actionName: "Typing")
        return true
      }
    default:
      break
    }
    return false
  }

  /// Applies an edit through the text view so it can be undone.
  public func apply(_ edit: TextEdit, actionName: String) {
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
    scrollView.columnWidth = mode == .writing
      ? (453.5 / Engine.typstTextSize * bodySize).rounded()
      : (sourceSize * 0.61 * 92).rounded()
    presentation = Presentation()
    apply(makePresentation(selection: textView.selectedRange()), inEditing: false, extra: nil, everything: true)
    invalidateLayout(NSRange(location: 0, length: storage.length))
    updatePreview()
    delegate?.typstEditorDisplayDidChange(self)
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
    let scale = textView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    guard color != mathColor || scale != backingScale else { return }
    mathColor = color
    backingScale = scale
    if storage.length > 0 { restyleEverything() }
  }


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
        font = Typefaces.editorMono(family: configuration.sourceFontName, size: bodySize * 0.85)
        color = .labelColor
      } else if style.contains(.mathSource) {
        font = Typefaces.editorMono(family: configuration.sourceFontName, size: size * 0.8)
        color = .systemIndigo
      } else if style.contains(.label) {
        // Labels stay visible but quiet, like a tag on the element before them.
        font = Typefaces.editorMono(family: configuration.sourceFontName, size: size * 0.7)
        color = .tertiaryLabelColor
      } else if style.contains(.unsupported) || style.contains(.comment) {
        font = Typefaces.editorMono(family: configuration.sourceFontName, size: size * 0.78, italic: style.contains(.comment))
        color = style.contains(.comment) ? .tertiaryLabelColor : .secondaryLabelColor
      } else if style.contains(.code) || style.contains(.rawBlock) {
        font = Typefaces.typstMono(
          size: size * 0.8, bold: style.contains(.bold), italic: style.contains(.italic))
      } else {
        font = Typefaces.serif(
          size: size, bold: style.contains(.bold) || run.heading > 0,
          italic: style.contains(.italic))
      }
      if style.contains(.reference) { color = .linkColor }
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
        family: configuration.sourceFontName, size: sourceSize, bold: bold, italic: style.contains(.italic) || style.contains(.comment))
      if style.contains(.mathSource) {
        color = .systemIndigo
      } else if style.contains(.comment) {
        color = .secondaryLabelColor
      } else if style.contains(.unsupported) {
        color = .systemPink
      } else if style.contains(.code) || style.contains(.rawBlock) {
        color = .systemBrown
      } else if style.contains(.link) || style.contains(.reference) {
        color = .linkColor
      } else if style.contains(.label) {
        color = .systemTeal
      }
      if style.contains(.marker) { color = .secondaryLabelColor }
      paragraph.minimumLineHeight = (sourceSize * 1.5).rounded()
    }
    // Tab characters line up with the indentation width. The width comes from the paragraph's
    // font, not this run's, so every run in a paragraph shares one paragraph style.
    let paragraphFont: NSFont
    switch mode {
    case .source:
      paragraphFont = Typefaces.editorMono(family: configuration.sourceFontName, size: sourceSize)
    case .writing where run.paragraph.rawBlock || run.paragraph.mathCard == .source:
      paragraphFont = Typefaces.editorMono(family: configuration.sourceFontName, size: bodySize * 0.8)
    case .writing:
      paragraphFont = Typefaces.serif(
        size: bodySize * Presentation.headingScale(run.paragraph.heading), bold: false, italic: false)
    }
    paragraph.tabStops = []
    paragraph.defaultTabInterval =
      (" " as NSString).size(withAttributes: [.font: paragraphFont]).width * CGFloat(configuration.tabWidth)
    result[.foregroundColor] = color
    result[.paragraphStyle] = paragraph
    attributeCache[key] = result
    return result
  }

  // MARK: Layout

  public func layoutManager(
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

  public func layoutManager(
    _ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
    forControlCharacterAt charIndex: Int
  ) -> NSLayoutManager.ControlCharacterAction {
    if concealing, presentation.replacements[charIndex] != nil { return .whitespace }
    return action
  }

  public func layoutManager(
    _ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int,
    for textContainer: NSTextContainer, proposedLineFragment proposedRect: NSRect,
    glyphPosition: NSPoint, characterIndex charIndex: Int
  ) -> NSRect {
    guard concealing, let metrics = metrics(forReplacementAt: charIndex) else { return .zero }
    return NSRect(
      x: glyphPosition.x, y: glyphPosition.y - metrics.baseline, width: metrics.size.width,
      height: metrics.size.height)
  }

  public func layoutManager(
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
          // A rendered display equation reads like typeset math, with room for its hover highlight.
          extraTop += card.gap + card.caption
          extraBottom += card.gap + card.caption
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

  private var hoveredMath: Int?

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

  /// Draws the source card of an equation being edited, highlights behind inline equation
  /// source, and a quiet highlight on the rendered equation under the pointer.
  func drawDecorations(forGlyphRange glyphs: NSRange, at origin: NSPoint) {
    drawIndentGuides(forCharacters: layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil), at: origin)
    drawAnnotations(forCharacters: layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
    guard concealing else { return }
    let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    let accent = NSColor.controlAccentColor
    let em = bodySize
    for block in presentation.mathBlocks
    where !block.rendered && NSIntersectionRange(block.lines, characters).length > 0 {
      guard let geometry = cardGeometry(block) else { continue }
      let card = geometry.card.offsetBy(dx: origin.x, dy: origin.y)
      let path = NSBezierPath(
        roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: em * 0.55, yRadius: em * 0.55)
      accent.withAlphaComponent(block.active ? 0.07 : 0.045).setFill()
      path.fill()
      accent.withAlphaComponent(block.active ? 0.45 : 0.22).setStroke()
      path.lineWidth = 1
      path.stroke()
      if let field = geometry.field?.offsetBy(dx: origin.x, dy: origin.y) {
        let fieldPath = NSBezierPath(roundedRect: field, xRadius: em * 0.35, yRadius: em * 0.35)
        NSColor.textBackgroundColor.setFill()
        fieldPath.fill()
        fieldPath.lineWidth = block.active ? 2 : 1
        (block.active ? accent : NSColor.separatorColor).setStroke()
        fieldPath.stroke()
      }
    }
    if let hovered = hoveredMath, NSLocationInRange(hovered, characters),
      var rect = renderedMathRect(at: hovered)
    {
      rect = rect.offsetBy(dx: origin.x, dy: origin.y)
      let isBlock = mathBlock(containing: hovered)?.range.location == hovered
      let highlight = rect.insetBy(dx: -em * (isBlock ? 0.6 : 0.25), dy: -em * (isBlock ? 0.3 : 0.12))
      NSColor.labelColor.withAlphaComponent(0.08).setFill()
      NSBezierPath(roundedRect: highlight, xRadius: em * 0.3, yRadius: em * 0.3).fill()
      if isBlock,
        let pencil = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edit equation")?
          .withSymbolConfiguration(.init(pointSize: em * 0.7, weight: .regular))
      {
        let tinted = NSImage(size: pencil.size, flipped: false) { bounds in
          pencil.draw(in: bounds)
          NSColor.secondaryLabelColor.set()
          bounds.fill(using: .sourceAtop)
          return true
        }
        tinted.draw(
          in: NSRect(
            x: highlight.maxX + em * 0.35, y: highlight.midY - pencil.size.height / 2,
            width: pencil.size.width, height: pencil.size.height),
          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
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

  /// Where a rendered equation is drawn, in text container coordinates.
  private func renderedMathRect(at index: Int) -> NSRect? {
    guard case .math = presentation.replacements[index], let metrics = metrics(forReplacementAt: index)
    else { return nil }
    let glyph = layout.glyphIndexForCharacter(at: index)
    guard glyph < layout.numberOfGlyphs else { return nil }
    let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    let location = layout.location(forGlyphAt: glyph)
    return NSRect(
      x: line.minX + location.x, y: line.minY + location.y - metrics.baseline,
      width: metrics.size.width, height: metrics.size.height)
  }

  /// The rendered equation under a point, identified by its first character.
  private func renderedMath(at point: NSPoint) -> Int? {
    let origin = textView.textContainerOrigin
    let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
    guard local.y >= 0, layout.numberOfGlyphs > 0 else { return nil }
    let glyph = min(layout.glyphIndex(for: local, in: container), layout.numberOfGlyphs - 1)
    let line = layout.characterRange(
      forGlyphRange: layout.glyphRange(
        forCharacterRange: storage.mutableString.lineRange(
          for: NSRange(location: layout.characterIndexForGlyph(at: glyph), length: 0)),
        actualCharacterRange: nil), actualGlyphRange: nil)
    let keys = replacementKeys
    var index = keys.lowerBound(line.location)
    while index < keys.count, keys[index] < NSMaxRange(line) {
      let key = keys[index]
      index += 1
      guard let rect = renderedMathRect(at: key) else { continue }
      if let block = mathBlock(containing: key), block.range.location == key,
        let card = cardGeometry(block)?.card, card.contains(local)
      {
        return key
      }
      if rect.insetBy(dx: -4, dy: -3).contains(local) { return key }
    }
    return nil
  }

  /// Opens an equation for editing when its rendering, or its card outside the source field, is
  /// clicked, putting the cursor at the end of its content.
  func handleClick(at point: NSPoint, event: NSEvent) -> Bool {
    guard concealing, event.clickCount == 1,
      event.modifierFlags.intersection([.shift, .command]).isEmpty
    else { return false }
    let range: NSRange
    if let rendered = renderedMath(at: point),
      let element = elements.first(where: { $0.kind == .math && $0.range.location == rendered })
    {
      range = element.range
    } else if let block = block(at: point), !block.rendered {
      if let field = cardGeometry(block)?.field?.offsetBy(
        dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y), field.contains(point)
      {
        return false
      }
      range = block.range
    } else {
      return false
    }
    let text = storage.mutableString
    var end = NSMaxRange(range) - 1
    while end > range.location + 1, [0x20, 0x09, 0x0A].contains(text.character(at: end - 1)) {
      end -= 1
    }
    hoveredMath = nil
    textView.toolTip = nil
    textView.window?.makeFirstResponder(textView)
    textView.setSelectedRange(NSRange(location: end, length: 0))
    return true
  }

  private func block(at point: NSPoint) -> MathBlock? {
    let origin = textView.textContainerOrigin
    let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
    guard local.y >= 0, layout.numberOfGlyphs > 0 else { return nil }
    let glyph = min(layout.glyphIndex(for: local, in: container), layout.numberOfGlyphs - 1)
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

  #if PLAINST_CHECKS
    /// Shows the hover highlight on the equation starting at `index`, for snapshots.
    func showHover(at index: Int) {
      hoveredMath = renderedMathRect(at: index) == nil ? nil : index
      textView.needsDisplay = true
    }
  #endif

  func mouseMoved(to point: NSPoint?) {
    let hovered = concealing ? point.flatMap { renderedMath(at: $0) } : nil
    if hovered != nil { NSCursor.pointingHand.set() }
    let problem = hovered == nil ? point.flatMap { diagnostic(at: $0) } : nil
    let tip = hovered != nil ? "Edit equation" : problem.map(Self.describe)
    if textView.toolTip != tip { textView.toolTip = tip }
    guard hovered != hoveredMath else { return }
    hoveredMath = hovered
    textView.needsDisplay = true
  }

  // MARK: Equation preview

  func updatePreview() {
    guard configuration.equationPreviews, let math = presentation.activeMath,
      NSMaxRange(math.range) <= storage.length,
      math.range.length > 0, textView.window?.firstResponder === textView,
      NSMaxRange(textView.selectedRange()) <= NSMaxRange(math.range),
      textView.selectedRange().location >= math.range.location
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

  /// Compiles the text after `delay`, unless it changes again first.
  public func scheduleCompile(delay: TimeInterval = 0.35) {
    compileGeneration += 1
    let generation = compileGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self, generation == self.compileGeneration else { return }
      let text = self.text
      let key = self.engineKey
      let collectsPages = self.collectsPages
      Self.engineQueue.async {
        let result = Engine.compile(text, pdf: false, key: key)
        let pages = collectsPages ? Engine.previewPages(key: key) : nil
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            guard generation == self.compileGeneration else { return }
            self.showCompileResult(result, pages: pages, for: text)
          }
        }
      }
    }
  }

  private func showCompileResult(_ result: CompileResult, pages: [PreviewPage]?, for text: String) {
    lastCompiledText = text
    diagnostics = result.diagnostics
    pageCount = result.pages
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
    delegate?.typstEditor(self, didCompile: result, pages: pages)
    // Messages at the ends of lines wait for a pause, so they don't flicker while typing.
    let generation = compileGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
      guard let self, generation == self.compileGeneration, text == self.text else { return }
      self.showAnnotations()
    }
  }

  private func showAnnotations() {
    let text = storage.mutableString
    var byLine: [Int: Annotation] = [:]
    for diagnostic in diagnostics {
      guard let range = diagnostic.range, range.location <= text.length else { continue }
      let line = text.lineRange(for: NSRange(location: min(range.location, text.length), length: 0))
      if var existing = byLine[line.location] {
        existing.extra += 1
        if diagnostic.isError && !existing.diagnostic.isError { existing.diagnostic = diagnostic }
        byLine[line.location] = existing
      } else {
        byLine[line.location] = Annotation(location: range.location, diagnostic: diagnostic, extra: 0)
      }
    }
    annotations = byLine.values.sorted { $0.location < $1.location }
    textView.needsDisplay = true
  }

  /// Hides line-end messages while the text changes under them.
  private func clearAnnotations() {
    guard !annotations.isEmpty else { return }
    annotations = []
    textView.needsDisplay = true
  }

  /// Where a problem's message is drawn, in text view coordinates, and whether it fits beside
  /// the text or only as an icon in the margin.
  private func annotationRect(_ annotation: Annotation) -> (rect: NSRect, compact: Bool)? {
    let text = storage.mutableString
    guard annotation.location <= text.length, storage.length > 0 else { return nil }
    let line = text.lineRange(for: NSRange(location: min(annotation.location, text.length), length: 0))
    var last = NSMaxRange(line) - 1
    while last > line.location, [0x0A, 0x0D].contains(text.character(at: last)) { last -= 1 }
    last = max(0, min(last, storage.length - 1))
    let glyph = layout.glyphIndexForCharacter(at: last)
    guard glyph < layout.numberOfGlyphs else { return nil }
    let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    let used = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
    let origin = textView.textContainerOrigin
    let height = NSFont.smallSystemFontSize + 7
    let y = origin.y + fragment.minY + ((used.height - height) / 2).rounded()
    let start = origin.x + used.maxX + 14
    let limit = textView.bounds.width - 12
    if limit - start >= 90 {
      return (NSRect(x: start, y: y, width: limit - start, height: height), false)
    }
    let marginX = origin.x + container.size.width + 4
    guard textView.bounds.width - marginX >= 16 else { return nil }
    return (NSRect(x: marginX, y: y, width: 16, height: height), true)
  }

  private func drawAnnotations(forCharacters characters: NSRange) {
    guard !annotations.isEmpty else { return }
    let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    for annotation in annotations where NSLocationInRange(annotation.location, characters)
      || annotation.location == NSMaxRange(characters) && annotation.location == storage.length
    {
      guard let (rect, compact) = annotationRect(annotation) else { continue }
      let color: NSColor = annotation.diagnostic.isError ? .systemRed : .systemOrange
      let icon = NSImage(
        systemSymbolName: annotation.diagnostic.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill",
        accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: NSFont.smallSystemFontSize - 1, weight: .semibold)
          .applying(.init(paletteColors: [color])))
      if compact {
        icon?.draw(in: NSRect(x: rect.minX, y: rect.midY - 6, width: 12, height: 12).integral,
          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        continue
      }
      var message = annotation.diagnostic.message
      if annotation.extra > 0 { message += "  +\(annotation.extra)" }
      let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
      let textWidth = min((message as NSString).size(withAttributes: attributes).width, rect.width - 30)
      let capsule = NSRect(x: rect.minX, y: rect.minY, width: textWidth + 30, height: rect.height)
      color.withAlphaComponent(0.1).setFill()
      NSBezierPath(roundedRect: capsule, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
      icon?.draw(in: NSRect(x: capsule.minX + 7, y: capsule.midY - 6, width: 12, height: 12).integral,
        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineBreakMode = .byTruncatingTail
      var textAttributes = attributes
      textAttributes[.paragraphStyle] = paragraph
      (message as NSString).draw(
        with: NSRect(x: capsule.minX + 23, y: capsule.minY + 2, width: textWidth, height: rect.height - 2),
        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: textAttributes)
    }
  }

  /// The problem under the pointer, from its underline or its line-end message.
  private func diagnostic(at point: NSPoint) -> Diagnostic? {
    for annotation in annotations {
      if let (rect, _) = annotationRect(annotation), rect.insetBy(dx: -2, dy: -2).contains(point) {
        return annotation.diagnostic
      }
    }
    let origin = textView.textContainerOrigin
    let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
    guard layout.numberOfGlyphs > 0 else { return nil }
    var fraction: CGFloat = 0
    let glyph = layout.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: &fraction)
    let glyphRect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
    guard glyphRect.insetBy(dx: -1, dy: -2).contains(local) else { return nil }
    let character = layout.characterIndexForGlyph(at: glyph)
    return diagnostics.first { diagnostic in
      guard let range = diagnostic.range else { return false }
      return NSLocationInRange(character, range) || (range.length == 0 && character == range.location)
    }
  }

  static func describe(_ diagnostic: Diagnostic) -> String {
    ([diagnostic.message] + diagnostic.hints.map { "Hint: \($0)" }).joined(separator: "\n")
  }

  // MARK: Commands

  /// Switches between the Writing and Source views, keeping the selection.
  public func setMode(_ newMode: EditorMode) {
    guard newMode != mode else { return }
    let selection = textView.selectedRange()
    mode = newMode
    assistant.dismiss()
    restyleEverything()
    textView.setSelectedRange(selection)
    textView.scrollRangeToVisible(selection)
  }

  /// Sets the zoom, from 50% to 400%.
  public func setZoom(_ percent: Int) {
    let clamped = min(400, max(50, percent))
    guard clamped != zoomPercent else { return }
    zoomPercent = clamped
    restyleEverything()
    textView.scrollRangeToVisible(textView.selectedRange())
  }

  private var editableText: NSString { storage.mutableString }

  /// Adds or removes bold, italic or code around the selection.
  public func toggle(_ inline: Formatting.Inline, actionName: String) {
    apply(
      Formatting.toggle(
        inline, text: editableText, selection: textView.selectedRange(), elements: elements),
      actionName: actionName)
  }

  /// Makes the selected lines a heading of `level`, or body text for level 0.
  public func setHeading(level: Int) {
    apply(
      Formatting.setHeading(level: level, text: editableText, selection: textView.selectedRange()),
      actionName: level == 0 ? "Body Text" : "Heading")
  }

  public func toggleList(_ kind: Formatting.ListStyle, actionName: String) {
    apply(
      Formatting.toggleList(kind, text: editableText, selection: textView.selectedRange()),
      actionName: actionName)
  }

  public func insertEquation(block: Bool) {
    apply(
      Formatting.insertEquation(block: block, text: editableText, selection: textView.selectedRange()),
      actionName: block ? "Display Equation" : "Equation")
  }

  /// Indents or outdents the selected lines by one level; list items nest or unnest. Beeps when
  /// there is nothing to outdent.
  public func indent(outdent: Bool) {
    let selection = textView.selectedRange()
    let width = configuration.tabWidth
    guard
      let edit = Formatting.indentList(text: editableText, selection: selection, outdent: outdent, width: width)
        ?? Formatting.indentLines(text: editableText, selection: selection, outdent: outdent, width: width)
    else {
      NSSound.beep()
      return
    }
    apply(edit, actionName: outdent ? "Decrease Indent" : "Increase Indent")
  }

  /// The 1-based line and column of a location.
  public func lineAndColumn(at location: Int) -> (line: Int, column: Int) {
    let place = index.position(min(max(0, location), storage.length))
    return (place.line, place.column)
  }

  /// The number of lines, counting an empty last line.
  public var lineCount: Int { index.starts.count }

  /// Where a 1-based line starts, or nil past the last line.
  public func location(ofLine line: Int) -> Int? {
    guard line > 0, line <= index.starts.count else { return nil }
    return index.starts[line - 1]
  }
}

extension TypstTextView {
  override public func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    editor?.refreshEnvironment()
  }

  override public func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    editor?.refreshEnvironment()
  }
}
