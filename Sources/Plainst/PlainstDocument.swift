import AppKit
import PDFKit
import PlainstCore
import PlainstEditor
import UniformTypeIdentifiers

extension UTType {
  static let typst = UTType(importedAs: "app.typst.typ", conformingTo: .plainText)
}

@objc(PlainstDocument)
final class PlainstDocument: NSDocument {
  var file = TextFile(lineEnding: AppPreferences.lineEnding)
  var editor: Editor?

  nonisolated override class var autosavesInPlace: Bool { true }
  nonisolated override class var autosavesDrafts: Bool { true }
  nonisolated override class var preservesVersions: Bool { true }

  var currentText: String { editor?.text ?? file.text }
  /// A name for an unsaved document that isn't a regular new document, such as the guide.
  var untitledName: String?

  override var displayName: String! {
    get { fileURL == nil ? (untitledName ?? super.displayName) : super.displayName }
    set { super.displayName = newValue }
  }

  override var isDocumentEdited: Bool {
    if fileURL == nil && currentText.isEmpty { return false }
    return super.isDocumentEdited
  }

  func syncEditedIndicator() {
    for controller in windowControllers { controller.window?.isDocumentEdited = isDocumentEdited }
  }

  override func updateChangeCount(_ change: NSDocument.ChangeType) {
    super.updateChangeCount(change)
    syncEditedIndicator()
  }

  override func makeWindowControllers() {
    guard windowControllers.isEmpty else { return }
    let controller = Editor(document: self)
    editor = controller
    addWindowController(controller)
  }

  override func read(from data: Data, ofType typeName: String) throws {
    let loaded = try TextFile(data: data)
    MainActor.assumeIsolated {
      file = loaded
      if let editor {
        editor.loadText(loaded.text)
        file.text = ""
      }
    }
  }

  override func data(ofType typeName: String) throws -> Data {
    var output = file
    output.text = currentText
    return try output.data()
  }

  override func save(
    to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
    completionHandler: @escaping ((any Error)?) -> Void
  ) {
    super.save(to: url, ofType: typeName, for: saveOperation) { error in
      if error == nil { self.syncEditedIndicator() }
      completionHandler(error)
    }
  }

  override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
    savePanel.allowedContentTypes = [.typst]
    savePanel.allowsOtherFileTypes = true
    savePanel.isExtensionHidden = false
    return true
  }

  // MARK: PDF

  private var pdfBaseName: String {
    let name = fileURL?.deletingPathExtension().lastPathComponent ?? displayName ?? "Untitled"
    return (name as NSString).deletingPathExtension
  }

  /// Compiles the current text off the main thread and hands back the PDF or the first error.
  func makePDF(_ completion: @escaping @MainActor (Result<Data, EngineError>) -> Void) {
    let text = currentText
    TypstEditor.engineQueue.async {
      let result = Engine.compile(text, pdf: true)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          if let pdf = result.pdf, result.errors.isEmpty {
            completion(.success(pdf))
          } else {
            let error = result.errors.first
            var message = error?.message ?? "Typst could not produce a PDF."
            if let range = error?.range {
              let line = (text as NSString).substring(to: min(range.location, (text as NSString).length))
                .components(separatedBy: "\n").count
              message = "Line \(line): " + message
            }
            completion(.failure(EngineError(message: message)))
          }
        }
      }
    }
  }

  private func presentPDFError(_ error: EngineError, action: String) {
    let alert = NSAlert()
    alert.messageText = "\(action) needs the document to compile"
    alert.informativeText = error.message + "\n\nFix the problem shown in the status bar and try again."
    alert.alertStyle = .warning
    if let window = windowControllers.first?.window {
      alert.beginSheetModal(for: window)
    } else {
      alert.runModal()
    }
  }

  @objc func exportPDF(_ sender: Any?) {
    guard let window = windowControllers.first?.window else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.pdf]
    panel.nameFieldStringValue = pdfBaseName + ".pdf"
    if let directory = fileURL?.deletingLastPathComponent() { panel.directoryURL = directory }
    panel.beginSheetModal(for: window) { response in
      guard response == .OK, let url = panel.url else { return }
      MainActor.assumeIsolated { self.exportPDF(to: url, completion: nil) }
    }
  }

  func exportPDF(to url: URL, completion: (@MainActor (Bool) -> Void)?) {
    makePDF { result in
      switch result {
      case .success(let data):
        do {
          try data.write(to: url, options: .atomic)
          completion?(true)
        } catch {
          self.presentError(error)
          completion?(false)
        }
      case .failure(let error):
        self.presentPDFError(error, action: "Exporting a PDF")
        completion?(false)
      }
    }
  }

  override func printDocument(_ sender: Any?) {
    makePDF { result in
      switch result {
      case .success(let data):
        guard let pdf = PDFDocument(data: data),
          let operation = pdf.printOperation(
            for: self.printInfo, scalingMode: .pageScaleNone, autoRotate: true)
        else { return }
        operation.jobTitle = self.pdfBaseName
        if let window = self.windowControllers.first?.window {
          operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
          operation.run()
        }
      case .failure(let error):
        self.presentPDFError(error, action: "Printing")
      }
    }
  }
}

