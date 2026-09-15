import AppKit
import CoreText
import PlainstCore
import PlainstEditor

enum PreferenceKey {
  static let appearance = "appearance"
  static let defaultMode = "defaultMode"
  static let status = "status"
  static let checkSpelling = "checkSpelling"
  static let writingTools = "writingTools"
  static let completions = "completions"
  static let autoPair = "autoPair"
  static let equationPreviews = "equationPreviews"
  static let symbolsVisible = "symbolsVisible"
  static let previewVisible = "previewVisible"
  static let outlineVisible = "outlineVisible"
  static let writingSize = "writingSize"
  static let sourceFontName = "sourceFontName"
  static let sourceFontSize = "sourceFontSize"
  static let lineEnding = "lineEnding"
  static let tabWidth = "tabWidth"
  static let indentGuides = "indentGuides"
  static let textWidth = "textWidth"
}

enum AppAppearance: String, CaseIterable {
  case system, light, dark

  var title: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  var value: NSAppearance? {
    switch self {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
  }
}

/// How large the Writing view draws the document, which never changes the document itself.
enum WritingSize: Double, CaseIterable {
  case small = 0.9
  case medium = 1
  case large = 1.15
  case extraLarge = 1.3

  var title: String {
    switch self {
    case .small: "90%"
    case .medium: "100%"
    case .large: "115%"
    case .extraLarge: "130%"
    }
  }
}

extension Notification.Name {
  static let editorDefaultsDidChange = Notification.Name("PlainstEditorDefaultsDidChange")
}

enum AppPreferences {
  static let settingKeys = [
    PreferenceKey.appearance, PreferenceKey.defaultMode, PreferenceKey.status,
    PreferenceKey.checkSpelling, PreferenceKey.writingTools, PreferenceKey.completions,
    PreferenceKey.autoPair, PreferenceKey.equationPreviews, PreferenceKey.writingSize,
    PreferenceKey.sourceFontName, PreferenceKey.sourceFontSize, PreferenceKey.lineEnding,
    PreferenceKey.tabWidth, PreferenceKey.indentGuides, PreferenceKey.textWidth,
  ]

  static func registerDefaults() {
    UserDefaults.standard.register(defaults: [
      PreferenceKey.appearance: AppAppearance.system.rawValue,
      PreferenceKey.defaultMode: EditorMode.writing.rawValue,
      PreferenceKey.status: true,
      PreferenceKey.checkSpelling: false,
      PreferenceKey.writingTools: false,
      PreferenceKey.completions: true,
      PreferenceKey.autoPair: true,
      PreferenceKey.equationPreviews: true,
      PreferenceKey.writingSize: WritingSize.medium.rawValue,
      PreferenceKey.sourceFontName: "",
      PreferenceKey.sourceFontSize: 13.0,
      PreferenceKey.lineEnding: LineEnding.lf.rawValue,
      PreferenceKey.tabWidth: 4,
      PreferenceKey.indentGuides: true,
      PreferenceKey.textWidth: TextWidth.page.rawValue,
    ])
  }

  static var completions: Bool { UserDefaults.standard.bool(forKey: PreferenceKey.completions) }
  static var autoPair: Bool { UserDefaults.standard.bool(forKey: PreferenceKey.autoPair) }
  static var equationPreviews: Bool {
    UserDefaults.standard.bool(forKey: PreferenceKey.equationPreviews)
  }

  static var appearance: AppAppearance {
    AppAppearance(rawValue: UserDefaults.standard.string(forKey: PreferenceKey.appearance) ?? "")
      ?? .system
  }

  @MainActor static func applyAppearance() { NSApp.appearance = appearance.value }

  static var defaultMode: EditorMode {
    EditorMode(rawValue: UserDefaults.standard.string(forKey: PreferenceKey.defaultMode) ?? "")
      ?? .writing
  }

  static var writingToolsEnabled: Bool {
    UserDefaults.standard.bool(forKey: PreferenceKey.writingTools)
  }

  static var writingSize: CGFloat {
    let value = UserDefaults.standard.double(forKey: PreferenceKey.writingSize)
    return value.isFinite && (0.5...2).contains(value) ? value : 1
  }

  /// The Source view's font family, or an empty string for the system monospaced font.
  static var sourceFontName: String {
    UserDefaults.standard.string(forKey: PreferenceKey.sourceFontName) ?? ""
  }

  static var sourceFontSize: CGFloat {
    let value = UserDefaults.standard.double(forKey: PreferenceKey.sourceFontSize)
    return value.isFinite && (8...48).contains(value) ? value : 13
  }

