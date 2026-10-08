import Combine
import Foundation

@MainActor
final class InitialWorkspaceRestorationCoordinator: ObservableObject {
    private var hasClaimedInitialRestore = false
    private var workspacePathsOpenedAtLaunch = Set<String>()

    func claimInitialRestore() -> Bool {
        guard !hasClaimedInitialRestore else { return false }

        hasClaimedInitialRestore = true
        return true
    }

    /// Records a workspace a window opened at launch (from Finder, the Dock, or a capture), so a
    /// restored window does not open it a second time as the last workspace.
    func noteWorkspaceOpenedAtLaunch(_ url: URL) {
        workspacePathsOpenedAtLaunch.insert(url.standardizedFileURL.path)
    }

    func wasOpenedAtLaunch(_ url: URL) -> Bool {
        workspacePathsOpenedAtLaunch.contains(url.standardizedFileURL.path)
    }
}