@objc(PlainstDocumentController)
final class PlainstDocumentController: NSDocumentController {
  private(set) var pendingDocumentOpenCount = 0

  override func typeForContents(of url: URL) throws -> String { UTType.typst.identifier }

  override func reopenDocument(
    for urlOrNil: URL?, withContentsOf contentsURL: URL, display displayDocument: Bool,
    completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void
  ) {
    // Automated checks start clean instead of restoring drafts from earlier runs.
    #if PLAINST_CHECKS
      guard !AppChecks.isChecking else { return completionHandler(nil, false, nil) }
    #endif
    super.reopenDocument(
      for: urlOrNil, withContentsOf: contentsURL, display: displayDocument,
      completionHandler: completionHandler)
  }

  @IBAction func newWindowForTab(_ sender: Any?) {
    let sourceWindow = NSApp.keyWindow ?? NSApp.mainWindow
    do {
      let document = try openUntitledDocumentAndDisplay(false)
      document.makeWindowControllers()
      guard let window = document.windowControllers.first?.window else {
        document.close()
        return
      }
      if let sourceWindow, sourceWindow.isVisible {
        sourceWindow.addTabbedWindow(window, ordered: .above)
      }
      document.showWindows()
    } catch {
      NSApp.presentError(error)
    }
  }

  override func beginOpenPanel(
    _ openPanel: NSOpenPanel, forTypes inTypes: [String]?,
    completionHandler: @escaping (Int) -> Void
  ) {
    openPanel.allowedContentTypes = [.typst, .plainText]
    super.beginOpenPanel(openPanel, forTypes: nil, completionHandler: completionHandler)
  }

  override func openDocument(
    withContentsOf url: URL, display displayDocument: Bool,
    completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void
  ) {
    let transient = documents.first(where: isTransientUntitledDocument)
    pendingDocumentOpenCount += 1
    super.openDocument(withContentsOf: url, display: displayDocument) {
      document, alreadyOpen, error in
      self.pendingDocumentOpenCount -= 1
      if document != nil, let transient, transient !== document { transient.close() }
      completionHandler(document, alreadyOpen, error)
    }
  }

  private func isTransientUntitledDocument(_ document: NSDocument) -> Bool {
    guard let document = document as? PlainstDocument else { return false }
    return document.fileURL == nil && !document.isDocumentEdited && document.currentText.isEmpty
  }

  /// Opens a new untitled document containing `text`, such as the syntax guide.
  func openUntitled(text: String, name: String? = nil) {
    do {
      guard let document = try openUntitledDocumentAndDisplay(false) as? PlainstDocument else {
        return
      }
      document.untitledName = name
      document.makeWindowControllers()
      document.editor?.loadText(text)
      document.showWindows()
    } catch {
      NSApp.presentError(error)
    }
  }
}
