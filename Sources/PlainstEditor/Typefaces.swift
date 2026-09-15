import AppKit
import CoreText
import PlainstCore

/// The typefaces Typst uses by default, registered so the Writing view matches the PDF.
@MainActor
public enum Typefaces {
  /// Family names of the fonts bundled with Typst, as macOS knows them.
  private static var bundledFamilies: [String] = []

  /// The macOS family name for a family Typst names, which can differ in spacing or case, such
  /// as "New Computer Modern" and "NewComputerModern".
  static func installedFamily(matching family: String) -> String? {
    func key(_ name: String) -> String {
      name.lowercased().filter { !" -_".contains($0) }
    }
    let wanted = key(family)
    return (bundledFamilies + NSFontManager.shared.availableFontFamilies).first { key($0) == wanted }
  }

  public static func registerBundledFonts() {
    for data in Engine.bundledFonts() {
      guard let provider = CGDataProvider(data: data as CFData), let font = CGFont(provider) else {
        continue
      }
      var error: Unmanaged<CFError>?
      CTFontManagerRegisterGraphicsFont(font, &error)
      error?.release()
      let family = CTFontCopyFamilyName(CTFontCreateWithGraphicsFont(font, 12, nil, nil)) as String
      if !bundledFamilies.contains(family) { bundledFamilies.append(family) }
    }
  }

  /// The document's text font: `family` when it is installed, otherwise Typst's default serif.
  public static func serif(family: String? = nil, size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
    if let requested = family, requested.caseInsensitiveCompare(DocumentStyle.defaultFont) != .orderedSame,
      let family = installedFamily(matching: requested)
    {
      // Look fonts up by family, which also finds the fonts bundled with Typst that Plainst
      // registers for itself.
      func matches(_ font: NSFont?) -> NSFont? {
        guard let font, font.familyName?.caseInsensitiveCompare(family) == .orderedSame else { return nil }
        return font
      }
      let base = NSFontDescriptor(fontAttributes: [.family: family])
      var symbolic: NSFontDescriptor.SymbolicTraits = []
      if bold { symbolic.insert(.bold) }
      if italic { symbolic.insert(.italic) }
      if let font = matches(NSFont(descriptor: base.withSymbolicTraits(symbolic), size: size)),
        font.fontDescriptor.symbolicTraits.isSuperset(of: symbolic)
      {
        return font
      }
      if let regular = matches(NSFont(descriptor: base, size: size)) {
        // A family without a bold or italic face gets one derived from its regular face.
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        return traits.isEmpty ? regular : NSFontManager.shared.convert(regular, toHaveTrait: traits)
      }
    }
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
