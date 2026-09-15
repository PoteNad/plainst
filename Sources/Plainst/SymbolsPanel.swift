import AppKit
import PlainstCore
import PlainstEditor

/// A browsable, searchable collection of Typst symbols and math structures.
enum SymbolCatalog {
  /// Common math structures, inserted as snippets with placeholders.
  struct Template {
    var title: String
    var snippet: String
    /// Rendered with Typst for the button's image.
    var preview: String
    /// Shown until the Typst rendering is ready.
    var fallback: String
  }

  static let templates: [Template] = [
    Template(title: "Fraction", snippet: "frac(${a}, ${b})", preview: "$frac(a, b)$", fallback: "a⁄b"),
    Template(title: "Square root", snippet: "sqrt(${x})", preview: "$sqrt(x)$", fallback: "√x"),
    Template(title: "Root", snippet: "root(${n}, ${x})", preview: "$root(n, x)$", fallback: "ⁿ√x"),
    Template(title: "Superscript", snippet: "${x}^${2}", preview: "$x^2$", fallback: "x²"),
    Template(title: "Subscript", snippet: "${x}_${i}", preview: "$x_i$", fallback: "xᵢ"),
    Template(title: "Sum with limits", snippet: "sum_(${i=1})^${n}", preview: "$sum_(i=1)^n$", fallback: "Σ"),
    Template(title: "Integral with limits", snippet: "integral_${a}^${b}", preview: "$integral_a^b$", fallback: "∫"),
    Template(title: "Limit", snippet: "lim_(${x -> 0})", preview: "$lim_(x -> 0)$", fallback: "lim"),
    Template(title: "Vector", snippet: "vec(${a}, ${b})", preview: "$vec(a, b)$", fallback: "(a b)"),
    Template(title: "Matrix", snippet: "mat(${a}, ${b}; ${c}, ${d})", preview: "$mat(a, b; c, d)$", fallback: "[⋯]"),
    Template(title: "Cases", snippet: "cases(${a} \"if\" ${x}, ${b} \"otherwise\")", preview: "$cases(a, b)$", fallback: "{⋯"),
    Template(title: "Binomial", snippet: "binom(${n}, ${k})", preview: "$binom(n, k)$", fallback: "(n k)"),
    Template(title: "Absolute value", snippet: "abs(${x})", preview: "$abs(x)$", fallback: "|x|"),
    Template(title: "Norm", snippet: "norm(${x})", preview: "$norm(x)$", fallback: "‖x‖"),
    Template(title: "Hat", snippet: "hat(${x})", preview: "$hat(x)$", fallback: "x̂"),
    Template(title: "Bar", snippet: "overline(${x})", preview: "$overline(x)$", fallback: "x̄"),
    Template(title: "Vector arrow", snippet: "arrow(${x})", preview: "$arrow(x)$", fallback: "x⃗"),
    Template(title: "Dot", snippet: "dot(${x})", preview: "$dot(x)$", fallback: "ẋ"),
    Template(title: "Text in math", snippet: "\"${text}\"", preview: "$\"abc\"$", fallback: "abc"),
    Template(title: "Blackboard bold", snippet: "bb(${R})", preview: "$bb(R)$", fallback: "ℝ"),
    Template(title: "Calligraphic", snippet: "cal(${A})", preview: "$cal(A)$", fallback: "𝒜"),
  ]

  /// Symbols most documents need, shown before the full catalogue.
  static let common = [
    "alpha", "beta", "gamma", "delta", "epsilon", "theta", "lambda", "mu", "pi", "sigma", "phi",
    "omega", "Gamma", "Delta", "Sigma", "Omega", "plus.minus", "times", "div", "dot.op", "eq.not",
    "lt.eq", "gt.eq", "approx", "equiv", "prop", "in", "subset.eq", "union", "inter", "nothing",
    "forall", "exists", "and", "or", "not", "arrow.r", "arrow.l", "arrow.l.r", "arrow.r.double",
    "arrow.l.r.double", "arrow.r.bar", "sum", "product", "integral", "partial", "nabla", "infinity",
    "RR", "ZZ", "QQ", "NN", "CC", "dots.h", "dots.h.c", "dots.v", "degree", "prime", "angle", "perp",
  ]

