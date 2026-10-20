import Foundation

public enum WorkspaceScanResultPatcher {
    public static func applyingFileChanges(
        to result: WorkspaceDocumentScanResult,
        rootURL: URL,
        changedPaths: Set<String>,
        ignoredDirectoryNames: Set<String> = WorkspaceDocumentScanner.defaultIgnoredDirectoryNames
    ) -> WorkspaceDocumentScanResult? {
        let rootURL = rootURL.standardizedFileURL
        var rootNode = result.root
        var documentsByID = Dictionary(uniqueKeysWithValues: result.documents.map { ($0.id, $0) })

        for path in changedPaths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard WorkspaceDocumentSupport.isURL(url, containedIn: rootURL) else { continue }
            guard url != rootURL else { return nil }

            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: url.path) {
                guard let values = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey, .isSymbolicLinkKey]
                ) else {
                    return nil
                }
                if values.isDirectory == true {
                    let existingNode = rootNode.node(withID: url.path)
                    if values.isPackage == true
                        || shouldSkipDirectory(url, rootURL: rootURL, ignoredDirectoryNames: ignoredDirectoryNames) {
                        if existingNode?.kind == .folder {
                            removeDocuments(containedIn: url, from: &documentsByID)
                            rootNode = removingNode(id: url.path, from: rootNode)
                        }
                        continue
                    }

                    guard let folderNode = try? scanDirectoryNode(
                        url,
                        rootURL: rootURL,
                        documentsByID: &documentsByID,
                        ignoredDirectoryNames: ignoredDirectoryNames
                    ) else {
                        return nil
                    }

                    removeDocuments(containedIn: url, from: &documentsByID)
                    for document in documents(in: folderNode) {
                        documentsByID[document.id] = document
                    }
                    rootNode = removingNode(id: url.path, from: rootNode)
                    rootNode = inserting(folderNode, into: rootNode, rootURL: rootURL)
                    continue
                }
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    documentsByID.removeValue(forKey: url.path)
                    rootNode = removingNode(id: url.path, from: rootNode)
                    continue
                }
                guard !shouldSkipFile(url, rootURL: rootURL, ignoredDirectoryNames: ignoredDirectoryNames) else {
                    documentsByID.removeValue(forKey: url.path)
                    rootNode = removingNode(id: url.path, from: rootNode)
                    continue
                }

                let document = WorkspaceDocument(
                    url: url,
                    rootURL: rootURL,
                    classification: WorkspaceDocumentSupport.classification(for: url)
                )
                documentsByID[document.id] = document
                rootNode = inserting(document, into: rootNode, rootURL: rootURL)
            } else {
                if let existingNode = rootNode.node(withID: url.path), existingNode.kind == .folder {
                    removeDocuments(containedIn: url, from: &documentsByID)
                    rootNode = removingNode(id: url.path, from: rootNode)
                    continue
                }
                documentsByID.removeValue(forKey: url.path)
                rootNode = removingNode(id: url.path, from: rootNode)
            }
        }

        return WorkspaceDocumentScanResult(
            root: rootNode,
            documents: documentsByID.values.sorted { lhs, rhs in
                lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
            }
        )
    }

    private static func inserting(_ insertedNode: SidebarNode, into rootNode: SidebarNode, rootURL: URL) -> SidebarNode {
        let components = insertedNode.relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return rootNode }
        return inserting(insertedNode, components: components, into: rootNode, rootURL: rootURL)
    }

    private static func inserting(
        _ insertedNode: SidebarNode,
        components: [String],
        into node: SidebarNode,
        rootURL: URL
    ) -> SidebarNode {
        guard let first = components.first else { return node }

        if components.count == 1 {
            var children = node.children ?? []
            children.removeAll { $0.id == insertedNode.id }
            children.append(insertedNode)
            return replacingChildren(of: node, with: sorted(children))
        }

        var children = node.children ?? []
        let folderURL = node.url.appendingPathComponent(first, isDirectory: true).standardizedFileURL
        let folderPath = folderURL.path
        let folderIndex = children.firstIndex { $0.id == folderPath && $0.kind == .folder }
        let folderNode = folderIndex.map { children[$0] } ?? SidebarNode(
            id: folderPath,
            url: folderURL,
            name: first,
            relativePath: WorkspaceDocumentSupport.relativePath(for: folderURL, in: rootURL),
            kind: .folder,
            children: []
        )

        let updatedFolder = inserting(
            insertedNode,
            components: Array(components.dropFirst()),
            into: folderNode,
            rootURL: rootURL
        )

        if let folderIndex {
            children[folderIndex] = updatedFolder
        } else {
            children.append(updatedFolder)
        }

        return replacingChildren(of: node, with: sorted(children))
    }

    private static func inserting(_ document: WorkspaceDocument, into rootNode: SidebarNode, rootURL: URL) -> SidebarNode {
        let components = document.relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return rootNode }
        return inserting(document, components: components, into: rootNode, rootURL: rootURL)
    }

    private static func inserting(
        _ document: WorkspaceDocument,
        components: [String],
        into node: SidebarNode,
        rootURL: URL
    ) -> SidebarNode {
        guard let first = components.first else { return node }

        if components.count == 1 {
            let fileNode = SidebarNode(
                id: document.id,
                url: document.url,
                name: document.displayName,
                relativePath: document.relativePath,
                kind: .file,
                document: document
            )
            var children = node.children ?? []
            children.removeAll { $0.id == document.id }
            children.append(fileNode)
            return replacingChildren(of: node, with: sorted(children))
        }

        var children = node.children ?? []
        let folderURL = node.url.appendingPathComponent(first, isDirectory: true).standardizedFileURL
        let folderPath = folderURL.path
        let folderIndex = children.firstIndex { $0.id == folderPath && $0.kind == .folder }
        let folderNode = folderIndex.map { children[$0] } ?? SidebarNode(
            id: folderPath,
            url: folderURL,
            name: first,
            relativePath: WorkspaceDocumentSupport.relativePath(for: folderURL, in: rootURL),
            kind: .folder,
            children: []
        )

        let updatedFolder = inserting(
            document,
            components: Array(components.dropFirst()),
            into: folderNode,
            rootURL: rootURL
        )

        if let folderIndex {
            children[folderIndex] = updatedFolder
        } else {
            children.append(updatedFolder)
        }

        return replacingChildren(of: node, with: sorted(children))
    }

    private static func removingNode(id: String, from node: SidebarNode) -> SidebarNode {
        guard var children = node.children else { return node }
        children.removeAll { $0.id == id }
        children = children.map { child in
            child.kind == .folder ? removingNode(id: id, from: child) : child
        }
        return replacingChildren(of: node, with: sorted(children))
    }

    private static func scanDirectoryNode(
        _ directoryURL: URL,
        rootURL: URL,
        documentsByID: inout [String: WorkspaceDocument],
        ignoredDirectoryNames: Set<String>
    ) throws -> SidebarNode {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )

        var children: [SidebarNode] = []
        for url in contents {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey, .isSymbolicLinkKey])

            if values.isDirectory == true, values.isPackage != true, values.isSymbolicLink != true {
                guard !ignoredDirectoryNames.contains(url.lastPathComponent) else { continue }
                let child = try scanDirectoryNode(
                    url,
                    rootURL: rootURL,
                    documentsByID: &documentsByID,
                    ignoredDirectoryNames: ignoredDirectoryNames
                )
                children.append(child)
            } else if values.isRegularFile == true, values.isSymbolicLink != true {
                let document = WorkspaceDocument(
                    url: url,
                    rootURL: rootURL,
                    classification: WorkspaceDocumentSupport.classification(for: url)
                )
                documentsByID[document.id] = document
                children.append(SidebarNode(
                    id: document.id,
                    url: document.url,
                    name: document.displayName,
                    relativePath: document.relativePath,
                    kind: .file,
                    document: document
                ))
            }
        }

        return SidebarNode(
            id: directoryURL.standardizedFileURL.path,
            url: directoryURL.standardizedFileURL,
            name: directoryURL.lastPathComponent,
            relativePath: WorkspaceDocumentSupport.relativePath(for: directoryURL, in: rootURL),
            kind: .folder,
            children: sorted(children)
        )
    }

    private static func documents(in node: SidebarNode) -> [WorkspaceDocument] {
        var result: [WorkspaceDocument] = []
        if let document = node.document {
            result.append(document)
        }
        for child in node.children ?? [] {
            result.append(contentsOf: documents(in: child))
        }
        return result
    }

    private static func removeDocuments(containedIn directoryURL: URL, from documentsByID: inout [String: WorkspaceDocument]) {
        let directoryPath = directoryURL.standardizedFileURL.path
        documentsByID = documentsByID.filter { id, _ in
            !WorkspaceDocumentSupport.isPath(id, containedIn: directoryPath)
        }
    }

    private static func shouldSkipDirectory(
        _ url: URL,
        rootURL: URL,
        ignoredDirectoryNames: Set<String>
    ) -> Bool {
        guard !ignoredDirectoryNames.contains(url.lastPathComponent) else { return true }
        guard !url.lastPathComponent.hasPrefix(".") else { return true }
        return relativeComponents(for: url, rootURL: rootURL).dropLast().contains { component in
            hidesContents(ofFolderNamed: component, ignoredDirectoryNames: ignoredDirectoryNames)
        }
    }

    private static func shouldSkipFile(
        _ url: URL,
        rootURL: URL,
        ignoredDirectoryNames: Set<String>
    ) -> Bool {
        let components = relativeComponents(for: url, rootURL: rootURL)
        guard let fileName = components.last else { return true }
        guard !fileName.hasPrefix(".") else { return true }
        return components.dropLast().contains { component in
            hidesContents(ofFolderNamed: component, ignoredDirectoryNames: ignoredDirectoryNames)
        }
    }

    /// Whether the scan leaves out everything inside a folder with this name: a hidden or ignored
    /// folder, or a package, which Finder shows as one item.
    private static func hidesContents(ofFolderNamed name: String, ignoredDirectoryNames: Set<String>) -> Bool {
        ignoredDirectoryNames.contains(name) || name.hasPrefix(".") || WorkspaceDocumentSupport.isPackageName(name)
    }

    private static func relativeComponents(for url: URL, rootURL: URL) -> [String] {
        WorkspaceDocumentSupport.relativePath(for: url, in: rootURL)
            .split(separator: "/")
            .map(String.init)
    }

    private static func replacingChildren(of node: SidebarNode, with children: [SidebarNode]) -> SidebarNode {
        SidebarNode(
            id: node.id,
            url: node.url,
            name: node.name,
            relativePath: node.relativePath,
            kind: node.kind,
            document: node.document,
            children: children
        )
    }

    private static func sorted(_ nodes: [SidebarNode]) -> [SidebarNode] {
        nodes.sorted { lhs, rhs in
            if lhs.kind != rhs.kind {
                return lhs.kind == .folder
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
