// swift-tools-version: 6.0
import PackageDescription

// The Typst engine is a Rust static library built by scripts/build.sh.
let engineLibrary =
  Context.environment["PLAINST_ENGINE_LIB"] ?? Context.packageDirectory + "/engine/target/release"
let linkEngine: [LinkerSetting] = [.unsafeFlags(["-L", engineLibrary])]
// Record the real SDK in the app. Some SwiftPM toolchains record the deployment target instead,
// and AppKit then draws windows with older styling. scripts/toolchain.sh sets the version.
let linkApp: [LinkerSetting] =
  linkEngine
  + (Context.environment["PLAINST_SDK_VERSION"].map {
    [.unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "13.0", "-Xlinker", $0])]
  } ?? [])
let checking = Context.environment["PLAINST_CHECKS"] == "1"

let package = Package(
  name: "Plainst", platforms: [.macOS(.v13)],
  products: [
    .executable(name: "Plainst", targets: ["Plainst"]),
    // The Typst editor view, for other apps. It needs the engine library built by scripts/build.sh.
    .library(name: "PlainstEditor", targets: ["PlainstEditor"]),
  ],
  targets: [
    .systemLibrary(name: "CPlainstEngine", path: "Sources/CPlainstEngine"),
    .target(name: "PlainstCore", dependencies: ["CPlainstEngine"], linkerSettings: linkEngine),
    .target(
      name: "PlainstEditor", dependencies: ["PlainstCore"],
      // The app's checks look inside the editor with @testable import.
      swiftSettings: checking ? [.define("PLAINST_CHECKS"), .unsafeFlags(["-enable-testing"])] : [],
      linkerSettings: linkEngine),
    .executableTarget(
      name: "Plainst", dependencies: ["PlainstCore", "PlainstEditor"], exclude: checking ? [] : ["AppChecks.swift"],
      swiftSettings: checking ? [.define("PLAINST_CHECKS")] : [], linkerSettings: linkApp),
    .testTarget(name: "PlainstCoreTests", dependencies: ["PlainstCore"], linkerSettings: linkEngine),
    .testTarget(
      name: "PlainstEditorTests", dependencies: ["PlainstCore", "PlainstEditor"], linkerSettings: linkEngine),
  ])
