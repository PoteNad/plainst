import AppKit

// Renders the Liquid Glass icon in Assets/Plainst.icon with Icon Composer, then builds
// Assets/Plainst.icns from it for macOS versions before 26.
// Edit the layers in Icon Composer, then run from the repository root:
//   swift scripts/make-icon.swift

let ictool =
  "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
let render = Process()
render.executableURL = URL(fileURLWithPath: ictool)
render.arguments = [
  "Assets/Plainst.icon", "--export-image", "--output-file", "Assets/Plainst-Liquid.png",
  "--platform", "macOS", "--rendition", "Default", "--width", "1024", "--height", "1024",
  "--scale", "1",
]
render.standardOutput = FileHandle.nullDevice
try render.run()
render.waitUntilExit()
guard render.terminationStatus == 0 else { fatalError("Icon Composer could not render the icon") }

let sourceURL = URL(fileURLWithPath: "Assets/Plainst-Liquid.png")
guard let source = NSImage(contentsOf: sourceURL) else {
  fatalError("Could not load \(sourceURL.path)")
}

var images: [Int: Data] = [:]
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  NSGraphicsContext.current?.imageInterpolation = .high
  source.draw(
    in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
    from: NSRect(origin: .zero, size: source.size), operation: .copy, fraction: 1)
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
print("Wrote Assets/Plainst-Liquid.png and Assets/Plainst.icns")
