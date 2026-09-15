import Foundation
import Testing

@testable import PlainstCore

@Suite struct FileRoundTrip {
  @Test(arguments: [
    "= Title\n\nCafé $x^2$ 中文 👩🏽‍💻\n",
    "= Title\r\n\r\nWindows line endings\r\n",
    "Mixed\r\nline\nendings\rremain unchanged",
    "\u{FEFF}= With a byte order mark\n",
    "No trailing newline",
    "",
  ])
  func openingAndSavingIsByteIdentical(_ content: String) throws {
    let data = Data(content.utf8)
    let file = try TextFile(data: data)
    #expect(try file.data() == data)
  }

  @Test func editingMixedLineEndingsUsesTheDetectedStyle() throws {
    let data = Data("one\r\ntwo\r\nthree\n".utf8)
    var file = try TextFile(data: data)
    #expect(file.hasMixedLineEndings)
    file.text += "four\n"
    #expect(try file.data() == Data("one\r\ntwo\r\nthree\r\nfour\r\n".utf8))
  }
}

@Suite struct Outline {
  @Test func findsSupportedMarkup() {
    let text = "= Notes\n\nA *bold* _word_ and $x$.\n\n$ y = m x + b $\n\n- item\n+ one\n"
    let kinds = Set(Engine.outline(text).map(\.kind))
    #expect(kinds.isSuperset(of: [.heading, .strong, .emph, .math, .list, .enum]))
    let display = Engine.outline(text).first { $0.kind == .math && $0.block }
    #expect(display.map { (text as NSString).substring(with: $0.range) } == "$ y = m x + b $")
  }

  @Test func compilesAndExports() {
    let result = Engine.compile("= Hello\n\nWorld $x$\n", pdf: true)
    #expect(result.errors.isEmpty)
    #expect(result.pages == 1)
    #expect(result.pdf?.prefix(4) == Data("%PDF".utf8))
  }

  @Test func rendersEquations() throws {
    let render = try Engine.renderMath(
      "$a/b$", block: false, pixelsPerPoint: 2, color: (0, 0, 0, 255)
    ).get()
    #expect(render.image.width > 0)
    #expect(render.baseline > 0 && render.baseline < render.size.height)
  }
}

@Suite struct WritingPresentation {
  let text = "= Title\n\nSome *bold* text.\n" as NSString

  @Test func hidesMarkupAwayFromTheCaret() {
    let elements = Engine.outline(text as String)
    let away = Presentation.make(
      text: text, elements: elements, selection: NSRange(location: 0, length: 0), mode: .writing)
    // The caret is in the heading, so its marker shows; the strong delimiters are hidden.
    #expect(!away.hidden.contains(0))
    #expect(away.hidden.contains(14) && away.hidden.contains(19))

    let inside = Presentation.make(
      text: text, elements: elements, selection: NSRange(location: 16, length: 0), mode: .writing)
    #expect(inside.hidden.contains(0) && inside.hidden.contains(1))
    #expect(!inside.hidden.contains(14) && !inside.hidden.contains(19))
  }

  @Test func sourceModeHidesNothing() {
    let presentation = Presentation.make(
      text: text, elements: Engine.outline(text as String),
      selection: NSRange(location: 30, length: 0), mode: .source)
    #expect(presentation.hidden.isEmpty && presentation.replacements.isEmpty)
    #expect(presentation.runs.map(\.range.length).reduce(0, +) == text.length)
  }

  @Test func equationsStayVisibleUntilRendered() {
    let text = "Let $x$ be\n" as NSString
    let elements = Engine.outline(text as String)
    let pending = Presentation.make(
      text: text, elements: elements, selection: NSRange(location: 0, length: 0), mode: .writing)
    #expect(pending.replacements.isEmpty && pending.hidden.isEmpty)
    let rendered = Presentation.make(
      text: text, elements: elements, selection: NSRange(location: 0, length: 0), mode: .writing,
      canRenderMath: { _ in true })
    #expect(rendered.replacements[4] == .math(source: "$x$", block: false, scale: 1))
    #expect(rendered.hidden.contains(5) && rendered.hidden.contains(6))
  }

  @Test func listsShowBulletsAndNumbers() {
    let text = "- a\n  - b\n+ one\n+ two\n" as NSString
    let presentation = Presentation.make(
      text: text, elements: Engine.outline(text as String),
      selection: NSRange(location: text.length, length: 0), mode: .writing)
    #expect(presentation.replacements[0] == .text("•"))
    #expect(presentation.replacements[6] == .text("‣"))
    #expect(presentation.replacements[16] == .text("2."))
  }

