#if PLAINST_CHECKS
import AppKit
import PDFKit
import PlainstCore

/// End-to-end checks driven by environment variables, used by scripts/check.sh.
@MainActor
enum AppChecks {
  static let environment = ProcessInfo.processInfo.environment

  static func fail(_ message: String) -> Never {
    fputs("Check failed: \(message)\n", stderr)
    exit(1)
  }

  /// Whether this launch is an automated check, which must not touch the user's drafts.
  static var isChecking: Bool {
    [
      "PLAINST_LAUNCH_CHECK", "PLAINST_EDIT_CHECK", "PLAINST_PERF_CHECK",
      "PLAINST_ROUNDTRIP_CHECK", "PLAINST_EXPORT_CHECK", "PLAINST_SNAPSHOT", "PLAINST_INPUT_CHECK",
    ]
      .contains { environment[$0] != nil }
  }

  /// Discards every open document so no draft is left behind, then quits.
  static func finish() -> Never {
    for document in NSDocumentController.shared.documents {
      document.updateChangeCount(.changeCleared)
      document.autosavedContentsFileURL.map { try? FileManager.default.removeItem(at: $0) }
      document.close()
    }
    exit(0)
  }

  static func pass(_ message: String) {
    print("Check passed: \(message)")
    fflush(stdout)
  }

