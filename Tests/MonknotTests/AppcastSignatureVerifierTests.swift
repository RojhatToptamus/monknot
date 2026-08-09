import Foundation
import XCTest

final class AppcastSignatureVerifierTests: XCTestCase {
    func testVerifierRejectsAFeedWithAnInvalidEd25519Signature() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonknotAppcastSignatureVerifierTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let appcastURL = temporaryDirectory.appendingPathComponent("appcast.xml")
        let archiveURL = temporaryDirectory.appendingPathComponent("Monknot.dmg")
        let publicKeyURL = temporaryDirectory.appendingPathComponent("public-key")
        let invalidSignature = Data(repeating: 0, count: 64).base64EncodedString()
        let unsignedAppcast = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel><item><enclosure sparkle:edSignature="\(invalidSignature)" /></item></channel>
        </rss>

        """
        let signedAppcast = unsignedAppcast + """
        <!-- sparkle-signatures:
        edSignature: \(invalidSignature)
        length: \(unsignedAppcast.utf8.count)
        -->
        """

        try Data("not a release artifact".utf8).write(to: archiveURL)
        try Data(signedAppcast.utf8).write(to: appcastURL)
        try Data("eRFPLZuNM6m8bltmtpPX4fzKbufI1z6rKJHtgIIsllk=\n".utf8).write(to: publicKeyURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "swift",
            root.appendingPathComponent("script/verify_appcast_signatures.swift").path,
            appcastURL.path,
            archiveURL.path,
            publicKeyURL.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["CLANG_MODULE_CACHE_PATH"] = temporaryDirectory.appendingPathComponent("clang-cache").path
        environment["SWIFT_MODULECACHE_PATH"] = temporaryDirectory.appendingPathComponent("swift-cache").path
        process.environment = environment
        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let errorOutput = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertTrue(errorOutput.contains("appcast signed-feed signature is invalid"), errorOutput)
    }
}
