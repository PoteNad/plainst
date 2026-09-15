import AppKit
import PlainstCore
import PlainstEditor

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private lazy var settingsController = SettingsWindowController()
  private let recentMenu = NSMenu(title: "Open Recent")
  private var writingToolsItems: [NSMenuItem] = []

  // Menus are built before windows are restored or opened, so the menu bar is never empty
  // while the first document appears.
  func applicationWillFinishLaunching(_ notification: Notification) {
    NSWindow.allowsAutomaticWindowTabbing = true
    buildMenus()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NotificationCenter.default.addObserver(
      self, selector: #selector(preferencesDidChange), name: .editorDefaultsDidChange, object: nil)
    TypstEditor.engineQueue.async { Engine.warmUp() }
    #if PLAINST_CHECKS
      // Automated checks run in the background so they never take keyboard focus from the user.
      if AppChecks.isChecking { return }
    #endif
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
  func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func buildMenus() {
    let bar = NSMenu()
    NSApp.mainMenu = bar

    func menu(_ title: String) -> NSMenu {
      let item = NSMenuItem()
      let menu = NSMenu(title: title)
      item.submenu = menu
      bar.addItem(item)
      return menu
    }

    func submenu(_ parent: NSMenu, _ title: String) -> NSMenu {
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      let menu = NSMenu(title: title)
      item.submenu = menu
      parent.addItem(item)
      return menu
    }

    @discardableResult
    func add(
      _ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
      modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil, tag: Int? = nil
    ) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.keyEquivalentModifierMask = modifiers
      item.target = target
      if let tag { item.tag = tag }
      menu.addItem(item)
      return item
    }

    let app = menu("Plainst")
    add(app, "About Plainst", #selector(showAbout(_:)), target: self)
    app.addItem(.separator())
    add(app, "Settings…", #selector(showSettings(_:)), ",", target: self)
    app.addItem(.separator())
    let services = submenu(app, "Services")
    NSApp.servicesMenu = services
    app.addItem(.separator())
    add(app, "Hide Plainst", #selector(NSApplication.hide(_:)), "h")
    add(
      app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h",
      modifiers: [.command, .option])
    add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
    app.addItem(.separator())
    add(app, "Quit Plainst", #selector(NSApplication.terminate(_:)), "q")

    let file = menu("File")
    add(file, "New Window", #selector(NSDocumentController.newDocument(_:)), "n")
    add(file, "New Tab", #selector(PlainstDocumentController.newWindowForTab(_:)), "t")
    add(file, "Open…", #selector(NSDocumentController.openDocument(_:)), "o")
    let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
    recentItem.submenu = recentMenu
    recentMenu.delegate = self
    file.addItem(recentItem)
    file.addItem(.separator())
    add(file, "Close", #selector(NSWindow.performClose(_:)), "w")
    add(file, "Save", #selector(NSDocument.save(_:)), "s")
    add(file, "Save As…", #selector(NSDocument.saveAs(_:)), "s", modifiers: [.command, .shift])
    add(file, "Revert to Saved", #selector(NSDocument.revertToSaved(_:)))
    file.addItem(.separator())
    add(
      file, "Duplicate", #selector(NSDocument.duplicate(_:)), "s",
      modifiers: [.command, .shift, .option])
    add(file, "Rename…", #selector(NSDocument.rename(_:)))
    add(file, "Move To…", #selector(NSDocument.move(_:)))
    file.addItem(.separator())
    add(
      file, "Export as PDF…", #selector(PlainstDocument.exportPDF(_:)), "e",
      modifiers: [.command, .shift])
    add(file, "Print…", #selector(NSDocument.printDocument(_:)), "p")

    let edit = menu("Edit")
    add(edit, "Undo", Selector(("undo:")), "z")
    add(edit, "Redo", Selector(("redo:")), "z", modifiers: [.command, .shift])
    edit.addItem(.separator())
    add(edit, "Cut", #selector(NSText.cut(_:)), "x")
    add(edit, "Copy", #selector(NSText.copy(_:)), "c")
    add(edit, "Paste", #selector(NSText.paste(_:)), "v")
    add(edit, "Delete", #selector(NSText.delete(_:)))
    add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
    edit.addItem(.separator())
    let find = submenu(edit, "Find")
    add(find, "Find…", #selector(Editor.showFind(_:)), "f")
    add(
      find, "Find and Replace…", #selector(Editor.showReplace(_:)), "f",
      modifiers: [.command, .option])
    add(find, "Find Next", #selector(Editor.findNext(_:)), "g")
    add(
      find, "Find Previous", #selector(Editor.findPrevious(_:)), "g", modifiers: [.command, .shift])
    find.addItem(.separator())
    add(
      find, "Use Selection for Find", #selector(NSTextView.performTextFinderAction(_:)), "e",
      tag: NSTextFinder.Action.setSearchString.rawValue)
    add(find, "Jump to Selection", #selector(NSTextView.centerSelectionInVisibleArea(_:)), "j")
    add(edit, "Go to Line…", #selector(Editor.goToLine(_:)), "l")
    add(edit, "Show Completions", #selector(NSTextView.complete(_:)), "\u{1b}", modifiers: [.option])
    edit.addItem(.separator())
    if #available(macOS 15.2, *) {
      writingToolsItems = NSMenuItem.writingToolsItems
      writingToolsItems.forEach(edit.addItem)
      updateWritingToolsItem()
    }
    let spelling = submenu(edit, "Spelling and Grammar")
    add(spelling, "Show Spelling and Grammar", #selector(NSTextView.showGuessPanel(_:)), ":")
    add(spelling, "Check Document Now", #selector(NSTextView.checkSpelling(_:)), ";")
    spelling.addItem(.separator())
    add(
      spelling, "Check Spelling While Typing",
      #selector(NSTextView.toggleContinuousSpellChecking(_:)))
    let transformations = submenu(edit, "Transformations")
    add(transformations, "Make Upper Case", #selector(NSResponder.uppercaseWord(_:)))
    add(transformations, "Make Lower Case", #selector(NSResponder.lowercaseWord(_:)))
    add(transformations, "Capitalize", #selector(NSResponder.capitalizeWord(_:)))
    let speech = submenu(edit, "Speech")
    add(speech, "Start Speaking", #selector(NSTextView.startSpeaking(_:)))
    add(speech, "Stop Speaking", #selector(NSTextView.stopSpeaking(_:)))

    let format = menu("Format")
    add(format, "Bold", #selector(Editor.toggleBold(_:)), "b")
    add(format, "Italic", #selector(Editor.toggleItalic(_:)), "i")
    add(format, "Code", #selector(Editor.toggleCode(_:)), "k", modifiers: [.command, .control])
    format.addItem(.separator())
    add(format, "Heading 1", #selector(Editor.makeHeading(_:)), "1", modifiers: [.command, .option], tag: 1)
    add(format, "Heading 2", #selector(Editor.makeHeading(_:)), "2", modifiers: [.command, .option], tag: 2)
    add(format, "Heading 3", #selector(Editor.makeHeading(_:)), "3", modifiers: [.command, .option], tag: 3)
    add(format, "Body Text", #selector(Editor.makeHeading(_:)), "0", modifiers: [.command, .option], tag: 0)
    format.addItem(.separator())
    add(format, "Bulleted List", #selector(Editor.toggleBulletedList(_:)), "8", modifiers: [.command, .shift])
    add(format, "Numbered List", #selector(Editor.toggleNumberedList(_:)), "7", modifiers: [.command, .shift])
    add(format, "Increase Indent", #selector(Editor.increaseIndent(_:)), "]")
    add(format, "Decrease Indent", #selector(Editor.decreaseIndent(_:)), "[")
    format.addItem(.separator())
    add(format, "Equation", #selector(Editor.insertInlineEquation(_:)), "e", modifiers: [.command, .option])
    add(
      format, "Display Equation", #selector(Editor.insertDisplayEquation(_:)), "e",
      modifiers: [.command, .option, .shift])

    let view = menu("View")
    add(view, "Writing", #selector(Editor.showWriting(_:)), "1")
    add(view, "Source", #selector(Editor.showSource(_:)), "2")
    view.addItem(.separator())
    add(view, "Show Outline", #selector(Editor.toggleOutline(_:)), "s", modifiers: [.command, .control])
    add(view, "Show Preview", #selector(Editor.togglePreview(_:)), "p", modifiers: [.command, .option])
    add(view, "Show Symbols", #selector(Editor.toggleSymbols(_:)), "t", modifiers: [.command, .option])
    add(view, "Go to Heading…", #selector(Editor.showOutline(_:)), "6", modifiers: [.control])
    view.addItem(.separator())
    add(view, "Zoom In", #selector(Editor.zoomIn(_:)), "+")
    add(view, "Zoom Out", #selector(Editor.zoomOut(_:)), "-")
    add(view, "Actual Size", #selector(Editor.zoomReset(_:)), "0")
    view.addItem(.separator())
    add(view, "Show Status Bar", #selector(Editor.toggleStatus(_:)))
    view.addItem(.separator())
    add(
      view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f",
      modifiers: [.command, .control])

    let window = menu("Window")
    add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
    add(window, "Zoom", #selector(NSWindow.performZoom(_:)))
    window.addItem(.separator())
    add(
      window, "Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "[",
      modifiers: [.command, .shift])
    add(
      window, "Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "]",
      modifiers: [.command, .shift])
    add(window, "Move Tab to New Window", #selector(NSWindow.moveTabToNewWindow(_:)))
    add(window, "Merge All Windows", #selector(NSWindow.mergeAllWindows(_:)))
    window.addItem(.separator())
    add(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
    NSApp.windowsMenu = window

    let help = menu("Help")
    add(help, "Plainst Guide", #selector(showGuide(_:)), "?", target: self)
    help.addItem(.separator())
    add(help, "Typst Documentation", #selector(openTypstDocs(_:)), target: self)
    add(help, "Plainst on GitHub", #selector(openGitHub(_:)), target: self)
    NSApp.helpMenu = help
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    guard menu === recentMenu else { return }
    menu.removeAllItems()
    let urls = NSDocumentController.shared.recentDocumentURLs
    if urls.isEmpty {
      let empty = NSMenuItem(title: "No Recent Documents", action: nil, keyEquivalent: "")
      empty.isEnabled = false
      menu.addItem(empty)
      return
    }
    for url in urls {
      let item = NSMenuItem(
        title: FileManager.default.displayName(atPath: url.path),
        action: #selector(openRecent(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = url
      item.toolTip = url.path
      menu.addItem(item)
    }
    menu.addItem(.separator())
    let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecent(_:)), keyEquivalent: "")
    clear.target = self
    menu.addItem(clear)
  }

  @objc func showAbout(_ sender: Any?) {
    // Like PoteNad, show only the version, not the build number.
    NSApp.orderFrontStandardAboutPanel(options: [
      .version: "",
      .credits: NSAttributedString(
        string: "A small, native Typst editor for prose and math.\nTypesetting by the Typst compiler (Apache-2.0).",
        attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor])
    ])
  }

  @objc private func showSettings(_ sender: Any?) { settingsController.show() }

  @objc private func preferencesDidChange(_ notification: Notification) { updateWritingToolsItem() }

  private func updateWritingToolsItem() {
    writingToolsItems.forEach { $0.isHidden = !AppPreferences.writingToolsEnabled }
  }

  @objc private func openRecent(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? URL else { return }
    NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
      if let error { NSApp.presentError(error) }
    }
  }

  @objc private func clearRecent(_ sender: Any?) {
    NSDocumentController.shared.clearRecentDocuments(sender)
  }

  @objc private func showGuide(_ sender: Any?) {
    (NSDocumentController.shared as? PlainstDocumentController)?.openUntitled(text: Guide.text, name: "Plainst Guide")
  }

  @objc private func openTypstDocs(_ sender: Any?) {
    NSWorkspace.shared.open(URL(string: "https://typst.app/docs/reference/syntax/")!)
  }

  @objc private func openGitHub(_ sender: Any?) {
    NSWorkspace.shared.open(URL(string: "https://github.com/PoteNad/plainst")!)
  }
}

enum Guide {
  static let text = """
    = Welcome to Plainst

    Plainst edits one Typst file of prose and math. Press *⌘2* to see the source of this page and *⌘1* to come back. Press *⌥⌘P* to show the typeset document beside the text, and *⌃6* to jump to a heading.

    == Text

    Write paragraphs as plain text, separated by a blank line. Use *bold* with asterisks, _italic_ with underscores, and `code` with backticks. Two hyphens make an en dash -- like this.

    == Lists

    - Start a bulleted item with a hyphen.
    - Press Return to continue the list, or Return twice to end it.
      - Press Tab to nest an item.

    + Numbered items start with a plus sign.
    + Plainst numbers them for you.

    / Term: A term list pairs a term with its description.

    == Math

    Put inline math between dollar signs, like $a^2 + b^2 = c^2$. Click an equation to edit it; a preview appears below while you type.

    Add spaces inside the dollar signs for a display equation:

    $ integral_0^1 x^2 dif x = 1/3 $

    $ sum_(k=1)^n k = (n(n+1))/2 $

    Greek letters and symbols have names: $alpha, beta, pi, infinity, arrow.r$. Press *⌥⌘T* to browse them all.

    == Labels and references <references>

    A label names the heading, equation, or figure just before it. Write it in angle brackets, like the label after this section's title.

    Numbered things can be referred to by their labels. Turn on equation numbers, label an equation, and refer to it with an \\@ sign followed by the label. Plainst suggests your labels as you type.

    #set math.equation(numbering: "(1)")

    $ e^(i pi) + 1 = 0 $ <euler>

    Euler's identity, @euler, connects five famous constants. Headings need numbers too before you can refer to them, which `#set heading(numbering: "1.")` turns on.

    == Everything else

    Plainst keeps any other Typst exactly as written and shows it in grey, like the next line. Show the preview to see its effect on the typeset document.

    #set text(lang: "en")

    // Comments like this one never appear in the PDF.

    Choose *File → Export as PDF* to typeset the document with Typst.
    """
}
