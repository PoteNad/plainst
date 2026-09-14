import AppKit
import PlainstCore

/// Identifies one rendering of an equation.
struct MathKey: Hashable, Sendable {
  var source: String
  var block: Bool
  /// The size of 1em in view points, times 100.
  var emSize: Int
  /// Pixels per view point, times 100.
  var backingScale: Int
  var color: UInt32
}

/// Renders equations with Typst in the background and keeps the results.
@MainActor
final class MathImages {
  static let shared = MathImages()

  enum Entry {
    case rendered(NSImage, size: CGSize, baseline: CGFloat)
    case failed(String)
  }

  private var cache: [MathKey: Entry] = [:]
  private var order: [MathKey] = []
  private var pending = Set<MathKey>()
  private var waiting: [MathKey: [(Entry) -> Void]] = [:]
  private let queue = DispatchQueue(label: "io.github.PoteNad.plainst.math", qos: .userInitiated)
  private let limit = 800

  static let didRender = Notification.Name("PlainstMathDidRender")

  func entry(_ key: MathKey) -> Entry? { cache[key] }

  /// Returns a cached rendering or starts one. `completion` runs on the main thread when a
  /// new rendering finishes.
  @discardableResult
  func request(_ key: MathKey, completion: ((Entry) -> Void)? = nil) -> Entry? {
    if let entry = cache[key] { return entry }
    if let completion { waiting[key, default: []].append(completion) }
    guard pending.insert(key).inserted else { return nil }
    queue.async {
      let em = CGFloat(key.emSize) / 100
      let scale = em / Engine.typstTextSize
      let color = (
        UInt8(key.color >> 24 & 0xFF), UInt8(key.color >> 16 & 0xFF), UInt8(key.color >> 8 & 0xFF),
        UInt8(key.color & 0xFF)
      )
      let result = Engine.renderMath(
        key.source, block: key.block,
        pixelsPerPoint: Double(scale * CGFloat(key.backingScale) / 100), color: color)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          let entry: Entry
          switch result {
          case .success(let render):
            let size = CGSize(width: render.size.width * scale, height: render.size.height * scale)
            let image = NSImage(cgImage: render.image, size: size)
            entry = .rendered(image, size: size, baseline: render.baseline * scale)
          case .failure(let error):
            entry = .failed(error.message)
          }
          self.store(key, entry)
        }
      }
    }
    return nil
  }

  private func store(_ key: MathKey, _ entry: Entry) {
    pending.remove(key)
    cache[key] = entry
    order.append(key)
    if order.count > limit {
      for old in order.prefix(order.count - limit) { cache[old] = nil }
      order.removeFirst(order.count - limit)
    }
    waiting.removeValue(forKey: key)?.forEach { $0(entry) }
    NotificationCenter.default.post(name: Self.didRender, object: nil)
  }

  static func packedColor(_ color: NSColor, appearance: NSAppearance) -> UInt32 {
    var result: UInt32 = 0xFF
    appearance.performAsCurrentDrawingAppearance {
      guard let rgb = color.usingColorSpace(.sRGB) else { return }
      func byte(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
      result =
        byte(rgb.redComponent) << 24 | byte(rgb.greenComponent) << 16 | byte(rgb.blueComponent) << 8
        | byte(rgb.alphaComponent)
    }
    return result
  }
}
