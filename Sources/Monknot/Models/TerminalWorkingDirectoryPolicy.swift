import Foundation

enum TerminalWorkingDirectoryPreference: String, CaseIterable {
    static let key = "Monknot.terminalWorkingDirectory"
    static let defaultValue = TerminalWorkingDirectoryPreference.activeDocumentFolder

    case activeDocumentFolder
    case workspaceRoot

    var title: String {
        switch self {
        case .activeDocumentFolder:
            return "Active document folder"
        case .workspaceRoot:
            return "Workspace root"
        }
    }
}

enum TerminalWorkingDirectoryPolicy {
    static func directory(
        preference: TerminalWorkingDirectoryPreference,
        workspaceURL: URL?,
        selectedDocumentURL: URL?
    ) -> URL? {
        guard let workspaceURL else { return nil }
        let standardizedWorkspaceURL = workspaceURL.standardizedFileURL

        guard preference == .activeDocumentFolder,
              let selectedDocumentURL,
              isContained(selectedDocumentURL.standardizedFileURL, in: standardizedWorkspaceURL)
        else {
            return standardizedWorkspaceURL
        }

        return selectedDocumentURL.standardizedFileURL.deletingLastPathComponent()
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        return candidateComponents.count > rootComponents.count
            && Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }
}
