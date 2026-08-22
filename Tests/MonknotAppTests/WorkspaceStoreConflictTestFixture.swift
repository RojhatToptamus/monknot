import XCTest
import Combine
import MonknotCore
@testable import MonknotApp

@MainActor
class WorkspaceStoreConflictTestCase: WorkspaceStoreTestCase {

    @MainActor
    func waitUntil(timeout: TimeInterval = 3, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    func makeConflictedStore(
        in root: URL
    ) async throws -> (store: WorkspaceStore, sourceURL: URL) {
        let sourceURL = root.appendingPathComponent("Note.md")
        try "baseline\n".write(to: sourceURL, atomically: true, encoding: .utf8)

        let store = makeWorkspaceStore()
        store.openWorkspace(root)
        let didOpen = await waitUntil { !store.isBusy && !store.isDocumentLoading }
        guard didOpen else {
            throw CocoaError(.fileReadUnknown)
        }
        store.setDocumentText("local\n")
        try "disk\n".write(to: sourceURL, atomically: false, encoding: .utf8)
        store.testing_clearWatcherSuppression()
        store.refresh()
        let didDetectConflict = await waitUntil(timeout: 8) {
            store.selectedDocumentExternalChange
        }
        guard didDetectConflict else {
            throw CocoaError(.fileReadUnknown)
        }
        return (store, sourceURL)
    }

    func waitForSave(_ store: WorkspaceStore) async -> Bool {
        let didStart = await waitUntil { store.isSaving }
        guard didStart else { return false }
        return await waitUntil { !store.isSaving }
    }

    func makeTemporaryDirectory() throws -> URL {
        try makeWorkspaceStoreTemporaryDirectory(prefix: "MonknotWorkspaceStoreConflictTests")
    }

}

final class BlockingWorkspaceScanner: WorkspaceDocumentScanning, @unchecked Sendable {
    let condition = NSCondition()
    let blockingCall: Int
    var callCount = 0
    var isReleased = false
    var blocking = false
    var completedBlockedCall = false

    init(blockingCall: Int) {
        self.blockingCall = blockingCall
    }

    var isBlocking: Bool {
        condition.withLock { blocking }
    }

    var didCompleteBlockedCall: Bool {
        condition.withLock { completedBlockedCall }
    }

    func scan(rootURL: URL) throws -> WorkspaceDocumentScanResult {
        condition.lock()
        callCount += 1
        let shouldBlock = callCount == blockingCall
        if shouldBlock {
            blocking = true
            while !isReleased {
                condition.wait()
            }
        }
        condition.unlock()

        let result = try WorkspaceDocumentScanner().scan(rootURL: rootURL)
        if shouldBlock {
            condition.withLock {
                completedBlockedCall = true
            }
        }
        return result
    }

    func resume() {
        condition.withLock {
            isReleased = true
            condition.broadcast()
        }
    }
}

final class BlockingFailureWorkspaceScanner: WorkspaceDocumentScanning, @unchecked Sendable {
    let condition = NSCondition()
    let blockingCall: Int
    var storedCallCount = 0
    var isReleased = false
    var blocking = false
    var completedBlockedCall = false

    init(blockingCall: Int) {
        self.blockingCall = blockingCall
    }

    var callCount: Int {
        condition.withLock { storedCallCount }
    }

    var isBlocking: Bool {
        condition.withLock { blocking }
    }

    var didCompleteBlockedCall: Bool {
        condition.withLock { completedBlockedCall }
    }

    func scan(rootURL: URL) throws -> WorkspaceDocumentScanResult {
        condition.lock()
        storedCallCount += 1
        let shouldBlock = storedCallCount == blockingCall
        if shouldBlock {
            blocking = true
            while !isReleased {
                condition.wait()
            }
            completedBlockedCall = true
        }
        condition.unlock()

        if shouldBlock {
            throw CocoaError(.fileReadUnknown)
        }
        return try WorkspaceDocumentScanner().scan(rootURL: rootURL)
    }

    func resume() {
        condition.withLock {
            isReleased = true
            condition.broadcast()
        }
    }
}
