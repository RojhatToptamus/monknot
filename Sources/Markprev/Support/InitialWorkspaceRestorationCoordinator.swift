import Combine

@MainActor
final class InitialWorkspaceRestorationCoordinator: ObservableObject {
    private var hasClaimedInitialRestore = false

    func claimInitialRestore() -> Bool {
        guard !hasClaimedInitialRestore else { return false }

        hasClaimedInitialRestore = true
        return true
    }
}
