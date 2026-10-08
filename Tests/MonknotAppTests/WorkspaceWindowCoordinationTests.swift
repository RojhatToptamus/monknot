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
        var shownWorkspace: URL?
        var openedPaths: [String] = []
        center.installReusableWindow(id: UUID(), workspaceURL: { shownWorkspace }) { request, claim in
            XCTAssertEqual(claim, .empty)
            shownWorkspace = request.workspaceURL
        }
        center.installOpenWindowAction { request in
            openedPaths.append(request.workspaceURL?.path ?? "")
        }

        center.openWorkspaceWindow(at: first)
        center.finishInitialWorkspaceRequestHandling()
        center.openWorkspaceWindow(at: second)

        XCTAssertEqual(shownWorkspace?.path, first.path)
        XCTAssertEqual(openedPaths, [second.path])
    }

    func testRequestsGoToTheWindowShowingTheWorkspaceOrTheClosestOneContainingTheFile() {
        let projects = URL(fileURLWithPath: "/tmp/Monknot/Projects", isDirectory: true)
        let notes = projects.appendingPathComponent("Notes", isDirectory: true)
        let projectsWindow = UUID()
        let notesWindow = UUID()
        let emptyWindow = UUID()
        let windows: [UUID: URL?] = [projectsWindow: projects, notesWindow: notes, emptyWindow: nil]

        func assertClaim(
            _ request: MonknotWorkspaceWindowRequest,
            _ windowID: UUID,
            _ claim: WorkspaceWindowClaim,
            line: UInt = #line
        ) {
            let choice = WorkspaceWindowRequestCenter.claim(for: request, windows: windows)
            XCTAssertEqual(choice?.windowID, windowID, line: line)
            XCTAssertEqual(choice?.claim, claim, line: line)
        }
        func fileRequest(_ url: URL) -> MonknotWorkspaceWindowRequest {
            MonknotWorkspaceWindowRequest(workspaceURL: url.deletingLastPathComponent(), selectedDocumentURL: url)
        }

        // The workspace itself, although another window's workspace contains it.
        assertClaim(MonknotWorkspaceWindowRequest(workspaceURL: notes), notesWindow, .showsWorkspace)
        // A file whose folder is not open goes to the deepest workspace that contains it.
        assertClaim(fileRequest(notes.appendingPathComponent("Daily/todo.md")), notesWindow, .containsDocument)
        assertClaim(fileRequest(projects.appendingPathComponent("plan.md")), projectsWindow, .showsWorkspace)
        // A folder inside an open workspace is a workspace of its own: it takes the empty window.
        assertClaim(
            MonknotWorkspaceWindowRequest(workspaceURL: projects.appendingPathComponent("Archive", isDirectory: true)),
            emptyWindow,
            .empty
        )
        // A sibling folder that shares the name prefix is not inside the workspace.
        assertClaim(fileRequest(URL(fileURLWithPath: "/tmp/Monknot/Projects-old/note.md")), emptyWindow, .empty)
        // No empty window left: a new window.
        XCTAssertNil(WorkspaceWindowRequestCenter.claim(
            for: MonknotWorkspaceWindowRequest(workspaceURL: URL(fileURLWithPath: "/tmp/Monknot/Elsewhere")),
            windows: [projectsWindow: projects]
        ))
    }

    func testAWindowStillOpeningAWorkspaceCountsAsShowingIt() {
        let workspace = URL(fileURLWithPath: "/tmp/Monknot/Notes", isDirectory: true)
        let center = WorkspaceWindowRequestCenter()
        let openingWindow = UUID()
        var taken: [WorkspaceWindowClaim] = []
        var newWindows = 0
        // The window reports the workspace it is opening before the scan finishes.
        center.installReusableWindow(id: openingWindow, workspaceURL: { workspace }) { _, claim in
            taken.append(claim)
        }
        center.installOpenWindowAction { _ in newWindows += 1 }
        center.finishInitialWorkspaceRequestHandling()

        // Two files from one folder opened together in Finder.
        center.openWorkspaceWindow(at: workspace, selecting: workspace.appendingPathComponent("a.md"))
        center.openWorkspaceWindow(at: workspace, selecting: workspace.appendingPathComponent("b.md"))

        XCTAssertEqual(taken, [.showsWorkspace, .showsWorkspace])
        XCTAssertEqual(newWindows, 0)
        XCTAssertTrue(center.isWorkspaceShown(workspace, excludingWindow: UUID()))
        XCTAssertFalse(center.isWorkspaceShown(workspace, excludingWindow: openingWindow))
    }
}
