import Foundation
import MonknotCore
import XCTest
@testable import MonknotApp

@MainActor
class WorkspaceStoreLinkTestCase: WorkspaceStoreTestCase {

    func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceStoreLinkMoveTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Source.md").standardizedFileURL
        let target = root.appendingPathComponent("Target.md").standardizedFileURL
        try "[target](Target.md)\n".write(to: source, atomically: true, encoding: .utf8)
        try "# Target\n".write(to: target, atomically: true, encoding: .utf8)
        return Fixture(root: root, source: source, target: target)
    }

    func waitUntil(
        timeout: TimeInterval = 8,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    func assertEventually(
        timeout: TimeInterval = 8,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let result = await waitUntil(timeout: timeout, condition: condition)
        XCTAssertTrue(result, file: file, line: line)
    }

    struct Fixture {
        let root: URL
        let source: URL
        let target: URL

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

final class FailingWorkspaceScanner: WorkspaceDocumentScanning, @unchecked Sendable {
    let lock = NSLock()
    let failOnCall: Int
    var callCount = 0

    init(failOnCall: Int) {
        self.failOnCall = failOnCall
    }

    func scan(rootURL: URL) throws -> WorkspaceDocumentScanResult {
        lock.lock()
        callCount += 1
        let shouldFail = callCount == failOnCall
        lock.unlock()

        if shouldFail {
            throw FailingWorkspaceScannerError.scanFailure
        }
        return try WorkspaceDocumentScanner().scan(rootURL: rootURL)
    }
}

enum FailingWorkspaceScannerError: LocalizedError {
    case scanFailure

    var errorDescription: String? {
        "Injected scan failure."
    }
}
