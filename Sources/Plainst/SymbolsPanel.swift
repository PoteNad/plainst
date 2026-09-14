import AppKit
import PlainstCore

/// A browsable, searchable collection of Typst symbols and math structures.
enum SymbolCatalog {
  struct Group {
    var title: String
    var names: [String]
  }

  /// Common math structures, inserted as snippets with placeholders.
  struct Template {
    var title: String
    var snippet: String
    /// Rendered with Typst for the button's image.
    var preview: String
  }

  static let groups: [Group] = [
    Group(
      title: "Greek",
      names: [
        "alpha", "beta", "gamma", "delta", "epsilon", "epsilon.alt", "zeta", "eta", "theta",
        "theta.alt", "iota", "kappa", "lambda", "mu", "nu", "xi", "pi", "rho", "sigma", "tau",
        "upsilon", "phi", "phi.alt", "chi", "psi", "omega", "Gamma", "Delta", "Theta", "Lambda",
        "Xi", "Pi", "Sigma", "Upsilon", "Phi", "Psi", "Omega",
      ]),
    Group(
      title: "Operators",
      names: [
        "plus", "minus", "plus.minus", "minus.plus", "times", "div", "dot.op", "ast.op", "star.op",
        "compose", "plus.o", "times.o", "slash", "backslash", "without", "convolve",
      ]),
    Group(
      title: "Relations",
      names: [
        "eq", "eq.not", "lt", "gt", "lt.eq", "gt.eq", "approx", "tilde.op", "equiv", "prop", "lt.double",
        "gt.double", "prec", "succ", "colon.eq", "eq.def", "perp", "parallel",
      ]),
    Group(
      title: "Arrows",
      names: [
        "arrow.r", "arrow.l", "arrow.t", "arrow.b", "arrow.l.r", "arrow.t.b", "arrow.r.double",
        "arrow.l.double", "arrow.l.r.double", "arrow.r.bar", "arrow.r.long", "arrow.r.hook",
        "arrow.r.squiggly", "arrow.tr", "arrow.br", "harpoon.rt", "arrows.rl",
      ]),
    Group(
      title: "Sets and Logic",
      names: [
        "in", "in.not", "subset", "subset.eq", "supset", "supset.eq", "union", "inter", "nothing",
        "forall", "exists", "exists.not", "and", "or", "not", "top", "bot", "therefore", "because",
        "tack.r",
      ]),
    Group(
      title: "Calculus and Big Operators",
      names: [
        "sum", "product", "integral", "integral.double", "integral.triple", "integral.cont",
        "union.big", "inter.big", "partial", "nabla", "infinity", "prime", "degree",
      ]),
    Group(
      title: "Letters and Dots",
      names: [
        "aleph", "ell", "planck", "RR", "ZZ", "QQ", "NN", "CC", "dots.h", "dots.h.c", "dots.v",
        "dots.down", "angle", "triangle.stroked.t", "square.stroked", "circle.stroked",
      ]),
  ]

