import Foundation

// Writes engine/src/symbol_groups.txt, the categories of Typst's symbols, from the section
// comments in codex's sym.txt. Run from the repository root after updating the codex crate:
//   swift scripts/generate-symbol-groups.swift

func run(_ arguments: [String]) throws -> Data {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = arguments
  let pipe = Pipe()
  process.standardOutput = pipe
  try process.run()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return data
}

let metadata = try run(["cargo", "metadata", "--format-version", "1", "--manifest-path", "engine/Cargo.toml"])
guard let json = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
  let packages = json["packages"] as? [[String: Any]],
  let codex = packages.first(where: { $0["name"] as? String == "codex" }),
  let manifest = codex["manifest_path"] as? String, let version = codex["version"] as? String
else { fatalError("codex was not found in the engine's dependencies") }

let source = URL(fileURLWithPath: manifest).deletingLastPathComponent()
  .appendingPathComponent("src/modules/sym.txt")
let lines = try String(contentsOf: source, encoding: .utf8).components(separatedBy: "\n")

// Invisible characters make poor buttons, so these sections are left out.
let skipped: Set<String> = ["Control", "Spaces"]
let renamed = [
  "Printable characters representing control (non-printable) characters": "Control Pictures",
  "Miscellaneous Technical": "Miscellaneous technical",
]
var output = ["# Generated from codex \(version) sym.txt by scripts/generate-symbol-groups.swift. Do not edit."]
var inCommentBlock = false
var skipping = false
for line in lines {
  if line.hasPrefix("//") {
    let text = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
    // The first line of a comment block names the section; later lines explain it.
    if !inCommentBlock, !text.contains("http"), text.split(separator: " ").count <= 8 {
      var title = text
      if title.hasSuffix(".") { title.removeLast() }
      skipping = skipped.contains(title)
      if !skipping { output.append("== \(renamed[title] ?? title)") }
    }
    inCommentBlock = true
    continue
  }
  inCommentBlock = false
  guard !skipping, let first = line.first, first.isLetter else { continue }
  if let name = line.split(separator: " ").first { output.append(String(name)) }
}
try (output.joined(separator: "\n") + "\n").write(
  toFile: "engine/src/symbol_groups.txt", atomically: true, encoding: .utf8)
print("Wrote engine/src/symbol_groups.txt")
