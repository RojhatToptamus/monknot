import Foundation

public struct MarkdownFileScanResult: Sendable {
    public let root: SidebarNode
    public let files: [MarkdownFile]

    public init(root: SidebarNode, files: [MarkdownFile]) {
        self.root = root
        self.files = files
    }
}

public protocol MarkdownFileScanning: Sendable {
    func scan(rootURL: URL) throws -> MarkdownFileScanResult
}

public struct MarkdownFileScanner: MarkdownFileScanning {
    private let ignoredDirectoryNames: Set<String>

    public init(
        fileManager: FileManager = .default,
        ignoredDirectoryNames: Set<String> = [".build", ".git", "DerivedData", "dist", "node_modules"]
    ) {
        self.ignoredDirectoryNames = ignoredDirectoryNames
    }

    public func scan(rootURL: URL) throws -> MarkdownFileScanResult {
        var files: [MarkdownFile] = []
        let rootChildren = try scanDirectory(rootURL, rootURL: rootURL, files: &files)
        let rootName = rootURL.lastPathComponent.isEmpty ? rootURL.path : rootURL.lastPathComponent
        let rootNode = SidebarNode(
            id: rootURL.standardizedFileURL.path,
            url: rootURL.standardizedFileURL,
            name: rootName,
            relativePath: "",
            kind: .folder,
            children: rootChildren
        )

        return MarkdownFileScanResult(root: rootNode, files: files)
    }

    private func scanDirectory(_ directoryURL: URL, rootURL: URL, files: inout [MarkdownFile]) throws -> [SidebarNode] {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )

        var nodes: [SidebarNode] = []

        for url in contents {
            let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey, .isSymbolicLinkKey])

            if resourceValues.isDirectory == true, resourceValues.isPackage != true, resourceValues.isSymbolicLink != true {
                guard !ignoredDirectoryNames.contains(url.lastPathComponent) else {
                    continue
                }

                let children = try scanDirectory(url, rootURL: rootURL, files: &files)
                guard !children.isEmpty else {
                    continue
                }

                nodes.append(SidebarNode(
                    id: url.standardizedFileURL.path,
                    url: url.standardizedFileURL,
                    name: url.lastPathComponent,
                    relativePath: MarkdownFileSupport.relativePath(for: url, in: rootURL),
                    kind: .folder,
                    children: children
                ))
            } else if resourceValues.isRegularFile == true, MarkdownFileSupport.isMarkdownFile(url) {
                let file = MarkdownFile(url: url, rootURL: rootURL)
                files.append(file)
                nodes.append(SidebarNode(
                    id: file.id,
                    url: file.url,
                    name: file.displayName,
                    relativePath: file.relativePath,
                    kind: .file,
                    file: file
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
