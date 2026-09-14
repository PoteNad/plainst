import CPlainstEngine
import CoreGraphics
import Foundation

/// A construct found in the document, with ranges in UTF-16 offsets.
public struct OutlineElement: Equatable, Sendable {
  public enum Kind: String, Sendable, Decodable {
    case heading, strong, emph, raw, link, code, comment, linebreak, escape, shorthand, math
    case list, `enum`, term
  }

  public var kind: Kind
  public var range: NSRange
  /// Characters that are only markup, such as `*` or `= `.
  public var markers: [NSRange]
  /// The heading level or list number.
  public var number: Int?
  /// Whether an equation or raw block is displayed on its own.
  public var block: Bool
  /// The replacement for a shorthand such as `--`.
  public var text: String?
  /// A secondary range, such as the term of a term list item.
  public var content: NSRange?

  public init(
    kind: Kind, range: NSRange, markers: [NSRange] = [], number: Int? = nil, block: Bool = false,
    text: String? = nil, content: NSRange? = nil
  ) {
    self.kind = kind
    self.range = range
    self.markers = markers
    self.number = number
    self.block = block
    self.text = text
    self.content = content
  }
}

/// A problem reported by the Typst compiler.
public struct Diagnostic: Equatable, Sendable {
  public var isError: Bool
  /// The affected range, or nil when Typst could not locate it in the document.
  public var range: NSRange?
  public var message: String
  public var hints: [String]
}

public struct CompileResult: Sendable {
  public var pages: Int
  public var diagnostics: [Diagnostic]
  public var pdf: Data?

  public var errors: [Diagnostic] { diagnostics.filter(\.isError) }
}

/// A rendered equation. Sizes are in Typst points at 11pt text.
public struct MathRender: @unchecked Sendable {
  public var image: CGImage
  public var size: CGSize
  /// Distance from the top of the image to the baseline.
  public var baseline: CGFloat
}

public struct EngineError: Error, Equatable, Sendable, CustomStringConvertible {
  public var message: String
  public var description: String { message }

  public init(message: String) { self.message = message }
}

/// Swift entry points into the Typst engine. The functions are thread-safe but
/// may take a while, so call compile and renderMath off the main thread.
public enum Engine {
  /// Typst's default text size, which rendered equations are measured against.
  public static let typstTextSize: CGFloat = 11

  private struct RawCompile: Decodable {
    struct Item: Decodable {
      var error: Bool
      var s: Int
      var e: Int
      var located: Bool
      var message: String
      var hints: [String]
    }
    var pages: Int
    var diagnostics: [Item]
  }

  private static func call(_ text: String, _ body: (UnsafePointer<UInt8>?, Int) -> PlainstBuffer)
    -> Data
  {
    var text = text
    let buffer = text.withUTF8 { body($0.baseAddress, $0.count) }
    defer { plainst_buffer_free(buffer) }
    guard let data = buffer.data else { return Data() }
    return Data(bytes: data, count: buffer.len)
  }

  /// Element kinds in the order the engine numbers them.
  private static let kinds: [OutlineElement.Kind] = [
    .heading, .strong, .emph, .raw, .link, .code, .comment, .linebreak, .escape, .shorthand,
    .math, .list, .enum, .term,
  ]
  private static let shorthands = ["\u{2013}", "\u{2014}", "\u{2026}", "\u{00A0}"]

