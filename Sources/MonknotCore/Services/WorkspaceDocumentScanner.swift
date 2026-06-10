import Foundation
import OSLog

public struct WorkspaceDocumentScanResult: Sendable {
    public let root: SidebarNode
    public let documents: [WorkspaceDocument]

    public init(root: SidebarNode, documents: [WorkspaceDocument]) {
        self.root = root
        self.documents = documents
    }
}

public protocol WorkspaceDocumentScanning: Sendable {
    func scan(rootURL: URL) throws -> WorkspaceDocumentScanResult
}

public struct WorkspaceDocumentScanner: WorkspaceDocumentScanning {
    private let ignoredDirectoryNames: Set<String>

    public init(
        ignoredDirectoryNames: Set<String> = [".build", ".git", "DerivedData", "dist", "node_modules"]
    ) {
        self.ignoredDirectoryNames = ignoredDirectoryNames
    }

    public func scan(rootURL: URL) throws -> WorkspaceDocumentScanResult {
        let signpostID = MonknotSignposting.workspaceScan.beginInterval("WorkspaceScan")
        defer { MonknotSignposting.workspaceScan.endInterval("WorkspaceScan", signpostID) }
        try Task.checkCancellation()
        var documents: [WorkspaceDocument] = []
        let rootChildren = try scanDirectory(rootURL, rootURL: rootURL, documents: &documents)
        let rootName = rootURL.lastPathComponent.isEmpty ? rootURL.path : rootURL.lastPathComponent
        let rootNode = SidebarNode(
            id: rootURL.standardizedFileURL.path,
            url: rootURL.standardizedFileURL,
            name: rootName,
            relativePath: "",
            kind: .folder,
            children: rootChildren
        )

        return WorkspaceDocumentScanResult(root: rootNode, documents: documents)
    }

    private func scanDirectory(_ directoryURL: URL, rootURL: URL, documents: inout [WorkspaceDocument]) throws -> [SidebarNode] {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )

        var nodes: [SidebarNode] = []

        for url in contents {
            try Task.checkCancellation()
            let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey, .isSymbolicLinkKey])

            if resourceValues.isDirectory == true, resourceValues.isPackage != true, resourceValues.isSymbolicLink != true {
                guard !ignoredDirectoryNames.contains(url.lastPathComponent) else {
                    continue
                }

                let children = try scanDirectory(url, rootURL: rootURL, documents: &documents)

                nodes.append(SidebarNode(
                    id: url.standardizedFileURL.path,
                    url: url.standardizedFileURL,
                    name: url.lastPathComponent,
                    relativePath: WorkspaceDocumentSupport.relativePath(for: url, in: rootURL),
                    kind: .folder,
                    children: children
                ))
            } else if resourceValues.isRegularFile == true, resourceValues.isSymbolicLink != true {
                guard WorkspaceDocumentSupport.shouldIncludeInWorkspaceScan(url) else { continue }

                let classification = WorkspaceDocumentSupport.classification(for: url)
                guard classification.kind != .unsupported else { continue }

                let document = WorkspaceDocument(url: url, rootURL: rootURL, classification: classification)
                documents.append(document)
                nodes.append(SidebarNode(
                    id: document.id,
                    url: document.url,
                    name: document.displayName,
                    relativePath: document.relativePath,
                    kind: .file,
                    document: document
                ))
            }
        }

        return nodes.sorted { lhs, rhs in
            if lhs.kind != rhs.kind {
                return lhs.kind == .folder
            }

            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