  static let templates: [Template] = [
    Template(title: "Fraction", snippet: "frac(${a}, ${b})", preview: "$frac(a, b)$"),
    Template(title: "Square root", snippet: "sqrt(${x})", preview: "$sqrt(x)$"),
    Template(title: "Root", snippet: "root(${n}, ${x})", preview: "$root(n, x)$"),
    Template(title: "Superscript", snippet: "${x}^${2}", preview: "$x^2$"),
    Template(title: "Subscript", snippet: "${x}_${i}", preview: "$x_i$"),
    Template(title: "Sum with limits", snippet: "sum_(${i=1})^${n}", preview: "$sum_(i=1)^n$"),
    Template(title: "Integral with limits", snippet: "integral_${a}^${b}", preview: "$integral_a^b$"),
    Template(title: "Limit", snippet: "lim_(${x -> 0})", preview: "$lim_(x -> 0)$"),
    Template(title: "Vector", snippet: "vec(${a}, ${b})", preview: "$vec(a, b)$"),
    Template(title: "Matrix", snippet: "mat(${a}, ${b}; ${c}, ${d})", preview: "$mat(a, b; c, d)$"),
    Template(title: "Cases", snippet: "cases(${a} \"if\" ${x}, ${b} \"otherwise\")", preview: "$cases(a, b)$"),
    Template(title: "Binomial", snippet: "binom(${n}, ${k})", preview: "$binom(n, k)$"),
    Template(title: "Absolute value", snippet: "abs(${x})", preview: "$abs(x)$"),
    Template(title: "Norm", snippet: "norm(${x})", preview: "$norm(x)$"),
    Template(title: "Hat", snippet: "hat(${x})", preview: "$hat(x)$"),
    Template(title: "Bar", snippet: "overline(${x})", preview: "$overline(x)$"),
    Template(title: "Vector arrow", snippet: "arrow(${x})", preview: "$arrow(x)$"),
    Template(title: "Dot", snippet: "dot(${x})", preview: "$dot(x)$"),
    Template(title: "Text in math", snippet: "\"${text}\"", preview: "$\"abc\"$"),
    Template(title: "Blackboard bold", snippet: "bb(${R})", preview: "$bb(R)$"),
    Template(title: "Calligraphic", snippet: "cal(${A})", preview: "$cal(A)$"),
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

  override func loadView() {
    let root = NSView()
    search.placeholderString = "Search symbols"
    search.delegate = self
    search.sendsSearchStringImmediately = true
    search.setAccessibilityLabel("Search symbols")
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
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
    footer.stringValue = "Click a symbol to insert it."
    footer.toolTip = "Outside an equation, symbols are inserted between dollar signs."
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
    NotificationCenter.default.addObserver(
      self, selector: #selector(mathDidRender), name: MathImages.didRender, object: nil)
  }

  func focusSearch() { view.window?.makeFirstResponder(search) }

  func controlTextDidChange(_ notification: Notification) { rebuild() }

  private var templateButtons: [(SymbolButton, SymbolCatalog.Template)] = []

  private func rebuild() {
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    templateButtons = []
    let query = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
    if query.isEmpty {
      addSection("Structures", SymbolCatalog.templates.map { template in button(for: template) })
      for group in SymbolCatalog.groups {
        addSection(group.title, group.names.compactMap { symbolButton($0) })
      }
    } else {
      let templates = SymbolCatalog.templates.filter {
        $0.title.lowercased().contains(query) || $0.snippet.lowercased().contains(query)
      }
      if !templates.isEmpty { addSection("Structures", templates.map { button(for: $0) }) }
      let matches = Engine.symbols.filter { $0.name.lowercased().contains(query) }
        .sorted { ($0.name.lowercased().hasPrefix(query) ? 0 : 1, $0.name.count) < ($1.name.lowercased().hasPrefix(query) ? 0 : 1, $1.name.count) }
        .prefix(180)
      let buttons = matches.compactMap { symbolButton($0.name) }
      if buttons.isEmpty && templates.isEmpty {
        let empty = NSTextField(labelWithString: "No symbols match “\(search.stringValue)”.")
        empty.textColor = .secondaryLabelColor
        stack.addArrangedSubview(empty)
      } else if !buttons.isEmpty {
        addSection("Symbols", buttons)
      }
    }
  }

  private func addSection(_ title: String, _ buttons: [SymbolButton]) {
    guard !buttons.isEmpty else { return }
    let heading = NSTextField(labelWithString: title)
    heading.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
    heading.textColor = .labelColor
    stack.addArrangedSubview(heading)
    // Structures are wider than single symbols, so they get larger cells.
    let template = buttons.first?.isTemplate == true
    let grid = SymbolGrid(
      buttons: buttons,
      cell: NSSize(width: SymbolButton.side * (template ? 2 : 1) + (template ? 3 : 0), height: SymbolButton.side + (template ? 8 : 0)))
    stack.addArrangedSubview(grid)
    grid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
    stack.setCustomSpacing(4, after: heading)
  }

  private func symbolButton(_ name: String) -> SymbolButton? {
    guard let value = SymbolCatalog.values[name] else { return nil }
    let button = SymbolButton(target: self, action: #selector(insertSymbol(_:)))
    button.code = name
    button.title = value
    button.font = NSFont(name: "NewCMMath-Regular", size: 19) ?? .systemFont(ofSize: 17)
    button.toolTip = name
    button.setAccessibilityLabel("\(name), \(value)")
    return button
  }

  private func button(for template: SymbolCatalog.Template) -> SymbolButton {
    let button = SymbolButton(target: self, action: #selector(insertSymbol(_:)), template: true)
    button.code = template.snippet
    button.toolTip = "\(template.title): \(ExpandedSnippet(template.snippet).text)"
    button.setAccessibilityLabel(template.title)
    templateButtons.append((button, template))
    updateImage(button, template)
    return button
  }

  private func updateImage(_ button: SymbolButton, _ template: SymbolCatalog.Template) {
    let appearance = view.effectiveAppearance
    let key = MathKey(
      source: template.preview, block: false, emSize: 1500,
      backingScale: Int(((view.window?.backingScaleFactor ?? 2) * 100).rounded()),
      color: MathImages.packedColor(.labelColor, appearance: appearance))
    if case .rendered(let image, _, _) = MathImages.shared.request(key) {
      button.image = image
      button.title = ""
      button.imageScaling = .scaleProportionallyDown
    } else {
      button.title = template.title.prefix(1).description
    }
  }

  @objc private func mathDidRender(_ notification: Notification) {
    for (button, template) in templateButtons where button.image == nil {
      updateImage(button, template)
    }
  }

  @objc private func insertSymbol(_ sender: SymbolButton) {
    editor?.insertMath(sender.code, snippet: sender.isTemplate)
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
    if template { imagePosition = .imageOnly }
  }
}