  /// Parses the document into styled elements.
  public static func outline(_ text: String) -> [OutlineElement] {
    let data = call(text) { plainst_outline($0, $1) }
    guard data.count % 4 == 0, data.prefix(4) != Data("PLE1".utf8) else { return [] }
    return data.withUnsafeBytes { raw -> [OutlineElement] in
      let count = raw.count / 4
      var index = 0
      func next() -> Int {
        defer { index += 1 }
        return Int(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: index * 4, as: Int32.self)))
      }
      func range(_ start: Int, _ end: Int) -> NSRange {
        NSRange(location: max(0, start), length: max(0, end - start))
      }
      var result: [OutlineElement] = []
      while index + 9 <= count {
        let kind = next()
        let start = next()
        let end = next()
        let number = next()
        let flags = next()
        let contentStart = next()
        let contentEnd = next()
        let shorthand = next()
        let markerCount = next()
        guard markerCount >= 0, index + markerCount * 2 <= count else { break }
        var markers: [NSRange] = []
        for _ in 0..<markerCount {
          let markerStart = next()
          markers.append(range(markerStart, next()))
        }
        guard kinds.indices.contains(kind) else { continue }
        result.append(
          OutlineElement(
            kind: kinds[kind], range: range(start, end), markers: markers,
            number: number == Int(Int32.min) ? nil : number, block: flags & 1 != 0,
            text: shorthands.indices.contains(shorthand) ? shorthands[shorthand] : nil,
            content: contentStart >= 0 ? range(contentStart, contentEnd) : nil))
      }
      return result
    }
  }

  /// Compiles the document and optionally produces a PDF.
  public static func compile(_ text: String, pdf: Bool) -> CompileResult {
    let data = call(text) { plainst_compile($0, $1, pdf) }
    guard data.count >= 8, data.prefix(4) == Data("PLC1".utf8) else {
      return CompileResult(
        pages: 0,
        diagnostics: [
          Diagnostic(
            isError: true, range: nil, message: String(decoding: data.dropFirst(4), as: UTF8.self),
            hints: [])
        ], pdf: nil)
    }
    let jsonLength = Int(data.readUInt32(at: 4))
    let jsonEnd = 8 + jsonLength
    guard data.count >= jsonEnd,
      let raw = try? JSONDecoder().decode(RawCompile.self, from: data.subdata(in: 8..<jsonEnd))
    else {
      return CompileResult(pages: 0, diagnostics: [], pdf: nil)
    }
    let diagnostics = raw.diagnostics.map {
      Diagnostic(
        isError: $0.error,
        range: $0.located ? NSRange(location: $0.s, length: max(0, $0.e - $0.s)) : nil,
        message: $0.message, hints: $0.hints)
    }
    let pdfData = data.count > jsonEnd ? data.subdata(in: jsonEnd..<data.count) : nil
    return CompileResult(pages: raw.pages, diagnostics: diagnostics, pdf: pdf ? pdfData : nil)
  }

  /// Renders an equation, including its `$` delimiters, at the given pixel density.
  public static func renderMath(
    _ equation: String, block: Bool, pixelsPerPoint: Double, color: (UInt8, UInt8, UInt8, UInt8)
  ) -> Result<MathRender, EngineError> {
    let rgba =
      UInt32(color.0) << 24 | UInt32(color.1) << 16 | UInt32(color.2) << 8 | UInt32(color.3)
    let data = call(equation) { plainst_render_math($0, $1, block, pixelsPerPoint, rgba) }
    if data.prefix(4) == Data("PLE1".utf8) {
      return .failure(EngineError(message: String(decoding: data.dropFirst(4), as: UTF8.self)))
    }
    guard data.count >= 24, data.prefix(4) == Data("PLI1".utf8) else {
      return .failure(EngineError(message: "The equation could not be rendered"))
    }
    let width = Int(data.readUInt32(at: 4))
    let height = Int(data.readUInt32(at: 8))
    let size = CGSize(
      width: CGFloat(data.readFloat32(at: 12)), height: CGFloat(data.readFloat32(at: 16)))
    let baseline = CGFloat(data.readFloat32(at: 20))
    let pixels = data.subdata(in: 24..<data.count)
    guard width > 0, height > 0, pixels.count == width * height * 4,
      let provider = CGDataProvider(data: pixels as CFData),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    else {
      return .failure(EngineError(message: "The equation could not be rendered"))
    }
    return .success(MathRender(image: image, size: size, baseline: baseline))
  }

  private struct RawCompletions: Decodable {
    struct Item: Decodable {
      var kind: String
      var label: String
      var apply: String
      var detail: String
      var symbol: String
    }
    var from: Int
    var items: [Item]
  }

  /// Typst's completions at a cursor, the same suggestions its language server offers.
  public static func completions(_ text: String, cursor: Int, explicit: Bool) -> CompletionList {
    let data = call(text) { plainst_complete($0, $1, max(0, cursor), explicit) }
    guard let raw = try? JSONDecoder().decode(RawCompletions.self, from: data) else {
      return CompletionList(from: cursor, items: [])
    }
    return CompletionList(
      from: raw.from,
      items: raw.items.map {
        Completion(
          kind: Completion.Kind(rawValue: $0.kind) ?? .syntax, label: $0.label, apply: $0.apply,
          detail: $0.detail, symbol: $0.symbol.isEmpty ? nil : $0.symbol)
      })
  }

  /// Every symbol Typst knows, by full name, such as `arrow.r.double`.
  public static let symbols: [TypstSymbol] = {
    let data = call("") { _, _ in plainst_symbols() }
    guard let raw = try? JSONDecoder().decode([[String]].self, from: data) else { return [] }
    return raw.compactMap { $0.count == 2 ? TypstSymbol(name: $0[0], value: $0[1]) : nil }
  }()

  /// Loads fonts and the standard library so the first render is fast.
  public static func warmUp() { plainst_warm_up() }

  /// The fonts Typst uses by default, so the Writing view can match the PDF.
  public static func bundledFonts() -> [Data] {
    (0..<plainst_bundled_font_count()).compactMap { index in
      var length = 0
      guard let pointer = plainst_bundled_font(index, &length) else { return nil }
      return Data(
        bytesNoCopy: UnsafeMutableRawPointer(mutating: pointer), count: length, deallocator: .none)
    }
  }
}

extension Data {
  fileprivate func readUInt32(at offset: Int) -> UInt32 {
    var value: UInt32 = 0
    _ = Swift.withUnsafeMutableBytes(of: &value) {
      copyBytes(to: $0, from: (startIndex + offset)..<(startIndex + offset + 4))
    }
    return UInt32(littleEndian: value)
  }

  fileprivate func readFloat32(at offset: Int) -> Float32 {
    Float32(bitPattern: readUInt32(at: offset))
  }
}
