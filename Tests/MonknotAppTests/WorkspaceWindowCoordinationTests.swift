import Foundation
import XCTest
@testable import MonknotApp

@MainActor
final class WorkspaceWindowCoordinationTests: XCTestCase {
    func testOnlyFirstWindowClaimsInitialWorkspaceRestoration() {
        let coordinator = InitialWorkspaceRestorationCoordinator()
        XCTAssertTrue(coordinator.claimInitialRestore())
        XCTAssertFalse(coordinator.claimInitialRestore())
        XCTAssertFalse(coordinator.claimInitialRestore())
        XCTAssertTrue(InitialWorkspaceRestorationCoordinator().claimInitialRestore())
    }

    func testWindowRequestsQueueUntilInitialHandlingAndThenFlushInOrder() {
        let first = URL(fileURLWithPath: "/tmp/Monknot/First", isDirectory: true)
        let second = URL(fileURLWithPath: "/tmp/Monknot/Second", isDirectory: true)
        let selected = first.appendingPathComponent("README.md")
        let center = WorkspaceWindowRequestCenter()
        var openedPaths: [String] = []

        center.openWorkspaceWindow(at: first, selecting: selected)
        center.openWorkspaceWindow(at: second)
        let initial = center.consumePendingInitialWorkspaceRequest()
        XCTAssertEqual(initial?.workspaceURL?.standardizedFileURL, first.standardizedFileURL)
        XCTAssertEqual(initial?.selectedDocumentURL?.standardizedFileURL, selected.standardizedFileURL)
        center.installOpenWindowAction { request in
            openedPaths.append(request.workspaceURL?.standardizedFileURL.path ?? "")
        }
        center.finishInitialWorkspaceRequestHandling()

        XCTAssertEqual(openedPaths, [second.standardizedFileURL.path])
    }

    func testReusableWindowConsumesFirstRequestWithoutOpeningAnotherWindow() {
        let first = URL(fileURLWithPath: "/tmp/Monknot/First", isDirectory: true)
        let second = URL(fileURLWithPath: "/tmp/Monknot/Second", isDirectory: true)
        let center = WorkspaceWindowRequestCenter()
        var reusedPaths: [String] = []
        var openedPaths: [String] = []
        center.installReusableWindowHandler(id: UUID()) { request in
            guard reusedPaths.isEmpty else { return false }
            reusedPaths.append(request.workspaceURL?.path ?? "")
            return true
        }
        center.installOpenWindowAction { request in
            openedPaths.append(request.workspaceURL?.path ?? "")
        }

        center.openWorkspaceWindow(at: first)
        center.finishInitialWorkspaceRequestHandling()
        center.openWorkspaceWindow(at: second)

        XCTAssertEqual(reusedPaths, [first.path])
        XCTAssertEqual(openedPaths, [second.path])
    }
}
