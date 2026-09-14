import AppKit

// Draws the Plainst icon: PoteNad's paper tile with a line of text and an equation.
// Run from the repository root: swift scripts/make-icon.swift

func drawIcon(in size: CGFloat) {
  let scale = size / 1024
  let context = NSGraphicsContext.current!.cgContext
  context.scaleBy(x: scale, y: scale)
  // AppKit's origin is bottom-left; the artwork below is laid out top-down.
  context.translateBy(x: 0, y: 1024)
  context.scaleBy(x: 1, y: -1)

  let shadow = NSBezierPath(roundedRect: NSRect(x: 104, y: 126, width: 816, height: 816), xRadius: 184, yRadius: 184)
  NSColor(white: 0, alpha: 0.18).setFill()
  shadow.fill()
  let tile = NSBezierPath(roundedRect: NSRect(x: 104, y: 104, width: 816, height: 816), xRadius: 184, yRadius: 184)
  NSGradient(starting: .white, ending: NSColor(srgbRed: 0xF1 / 255, green: 0xF2 / 255, blue: 0xF5 / 255, alpha: 1))!
    .draw(in: tile, angle: -90)
  NSColor(white: 0, alpha: 0.1).setStroke()
  let border = NSBezierPath(roundedRect: NSRect(x: 106, y: 106, width: 812, height: 812), xRadius: 182, yRadius: 182)
  border.lineWidth = 4
  border.stroke()

  let ink = NSColor(srgbRed: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255, alpha: 1)
  ink.setFill()
  NSBezierPath(roundedRect: NSRect(x: 222, y: 250, width: 420, height: 54), xRadius: 27, yRadius: 27).fill()
  NSBezierPath(roundedRect: NSRect(x: 222, y: 380, width: 580, height: 34), xRadius: 17, yRadius: 17).fill()
  NSBezierPath(roundedRect: NSRect(x: 222, y: 480, width: 500, height: 34), xRadius: 17, yRadius: 17).fill()

  // A display equation in Typst's accent blue.
  let blue = NSColor(srgbRed: 0x34 / 255, green: 0x78 / 255, blue: 0xF6 / 255, alpha: 1)
  let font = NSFont(name: "Times New Roman Italic", size: 250) ?? NSFont.systemFont(ofSize: 250)
  let equation = NSAttributedString(string: "x²", attributes: [.font: font, .foregroundColor: blue])
  context.saveGState()
  context.translateBy(x: 0, y: 1024)
  context.scaleBy(x: 1, y: -1)
  let bounds = equation.size()
  equation.draw(at: NSPoint(x: 512 - bounds.width / 2, y: 1024 - 840))
  context.restoreGState()
}

let directory = URL(fileURLWithPath: "build/Plainst.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
var images: [Int: Data] = [:]
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  drawIcon(in: CGFloat(pixels))
  NSGraphicsContext.restoreGraphicsState()
  images[pixels] = bitmap.representation(using: .png, properties: [:])!
}

func bigEndian(_ value: Int) -> Data {
  var value = UInt32(value).bigEndian
  return Data(bytes: &value, count: 4)
}

var chunks = Data()
for (type, pixels) in [
  ("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256),
  ("ic09", 512), ("ic10", 1024), ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512),
] {
  let image = images[pixels]!
  chunks.append(Data(type.utf8))
  chunks.append(bigEndian(image.count + 8))
  chunks.append(image)
}
var icon = Data("icns".utf8)
icon.append(bigEndian(chunks.count + 8))
icon.append(chunks)
try icon.write(to: URL(fileURLWithPath: "Assets/Plainst.icns"))
try images[1024]!.write(to: URL(fileURLWithPath: "Assets/Plainst.png"))
print("Wrote Assets/Plainst.icns")
