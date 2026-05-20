import Foundation

struct MonknotWorkspaceWindowRequest: Codable, Hashable, Sendable {
    static let windowGroupID = "workspace"

    var id: UUID
    var workspacePath: String?
    var selectedDocumentPath: String?

    init(id: UUID = UUID(), workspaceURL: URL? = nil, selectedDocumentURL: URL? = nil) {
        self.id = id
        self.workspacePath = workspaceURL?.standardizedFileURL.path
        self.selectedDocumentPath = selectedDocumentURL?.standardizedFileURL.path
    }

    var workspaceURL: URL? {
        guard let workspacePath else { return nil }
        return URL(fileURLWithPath: workspacePath, isDirectory: true)
    }

    var selectedDocumentURL: URL? {
        guard let selectedDocumentPath else { return nil }
        return URL(fileURLWithPath: selectedDocumentPath)
    }
}

@MainActor
final class WorkspaceWindowRequestCenter {
    static let shared = WorkspaceWindowRequestCenter()

    private var openWindow: ((MonknotWorkspaceWindowRequest) -> Void)?
    private var pendingRequests: [MonknotWorkspaceWindowRequest] = []
    private var reusableWindowHandlers: [UUID: (MonknotWorkspaceWindowRequest) -> Bool] = [:]
    private var didHandleInitialWorkspaceRequest = false

    func installOpenWindowAction(_ action: @escaping (MonknotWorkspaceWindowRequest) -> Void) {
        openWindow = action
        flushPendingWorkspaceRequestsIfReady()
    }

    func installReusableWindowHandler(
        id: UUID,
        handler: @escaping (MonknotWorkspaceWindowRequest) -> Bool
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
        for handler in reusableWindowHandlers.values where handler(request) {
            return true
        }

        return false
    }
}
