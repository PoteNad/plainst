import AppKit
import CoreText
import PlainstCore

enum PreferenceKey {
  static let appearance = "appearance"
  static let defaultMode = "defaultMode"
  static let status = "status"
  static let checkSpelling = "checkSpelling"
  static let writingTools = "writingTools"
  static let completions = "completions"
  static let autoPair = "autoPair"
  static let symbolsVisible = "symbolsVisible"
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

extension Notification.Name {
  static let editorDefaultsDidChange = Notification.Name("PlainstEditorDefaultsDidChange")
}

enum AppPreferences {
  static func registerDefaults() {
    UserDefaults.standard.register(defaults: [
      PreferenceKey.appearance: AppAppearance.system.rawValue,
      PreferenceKey.defaultMode: EditorMode.writing.rawValue,
      PreferenceKey.status: true,
      PreferenceKey.checkSpelling: false,
      PreferenceKey.writingTools: false,
      PreferenceKey.completions: true,
      PreferenceKey.autoPair: true,
    ])
  }

  static var completions: Bool { UserDefaults.standard.bool(forKey: PreferenceKey.completions) }
  static var autoPair: Bool { UserDefaults.standard.bool(forKey: PreferenceKey.autoPair) }

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
}

/// The typefaces Typst uses by default, registered so the Writing view matches the PDF.
@MainActor
enum Typefaces {
  static func registerBundledFonts() {
    for data in Engine.bundledFonts() {
      guard let provider = CGDataProvider(data: data as CFData), let font = CGFont(provider) else {
        continue
      }
      var error: Unmanaged<CFError>?
      CTFontManagerRegisterGraphicsFont(font, &error)
      error?.release()
    }
  }

  static func serif(size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
    let name: String
    switch (bold, italic) {
    case (true, true): name = "LibertinusSerif-BoldItalic"
    case (true, false): name = "LibertinusSerif-Bold"
    case (false, true): name = "LibertinusSerif-Italic"
    case (false, false): name = "LibertinusSerif-Regular"
    }
    if let font = NSFont(name: name, size: size) { return font }
    var traits: NSFontTraitMask = []
    if bold { traits.insert(.boldFontMask) }
    if italic { traits.insert(.italicFontMask) }
    return NSFontManager.shared.font(
      withFamily: "Times New Roman", traits: traits, weight: bold ? 9 : 5, size: size)
      ?? .systemFont(ofSize: size)
  }

  static func typstMono(size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
    let name: String
    switch (bold, italic) {
    case (true, true): name = "DejaVuSansMono-BoldOblique"
    case (true, false): name = "DejaVuSansMono-Bold"
    case (false, true): name = "DejaVuSansMono-Oblique"
    case (false, false): name = "DejaVuSansMono"
    }
    return NSFont(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
  }

  static func editorMono(size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
    var font = NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
    if italic {
      font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }
    return font
  }
}

@MainActor
final class SettingsWindowController: NSWindowController {
  private let appearanceControl = NSSegmentedControl(
    labels: AppAppearance.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
  private let modeControl = NSSegmentedControl(
    labels: EditorMode.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
  private let statusBar = NSButton(checkboxWithTitle: "Show status bar", target: nil, action: nil)
  private let spelling = NSButton(
    checkboxWithTitle: "Check spelling while typing", target: nil, action: nil)
  private let writingTools = NSButton(
    checkboxWithTitle: "Enable Writing Tools (Apple Intelligence)", target: nil, action: nil)

  init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Plainst Settings"
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
    window.standardWindowButton(.zoomButton)?.isEnabled = false

    for control in [appearanceControl, modeControl] as [NSControl] {
      control.target = self
      control.action = #selector(changeOption)
    }
    for button in [statusBar, spelling, writingTools] {
      button.target = self
      button.action = #selector(changeOption)
    }
    func describe(_ control: NSView, _ text: String) {
      control.toolTip = text
      control.setAccessibilityHelp(text)
    }
    describe(appearanceControl, "Follow the system appearance or always use Light or Dark.")
    describe(modeControl, "Choose how documents look when they open. You can switch any time.")
    describe(statusBar, "Show the cursor position, word count, page count, and zoom level.")
    describe(spelling, "Underline possible spelling mistakes while you type.")
    describe(
      writingTools,
      "Show Apple's Writing Tools in the Edit menu when they are available.")
    if #unavailable(macOS 15.2) {
      writingTools.isEnabled = false
      writingTools.toolTip = "Requires macOS 15.2 or newer."
      writingTools.setAccessibilityHelp("Requires macOS 15.2 or newer.")
    }

    let generalGrid = NSGridView(views: [
      [NSTextField(labelWithString: "Appearance:"), appearanceControl],
      [NSTextField(labelWithString: "Open documents in:"), modeControl],
    ])
    generalGrid.rowSpacing = 8
    generalGrid.columnSpacing = 12
    generalGrid.column(at: 0).xPlacement = .trailing
    generalGrid.column(at: 1).width = 260
    let options = NSStackView(views: [statusBar, spelling, writingTools])
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

    let general = group("General", generalGrid)
    let editing = group("Editing", options)
    let content = NSStackView(views: [general, editing, buttons])
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = 16
    content.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
    window.contentView = content
    buttons.widthAnchor.constraint(equalTo: generalGrid.widthAnchor).isActive = true
    // Fit the window to its controls so the stack view doesn't stretch the grid's rows.
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
    appearanceControl.selectedSegment = AppAppearance.allCases.firstIndex(of: AppPreferences.appearance) ?? 0
    modeControl.selectedSegment = EditorMode.allCases.firstIndex(of: AppPreferences.defaultMode) ?? 0
    statusBar.state = UserDefaults.standard.bool(forKey: PreferenceKey.status) ? .on : .off
    spelling.state = UserDefaults.standard.bool(forKey: PreferenceKey.checkSpelling) ? .on : .off
    writingTools.state = AppPreferences.writingToolsEnabled ? .on : .off
  }

  @objc private func changeOption() {
    let defaults = UserDefaults.standard
    if AppAppearance.allCases.indices.contains(appearanceControl.selectedSegment) {
      defaults.set(AppAppearance.allCases[appearanceControl.selectedSegment].rawValue, forKey: PreferenceKey.appearance)
    }
    if EditorMode.allCases.indices.contains(modeControl.selectedSegment) {
      defaults.set(EditorMode.allCases[modeControl.selectedSegment].rawValue, forKey: PreferenceKey.defaultMode)
    }
    defaults.set(statusBar.state == .on, forKey: PreferenceKey.status)
    defaults.set(spelling.state == .on, forKey: PreferenceKey.checkSpelling)
    defaults.set(writingTools.state == .on, forKey: PreferenceKey.writingTools)
    AppPreferences.applyAppearance()
    NotificationCenter.default.post(name: .editorDefaultsDidChange, object: nil)
  }

  @objc private func restoreDefaults() {
    for key in [PreferenceKey.appearance, PreferenceKey.defaultMode, PreferenceKey.status, PreferenceKey.checkSpelling, PreferenceKey.writingTools] {
      UserDefaults.standard.removeObject(forKey: key)
    }
    AppPreferences.applyAppearance()
    sync()
    NotificationCenter.default.post(name: .editorDefaultsDidChange, object: nil)
  }
}
