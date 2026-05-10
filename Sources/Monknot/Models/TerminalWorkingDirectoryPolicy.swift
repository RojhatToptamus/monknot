import Foundation

enum TerminalWorkingDirectoryPolicy {
    static func directory(workspaceURL: URL?, selectedDocumentURL: URL?) -> URL? {
        if let workspaceURL {
            return workspaceURL
        }

        return selectedDocumentURL?.deletingLastPathComponent()
    }
}