  static let values: [String: String] = Dictionary(
    Engine.symbols.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
}

/// The symbols inspector shown beside the document.
@MainActor
final class SymbolsViewController: NSViewController, NSSearchFieldDelegate {
  weak var editor: Editor?
  private let search = NSSearchField()
  private let scroll = NSScrollView()
  private let stack = NSStackView()
  private let footer = NSTextField(labelWithString: "")
  /// Categories the user has opened, which stay open while the inspector is in use.
  private var expanded: Set<String> = []
  private var templateButtons: [(SymbolButton, SymbolCatalog.Template)] = []

  override func loadView() {
    let root = NSView()
    search.placeholderString = "Search all symbols"
    search.delegate = self
    search.sendsSearchStringImmediately = true
    search.setAccessibilityLabel("Search symbols")
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 16, right: 12)
    let document = FlippedView()
    document.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: document.topAnchor),
      stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
    ])
    scroll.documentView = document
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    footer.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    footer.textColor = .secondaryLabelColor
    footer.lineBreakMode = .byTruncatingTail
    footer.alignment = .center
    footer.stringValue = "\(Engine.symbols.count.formatted()) symbols"
    footer.toolTip = "Click a symbol to insert it. Outside an equation, it goes between dollar signs."
    for view in [search, scroll, footer] {
      view.translatesAutoresizingMaskIntoConstraints = false
      root.addSubview(view)
    }
    NSLayoutConstraint.activate([
      search.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 10),
      search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
      search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
      scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
      scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
      footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
      footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
      footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
      document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
      document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
      document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
    ])
    view = root
    rebuild()
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    // The window's resolution is known now, so render previews at the right scale.
    refreshPreviews()
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    if view.effectiveAppearance.name != previewAppearance { refreshPreviews() }
  }

  func focusSearch() { view.window?.makeFirstResponder(search) }

  #if PLAINST_CHECKS
    /// Opens a category and scrolls to it, for snapshots.
    func showCategory(_ title: String) {
      expanded.insert(title)
      rebuild()
      view.layoutSubtreeIfNeeded()
      if let header = stack.arrangedSubviews.first(where: { $0.identifier?.rawValue == title }) {
        let y = header.convert(NSPoint.zero, to: scroll.documentView).y
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y - 160)))
        scroll.reflectScrolledClipView(scroll.contentView)
      }
    }
  #endif

  func controlTextDidChange(_ notification: Notification) { rebuild() }

  var debugTemplateImages: String {
    "\(templateButtons.filter { $0.0.image != nil }.count) of \(templateButtons.count) rendered"
  }

  private func rebuild() {
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    templateButtons = []
    let query = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
    guard query.isEmpty else { return showResults(for: query) }

    addHeading("Structures")
    addGrid(SymbolCatalog.templates.map(templateButton))
    addHeading("Common")
    addGrid(SymbolCatalog.common.compactMap { name in
      SymbolCatalog.values[name].map { symbolButton(TypstSymbol(name: name, value: $0)) }
    })
    addDivider()
    for group in Engine.symbolGroups where !group.symbols.isEmpty {
      addCategory(group)
    }
    refreshPreviews()
  }

  private func showResults(for query: String) {
    let templates = SymbolCatalog.templates.filter {
      $0.title.lowercased().contains(query) || $0.snippet.lowercased().contains(query)
    }
    if !templates.isEmpty {
      addHeading("Structures")
      addGrid(templates.map(templateButton))
    }
    // Names that start with the query come first, then shorter names.
    let matches = Engine.symbols.filter { $0.name.lowercased().contains(query) || $0.value == query }
      .sorted {
        let a = ($0.name.lowercased().hasPrefix(query) ? 0 : 1, $0.name.count)
        let b = ($1.name.lowercased().hasPrefix(query) ? 0 : 1, $1.name.count)
        return a < b
      }
    if !matches.isEmpty {
      addHeading(matches.count == 1 ? "1 Symbol" : "\(matches.count) Symbols")
      addGrid(matches.prefix(400).map(symbolButton))
    }
    if templates.isEmpty && matches.isEmpty {
      let empty = NSTextField(labelWithString: "No symbols match “\(search.stringValue)”.")
      empty.textColor = .secondaryLabelColor
      stack.addArrangedSubview(empty)
    }
    refreshPreviews()
  }

  private func addHeading(_ title: String) {
    addHeader(SectionHeader(title: title, count: nil, isOpen: nil))
  }

  private func addHeader(_ header: SectionHeader) {
    if let last = stack.arrangedSubviews.last, !(last is NSBox) {
      // Closed categories sit close together; anything after symbols gets more room.
      let afterClosedHeader = (last as? SectionHeader)?.isOpen == false
      stack.setCustomSpacing(afterClosedHeader && header.isOpen != nil ? 2 : 14, after: last)
    }
    stack.addArrangedSubview(header)
    header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
    stack.setCustomSpacing(4, after: header)
  }

  private func addDivider() {
    let divider = NSBox()
    divider.boxType = .separator
    divider.translatesAutoresizingMaskIntoConstraints = false
    if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(14, after: last) }
    stack.addArrangedSubview(divider)
    divider.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
    stack.setCustomSpacing(10, after: divider)
  }

  /// A category header that shows or hides its symbols, built only when first opened.
  private func addCategory(_ group: SymbolGroup) {
    let isOpen = expanded.contains(group.title)
    let header = SectionHeader(title: group.title, count: group.symbols.count, isOpen: isOpen)
    header.identifier = NSUserInterfaceItemIdentifier(group.title)
    header.target = self
    header.action = #selector(toggleCategory(_:))
    addHeader(header)
    if isOpen { addGrid(group.symbols.map(symbolButton)) }
  }

  @objc private func toggleCategory(_ sender: NSControl) {
    guard let title = sender.identifier?.rawValue else { return }
    if expanded.contains(title) { expanded.remove(title) } else { expanded.insert(title) }
    let offset = scroll.contentView.bounds.origin
    rebuild()
    scroll.contentView.scroll(to: offset)
  }

  private func addGrid(_ buttons: [SymbolButton]) {
    guard !buttons.isEmpty else { return }
    // Structures are wider than single symbols, so they get larger cells.
    let template = buttons.first?.isTemplate == true
    let grid = SymbolGrid(
      buttons: buttons,
      cell: NSSize(
        width: template ? SymbolButton.side * 2 + 3 : SymbolButton.side,
        height: template ? SymbolButton.side + 8 : SymbolButton.side))
    stack.addArrangedSubview(grid)
    grid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
  }

  private func symbolButton(_ symbol: TypstSymbol) -> SymbolButton {
    let button = SymbolButton(target: self, action: #selector(insertSymbol(_:)))
    button.code = symbol.name
    button.title = symbol.value
    button.font = NSFont(name: "NewCMMath-Regular", size: 19) ?? .systemFont(ofSize: 17)
    button.toolTip = symbol.name
    button.setAccessibilityLabel("\(symbol.name), \(symbol.value)")
    return button
  }

  private func templateButton(_ template: SymbolCatalog.Template) -> SymbolButton {
    let button = SymbolButton(target: self, action: #selector(insertSymbol(_:)), template: true)
    button.code = template.snippet
    button.title = template.fallback
    button.font = NSFont(name: "NewCMMath-Regular", size: 15) ?? .systemFont(ofSize: 13)
    button.toolTip = "\(template.title): \(ExpandedSnippet(template.snippet).text)"
    button.setAccessibilityLabel(template.title)
    templateButtons.append((button, template))
    return button
  }

  private var previewAppearance: NSAppearance.Name?

  /// Renders each structure with Typst and swaps the image in when it is ready.
  private func refreshPreviews() {
    guard isViewLoaded else { return }
    let appearance = view.effectiveAppearance
    previewAppearance = appearance.name
    let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    let color = MathImages.packedColor(.labelColor, appearance: appearance)
    for (button, template) in templateButtons {
      let key = MathKey(
        source: template.preview, block: false, emSize: 1800,
        backingScale: Int((scale * 100).rounded()), color: color)
      let apply: (MathImages.Entry) -> Void = { [weak button] entry in
        guard let button, case .rendered(let image, _, _) = entry else { return }
        button.image = image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
      }
      if let entry = MathImages.shared.request(key, completion: apply) { apply(entry) }
    }
  }

  @objc private func insertSymbol(_ sender: SymbolButton) {
    editor?.insertMath(sender.code, snippet: sender.isTemplate)
  }
}

/// A section title in the inspector. Categories add a quiet count and a disclosure chevron,
/// and the whole row toggles them.
private final class SectionHeader: NSControl {
  /// Nil for fixed sections, otherwise whether the category is showing its symbols.
  let isOpen: Bool?
  private let label: NSTextField

  init(title: String, count: Int?, isOpen: Bool?) {
    self.isOpen = isOpen
    label = NSTextField(labelWithString: title)
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
    label.textColor = .labelColor
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    var constraints = [
      heightAnchor.constraint(equalToConstant: 20),
      label.leadingAnchor.constraint(equalTo: leadingAnchor),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
    ]
    if let isOpen {
      let chevron = NSImageView(
        image: NSImage(systemSymbolName: isOpen ? "chevron.down" : "chevron.right", accessibilityDescription: nil)!
          .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))!)
      chevron.contentTintColor = .tertiaryLabelColor
      chevron.translatesAutoresizingMaskIntoConstraints = false
      addSubview(chevron)
      let number = NSTextField(labelWithString: count.map(String.init) ?? "")
      number.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .regular)
      number.textColor = .tertiaryLabelColor
      number.translatesAutoresizingMaskIntoConstraints = false
      addSubview(number)
      constraints += [
        chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        chevron.widthAnchor.constraint(equalToConstant: 11),
        number.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -8),
        number.centerYAnchor.constraint(equalTo: centerYAnchor),
        label.trailingAnchor.constraint(lessThanOrEqualTo: number.leadingAnchor, constant: -8),
      ]
      setAccessibilityRole(.disclosureTriangle)
      setAccessibilityValue(isOpen ? 1 : 0)
      setAccessibilityLabel(count.map { "\(title), \($0) symbols" } ?? title)
      toolTip = isOpen ? "Hide \(title)" : "Show \(title)"
    } else {
      constraints.append(label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor))
      setAccessibilityElement(false)
    }
    NSLayoutConstraint.activate(constraints)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  override func mouseDown(with event: NSEvent) {
    guard isOpen != nil else { return }
    sendAction(action, to: target)
  }

  override func accessibilityPerformPress() -> Bool {
    guard isOpen != nil else { return false }
    return sendAction(action, to: target)
  }
}