  static func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(body) }
  }

  static func open(_ path: String, controller: PlainstDocumentController, then body: @escaping @MainActor (PlainstDocument) -> Void) {
    after(0.5) {
      controller.openDocument(withContentsOf: URL(fileURLWithPath: path), display: true) {
        document, _, error in
        MainActor.assumeIsolated {
          guard let document = document as? PlainstDocument else {
            fail("could not open \(path): \(String(describing: error))")
          }
          body(document)
        }
      }
    }
  }

  static func run(controller: PlainstDocumentController) {
    if environment["PLAINST_LAUNCH_CHECK"] == "1" { launchCheck(controller) }
    if environment["PLAINST_EDIT_CHECK"] == "1" { editCheck(controller) }
    if let path = environment["PLAINST_PERF_CHECK"] { performanceCheck(path, controller) }
    if let path = environment["PLAINST_ROUNDTRIP_CHECK"] { roundTripCheck(path, controller) }
    if let path = environment["PLAINST_EXPORT_CHECK"] { exportCheck(path, controller) }
    if let path = environment["PLAINST_SNAPSHOT"] { snapshot(path, controller) }
    if environment["PLAINST_INPUT_CHECK"] == "1" { inputCheck(controller) }
  }

  private static func launchCheck(_ controller: PlainstDocumentController) {
    after(1.5) {
      let windows = controller.documents.flatMap(\.windowControllers).compactMap(\.window)
      guard controller.documents.count == 1, windows.count == 1, windows[0].isVisible,
        let editor = (controller.documents[0] as? PlainstDocument)?.editor
      else { fail("expected one visible untitled window") }
      guard windows[0].firstResponder === editor.textView else {
        fail("the text view should have keyboard focus")
      }
      editor.textView.insertText("= Hello\n\nSome *bold* and $x^2$.", replacementRange: editor.textView.selectedRange())
      editor.setMode(.source)
      editor.setMode(.writing)
      controller.newWindowForTab(nil)
      after(1.5) {
        guard controller.documents.count == 2,
          windows[0].tabbedWindows?.count == 2
        else { fail("New Tab should add a tab to the window") }
        guard editor.text == "= Hello\n\nSome *bold* and $x^2$." else {
          fail("switching views changed the text to \(editor.text.debugDescription)")
        }
        guard !editor.presentation.replacements.isEmpty else {
          fail("the equation was not rendered in the Writing view")
        }
        // Saving a new document writes a Typst file with exactly the typed text.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("New.typ")
        guard let document = controller.documents.first(where: { ($0 as? PlainstDocument)?.editor === editor }),
          let type = controller.defaultType
        else { fail("no document to save") }
        document.save(to: url, ofType: type, for: .saveAsOperation) { error in
          MainActor.assumeIsolated {
            if let error { fail("saving a new document failed: \(error)") }
            guard FileManager.default.contents(atPath: url.path) == Data("= Hello\n\nSome *bold* and $x^2$.".utf8),
              document.fileURL?.pathExtension == "typ", !document.isDocumentEdited
            else { fail("the saved file did not match the text") }
            try? FileManager.default.removeItem(at: folder)
            pass("windows, tabs, views, equation rendering and saving new documents work")

            // Every catalogued symbol exists in Typst, and inserting symbols writes valid math.
            let missing = SymbolCatalog.groups.flatMap(\.names).filter { SymbolCatalog.values[$0] == nil }
            guard missing.isEmpty else { fail("unknown symbols in the catalog: \(missing)") }
            editor.loadText("Let  be x.")
            editor.textView.setSelectedRange(NSRange(location: 4, length: 0))
            editor.insertMath("epsilon", snippet: false)
            guard editor.text == "Let $epsilon$ be x." else {
              fail("inserting a symbol in prose should add an equation: \(editor.text.debugDescription)")
            }
            editor.textView.setSelectedRange(NSRange(location: 12, length: 0))
            editor.insertMath("arrow.r", snippet: false)
            let body = (editor.text as NSString).range(of: "x.")
            editor.textView.setSelectedRange(NSRange(location: body.location, length: 1))
            editor.insertMath("sqrt(${x})", snippet: true)
            guard editor.text == "Let $epsilon arrow.r$ be $sqrt(x)$.",
              Engine.compile(editor.text, pdf: false).errors.isEmpty
            else {
              fail("inserting symbols and structures produced \(editor.text.debugDescription)")
            }
            pass("the symbol catalog is valid and inserting symbols and structures writes valid Typst")
            finish()
          }
        }
      }
    }
  }

  /// Types, formats, undoes and makes random edits in both views, checking the text stays exact.
  private static func editCheck(_ controller: PlainstDocumentController) {
    after(1.5) {
      guard let document = controller.documents.first as? PlainstDocument,
        let editor = document.editor, let undo = document.undoManager
      else { fail("expected an untitled document") }
      let view = editor.textView
      @MainActor func type(_ text: String) {
        for character in text {
          if character == "\n" {
            view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
          } else {
            view.insertText(String(character), replacementRange: view.selectedRange())
          }
        }
      }
      @MainActor func expect(_ text: String, _ what: String) {
        guard editor.text == text else {
          fail("\(what): expected \(text.debugDescription), found \(editor.text.debugDescription)")
        }
      }
      @MainActor func settle() {
        editor.layout.ensureLayout(for: editor.container)
        view.display()
      }

      type("= Notes\n\n- one\ntwo\n\n")
      expect("= Notes\n\n- one\n- two\n", "Return should continue a list and end it on an empty item")
      type("Energy is $E = m c^2$ here.")
      view.setSelectedRange(NSRange(location: 0, length: 0))
      after(1.5) {
      settle()
      let mathStart = (editor.text as NSString).range(of: "$E").location
      guard editor.presentation.replacements[mathStart] != nil,
        editor.presentation.hidden.contains(mathStart + 1)
      else {
        fail("a rendered equation away from the caret should be concealed")
      }
      view.setSelectedRange(NSRange(location: mathStart + 3, length: 0))
      settle()
      guard editor.presentation.activeMath != nil, !editor.preview.isHidden else {
        fail("placing the caret in an equation should show its preview")
      }
      let before = editor.text
      let word = (editor.text as NSString).range(of: "Energy")
      view.setSelectedRange(word)
      // Close the automatic undo group between commands, as separate key presses would.
      @MainActor func asEvent(_ body: () -> Void) {
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
      }
      after(0.1) {
      asEvent { editor.toggleBold(nil) }
      expect(before.replacingOccurrences(of: "Energy", with: "*Energy*"), "Bold should wrap the selection")
      after(0.1) {
      asEvent { editor.toggleBold(nil) }
      expect(before, "Bold again should unwrap the selection")
      after(0.1) {
      undo.undo()
      expect(before.replacingOccurrences(of: "Energy", with: "*Energy*"), "Undo should restore the previous formatting")
      undo.redo()
      expect(before, "Redo should reapply the change")

      // Random edits in both views must never change anything but the intended text.
      var generator = CheckRandomNumberGenerator()
      let snippets = ["*", "_", "$", "$ x $", "= ", "\n", "- ", "+ ", "```\n", "`", "#set", "//", "a", " ", "é😀", "\\", "--", "/ T: d"]
      var model = editor.text as NSString
      let start = Date()
      for step in 0..<600 {
        if step % 150 == 0 { editor.setMode(step % 300 == 0 ? .source : .writing) }
        let length = model.length
        let location = Int.random(in: 0...length, using: &generator)
        let span = Int.random(in: 0...min(3, length - location), using: &generator)
        var range = NSRange(location: location, length: span)
        // Keep composed characters whole, as the text view would.
        if length > 0 {
          range = model.rangeOfComposedCharacterSequences(for: range)
        }
        let insertion = Bool.random(using: &generator) ? snippets.randomElement(using: &generator)! : ""
        asEvent {
          view.setSelectedRange(NSRange(location: range.location, length: 0))
          view.insertText(insertion, replacementRange: range)
        }
        model = model.replacingCharacters(in: range, with: insertion) as NSString
        if step % 20 == 0 { settle() }
        guard editor.text == model as String else {
          fail(
            "random edit \(step) (\(insertion.debugDescription) at \(range)) desynchronised the text: expected \((model as String).debugDescription), found \(editor.text.debugDescription)")
        }
      }
      settle()
      let elapsed = Date().timeIntervalSince(start)
      pass("typing, lists, formatting, undo and 600 random edits (\(String(format: "%.2f", elapsed))s)")
      finish()
      }
      }
      }
      }
    }
  }

  /// Sends real key and mouse events, the way a person types and clicks.
  private static func inputCheck(_ controller: PlainstDocumentController) {
    after(1.5) {
      guard let document = controller.documents.first as? PlainstDocument,
        let editor = document.editor, let window = editor.window
      else { fail("expected an untitled document") }
      let view = editor.textView
      // Mouse events only reach an active window, so this one check brings the app forward.
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)

      @MainActor func key(_ characters: String, code: UInt16 = 0) {
        for event: NSEvent.EventType in [.keyDown, .keyUp] {
          guard let e = NSEvent.keyEvent(
            with: event, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code)
          else { fail("could not make a key event") }
          NSApp.sendEvent(e)
        }
      }
      @MainActor func type(_ text: String) { for c in text { key(String(c)) } }
      @MainActor func left() { key("\u{F702}", code: 123) }
      /// Clicks at a point in the text view's coordinates.
      @MainActor func click(_ point: NSPoint, count: Int = 1, hold: Double = 0) {
        let location = view.convert(point, to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        guard
          let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: location, modifierFlags: [], timestamp: time,
            windowNumber: window.windowNumber, context: nil, eventNumber: count, clickCount: count,
            pressure: 1),
          let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: location, modifierFlags: [], timestamp: time + 0.01,
            windowNumber: window.windowNumber, context: nil, eventNumber: count, clickCount: count,
            pressure: 0)
        else { fail("could not make a mouse event") }
        if hold > 0 {
          // Release later, so AppKit tracks the press the way it does for a person.
          DispatchQueue.main.asyncAfter(deadline: .now() + hold) { NSApp.postEvent(up, atStart: false) }
        } else {
          NSApp.postEvent(up, atStart: false)
        }
        NSApp.sendEvent(down)
      }

      // Typing between two dollar signs keeps the cursor inside the equation.
      type("Energy $")
      type("$")
      left()
      type("m")
      after(0.8) {
        type("c")
        after(0.8) {
          guard editor.text == "Energy $mc$", view.selectedRange() == NSRange(location: 10, length: 0)
          else {
            fail("typing inside $$ moved the cursor: \(editor.text.debugDescription) selection \(view.selectedRange())")
          }
          pass("typing between dollar signs keeps the cursor in the equation")

          // Clicking below the last line puts the cursor at the very end.
          editor.loadText("one\ntwo\nthree\nfour\n")
          after(0.5) {
            editor.layout.ensureLayout(for: editor.container)
            let used = editor.layout.usedRect(for: editor.container)
            let origin = view.textContainerOrigin
            click(NSPoint(x: origin.x + 20, y: origin.y + used.maxY + 60))
            after(0.3) {
              guard view.selectedRange().location == editor.storage.length else {
                fail("clicking below the text put the cursor at \(view.selectedRange().location), not \(editor.storage.length)")
              }
              let lastLine = (editor.text as NSString).range(of: "four")
              let rect = editor.layout.boundingRect(
                forGlyphRange: editor.layout.glyphRange(forCharacterRange: lastLine, actualCharacterRange: nil),
                in: editor.container)
              click(NSPoint(x: origin.x + rect.maxX + 40, y: origin.y + rect.midY))
              after(0.3) {
                guard view.selectedRange().location == NSMaxRange(lastLine) else {
                  fail("clicking the last text line put the cursor at \(view.selectedRange().location), not \(NSMaxRange(lastLine))")
                }
                pass("clicking the last line and below the text places the cursor there")

                // Clicking a rendered display equation's card opens its source for editing.
                editor.loadText("Before\n\n$ x^2 + 1 $\n\nAfter\n")
                after(1.5) {
                  editor.layout.ensureLayout(for: editor.container)
                  guard let block = editor.presentation.mathBlocks.first, block.rendered else {
                    fail("the display equation should render as a card")
                  }
                  let glyph = editor.layout.glyphIndexForCharacter(at: block.range.location)
                  let line = editor.layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                  click(NSPoint(x: origin.x + 30, y: origin.y + line.midY))
                  after(0.5) {
                    let caret = view.selectedRange()
                    guard caret == NSRange(location: NSMaxRange(block.range) - 2, length: 0),
                      editor.presentation.mathBlocks.first?.active == true, !editor.preview.isHidden
                    else {
                      fail("clicking the card should edit the equation; cursor at \(caret)")
                    }
                    type("0")
                    after(0.5) {
                      guard editor.text == "Before\n\n$ x^2 + 10 $\n\nAfter\n",
                        view.selectedRange().location == NSMaxRange(block.range) - 1
                      else {
                        fail("typing in the card's field went elsewhere: \(editor.text.debugDescription)")
                      }
                      pass("clicking an equation card edits its source in place")

                      // Double-clicking a word in the source field selects that word.
                      let word = (editor.text as NSString).range(of: "10")
                      editor.layout.ensureLayout(for: editor.container)
                      let glyphs = editor.layout.glyphRange(forCharacterRange: word, actualCharacterRange: nil)
                      let rect = editor.layout.boundingRect(forGlyphRange: glyphs, in: editor.container)
                      let point = NSPoint(x: origin.x + rect.midX, y: origin.y + rect.midY)
                      click(point, count: 1)
                      click(point, count: 2)
                      after(0.5) {
                        guard view.selectedRange() == word else {
                          fail("double-clicking a word in the equation selected \(view.selectedRange()), not \(word)")
                        }
                        pass("double-clicking a word in an equation's source selects it")

                        // Dollar signs pair, Typst completions appear, and snippets fill in.
                        editor.loadText("")
                        type("Area $")
                        guard editor.text == "Area $$", view.selectedRange().location == 6 else {
                          fail("typing $ should insert a pair: \(editor.text.debugDescription)")
                        }
                        type("alp")
                        after(1.0) {
                          guard editor.assistant.popup.isVisible,
                            editor.assistant.popup.items.first?.label == "alpha"
                          else {
                            fail("typing alp in an equation should suggest alpha; got \(editor.assistant.popup.items.prefix(3).map(\.label))")
                          }
                          key("\r", code: 36)
                          guard editor.text == "Area $alpha$", !editor.assistant.popup.isVisible else {
                            fail("Return should accept the completion: \(editor.text.debugDescription)")
                          }
                          type(" = fra")
                          after(1.0) {
                            guard editor.assistant.popup.items.first?.label == "frac" else {
                              fail("typing fra should suggest frac")
                            }
                            key("\t", code: 48)
                            after(0.3) {
                              let text = editor.text as NSString
                              let open = text.range(of: "frac(").location
                              guard open != NSNotFound, view.selectedRange().location == open + 5 else {
                                fail("accepting frac should place the cursor in its first placeholder: \(editor.text.debugDescription) \(view.selectedRange())")
                              }
                              type("1, 2")
                              key("\t", code: 48)
                              let after = (editor.text as NSString).range(of: "frac(1, 2)")
                              guard after.location != NSNotFound,
                                view.selectedRange().location == NSMaxRange(after)
                              else {
                                fail("Tab after the last placeholder should leave the snippet: \(editor.text.debugDescription) \(view.selectedRange())")
                              }
                              pass("dollar signs pair, completions insert symbols, and Tab moves through snippets")
                              finish()
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  /// Measures typing in a large document, including layout of the visible text.
  private static func performanceCheck(_ path: String, _ controller: PlainstDocumentController) {
    open(path, controller: controller) { document in
      guard let editor = document.editor else { fail("no editor") }
      after(3) {
        let view = editor.textView
        let middle = editor.storage.length / 2
        view.setSelectedRange(NSRange(location: middle, length: 0))
        view.scrollRangeToVisible(view.selectedRange())
        view.display()
        var samples: [Double] = []
        for character in "Typing *speed* $x^2$ test " {
          let start = Date()
          view.insertText(String(character), replacementRange: view.selectedRange())
          view.displayIfNeeded()
          samples.append(Date().timeIntervalSince(start) * 1000)
        }
        samples.sort()
        let median = samples[samples.count / 2]
        let worst = samples.last ?? 0
        pass(
          "\(editor.storage.length) characters: median \(String(format: "%.1f", median)) ms, worst \(String(format: "%.1f", worst)) ms per keystroke")
        finish()
      }
    }
  }

  /// Opens a file, moves through every position in both views, saves, and compares bytes.
  private static func roundTripCheck(_ path: String, _ controller: PlainstDocumentController) {
    guard let original = FileManager.default.contents(atPath: path) else {
      fail("missing fixture \(path)")
    }
    open(path, controller: controller) { document in
      guard let editor = document.editor else { fail("no editor") }
      after(1.5) {
        for mode in [EditorMode.writing, .source, .writing] {
          editor.setMode(mode)
          for location in stride(from: 0, through: editor.storage.length, by: 1) {
            editor.textView.setSelectedRange(NSRange(location: location, length: 0))
          }
          editor.textView.setSelectedRange(NSRange(location: 0, length: editor.storage.length))
        }
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        document.updateChangeCount(.changeDone)
        document.save(to: URL(fileURLWithPath: path), ofType: document.fileType ?? "app.typst.typ", for: .saveOperation) { error in
          MainActor.assumeIsolated {
            if let error { fail("save failed: \(error)") }
            guard FileManager.default.contents(atPath: path) == original else {
              fail("saving an unedited document changed its bytes")
            }
            pass("opening, browsing both views and saving kept the file byte-identical")
            finish()
          }
        }
      }
    }
  }

  private static func exportCheck(_ pdfPath: String, _ controller: PlainstDocumentController) {
    guard let source = environment["PLAINST_OPEN"] else { fail("PLAINST_OPEN is required") }
    open(source, controller: controller) { document in
      document.exportPDF(to: URL(fileURLWithPath: pdfPath)) { success in
        guard success, let data = FileManager.default.contents(atPath: pdfPath),
          data.starts(with: Data("%PDF".utf8)), let pdf = PDFDocument(data: data), pdf.pageCount > 0
        else { fail("PDF export did not produce a PDF") }
        pass("PDF export works")
        finish()
      }
    }
  }

  /// Writes an image of the first window, for reviewing the interface without screen access.
  private static func snapshot(_ path: String, _ controller: PlainstDocumentController) {
    func capture() {
      guard let document = controller.documents.first as? PlainstDocument,
        let editor = document.editor, let window = editor.window
      else { fail("no window to capture") }
      if let mode = environment["PLAINST_MODE"].flatMap(EditorMode.init(rawValue:)) {
        editor.setMode(mode)
      }
      if let caret = environment["PLAINST_CARET"].flatMap(Int.init) {
        editor.textView.setSelectedRange(NSRange(location: min(caret, editor.storage.length), length: 0))
        editor.textView.scrollRangeToVisible(editor.textView.selectedRange())
      }
      if let width = environment["PLAINST_WIDTH"].flatMap(Double.init) {
        window.setContentSize(NSSize(width: width, height: environment["PLAINST_HEIGHT"].flatMap(Double.init) ?? 760))
      }
      if let typed = environment["PLAINST_TYPE"] {
        for character in typed {
          editor.textView.insertText(String(character), replacementRange: editor.textView.selectedRange())
        }
      }
      if let hover = environment["PLAINST_HOVER"].flatMap(Int.init) {
        after(2) { editor.showHover(at: hover) }
      }
      if environment["PLAINST_TABS"] == "1" {
        window.makeKeyAndOrderFront(nil)
        controller.newWindowForTab(nil)
        window.makeKeyAndOrderFront(nil)
      }
      if environment["PLAINST_SETTINGS"] == "1" {
        NSApp.sendAction(Selector(("showSettings:")), to: nil, from: nil)
      }
      if path == "-" {
        // Leave the windows on screen and report them so screencapture can record the real
        // window chrome, which cacheDisplay does not draw.
        after(1.5) {
          for shown in NSApp.orderedWindows where shown.isVisible {
            print("WINDOW \(shown.windowNumber) \(shown.title)")
          }
          fflush(stdout)
          after(Double(environment["PLAINST_WAIT"] ?? "4") ?? 4) { finish() }
        }
        return
      }
      after(Double(environment["PLAINST_WAIT"] ?? "3") ?? 3) {
        // The document window goes to `path`; any other window, such as Settings, gets a suffix.
        if !editor.assistant.popup.items.isEmpty, let popup = editor.assistant.popup.contentView {
          // The completion list hides when the app isn't frontmost, so draw its view directly.
          if let bitmap = popup.bitmapImageRepForCachingDisplay(in: popup.bounds) {
            popup.cacheDisplay(in: popup.bounds, to: bitmap)
            let output = (path as NSString).deletingPathExtension + "-completions.png"
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
          }
        }
        let others = NSApp.orderedWindows.filter { $0.isVisible && $0 !== window && $0.tabbedWindows?.contains(window) != true }
        for (index, shown) in ([window] + others).enumerated() {
          guard let view = shown.contentView?.superview else { fail("no content") }
          view.layoutSubtreeIfNeeded()
          guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            fail("could not capture")
          }
          view.cacheDisplay(in: view.bounds, to: bitmap)
          guard let data = bitmap.representation(using: .png, properties: [:]) else {
            fail("could not encode")
          }
          let output = index == 0 ? path : (path as NSString).deletingPathExtension + "-\(index).png"
          do { try data.write(to: URL(fileURLWithPath: output)) } catch { fail("\(error)") }
          pass("wrote \(output)")
        }
        finish()
      }
    }
    if let source = environment["PLAINST_OPEN"] {
      open(source, controller: controller) { _ in capture() }
    } else {
      after(1) { capture() }
    }
  }
}

private struct CheckRandomNumberGenerator: RandomNumberGenerator {
  private var state: UInt64 = 0x504C_4149_4E53_5401

  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1
    return state
  }
}
#endif
