import Foundation
import XCTest
@testable import MonknotApp
import MonknotCore

@MainActor
final class WorkspaceStoreTestContext {
    private let suiteName = "Monknot.WorkspaceStoreTests.\(UUID().uuidString)"
    private(set) lazy var userDefaults = UserDefaults(suiteName: suiteName)!
    private var stores: [WorkspaceStore] = []
    private var temporaryRoots: [URL] = []

    func makeStore(
        scanner: any WorkspaceDocumentScanning = WorkspaceDocumentScanner()
    ) -> WorkspaceStore {
        let store = WorkspaceStore(scanner: scanner, userDefaults: userDefaults)
        stores.append(store)
        return store
    }

    func makeTemporaryDirectory(prefix: String = "MonknotWorkspaceStoreTests") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryRoots.append(url)
        return url
    }

    func cleanUp() {
        stores.removeAll()
        WorkspaceTextContentCache.shared.invalidateAll()
        WorkspaceSearchIndex.shared.invalidateAll()
        WorkspacePDFTextCache.shared.invalidateAll()
        WorkspacePDFSearchIndex.shared.invalidateAll()
        for root in temporaryRoots.reversed() {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots.removeAll()
        userDefaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
class WorkspaceStoreTestCase: XCTestCase {
    private var workspaceStoreTestContext: WorkspaceStoreTestContext!

    override func setUp() async throws {
        try await super.setUp()
        workspaceStoreTestContext = WorkspaceStoreTestContext()
    }

    override func tearDown() async throws {
        workspaceStoreTestContext.cleanUp()
        workspaceStoreTestContext = nil
        try await super.tearDown()
    }

    func makeWorkspaceStore(
        scanner: any WorkspaceDocumentScanning = WorkspaceDocumentScanner()
    ) -> WorkspaceStore {
        workspaceStoreTestContext.makeStore(scanner: scanner)
    }

    func makeWorkspaceStoreTemporaryDirectory(
        prefix: String = "MonknotWorkspaceStoreTests"
    ) throws -> URL {
        try workspaceStoreTestContext.makeTemporaryDirectory(prefix: prefix)
    }
}