  /// The editor options chosen in Settings.
  static var editorConfiguration: TypstEditorConfiguration {
    TypstEditorConfiguration(
      writingSize: writingSize, sourceFontName: sourceFontName, sourceFontSize: sourceFontSize,
      completions: completions, autoPair: autoPair, equationPreviews: equationPreviews,
      checkSpelling: UserDefaults.standard.bool(forKey: PreferenceKey.checkSpelling),
      writingTools: writingToolsEnabled, tabWidth: tabWidth,
      showsIndentGuides: UserDefaults.standard.bool(forKey: PreferenceKey.indentGuides),
      textWidth: textWidth)
  }

  static var textWidth: TextWidth {
    TextWidth(rawValue: UserDefaults.standard.string(forKey: PreferenceKey.textWidth) ?? "") ?? .page
  }

  /// Columns per indentation level: 2, 4, or 8.
  static var tabWidth: Int {
    let value = UserDefaults.standard.integer(forKey: PreferenceKey.tabWidth)
    return [2, 4, 8].contains(value) ? value : 4
  }

  static var lineEnding: LineEnding {
    LineEnding(rawValue: UserDefaults.standard.string(forKey: PreferenceKey.lineEnding) ?? "") ?? .lf
  }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
  private let appearanceControl = NSSegmentedControl(
    labels: AppAppearance.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
  private let modeControl = NSSegmentedControl(
    labels: EditorMode.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
  private let writingSize = NSPopUpButton()
  private let sourceFamily = NSPopUpButton()
  private let sourceSize = NSTextField()
  private let sourceStepper = NSStepper()
  private let lineEnding = NSPopUpButton()
  private let tabWidth = NSPopUpButton()
  private let textWidth = NSPopUpButton()
  private let indentGuides = NSButton(
    checkboxWithTitle: "Show indentation guides", target: nil, action: nil)
  private let statusBar = NSButton(checkboxWithTitle: "Show status bar", target: nil, action: nil)
  private let spelling = NSButton(
    checkboxWithTitle: "Check spelling while typing", target: nil, action: nil)
  private let completions = NSButton(
    checkboxWithTitle: "Suggest completions while typing", target: nil, action: nil)
  private let autoPair = NSButton(
    checkboxWithTitle: "Pair brackets, quotes, and markup automatically", target: nil, action: nil)
  private let previews = NSButton(
    checkboxWithTitle: "Preview equations while editing them", target: nil, action: nil)
  private let writingTools = NSButton(
    checkboxWithTitle: "Enable Writing Tools (Apple Intelligence)", target: nil, action: nil)
  private let number = NumberFormatter()

  init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Plainst Settings"
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
    window.standardWindowButton(.zoomButton)?.isEnabled = false

    for value in WritingSize.allCases {
      writingSize.addItem(withTitle: value.title)
      writingSize.lastItem?.representedObject = value.rawValue
    }
    sourceFamily.addItem(withTitle: "System Monospaced")
    sourceFamily.lastItem?.representedObject = ""
    sourceFamily.menu?.addItem(.separator())
    for family in Typefaces.monospacedFamilies {
      sourceFamily.addItem(withTitle: family)
      sourceFamily.lastItem?.representedObject = family
    }
    for value in [LineEnding.lf, .crlf] {
      lineEnding.addItem(withTitle: value == .lf ? "LF (macOS and Linux)" : "CRLF (Windows)")
      lineEnding.lastItem?.representedObject = value.rawValue
    }
    for width in TextWidth.allCases {
      textWidth.addItem(withTitle: width.title)
      textWidth.lastItem?.representedObject = width.rawValue
    }
    for width in [2, 4, 8] {
      tabWidth.addItem(withTitle: "\(width) spaces")
      tabWidth.lastItem?.tag = width
    }
    number.numberStyle = .decimal
    number.maximumFractionDigits = 1
    number.usesGroupingSeparator = false
    sourceSize.formatter = number
    sourceSize.delegate = self
    sourceStepper.minValue = 8
    sourceStepper.maxValue = 48
    sourceStepper.increment = 1
    sourceStepper.valueWraps = false

    for control in [appearanceControl, modeControl, writingSize, sourceFamily, lineEnding, tabWidth, textWidth, sourceStepper]
      as [NSControl]
    {
      control.target = self
      control.action = #selector(changeOption)
    }
    for button in [statusBar, spelling, completions, autoPair, previews, indentGuides, writingTools] {
      button.target = self
      button.action = #selector(changeOption)
    }

    func describe(_ control: NSView, _ text: String) {
      control.toolTip = text
      control.setAccessibilityHelp(text)
    }
    describe(appearanceControl, "Follow the system appearance or always use Light or Dark.")
    describe(
      modeControl,
      "Choose whether documents open showing formatted text or their Typst source. You can switch any time with ⌘1 and ⌘2.")
    describe(
      writingSize,
      "Set how large the Writing view draws documents. This changes what you see, not the document; use Format ▸ Document Style for the document's own font and size.")
    describe(sourceFamily, "Choose the monospaced font for the Source view.")
    describe(sourceSize, "Set the Source view's font size in points, from 8 to 48.")
    describe(
      lineEnding, "Set the line endings for new documents. Existing documents keep their own.")
    describe(
      tabWidth,
      "Set how far Tab indents lines and nests list items, and how wide tab characters appear. Tab inserts spaces.")
    describe(
      textWidth,
      "Set how wide the text column is. Page matches the typeset page in the Writing view; Full Window uses the whole window.")
    describe(indentGuides, "Draw a faint line at each level of indentation.")
    describe(statusBar, "Show the cursor position, problems, word count, page count, and zoom level.")
    describe(spelling, "Underline possible spelling mistakes while you type.")
    describe(
      completions,
      "Suggest Typst symbols and functions as you type in equations, or after # in text. Press ⌥⎋ to ask for suggestions any time.")
    describe(
      autoPair,
      "Typing $, (, [, {, or a backtick adds its closing partner, as do quotes inside code. With text selected, those characters and * or _ wrap the selection instead of replacing it.")
    describe(previews, "Show the rendered equation below an equation while you edit its source.")
    describe(writingTools, "Show Apple's Writing Tools in the Edit menu when they are available.")
    if #unavailable(macOS 15.2) {
      writingTools.isEnabled = false
      describe(writingTools, "Requires macOS 15.2 or newer.")
    }

    let sizeControl = NSStackView(views: [sourceSize, sourceStepper])
    sizeControl.orientation = .horizontal
    sizeControl.spacing = 6
    sourceSize.widthAnchor.constraint(equalToConstant: 60).isActive = true

    let generalGrid = NSGridView(views: [
      [NSTextField(labelWithString: "Appearance:"), appearanceControl],
      [NSTextField(labelWithString: "Default view:"), modeControl],
    ])
    let textGrid = NSGridView(views: [
      [NSTextField(labelWithString: "Writing zoom:"), writingSize],
      [NSTextField(labelWithString: "Text width:"), textWidth],
      [NSTextField(labelWithString: "Source font:"), sourceFamily],
      [NSTextField(labelWithString: "Source font size:"), sizeControl],
      [NSTextField(labelWithString: "Tab width:"), tabWidth],
      [NSTextField(labelWithString: "New document line endings:"), lineEnding],
    ])
    for grid in [generalGrid, textGrid] {
      grid.rowSpacing = 8
      grid.columnSpacing = 12
      grid.column(at: 0).xPlacement = .trailing
      grid.column(at: 1).width = 260
      grid.rowAlignment = .firstBaseline
    }

    let options = NSStackView(views: [statusBar, spelling, completions, autoPair, previews, indentGuides, writingTools])
    options.orientation = .vertical
    options.alignment = .leading
    options.spacing = 6
    let restore = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
    describe(restore, "Reset every setting to its original value.")
    let buttons = NSStackView(views: [NSView(), restore])
    buttons.orientation = .horizontal

    func group(_ title: String, _ body: NSView) -> NSStackView {
      let heading = NSTextField(labelWithString: title)
      heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
      let stack = NSStackView(views: [heading, body])
      stack.orientation = .vertical
      stack.alignment = .leading
      stack.spacing = 8
      return stack
    }

    let content = NSStackView(views: [
      group("General", generalGrid), group("Text", textGrid), group("Editing", options), buttons,
    ])
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = 16
    content.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
    window.contentView = content
    generalGrid.widthAnchor.constraint(equalTo: textGrid.widthAnchor).isActive = true
    buttons.widthAnchor.constraint(equalTo: textGrid.widthAnchor).isActive = true
    // Fit the window to its controls so the stack view doesn't stretch the grids' rows.
    content.layoutSubtreeIfNeeded()
    window.setContentSize(content.fittingSize)
    sync()
  }

