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

/// How an open window can take a request. Windows that already show the workspace (or contain the
/// requested file) are asked before empty ones, so reopening a workspace or one of its files from
/// Finder brings its window forward instead of opening a second window on the same folder.
enum WorkspaceWindowClaim: CaseIterable {
    case showsWorkspace
    case empty
}

@MainActor
final class WorkspaceWindowRequestCenter {
    static let shared = WorkspaceWindowRequestCenter()

    private var openWindow: ((MonknotWorkspaceWindowRequest) -> Void)?
    private var pendingRequests: [MonknotWorkspaceWindowRequest] = []
    private var reusableWindowHandlers: [UUID: (MonknotWorkspaceWindowRequest, WorkspaceWindowClaim) -> Bool] = [:]
    private var didHandleInitialWorkspaceRequest = false

    func installOpenWindowAction(_ action: @escaping (MonknotWorkspaceWindowRequest) -> Void) {
        openWindow = action
        flushPendingWorkspaceRequestsIfReady()
    }

    func installReusableWindowHandler(
        id: UUID,
        handler: @escaping (MonknotWorkspaceWindowRequest, WorkspaceWindowClaim) -> Bool
    ) {
        reusableWindowHandlers[id] = handler
        flushPendingWorkspaceRequestsIfReady()
    }

    func removeReusableWindowHandler(id: UUID) {
        reusableWindowHandlers[id] = nil
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
        for claim in WorkspaceWindowClaim.allCases {
            for handler in reusableWindowHandlers.values where handler(request, claim) {
                return true
            }
        }

        return false
    }
}
