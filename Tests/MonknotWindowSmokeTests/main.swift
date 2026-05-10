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
        let request = MonknotWorkspaceWindowRequest(workspaceURL: requestURL)
        expect(request.workspaceURL?.standardizedFileURL.path == requestURL.standardizedFileURL.path, "workspace window requests should preserve the target path")

        let requestCenter = WorkspaceWindowRequestCenter()
        var openedPaths: [String] = []
        requestCenter.openWorkspaceWindow(at: requestURL)
        expect(openedPaths.isEmpty, "workspace requests should queue until SwiftUI installs openWindow")
        requestCenter.installOpenWindowAction { request in
            openedPaths.append(request.workspaceURL?.standardizedFileURL.path ?? "")
        }
        expect(openedPaths == [requestURL.standardizedFileURL.path], "installing openWindow should flush queued workspace requests once")

        print("Monknot window smoke tests passed")
    }
}
