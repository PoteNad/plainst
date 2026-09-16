import Foundation

// Writes THIRD_PARTY_NOTICES.md: the license and notice text for every crate compiled into the
// Typst engine, including the fonts and data Typst bundles. Run from the repository root after
// changing the engine's dependencies:
//   swift scripts/generate-notices.swift
// With --check, it only verifies that the file is current, for scripts/check.sh.

let outputPath = "THIRD_PARTY_NOTICES.md"
let checking = CommandLine.arguments.contains("--check")

func run(_ arguments: [String]) -> Data {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = arguments
  let pipe = Pipe()
  process.standardOutput = pipe
  do { try process.run() } catch { fatalError("Could not run \(arguments[0]): \(error)") }
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else { fatalError("\(arguments.joined(separator: " ")) failed") }
  return data
}

struct Crate {
  var name: String
  var version: String
  var license: String
  var authors: [String]
  var directory: URL
  var label: String { "\(name) \(version)" }
}

// Every crate linked into the app on either architecture: normal dependencies only, since build
// scripts and dev-dependencies are not shipped.
var crates: [String: Crate] = [:]
for triple in ["aarch64-apple-darwin", "x86_64-apple-darwin"] {
  let data = run([
    "cargo", "metadata", "--format-version", "1", "--locked", "--manifest-path", "engine/Cargo.toml",
    "--filter-platform", triple,
  ])
  guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
    let packages = json["packages"] as? [[String: Any]],
    let resolve = json["resolve"] as? [String: Any], let root = resolve["root"] as? String,
    let nodes = resolve["nodes"] as? [[String: Any]]
  else { fatalError("cargo metadata returned an unexpected shape") }
  let byID = Dictionary(uniqueKeysWithValues: packages.map { ($0["id"] as! String, $0) })
  let edges = Dictionary(uniqueKeysWithValues: nodes.map { node -> (String, [String]) in
    let deps = (node["deps"] as? [[String: Any]] ?? []).filter { dep in
      (dep["dep_kinds"] as? [[String: Any]] ?? []).contains { $0["kind"] is NSNull }
    }
    return (node["id"] as! String, deps.map { $0["pkg"] as! String })
  })
  var stack = edges[root] ?? []
  var seen = Set<String>()
  while let id = stack.popLast() {
    guard seen.insert(id).inserted, let package = byID[id] else { continue }
    stack += edges[id] ?? []
    let name = package["name"] as! String
    let version = package["version"] as! String
    guard let license = package["license"] as? String else {
      fatalError("\(name) \(version) has no SPDX license expression; add it to this script by hand")
    }
    crates["\(name) \(version)"] = Crate(
      name: name, version: version, license: license, authors: package["authors"] as? [String] ?? [],
      directory: URL(fileURLWithPath: package["manifest_path"] as! String).deletingLastPathComponent())
  }
}
let sortedCrates = crates.values.sorted { ($0.name, $0.version) < ($1.name, $1.version) }

// Licenses offered as alternatives are chosen in this order.
let preference = [
  "MIT", "Apache-2.0", "BSD-3-Clause", "BSD-2-Clause", "Zlib", "ISC", "0BSD", "Unicode-3.0", "MPL-2.0",
  "CC0-1.0", "Unlicense", "BSL-1.0",
]
let titles = [
  "MIT": "MIT License", "Apache-2.0": "Apache License 2.0", "BSD-3-Clause": "BSD 3-Clause License",
  "BSD-2-Clause": "BSD 2-Clause License", "Zlib": "zlib License", "ISC": "ISC License",
  "0BSD": "BSD Zero Clause License", "Unicode-3.0": "Unicode License v3", "MPL-2.0": "Mozilla Public License 2.0",
]
// Text that identifies each license in a crate's license files.
let markers = [
  "MIT": "Permission is hereby granted", "Apache-2.0": "Apache License", "BSD-3-Clause": "Redistribution and use",
  "BSD-2-Clause": "Redistribution and use", "Zlib": "provided 'as-is'", "ISC": "Permission to use, copy, modify",
  "0BSD": "Permission to use, copy, modify", "Unicode-3.0": "UNICODE LICENSE", "MPL-2.0": "Mozilla Public License",
]

/// The licenses a crate is used under: one choice from each alternative in its expression.
func chosenLicenses(_ expression: String) -> [String] {
  let flat = expression.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
    .replacingOccurrences(of: "/", with: " OR ")
  return flat.components(separatedBy: " AND ").map { part in
    let options = part.components(separatedBy: " OR ").map {
      $0.trimmingCharacters(in: .whitespaces).components(separatedBy: " WITH ")[0]
    }
    return preference.first(where: options.contains) ?? options[0]
  }
}