  required init?(coder: NSCoder) { fatalError() }

  func show() {
    sync()
    showWindow(nil)
    window?.center()
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    window?.makeFirstResponder(nil)
  }

  private func sync() {
    let defaults = UserDefaults.standard
    appearanceControl.selectedSegment = AppAppearance.allCases.firstIndex(of: AppPreferences.appearance) ?? 0
    modeControl.selectedSegment = EditorMode.allCases.firstIndex(of: AppPreferences.defaultMode) ?? 0
    let size = WritingSize.allCases.min { abs($0.rawValue - AppPreferences.writingSize) < abs($1.rawValue - AppPreferences.writingSize) }
    writingSize.selectItem(withTitle: size?.title ?? WritingSize.medium.title)
    if let index = sourceFamily.itemArray.firstIndex(where: {
      ($0.representedObject as? String) == AppPreferences.sourceFontName
    }) {
      sourceFamily.selectItem(at: index)
    } else {
      sourceFamily.selectItem(at: 0)
    }
    sourceSize.stringValue = number.string(from: NSNumber(value: Double(AppPreferences.sourceFontSize))) ?? "13"
    sourceStepper.doubleValue = Double(AppPreferences.sourceFontSize)
    lineEnding.selectItem(at: AppPreferences.lineEnding == .crlf ? 1 : 0)
    tabWidth.selectItem(withTag: AppPreferences.tabWidth)
    textWidth.selectItem(withTitle: AppPreferences.textWidth.title)
    indentGuides.state = defaults.bool(forKey: PreferenceKey.indentGuides) ? .on : .off
    statusBar.state = defaults.bool(forKey: PreferenceKey.status) ? .on : .off
    spelling.state = defaults.bool(forKey: PreferenceKey.checkSpelling) ? .on : .off
    completions.state = AppPreferences.completions ? .on : .off
    autoPair.state = AppPreferences.autoPair ? .on : .off
    previews.state = AppPreferences.equationPreviews ? .on : .off
    writingTools.state = AppPreferences.writingToolsEnabled ? .on : .off
  }

