import Foundation

struct MonknotWorkspaceWindowRequest: Codable, Hashable {
    static let windowGroupID = "workspace"

    var id: UUID
    var workspacePath: String?

    init(id: UUID = UUID(), workspaceURL: URL? = nil) {
        self.id = id
        self.workspacePath = workspaceURL?.standardizedFileURL.path
    }

    var workspaceURL: URL? {
        guard let workspacePath else { return nil }
        return URL(fileURLWithPath: workspacePath, isDirectory: true)
    }
}

@MainActor
final class WorkspaceWindowRequestCenter {
    static let shared = WorkspaceWindowRequestCenter()

    private var openWindow: ((MonknotWorkspaceWindowRequest) -> Void)?
    private var pendingRequests: [MonknotWorkspaceWindowRequest] = []

    func installOpenWindowAction(_ action: @escaping (MonknotWorkspaceWindowRequest) -> Void) {
        openWindow = action

        guard !pendingRequests.isEmpty else { return }
        let requests = pendingRequests
        pendingRequests.removeAll()
        requests.forEach(action)
    }

    func openWorkspaceWindow(at url: URL) {
        let request = MonknotWorkspaceWindowRequest(workspaceURL: url)

        if let openWindow {
            openWindow(request)
        } else {
            pendingRequests.append(request)
        }
    }
}
