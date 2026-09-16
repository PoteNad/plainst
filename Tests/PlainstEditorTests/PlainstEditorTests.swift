import AppKit
import PlainstCore
import PlainstEditor
import Testing

/// Uses only the editor's public interface, the way another app would.
@MainActor
@Suite struct EmbeddingTheEditor {
  final class Recorder: TypstEditorDelegate {
    var textChanges = 0
    var displayChanges = 0
    var compiled: CompileResult?
    var pages: [PreviewPage]?

    func typstEditorTextDidChange(_ editor: TypstEditor) { textChanges += 1 }
    func typstEditorDisplayDidChange(_ editor: TypstEditor) { displayChanges += 1 }
    func typstEditor(_ editor: TypstEditor, didCompile result: CompileResult, pages: [PreviewPage]?) {
      compiled = result
      self.pages = pages
    }
  }

  @Test func editsAndReportsThroughItsInterface() {
    let editor = TypstEditor(text: "Let x be small.", configuration: .init(autoPair: false))
    let recorder = Recorder()
    editor.delegate = recorder
    #expect(editor.text == "Let x be small.")
    #expect(editor.mode == .writing)

    editor.textView.setSelectedRange(NSRange(location: 4, length: 1))
    editor.insertEquation(block: false)
    #expect(editor.text == "Let $x$ be small.")
    #expect(recorder.textChanges == 1)

    editor.textView.setSelectedRange(NSRange(location: 11, length: 5))
    editor.toggle(.strong, actionName: "Bold")
    #expect(editor.text == "Let $x$ be *small*.")

    editor.setMode(.source)
    editor.setZoom(150)
    #expect(editor.mode == .source && editor.zoomPercent == 150)
    #expect(recorder.displayChanges == 2)
    #expect(editor.lineAndColumn(at: 4) == (1, 5))
  }

  @Test func insertsSymbolsAndReadsHeadings() {
    let editor = TypstEditor(text: "= Notes\n\nArea ")
    editor.textView.setSelectedRange(NSRange(location: editor.textLength, length: 0))
    editor.insertMath("pi", snippet: false)
    #expect(editor.text == "= Notes\n\nArea $pi$")
    #expect(editor.headings.map(\.title) == ["Notes"])
    #expect(editor.elements.contains { $0.kind == .math })
  }

  @Test func compilesAndCollectsPages() async throws {
    let editor = TypstEditor(text: "= Hello\n\nWorld $x^2$\n")
    let recorder = Recorder()
    editor.delegate = recorder
    editor.collectsPages = true
    editor.scheduleCompile(delay: 0)
    for _ in 0..<100 where recorder.pages == nil {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(recorder.compiled?.errors.isEmpty == true)
    #expect(recorder.pages?.count == 1)
    #expect(editor.pageCount == 1 && editor.diagnostics.isEmpty)
  }
}

@MainActor
@Suite struct PastingFormattedText {
  @Test func convertsAWebPage() throws {
    let html = """
      <h1>Notes</h1>
      <p>Some <b>bold</b>, <i>italic</i>, and <code>code</code> with a <a href="https://typst.app/">link</a>.</p>
      <ul><li>First</li><li>Second<ul><li>Nested</li></ul></li></ul>
      <ol><li>One</li></ol>
      <p>Prices like $5 * 2 # and // stay as written.</p>
      """
    let formatted = try #require(NSAttributedString(html: Data(html.utf8), documentAttributes: nil))
    let markup = try #require(TypstPaste.markup(from: formatted, indent: 2))
    #expect(markup.hasPrefix("= Notes\n\n"), "\(markup)")
    #expect(markup.contains("Some *bold*, _italic_, and `code` with a #link(\"https://typst.app/\")[link]."), "\(markup)")
    #expect(markup.contains("- First\n- Second\n  - Nested\n+ One"), "\(markup)")
    #expect(markup.contains("Prices like \\$5 \\* 2 \\# and \\// stay as written."), "\(markup)")
    #expect(Engine.compile(markup, pdf: false).errors.isEmpty, "\(markup)")
  }

  @Test func leavesPlainTextToThePlainPaste() {
    let plain = NSAttributedString(string: "Just words.", attributes: [.font: NSFont.systemFont(ofSize: 12)])
    #expect(TypstPaste.markup(from: plain) == nil)
  }
}