  @Test func reportsChangedRuns() {
    let a = "one *two* three" as NSString
    let b = "one *two* three!" as NSString
    let old = Presentation.make(
      text: a, elements: Engine.outline(a as String), selection: NSRange(), mode: .writing)
    let new = Presentation.make(
      text: b, elements: Engine.outline(b as String), selection: NSRange(), mode: .writing)
    let changed = Presentation.changedRange(old: old.runs, new: new.runs, newLength: b.length)
    #expect(changed != nil)
    #expect(Presentation.changedRange(old: old.runs, new: old.runs, newLength: a.length) == nil)
  }
}

@Suite struct FormattingCommands {
  func valid(_ text: String) -> Bool { Engine.compile(text, pdf: false).errors.isEmpty }

  @Test func togglesBold() {
    let text = "make this bold" as NSString
    let edit = Formatting.toggle(
      .strong, text: text, selection: NSRange(location: 5, length: 5),
      elements: Engine.outline(text as String))
    let bold = edit.applied(to: text as String)
    #expect(bold == "make *this* bold")
    #expect(valid(bold))
    let undo = Formatting.toggle(
      .strong, text: bold as NSString, selection: edit.selection,
      elements: Engine.outline(bold))
    #expect(undo.applied(to: bold) == "make this bold")
  }

  @Test func trimsWhitespaceBeforeWrapping() {
    let text = "a word here" as NSString
    let edit = Formatting.toggle(
      .emph, text: text, selection: NSRange(location: 1, length: 6), elements: [])
    #expect(edit.applied(to: text as String) == "a _word_ here")
  }

  @Test func setsHeadings() {
    let text = "Title\nbody" as NSString
    let edit = Formatting.setHeading(level: 2, text: text, selection: NSRange(location: 2, length: 0))
    #expect(edit.applied(to: text as String) == "== Title\nbody")
    let body = Formatting.setHeading(
      level: 0, text: "== Title\nbody" as NSString, selection: NSRange(location: 4, length: 0))
    #expect(body.applied(to: "== Title\nbody") == "Title\nbody")
  }

  @Test func togglesLists() {
    let text = "one\ntwo\n" as NSString
    let edit = Formatting.toggleList(.bullet, text: text, selection: NSRange(location: 0, length: 7))
    let list = edit.applied(to: text as String)
    #expect(list == "- one\n- two\n")
    #expect(valid(list))
    let back = Formatting.toggleList(
      .bullet, text: list as NSString, selection: NSRange(location: 0, length: 11))
    #expect(back.applied(to: list) == "one\ntwo\n")
  }

  @Test func continuesAndEndsLists() {
    let text = "+ first" as NSString
    let edit = Formatting.newline(text: text, selection: NSRange(location: 7, length: 0))
    #expect(edit?.applied(to: text as String) == "+ first\n+ ")
    let ended = Formatting.newline(
      text: "+ first\n+ " as NSString, selection: NSRange(location: 10, length: 0))
    #expect(ended?.applied(to: "+ first\n+ ") == "+ first\n")
    #expect(Formatting.newline(text: "plain" as NSString, selection: NSRange(location: 5, length: 0)) == nil)
  }

  @Test func insertsEquations() {
    let text = "Energy E = m c^2 here" as NSString
    let inline = Formatting.insertEquation(
      block: false, text: text, selection: NSRange(location: 7, length: 9))
    #expect(inline.applied(to: text as String) == "Energy $E = m c^2$ here")
    let block = Formatting.insertEquation(
      block: true, text: "ab" as NSString, selection: NSRange(location: 1, length: 0))
    #expect(block.applied(to: "ab") == "a\n$  $\nb")
    #expect(valid(inline.applied(to: text as String)))
  }
}

@Suite struct TypingAssistance {
  func type(_ character: String, in text: String, at location: Int, inCode: Bool = false) -> (String, Int)? {
    guard
      let edit = AutoPair.edit(
        typing: character, text: text as NSString, selection: NSRange(location: location, length: 0),
        inCode: inCode)
    else { return nil }
    return (edit.applied(to: text), edit.selection.location)
  }

  @Test func pairsAndStepsOverClosingCharacters() {
    #expect(type("$", in: "Area ", at: 5)! == ("Area $$", 6))
    #expect(type("(", in: "$f$", at: 2, inCode: true)! == ("$f()$", 3))
    #expect(type(")", in: "$f()$", at: 3, inCode: true)! == ("$f()$", 4))
    #expect(type("$", in: "$x$", at: 2, inCode: true)! == ("$x$", 3))
    #expect(type("\"", in: "text ", at: 5) == nil)
    #expect(type("\"", in: "#text()", at: 6, inCode: true)! == ("#text(\"\")", 7))
  }

