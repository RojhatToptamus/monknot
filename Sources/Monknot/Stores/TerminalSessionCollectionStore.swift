import Foundation
import MonknotCore

@MainActor
final class TerminalSessionCollectionStore: ObservableObject {
    @Published private var tabState = TerminalTabState()
    @Published private var sessionsByID: [String: TerminalSessionStore] = [:]

    var tabs: [TerminalTabItem] {
        tabState.tabs
    }

    var activeTerminalID: String? {
        tabState.selectedTerminalID
    }

    var activeSession: TerminalSessionStore? {
        guard let activeTerminalID else { return nil }
        return sessionsByID[activeTerminalID]
    }

    func session(for terminalID: String) -> TerminalSessionStore? {
        sessionsByID[terminalID]
    }

    func ensureActiveTerminal(in directory: URL?, workspaceRoot: URL? = nil) {
        guard !tabState.isEmpty else {
            createTerminal(in: directory, workspaceRoot: workspaceRoot)
            return
        }

        guard let activeSession else { return }
        activeSession.startIfNeeded()
    }

    @discardableResult
    func createTerminal(in directory: URL?, workspaceRoot: URL? = nil) -> TerminalSessionStore? {
        guard let resolvedDirectory = resolvedDirectory(directory, workspaceRoot: workspaceRoot) else { return nil }
        let tab = tabState.create(workingDirectoryPath: resolvedDirectory.path)
        let session = TerminalSessionStore(initialDirectory: resolvedDirectory)
        sessionsByID[tab.id] = session
        session.startIfNeeded(in: resolvedDirectory)
        objectWillChange.send()
        return session
    }

    func selectTerminal(id terminalID: String) {
        guard tabState.activate(terminalID: terminalID) else {
            return
        }

        objectWillChange.send()
    }

    func killTerminal(id terminalID: String) {
        sessionsByID[terminalID]?.stop()
        sessionsByID[terminalID] = nil
        tabState.remove(terminalID: terminalID)
        objectWillChange.send()
    }

    func restartTerminal(id terminalID: String) {
        sessionsByID[terminalID]?.restart()
    }

    func stopAll() {
        for session in sessionsByID.values {
            session.stop()
        }
        sessionsByID.removeAll()
        tabState.removeAll()
    }

    deinit {
        MainActor.assumeIsolated {
            for session in sessionsByID.values {
                session.stop()
            }
        }
    }

    private func resolvedDirectory(_ url: URL?, workspaceRoot: URL?) -> URL? {
        TerminalSessionStore.resolvedDirectory(url, containedIn: workspaceRoot)
    }
}
