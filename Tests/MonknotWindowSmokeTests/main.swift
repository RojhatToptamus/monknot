import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct MonknotWindowSmokeTests {
    @MainActor
    static func main() {
        let coordinator = InitialWorkspaceRestorationCoordinator()

        expect(coordinator.claimInitialRestore(), "first window should claim previous workspace restoration")
        expect(!coordinator.claimInitialRestore(), "second window should start empty instead of restoring the saved workspace")
        expect(!coordinator.claimInitialRestore(), "later windows should also start empty")

        let newAppSessionCoordinator = InitialWorkspaceRestorationCoordinator()
        expect(newAppSessionCoordinator.claimInitialRestore(), "a fresh app session should allow one initial restore")

        let requestURL = URL(fileURLWithPath: "/tmp/Monknot/Workspace", isDirectory: true)
        let selectedURL = requestURL.appendingPathComponent("README.md")
        let request = MonknotWorkspaceWindowRequest(workspaceURL: requestURL, selectedDocumentURL: selectedURL)
        expect(request.workspaceURL?.standardizedFileURL.path == requestURL.standardizedFileURL.path, "workspace window requests should preserve the target path")
        expect(request.selectedDocumentURL?.standardizedFileURL.path == selectedURL.standardizedFileURL.path, "workspace window requests should preserve the selected document path")

        let requestCenter = WorkspaceWindowRequestCenter()
        var openedPaths: [String] = []
        requestCenter.openWorkspaceWindow(at: requestURL, selecting: selectedURL)
        expect(openedPaths.isEmpty, "workspace requests should queue until SwiftUI installs openWindow")
        let consumedRequest = requestCenter.consumePendingInitialWorkspaceRequest()
        expect(consumedRequest?.workspaceURL?.standardizedFileURL.path == requestURL.standardizedFileURL.path, "the initial window should be able to consume the first queued workspace request")
        expect(consumedRequest?.selectedDocumentURL?.standardizedFileURL.path == selectedURL.standardizedFileURL.path, "consuming the initial request should preserve the selected document")

        requestCenter.installOpenWindowAction { request in
            openedPaths.append(request.workspaceURL?.standardizedFileURL.path ?? "")
        }
        requestCenter.finishInitialWorkspaceRequestHandling()
        requestCenter.openWorkspaceWindow(at: requestURL)
        expect(openedPaths == [requestURL.standardizedFileURL.path], "installed openWindow should handle later workspace requests immediately")

        let flushingRequestCenter = WorkspaceWindowRequestCenter()
        var flushedPaths: [String] = []
        let secondURL = URL(fileURLWithPath: "/tmp/Monknot/Second", isDirectory: true)
        flushingRequestCenter.openWorkspaceWindow(at: requestURL)
        flushingRequestCenter.openWorkspaceWindow(at: secondURL)
        expect(flushingRequestCenter.consumePendingInitialWorkspaceRequest()?.workspaceURL?.standardizedFileURL.path == requestURL.standardizedFileURL.path, "the initial window should consume only the first queued request")
        flushingRequestCenter.installOpenWindowAction { request in
            flushedPaths.append(request.workspaceURL?.standardizedFileURL.path ?? "")
        }
        flushingRequestCenter.finishInitialWorkspaceRequestHandling()
        expect(flushedPaths == [secondURL.standardizedFileURL.path], "remaining queued requests should flush to new windows after the initial window is handled")

        let lateInstallRequestCenter = WorkspaceWindowRequestCenter()
        var lateInstallPaths: [String] = []
        lateInstallRequestCenter.openWorkspaceWindow(at: requestURL)
        lateInstallRequestCenter.openWorkspaceWindow(at: secondURL)
        _ = lateInstallRequestCenter.consumePendingInitialWorkspaceRequest()
        lateInstallRequestCenter.finishInitialWorkspaceRequestHandling()
        lateInstallRequestCenter.installOpenWindowAction { request in
            lateInstallPaths.append(request.workspaceURL?.standardizedFileURL.path ?? "")
        }
        expect(lateInstallPaths == [secondURL.standardizedFileURL.path], "remaining queued requests should also flush if openWindow installs after initial handling")

        let reusableRequestCenter = WorkspaceWindowRequestCenter()
        var reusedPaths: [String] = []
        var openedAfterReusePaths: [String] = []
        let reusableID = UUID()
        reusableRequestCenter.installReusableWindowHandler(id: reusableID) { request in
            guard reusedPaths.isEmpty else { return false }
            reusedPaths.append(request.workspaceURL?.standardizedFileURL.path ?? "")
            return true
        }
        reusableRequestCenter.installOpenWindowAction { request in
            openedAfterReusePaths.append(request.workspaceURL?.standardizedFileURL.path ?? "")
        }
        reusableRequestCenter.openWorkspaceWindow(at: requestURL)
        reusableRequestCenter.finishInitialWorkspaceRequestHandling()
        expect(reusedPaths == [requestURL.standardizedFileURL.path], "an existing empty window should be able to reuse the first pending workspace request")
        expect(openedAfterReusePaths.isEmpty, "reusing the pending workspace request should not open a second window")
        reusableRequestCenter.openWorkspaceWindow(at: secondURL)
        expect(openedAfterReusePaths == [secondURL.standardizedFileURL.path], "later requests should still open new windows when no reusable window accepts them")

        print("Monknot window smoke tests passed")
    }
}