  @Test func pairsBackticksAndWrapsSelections() {
    #expect(type("`", in: "use ", at: 4)! == ("use ``", 5))
    #expect(type("`", in: "$x$", at: 2, inCode: true) == nil)
    func wrap(_ character: String, _ text: String, _ range: NSRange, inCode: Bool = false) -> String? {
      AutoPair.edit(typing: character, text: text as NSString, selection: range, inCode: inCode)?
        .applied(to: text)
    }
    #expect(wrap("*", "make bold", NSRange(location: 5, length: 4)) == "make *bold*")
    #expect(wrap("_", "an idea", NSRange(location: 3, length: 4)) == "an _idea_")
    #expect(wrap("$", "x^2 here", NSRange(location: 0, length: 3)) == "$x^2$ here")
    #expect(wrap("\"", "say hi", NSRange(location: 4, length: 2)) == "say \"hi\"")
    #expect(wrap("*", "$a b$", NSRange(location: 1, length: 1), inCode: true) == nil)
    #expect(type("*", in: "a ", at: 2) == nil)
  }

  @Test func leavesWordsAndEscapesAlone() {
    #expect(type("(", in: "word", at: 0) == nil)
    #expect(type("$", in: "costs 5", at: 7) == nil)
    #expect(type("$", in: "\\", at: 1) == nil)
  }

  @Test func deletesEmptyPairs() {
    let edit = AutoPair.deleteBackward(text: "a ()" as NSString, selection: NSRange(location: 3, length: 0))
    #expect(edit?.applied(to: "a ()") == "a ")
    #expect(AutoPair.deleteBackward(text: "a (b)" as NSString, selection: NSRange(location: 4, length: 0)) == nil)
  }

  @Test func expandsSnippets() {
    let snippet = ExpandedSnippet("frac(${num}, ${})")
    #expect(snippet.text == "frac(num, )")
    #expect(snippet.placeholders == [NSRange(location: 5, length: 3), NSRange(location: 10, length: 0)])
  }

  @Test func completesFromTypst() {
    let list = Engine.completions("$arrow.$", cursor: 7, explicit: false)
    #expect(list.items.contains { $0.label == "r" && $0.symbol == "→" })
    #expect(Engine.symbols.contains(TypstSymbol(name: "arrow.r.double", value: "⇒")))
  }
}

@Suite struct Navigation {
  @Test func listsHeadingsWithoutMarkup() {
    let text = "= The *big* idea <intro>\n\nBody.\n\n== Why $x^2$ // aside\n=== Deeper\n" as NSString
    let headings = DocumentOutline.headings(text: text, elements: Engine.outline(text as String))
    #expect(headings.map(\.title) == ["The big idea", "Why $x^2$", "Deeper"])
    #expect(headings.map(\.level) == [1, 2, 3])
    #expect(DocumentOutline.currentHeading(in: headings, at: 28) == 0)
    #expect(DocumentOutline.currentHeading(in: headings, at: text.length) == 2)
    #expect(DocumentOutline.currentHeading(in: [], at: 3) == nil)
  }

  @Test func matchesBracketsBesideTheCursor() {
    let text = "f(a [b] (c)) + g[d)" as NSString
    let all = NSRange(location: 0, length: text.length)
    func pair(_ caret: Int, strings: Bool = false) -> [Int]? {
      BracketMatch.pair(in: text, caret: caret, within: all, skipStrings: strings)
        .map { [$0.0.location, $0.1.location] }
    }
    #expect(pair(2) == [1, 11])  // after "("
    #expect(pair(12) == [11, 1])  // after the last ")"
    #expect(pair(4) == [4, 6])  // before "["
    #expect(pair(3) == nil)
    #expect(pair(17) == nil)  // "[" closed by the wrong bracket
    let quoted = "#f(\")\", x)" as NSString
    #expect(
      BracketMatch.pair(in: quoted, caret: 3, within: NSRange(location: 0, length: quoted.length), skipStrings: true)
        .map { $0.1.location } == 9)
    let escaped = "\\(a)" as NSString
    #expect(BracketMatch.pair(in: escaped, caret: 4, within: NSRange(location: 0, length: 4), skipStrings: false) == nil)
  }
}