  func controlTextDidEndEditing(_ notification: Notification) {
    guard let points = number.number(from: sourceSize.stringValue)?.doubleValue,
      (8...48).contains(points)
    else { return sync() }
    sourceStepper.doubleValue = points
    changeOption()
  }

  @objc private func changeOption() {
    let defaults = UserDefaults.standard
    if AppAppearance.allCases.indices.contains(appearanceControl.selectedSegment) {
      defaults.set(AppAppearance.allCases[appearanceControl.selectedSegment].rawValue, forKey: PreferenceKey.appearance)
    }
    if EditorMode.allCases.indices.contains(modeControl.selectedSegment) {
      defaults.set(EditorMode.allCases[modeControl.selectedSegment].rawValue, forKey: PreferenceKey.defaultMode)
    }
    if let value = writingSize.selectedItem?.representedObject as? Double {
      defaults.set(value, forKey: PreferenceKey.writingSize)
    }
    if let value = sourceFamily.selectedItem?.representedObject as? String {
      defaults.set(value, forKey: PreferenceKey.sourceFontName)
    }
    defaults.set(sourceStepper.doubleValue, forKey: PreferenceKey.sourceFontSize)
    sourceSize.stringValue = number.string(from: NSNumber(value: sourceStepper.doubleValue)) ?? ""
    if let value = lineEnding.selectedItem?.representedObject as? String {
      defaults.set(value, forKey: PreferenceKey.lineEnding)
    }
    if let width = textWidth.selectedItem?.representedObject as? String {
      defaults.set(width, forKey: PreferenceKey.textWidth)
    }
    if let width = tabWidth.selectedItem?.tag, width > 0 {
      defaults.set(width, forKey: PreferenceKey.tabWidth)
    }
    defaults.set(indentGuides.state == .on, forKey: PreferenceKey.indentGuides)
    defaults.set(statusBar.state == .on, forKey: PreferenceKey.status)
    defaults.set(spelling.state == .on, forKey: PreferenceKey.checkSpelling)
    defaults.set(completions.state == .on, forKey: PreferenceKey.completions)
    defaults.set(autoPair.state == .on, forKey: PreferenceKey.autoPair)
    defaults.set(previews.state == .on, forKey: PreferenceKey.equationPreviews)
    defaults.set(writingTools.state == .on, forKey: PreferenceKey.writingTools)
    AppPreferences.applyAppearance()
    NotificationCenter.default.post(name: .editorDefaultsDidChange, object: nil)
  }

  @objc private func restoreDefaults() {
    AppPreferences.settingKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    AppPreferences.applyAppearance()
    sync()
    NotificationCenter.default.post(name: .editorDefaultsDidChange, object: nil)
  }
}
