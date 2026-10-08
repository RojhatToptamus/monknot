import Foundation

struct MonknotWorkspaceWindowRequest: Codable, Hashable, Sendable {
    static let windowGroupID = "workspace"

    var id: UUID
    var workspacePath: String?
    var selectedDocumentPath: String?
    var captureMarkdown: String?
    var captureSuggestedName: String?

    init(
        id: UUID = UUID(),
        workspaceURL: URL? = nil,
        selectedDocumentURL: URL? = nil,
        captureItem: WorkspacePasteboardImportItem? = nil
    ) {
        self.id = id
        self.workspacePath = workspaceURL?.standardizedFileURL.path
        self.selectedDocumentPath = selectedDocumentURL?.standardizedFileURL.path
        if case .capturedMarkdown(let markdown, let suggestedName) = captureItem?.payload {
            self.captureMarkdown = markdown
            self.captureSuggestedName = suggestedName
        } else {
            self.captureMarkdown = nil
            self.captureSuggestedName = nil
        }
    }

    var workspaceURL: URL? {
        guard let workspacePath else { return nil }
        return URL(fileURLWithPath: workspacePath, isDirectory: true)
    }

    var selectedDocumentURL: URL? {
        guard let selectedDocumentPath else { return nil }
        return URL(fileURLWithPath: selectedDocumentPath)
    }

    var captureItem: WorkspacePasteboardImportItem? {
        guard let captureMarkdown, let captureSuggestedName else { return nil }
        return .capturedMarkdown(captureMarkdown, suggestedName: captureSuggestedName)
    }
}

/// How an open window takes a request; see `WorkspaceWindowRequestCenter.claim(for:windows:)`.
enum WorkspaceWindowClaim: Equatable {
    /// The window shows, or is opening, the requested workspace.
    case showsWorkspace
    /// The window's workspace contains the requested file.
    case containsDocument
    /// The window has no workspace yet.
    case empty
}

@MainActor
final class WorkspaceWindowRequestCenter {
    static let shared = WorkspaceWindowRequestCenter()

    private struct ReusableWindow {
        /// The workspace the window shows or is opening; nil while it has none.
        let workspaceURL: () -> URL?
        let take: (MonknotWorkspaceWindowRequest, WorkspaceWindowClaim) -> Void
    }

    private var openWindow: ((MonknotWorkspaceWindowRequest) -> Void)?
    private var pendingRequests: [MonknotWorkspaceWindowRequest] = []
    private var reusableWindows: [UUID: ReusableWindow] = [:]
    private var didHandleInitialWorkspaceRequest = false

    func installOpenWindowAction(_ action: @escaping (MonknotWorkspaceWindowRequest) -> Void) {
        openWindow = action
        flushPendingWorkspaceRequestsIfReady()
    }

    func installReusableWindow(
        id: UUID,
        workspaceURL: @escaping () -> URL?,
        take: @escaping (MonknotWorkspaceWindowRequest, WorkspaceWindowClaim) -> Void
    ) {
        reusableWindows[id] = ReusableWindow(workspaceURL: workspaceURL, take: take)
        flushPendingWorkspaceRequestsIfReady()
    }

    func removeReusableWindow(id: UUID) {
        reusableWindows[id] = nil
    }

    /// True when a window other than `windowID` shows or is opening this workspace. Windows starting
    /// at launch ask this before opening one, whichever of them starts first.
    func isWorkspaceShown(_ url: URL, excludingWindow windowID: UUID) -> Bool {
        let path = url.standardizedFileURL.path
        return reusableWindows.contains { id, window in
            id != windowID && window.workspaceURL()?.standardizedFileURL.path == path
        }
    }

    func consumePendingInitialWorkspaceRequest() -> MonknotWorkspaceWindowRequest? {
        guard !pendingRequests.isEmpty else { return nil }
        return pendingRequests.removeFirst()
    }

    func finishInitialWorkspaceRequestHandling() {
        didHandleInitialWorkspaceRequest = true
        flushPendingWorkspaceRequestsIfReady()
    }

    private func flushPendingWorkspaceRequestsIfReady() {
        guard didHandleInitialWorkspaceRequest else { return }

        pendingRequests.removeAll { request in
            openInReusableWindow(request)
        }

        guard let openWindow, !pendingRequests.isEmpty else { return }

        let requests = pendingRequests
        pendingRequests.removeAll()
        requests.forEach(openWindow)
    }

    func openWorkspaceWindow(at url: URL, selecting selectedDocumentURL: URL? = nil) {
        let request = MonknotWorkspaceWindowRequest(workspaceURL: url, selectedDocumentURL: selectedDocumentURL)
        openWorkspaceWindow(request)
    }

    func openWorkspaceWindow(_ request: MonknotWorkspaceWindowRequest) {
        if didHandleInitialWorkspaceRequest, openInReusableWindow(request) {
            return
        }

        if didHandleInitialWorkspaceRequest, let openWindow {
            openWindow(request)
        } else {
            pendingRequests.append(request)
        }
    }

    private func openInReusableWindow(_ request: MonknotWorkspaceWindowRequest) -> Bool {
        let workspaces = reusableWindows.mapValues { $0.workspaceURL() }
        guard let choice = Self.claim(for: request, windows: workspaces) else { return false }
        reusableWindows[choice.windowID]?.take(request, choice.claim)
        return true
    }

    /// The window a request belongs in: the one showing (or opening) its workspace; otherwise the
    /// one whose workspace most closely contains its file; otherwise an empty window. Nil means a new
    /// window. Reopening a workspace or one of its files therefore never opens a second window on it.
    static func claim(
        for request: MonknotWorkspaceWindowRequest,
        windows: [UUID: URL?]
    ) -> (windowID: UUID, claim: WorkspaceWindowClaim)? {
        let workspacePath = request.workspaceURL?.standardizedFileURL.path
        let documentPath = request.selectedDocumentURL?.standardizedFileURL.path
        var closestContainer: (windowID: UUID, rootLength: Int)?
        var emptyWindow: UUID?

        // Sorted so that a choice between equal windows does not depend on dictionary order.
        for (windowID, workspaceURL) in windows.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard let rootPath = workspaceURL?.standardizedFileURL.path else {
                emptyWindow = emptyWindow ?? windowID
                continue
            }
            if rootPath == workspacePath {
                return (windowID, .showsWorkspace)
            }
            let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            if let documentPath,
               documentPath.hasPrefix(rootPrefix),
               rootPath.count > (closestContainer?.rootLength ?? -1) {
                closestContainer = (windowID, rootPath.count)
            }
        }

        if let closestContainer {
            return (closestContainer.windowID, .containsDocument)
        }
        return emptyWindow.map { ($0, .empty) }
    }
}
