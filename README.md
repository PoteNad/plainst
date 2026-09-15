# Plainst

Plainst is a small, native macOS editor for single-file [Typst](https://typst.app) documents of prose and math. It shows headings, emphasis, lists, and rendered equations while you write, and it always saves an ordinary `.typ` file exactly as you typed it. Plainst requires macOS 13 or newer and works entirely offline.

## How it works

- **Writing** (⌘1) shows the document formatted with Typst's own fonts and equations rendered by the Typst compiler. Markup such as `*` or `=` is hidden until the cursor reaches it, and clicking an equation reveals its source with a live preview underneath.
- **Source** (⌘2) shows the file exactly as it is saved. Both views edit the same text, so switching never changes the document.
- **Preview** (⌥⌘P) shows the typeset document beside the text, updated as you type, so `#set` rules and other code show their effect. Only changed pages are redrawn, the preview follows the cursor, and clicking a page puts the cursor on that text.
- **Export as PDF** and **Print** typeset the document with the bundled Typst compiler, so the output matches `typst compile`.

Plainst formats paragraphs, headings, bold, italic, inline code and code blocks, bulleted, numbered, and term lists, dashes and other shorthands, and inline and display math. Anything else, such as `#set` rules or function calls, is kept exactly as written and shown in grey. Images, bibliographies, multiple files, and packages are intentionally unsupported.

## Features

- Native document windows and tabs, autosave, versions, Revert, Duplicate, Rename, and Move.
- Format commands that write plain Typst: Bold (⌘B), Italic (⌘I), Code, Headings (⌥⌘1–3), Bulleted and Numbered Lists (⇧⌘8, ⇧⌘7), Equations (⌥⌘E, ⇧⌥⌘E).
- Return continues a list and ends it on an empty item; Tab and Shift-Tab nest items.
- An outline sidebar (⌃⌘S) of the document's headings that follows the cursor, and Go to Heading (⌃6).
- Completions from Typst's own IDE engine for symbols, math functions, code, and label references after `@` (⌥⎋ to ask), with snippet placeholders you can Tab through.
- Automatic pairs for dollar signs, brackets, backticks, and quotes in code; typing `*` or `_` over a selection wraps it. The bracket beside the cursor and its partner are highlighted.
- A symbols inspector (⌥⌘T) to search and insert Typst symbols and common math structures.
- Settings for the default view, Writing text size, Source font, new document line endings, and each kind of typing assistance.
- Live Typst diagnostics with underlines, messages at the ends of their lines, and a status bar menu, plus word and page counts.
- Find and replace, spelling, zoom, light and dark appearances, and optional Apple Writing Tools that are off by default.
- Opening and saving an unedited file keeps it byte-for-byte identical, including line endings and byte order marks.

## Build from source

Plainst needs Xcode or the Command Line Tools with the macOS 26 SDK or newer, plus a Rust toolchain. The built app still runs on macOS 13 and newer.

```sh
./scripts/build.sh
open build/Plainst.app
```

The build compiles the Typst engine in `engine/` as a static library, builds the Swift app, and ad-hoc signs it for the current Mac. Run `./scripts/check.sh` for the full test suite, which includes end-to-end checks of editing, saving, and PDF export.

## License

MIT — see [LICENSE](LICENSE). Plainst includes the Typst compiler and Typst's default fonts under their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
