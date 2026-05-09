import Foundation
import XCTest

final class BuildScriptSyncTests: XCTestCase {
    func testManualBuildScriptListsAllSwiftSources() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let script = try String(contentsOf: root.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)

        let coreSources = try sourceEntries(named: "CORE_SOURCES", in: script)
        let appSources = try sourceEntries(named: "APP_SOURCES", in: script)

        XCTAssertEqual(
            coreSources,
            try swiftSources(under: root.appendingPathComponent("Sources/MarkprevCore")),
            "script/build_and_run.sh CORE_SOURCES must stay in sync with Sources/MarkprevCore"
        )
        XCTAssertEqual(
            appSources,
            try swiftSources(under: root.appendingPathComponent("Sources/Markprev")),
            "script/build_and_run.sh APP_SOURCES must stay in sync with Sources/Markprev"
        )
    }

    func testManualBuildScriptCopiesRuntimeResources() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let script = try String(contentsOf: root.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)

        let requiredResources = [
            "Sources/MarkprevCore/Resources/preview.css",
            "Sources/MarkprevCore/Resources/renderer.js",
            "Sources/Markprev/Resources/xterm.css",
            "Sources/Markprev/Resources/xterm.js",
            "Sources/Markprev/Resources/xterm-addon-fit.js"
        ]

        for resource in requiredResources {
            XCTAssertTrue(
                script.contains(resource),
                "script/build_and_run.sh must copy \(resource)"
            )
        }
    }

    private func sourceEntries(named arrayName: String, in script: String) throws -> Set<String> {
        guard let startRange = script.range(of: "\(arrayName)=(") else {
            throw NSError(domain: "BuildScriptSyncTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing \(arrayName) array"])
        }
        guard let endRange = script[startRange.upperBound...].range(of: "\n)") else {
            throw NSError(domain: "BuildScriptSyncTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing \(arrayName) terminator"])
        }

        let section = script[startRange.upperBound..<endRange.lowerBound]
        return Set(section
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { line -> String? in
                guard line.hasPrefix("\""), line.hasSuffix("\"") else { return nil }
                return String(line.dropFirst().dropLast())
            })
    }

    private func swiftSources(under directory: URL) throws -> Set<String> {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var sources: Set<String> = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relativePath = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            sources.insert(relativePath)
        }
        return sources
    }
}
