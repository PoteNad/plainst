import AppKit
import CoreText
import PlainstCore

/// The typefaces Typst uses by default, registered so the Writing view matches the PDF.
@MainActor
public enum Typefaces {
  public static func registerBundledFonts() {
    for data in Engine.bundledFonts() {
      guard let provider = CGDataProvider(data: data as CFData), let font = CGFont(provider) else {
        continue
      }
      var error: Unmanaged<CFError>?
      CTFontManagerRegisterGraphicsFont(font, &error)
      error?.release()
    }
  }

  public static func serif(size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
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

  public static func typstMono(size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
    let name: String
    switch (bold, italic) {
    case (true, true): name = "DejaVuSansMono-BoldOblique"
    case (true, false): name = "DejaVuSansMono-Bold"
    case (false, true): name = "DejaVuSansMono-Oblique"
    case (false, false): name = "DejaVuSansMono"
    }
    return NSFont(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
  }

  /// A monospaced font in `family`, or the system monospaced font for an empty family.
  public static func editorMono(family: String, size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
    var traits: NSFontTraitMask = []
    if bold { traits.insert(.boldFontMask) }
    if italic { traits.insert(.italicFontMask) }
    if !family.isEmpty,
      let font = NSFontManager.shared.font(
        withFamily: family, traits: traits, weight: bold ? 9 : 5, size: size)
        ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
    {
      return font
    }
    var font = NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
    if italic {
      font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }
    return font
  }

  /// Installed font families whose regular face is monospaced.
  public static var monospacedFamilies: [String] {
    let manager = NSFontManager.shared
    return manager.availableFontFamilies.filter { family in
      guard let members = manager.availableMembers(ofFontFamily: family),
        let name = members.first?.first as? String, let font = NSFont(name: name, size: 12)
      else { return false }
      return font.isFixedPitch
    }.sorted()
  }
}
