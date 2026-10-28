// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation

/// Inspect the shipped products rather than inferring linkage from target settings.
func output(_ executable: String, _ arguments: [String]) throws -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = arguments
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    try task.run()
    let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    let text = String(decoding: bytes, as: UTF8.self)
    guard task.terminationStatus == 0 else {
        throw NSError(domain: "ProductAudit", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "\(executable) failed: \(text)"])
    }
    return text
}

func require(_ condition: Bool, _ message: String) throws {
    guard condition else {
        throw NSError(domain: "ProductAudit", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

do {
    let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Build/Products/Release",
                        isDirectory: true)
    let modules = ["DolbyEEncoder", "DolbyEDecoder"]
    let products = modules.map { ("\($0).framework/\($0)", "OBJECT") }
        + [("dolbye-encode", "EXECUTE"), ("dolbye-decode", "EXECUTE")]
        + modules.map { ("Dynamic/\($0)Dynamic.framework/\($0)Dynamic", "DYLIB") }
    for (relative, kind) in products {
        let path = directory.appendingPathComponent(relative).path
        let architectures = try output("/usr/bin/lipo", ["-archs", path])
        try require(Set(architectures.split(whereSeparator: \.isWhitespace)) == Set(["arm64", "x86_64"]),
                    "\(relative): expected arm64 and x86_64, got \(architectures)")
        for architecture in ["arm64", "x86_64"] {
            if kind == "OBJECT" {
                let archive = try output("/usr/bin/otool", ["-arch", architecture, "-a", path])
                try require(archive.hasPrefix("Archive : "), "\(relative): expected a static archive")
            }
            let loadCommands = try output("/usr/bin/otool", ["-arch", architecture, "-l", path])
            let versions = loadCommands.split(separator: "\n").compactMap { line -> String? in
                let fields = line.split(whereSeparator: \.isWhitespace)
                return fields.first == "minos" && fields.count == 2 ? String(fields[1]) : nil
            }
            try require(!versions.isEmpty && versions.allSatisfy { $0 == "12.0" },
                        "\(relative) (\(architecture)): expected deployment floor 12.0, got \(Set(versions))")
            for command in loadCommands.components(separatedBy: "Load command ") {
                if command.contains("name /System/Library/Frameworks/SwiftData.framework/")
                    || command.contains("name /usr/lib/swift/libswiftObservation.dylib")
                    || command.contains("name /System/Library/Frameworks/SwiftUICore.framework/") {
                    try require(command.contains("LC_LOAD_WEAK_DYLIB"), "\(relative): newer OS framework must be weak-linked")
                }
            }
            let headers = try output("/usr/bin/otool", ["-arch", architecture, "-hv", path])
            let types = headers.split(separator: "\n").compactMap { line -> String? in
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.first == "MH_MAGIC_64", fields.count > 4 else { return nil }
                return String(fields[4])
            }
            try require(!types.isEmpty && types.allSatisfy { $0 == kind },
                        "\(relative) (\(architecture)): expected \(kind), got \(types)")
            let lines = try output("/usr/bin/otool", ["-arch", architecture, "-L", path]).split(separator: "\n")
            let dependencies = lines.filter { $0.hasPrefix("\t") }.map {
                String($0.dropFirst().components(separatedBy: " (compatibility version")[0])
            }
            let module = URL(fileURLWithPath: path).lastPathComponent
            let installName = "@rpath/\(module).framework/Versions/A/\(module)"
            for dependency in dependencies {
                if kind == "DYLIB", dependency == installName { continue }
                try require(dependency.hasPrefix("/System/Library/") || dependency.hasPrefix("/usr/lib/"),
                            "\(relative) (\(architecture)): non-system dependency \(dependency)")
            }
            if kind == "DYLIB" {
                try require(dependencies.first == installName, "\(relative): incorrect dynamic install name")
            } else if kind == "OBJECT" {
                try require(dependencies.isEmpty, "\(relative): static archive has dynamic load commands")
            }
        }
        print("Verified \(relative): \(kind), arm64 + x86_64, macOS 12.0+, macOS-only dependencies")
    }
} catch {
    FileHandle.standardError.write(Data("Product audit failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
