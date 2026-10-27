// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
task.arguments = ["ls-files", "-z"]
let pipe = Pipe(); task.standardOutput = pipe
try task.run()
let data = pipe.fileHandleForReading.readDataToEndOfFile()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("tracked-file inventory failed") }
let files = String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
guard !files.isEmpty else { fatalError("source checkout contains no tracked files") }
let excluded = Set(["research", "evidence", "vectors", "outputs", "build", "artifacts", "xcuserdata", "tests", "testresults"])
let media = Set(["wav", "mxf", "caf", "atmos", "dll", "vst", "vst3", "rar", "7z", "zip", "dmg", "p12", "mobileprovision"])
let credential = try NSRegularExpression(pattern: "-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}")
for path in files {
    let url = URL(fileURLWithPath: path)
    guard !path.split(separator: "/").contains(where: { excluded.contains($0.lowercased()) }),
          !media.contains(url.pathExtension.lowercased()) else { fatalError("excluded local material tracked: \(path)") }
    let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
    guard bytes.count <= 5 * 1024 * 1024 else { fatalError("unexpected large source artifact: \(path)") }
    if let text = String(data: bytes, encoding: .utf8) {
        guard credential.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil else { fatalError("credential-like content: \(path)") }
        if url.pathExtension == "swift" {
            guard text.hasPrefix("// Copyright © 2026 B00kerLouis.\n// SPDX-License-Identifier: LGPL-3.0-or-later\n") else { fatalError("missing owned-source license: \(path)") }
        }
    }
}
for path in ["LICENSE", "COPYING"] {
    guard files.contains(path) else { fatalError("license text missing: \(path)") }
}
print("Reviewed \(files.count) tracked files: source-only inventory and owned-source license checks passed.")

let project = try String(contentsOfFile: "Swift_Dolby_E.xcodeproj/project.pbxproj", encoding: .utf8)
guard !project.contains("com.apple.product-type.bundle.unit-test") else { fatalError("local verification target included in published project") }
