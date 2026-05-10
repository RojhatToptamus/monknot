import Foundation
import MarkprevCore

@MainActor
final class TerminalSessionCollectionStore: ObservableObject {
    @Published private var tabState = TerminalTabState()
    @Published private var sessionsByID: [String: TerminalSessionStore] = [:]

    private var defaultDirectory: URL?

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

    init(initialDirectory: URL? = nil) {
        defaultDirectory = TerminalSessionStore.resolvedDirectory(initialDirectory)
    }

    func session(for terminalID: String) -> TerminalSessionStore? {
        sessionsByID[terminalID]
    }

    func setDefaultDirectory(_ url: URL?) {
        defaultDirectory = TerminalSessionStore.resolvedDirectory(url)
        activeSession?.setDefaultDirectory(defaultDirectory)
    }

    func ensureActiveTerminal(in directory: URL?) {
        guard let resolvedDirectory = resolvedDirectory(directory) else { return }

        guard !tabState.isEmpty else {
            createTerminal(in: resolvedDirectory)
            return
        }

        guard let activeSession else { return }
        activeSession.startIfNeeded(in: resolvedDirectory)
    }

    @discardableResult
    func createTerminal(in directory: URL?) -> TerminalSessionStore? {
        guard let resolvedDirectory = resolvedDirectory(directory) else { return nil }
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

    private func resolvedDirectory(_ url: URL?) -> URL? {
        TerminalSessionStore.resolvedDirectory(url ?? defaultDirectory)
    }
}