private final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

/// Lays out equally sized buttons in as many columns as fit, wrapping to new rows.
private final class SymbolGrid: NSView {
  private let cell: NSSize
  private let spacing: CGFloat = 3

  init(buttons: [NSButton], cell: NSSize) {
    self.cell = cell
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    buttons.forEach(addSubview)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  private func columns(for width: CGFloat) -> Int {
    max(1, Int((width + spacing) / (cell.width + spacing)))
  }

  override var intrinsicContentSize: NSSize {
    let count = subviews.count
    let columns = columns(for: bounds.width > 0 ? bounds.width : 240)
    let rows = (count + columns - 1) / columns
    return NSSize(
      width: NSView.noIntrinsicMetric, height: CGFloat(rows) * (cell.height + spacing) - spacing)
  }

  override func setFrameSize(_ newSize: NSSize) {
    let widthChanged = newSize.width != frame.width
    super.setFrameSize(newSize)
    if widthChanged { invalidateIntrinsicContentSize() }
  }

  override func layout() {
    super.layout()
    let columns = columns(for: bounds.width)
    for (index, view) in subviews.enumerated() {
      view.frame = NSRect(
        x: CGFloat(index % columns) * (cell.width + spacing),
        y: CGFloat(index / columns) * (cell.height + spacing), width: cell.width, height: cell.height)
    }
  }
}

final class SymbolButton: NSButton {
  static let side: CGFloat = 34
  var code = ""
  private(set) var isTemplate = false

  convenience init(target: AnyObject, action: Selector, template: Bool = false) {
    let width = template ? SymbolButton.side * 2 + 3 : SymbolButton.side
    let height = template ? SymbolButton.side + 8 : SymbolButton.side
    self.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
    isTemplate = template
    self.target = target
    self.action = action
    bezelStyle = .smallSquare
    isBordered = true
    showsBorderOnlyWhileMouseInside = true
  }
}