func licenseFiles(in directory: URL) -> [(name: String, text: String)] {
  let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
  return names.sorted().compactMap { name in
    let upper = name.uppercased()
    guard upper.contains("LICEN") || upper.hasPrefix("COPYING"),
      let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    else { return nil }
    return (name, text)
  }
}

func normalized(_ text: String) -> String {
  text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

// Plainst's own MIT license supplies the standard wording for crates that ship no MIT file.
let mitBody = try String(contentsOfFile: "LICENSE", encoding: .utf8)
  .components(separatedBy: "\n").drop { !$0.hasPrefix("Permission is hereby granted") }.joined(separator: "\n")
let zeroBSDBody = """
  Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted.

  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
  """

// A crate's own license file, or else the license's standard text credited to its authors.
var found: [(crate: Crate, license: String, text: String?)] = []
for crate in sortedCrates {
  let files = licenseFiles(in: crate.directory)
  for license in chosenLicenses(crate.license) {
    let marker = markers[license] ?? license
    let matching = files.filter { $0.text.contains(marker) }
    let named = matching.first { file in
      let upper = file.name.uppercased()
      return (license == "MIT" && upper.contains("MIT")) || (license == "Apache-2.0" && upper.contains("APACHE"))
    }
    found.append((crate, license, (named ?? matching.first).map { normalized($0.text) }))
  }
}
var standardTexts: [String: String] = [:]
for entry in found where entry.text != nil && standardTexts[entry.license] == nil && entry.license != "MIT" {
  standardTexts[entry.license] = entry.text
}

var groups: [String: (license: String, crates: [String])] = [:]
for entry in found {
  let text: String
  if let own = entry.text {
    text = own
  } else {
    let holders = entry.crate.authors.isEmpty
      ? "The \(entry.crate.name) authors"
      : entry.crate.authors.map { $0.replacingOccurrences(of: #"\s*<[^>]*>"#, with: "", options: .regularExpression) }
        .joined(separator: ", ")
    switch entry.license {
    case "MIT": text = normalized("Copyright (c) \(holders)\n\n" + mitBody)
    case "0BSD": text = normalized("Copyright (c) \(holders)\n\n" + zeroBSDBody)
    default:
      guard let standard = standardTexts[entry.license] else {
        fatalError("No \(entry.license) license text was found for \(entry.crate.label); add one to this script")
      }
      text = entry.license == "Apache-2.0" ? "Copyright \(holders)\n\n" + standard : standard
    }
  }
  groups[text, default: (entry.license, [])].crates.append(entry.crate.label)
}

var output = """
  # Third-Party Notices

  Plainst's own code is available under the MIT License in LICENSE. Plainst also includes the Typst compiler, the Rust crates it depends on, and the fonts and data that Typst bundles, each under the license or notice below.

  This file is generated by `swift scripts/generate-notices.swift` from the engine's dependencies. Don't edit it by hand.

  ## Notices

  """
for crate in sortedCrates {
  let notices = ((try? FileManager.default.contentsOfDirectory(atPath: crate.directory.path)) ?? [])
    .filter { $0.uppercased().hasPrefix("NOTICE") }.sorted()
  for name in notices {
    guard let text = try? String(contentsOf: crate.directory.appendingPathComponent(name), encoding: .utf8)
    else { continue }
    output += "\n### \(crate.label)\n\n```text\n\(normalized(text))\n```\n"
  }
}
output += "\n## Licenses\n"
let ordered = groups.sorted { a, b in
  let rank = { (license: String) in preference.firstIndex(of: license) ?? preference.count }
  return (rank(a.value.license), a.value.crates[0]) < (rank(b.value.license), b.value.crates[0])
}
for (text, group) in ordered {
  let crates = Array(Set(group.crates)).sorted()
  output += "\n### \(titles[group.license] ?? group.license)\n\nUsed by \(crates.joined(separator: ", ")).\n\n```text\n\(text)\n```\n"
}

if checking {
  let current = try? String(contentsOfFile: outputPath, encoding: .utf8)
  guard current == output else {
    FileHandle.standardError.write(
      Data("\(outputPath) is out of date. Run: swift scripts/generate-notices.swift\n".utf8))
    exit(1)
  }
  print("\(outputPath) is current (\(crates.count) crates)")
} else {
  try output.write(toFile: outputPath, atomically: true, encoding: .utf8)
  print("Wrote \(outputPath) (\(crates.count) crates, \(groups.count) license texts)")
}
