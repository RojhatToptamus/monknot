import AppKit
import MonknotCore
import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var workspaceSearch: WorkspaceSearchState
    let theme: AppTheme
    let zoomScale: Double
    let openFolder: () -> Void
    let openRecentWorkspace: (URL) -> Void
    let newMarkdown: () -> Void
    let exportPDF: (WorkspaceDocument) -> Void
    let openDocument: (String) -> Void
    let openWorkspaceSearchResult: (WorkspaceSearchResult) -> Void
    let copyRelativePath: (URL) -> Void
    @State private var isDropTargeted = false
    @State private var expandedFolderIDs: Set<String> = []
    @State private var sidebarPrompt: SidebarNamePrompt?
    @State private var sidebarTreeFrame: CGRect = .zero
    @State private var sidebarNodeFrames: [String: CGRect] = [:]
    @State private var draggedSidebarNodeID: String?
    @State private var moveDropTargetFolderID: String?
    @State private var isMoveDropTargetingRoot = false
    @State private var recentDocuments: [RecentDocumentEntry] = []
    @State private var visibleNodes: [VisibleSidebarNode] = []

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    private var markdownLinkMoveReviewBinding: Binding<MarkdownLinkMoveReviewState?> {
        Binding(
            get: { store.pendingMarkdownLinkMoveReview },
            set: { review in
                guard review == nil, let current = store.pendingMarkdownLinkMoveReview else { return }
                store.cancelMarkdownLinkMoveReview(id: current.id)
            }
        )
    }

    private var displayedVisibleNodes: [VisibleSidebarNode] {
        guard visibleNodes.isEmpty,
              let rootChildren = store.rootNode?.children,
              !rootChildren.isEmpty
        else {
            return visibleNodes
        }

        return SidebarTreePresentation.visibleNodes(
            from: rootChildren,
            expandedFolderIDs: expandedFolderIDs
        )
    }

    private var tracksSidebarMoveFrames: Bool {
        draggedSidebarNodeID != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if !workspaceSearch.isPresented {
                    SidebarProjectHeader(
                        workspaceURL: store.workspaceURL,
                        canCreateMarkdown: store.workspaceURL != nil && !store.isBusy,
                        canSearch: store.workspaceURL != nil,
                        theme: theme,
                        zoomScale: zoomScale,
                        createMarkdown: newMarkdown,
                        showWorkspaceSearch: {
                            presentWorkspaceSearch()
                        }
                    )
                }

                sidebarMainContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .layoutPriority(1)

            Rectangle()
                .fill(theme.separatorColor)
                .frame(height: 1)

            SidebarSettingsButton(theme: theme, zoomScale: zoomScale)
                .layoutPriority(2)
        }
        .background {
            MonknotChromeSurfaceBackground(theme: theme, surface: theme.sidebarSurfaceColor)
        }
        .overlay {
            if isMoveDropTargetingRoot {
                RoundedRectangle(cornerRadius: theme.chromeRadius(12, zoomScale: zoomScale))
                    .stroke(theme.accentColor.opacity(0.85), lineWidth: 2)
                    .padding(8)
            } else if isDropTargeted {
                RoundedRectangle(cornerRadius: theme.chromeRadius(12, zoomScale: zoomScale))
                    .stroke(theme.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .padding(8)
            }
        }
        .onChange(of: store.rootNode?.id ?? "") {
            expandedFolderIDs = initialExpandedFolderIDs()
            refreshVisibleNodes()
        }
        .onChange(of: store.selectedDocumentID ?? "") {
            expandAncestorsForSelectedDocument()
        }
        .onChange(of: store.documents) { _, _ in
            refreshVisibleNodes()
        }
        .onChange(of: store.recentDocumentChangeSerial) { _, _ in
            refreshRecentDocuments()
        }
        .onChange(of: store.workspaceURL?.standardizedFileURL.path ?? "") { _, _ in
            refreshRecentDocuments()
        }
        .onAppear {
            expandedFolderIDs = initialExpandedFolderIDs()
            refreshVisibleNodes()
            refreshRecentDocuments()
        }
        .background {
            FileURLDropTarget(isTargeted: $isDropTargeted) { urls in
                handleDroppedURLs(urls)
            }
        }
        .sheet(item: $sidebarPrompt) { prompt in
            SidebarNameInputSheet(
                theme: theme,
                zoomScale: zoomScale,
                title: prompt.title,
                message: prompt.message,
                placeholder: prompt.placeholder,
                confirmTitle: prompt.confirmTitle,
                initialName: prompt.name,
                cancel: {
                    sidebarPrompt = nil
                },
                submit: { newName in
                    submitPrompt(prompt, name: newName)
                    sidebarPrompt = nil
                }
            )
        }
        .sheet(item: markdownLinkMoveReviewBinding) { review in
            MarkdownLinkMoveReviewSheet(
                review: review,
                theme: theme,
                zoomScale: zoomScale,
                cancel: {
                    store.cancelMarkdownLinkMoveReview(id: review.id)
                },
                confirm: {
                    store.confirmMarkdownLinkMoveReview(id: review.id)
                }
            )
        }
    }

    @ViewBuilder
    private var sidebarMainContent: some View {
        if workspaceSearch.isPresented {
            WorkspaceSearchView(
                state: workspaceSearch,
                documents: store.documents,
                dirtyTextByDocumentID: store.dirtyTextByDocumentID,
                dirtyPDFDataByDocumentID: store.dirtyPDFDataByDocumentID,
                theme: theme,
                zoomScale: zoomScale,
                close: { workspaceSearch.dismiss() },
                openResult: openWorkspaceSearchResult,
                replaceAll: {
                    workspaceSearch.clearReplaceStatus()
                    store.replaceInWorkspace(
                        find: workspaceSearch.query,
                        replacement: workspaceSearch.replaceText,
                        scope: workspaceSearch.replaceScope,
                        searchResultDocumentIDs: workspaceSearch.replaceScopeDocumentIDs
                    )
                },
                makeReplacePreview: makeWorkspaceReplacePreview,
                copyResults: copyWorkspaceSearchResults,
                canConfigureReplace: !workspaceSearch.isSearching && canReplaceInWorkspace,
                canReviewReplace: !workspaceSearch.isSearching
                    && canReplaceInWorkspace
                    && workspaceSearch.canReplaceInCurrentScope
            )
            .onChange(of: store.workspaceReplaceSummary) { _, summary in
                workspaceSearch.setReplaceStatusMessage(summary)
                if summary != nil {
                    refreshWorkspaceSearch()
                }
            }
        } else {
            let nodes = displayedVisibleNodes

            if !nodes.isEmpty {
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        SidebarScrollContainer {
                            LazyVStack(alignment: .leading, spacing: scaled(1)) {
                                ForEach(nodes) { visibleNode in
                                    SidebarNodeRow(
                                        visibleNode: visibleNode,
                                        selectedDocumentID: store.selectedDocumentID,
                                        saveState: visibleNode.node.document.map { store.saveState(for: $0.id) } ?? .clean,
                                        gitStatus: visibleNode.node.document.flatMap { document in
                                            store.gitStatusByRelativePath[document.relativePath]
                                        },
                                        isExpanded: visibleNode.isExpanded(in: expandedFolderIDs),
                                        tracksMoveFrame: tracksSidebarMoveFrames,
                                        theme: theme,
                                        zoomScale: zoomScale,
                                        toggleFolder: toggleFolder(_:),
                                        selectDocument: openDocument,
                                        createFileInFolder: beginCreateFile(in:),
                                        createFolderInFolder: beginCreateFolder(in:),
                                        copyFolderPath: copyPath(_:),
                                        copyFolderRelativePath: copyRelativePath,
                                        revealFolderInFinder: revealInFinder(_:),
                                        renameFolder: beginRenameFolder(_:),
                                        isMoveSource: draggedSidebarNodeID == visibleNode.id,
                                        isMoveTarget: moveDropTargetFolderID == visibleNode.dropTargetFolderID,
                                        dragChanged: handleSidebarNodeDragChanged(id:location:),
                                        dragEnded: handleSidebarNodeDragEnded(id:location:),
                                        renameDocument: beginRename(_:),
                                        copyPath: copyPath(_:),
                                        copyRelativePath: { copyRelativePath($0.url) },
                                        revealInFinder: revealInFinder(_:),
                                        exportPDF: exportPDF,
                                        copyDocument: copyDocument(_:),
                                        cutDocument: cutDocument(_:),
                                        deleteDocument: store.deleteDocument(_:)
                                    )
                                }
                            }
                            .padding(.horizontal, scaled(8))
                            .padding(.vertical, scaled(6))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .layoutPriority(1)
                        .coordinateSpace(name: SidebarMoveCoordinateSpace.name)
                        .background {
                            if tracksSidebarMoveFrames {
                                SidebarTreeFrameReader()
                            }
                        }
                        .onPreferenceChange(SidebarTreeFramePreferenceKey.self) { frame in
                            sidebarTreeFrame = frame
                        }
                        .onPreferenceChange(SidebarNodeFramePreferenceKey.self) { frames in
                            sidebarNodeFrames = frames
                        }

                        if !recentDocuments.isEmpty {
                            SidebarRecentDocumentsSection(
                                entries: recentDocuments,
                                selectedDocumentID: store.selectedDocumentID,
                                theme: theme,
                                zoomScale: zoomScale,
                                availableSidebarHeight: geometry.size.height,
                                openDocument: openDocument
                            )
                            .layoutPriority(2)
                        }
                    }
                }
                .contextMenu {
                    sidebarContextMenu
                }
            } else {
                EmptySidebarView(
                    theme: theme,
                    zoomScale: zoomScale,
                    workspaceURL: store.workspaceURL,
                    hasWorkspace: store.workspaceURL != nil,
                    isLoadingWorkspace: store.isWorkspaceOpening,
                    openRecentWorkspace: openRecentWorkspace
                )
                    .contextMenu {
                        sidebarContextMenu
                    }
            }
        }
    }

    private func presentWorkspaceSearch() {
        workspaceSearch.present(
            documents: store.documents,
            dirtyTextByDocumentID: store.dirtyTextByDocumentID,
            dirtyPDFDataByDocumentID: store.dirtyPDFDataByDocumentID
        )
    }

    private func refreshWorkspaceSearch() {
        workspaceSearch.refresh(
            documents: store.documents,
            dirtyTextByDocumentID: store.dirtyTextByDocumentID,
            dirtyPDFDataByDocumentID: store.dirtyPDFDataByDocumentID
        )
    }

    private func refreshVisibleNodes() {
        visibleNodes = SidebarTreePresentation.visibleNodes(
            from: store.rootNode?.children ?? [],
            expandedFolderIDs: expandedFolderIDs
        )
    }

    private func initialExpandedFolderIDs() -> Set<String> {
        ancestorFolderIDs(for: store.selectedDocumentID ?? store.documents.first?.id)
    }

    private func ancestorFolderIDs(for fileID: String?) -> Set<String> {
        guard let fileID,
              let document = store.document(id: fileID),
              let workspaceURL = store.workspaceURL
        else { return [] }

        var ancestorIDs: Set<String> = []
        var folderURL = workspaceURL.standardizedFileURL
        let folderComponents = document.relativePath.split(separator: "/").dropLast()

        for component in folderComponents {
            folderURL.appendPathComponent(String(component), isDirectory: true)
            ancestorIDs.insert(folderURL.standardizedFileURL.path)
        }

        return ancestorIDs
    }

    private func expandAncestorsForSelectedDocument() {
        let nextExpandedFolderIDs = expandedFolderIDs.union(ancestorFolderIDs(for: store.selectedDocumentID))
        guard nextExpandedFolderIDs != expandedFolderIDs else { return }

        expandedFolderIDs = nextExpandedFolderIDs
        refreshVisibleNodes()
    }

    private func toggleFolder(_ visibleNode: VisibleSidebarNode) {
        let folderIDs = Set(visibleNode.folderNodeIDs)
        if folderIDs.allSatisfy(expandedFolderIDs.contains) {
            expandedFolderIDs.subtract(folderIDs)
        } else {
            expandedFolderIDs.formUnion(folderIDs)
        }
        refreshVisibleNodes()
    }

    private func refreshRecentDocuments() {
        recentDocuments = store.recentDocuments()
    }

    private var canReplaceInWorkspace: Bool {
        store.workspaceURL != nil
            && !store.isBusy
            && !workspaceSearch.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func makeWorkspaceReplacePreview() -> WorkspaceReplacePreview? {
        let needle = workspaceSearch.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }

        let skipDocumentIDs = Set(store.documentSaveStates.filter { !$0.value.isClean }.map(\.key))
        let limitToDocumentIDs = workspaceSearch.replaceScope == .entireWorkspace
            ? nil
            : workspaceSearch.replaceScopeDocumentIDs

        return try? WorkspaceReplaceService().preview(
            find: needle,
            replacement: workspaceSearch.replaceText,
            documents: store.documents,
            skipDocumentIDs: skipDocumentIDs,
            limitToDocumentIDs: limitToDocumentIDs
        )
    }

    private func copyWorkspaceSearchResults() {
        let text = WorkspaceSearchResultExporter.tabSeparatedText(
            results: workspaceSearch.results,
            query: workspaceSearch.query
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func handleDroppedURLs(_ urls: [URL]) {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return }

        guard store.workspaceURL != nil else {
            fileURLs.forEach { store.handleDroppedURL($0) }
            return
        }

        store.importPasteboardItems(fileURLs.map(WorkspacePasteboardImportItem.fileURL))
    }

    @ViewBuilder
    private var sidebarContextMenu: some View {
        Button {
            beginCreateFile(in: nil)
        } label: {
            Label("New File", systemImage: MonknotWorkspaceIcons.newFile)
        }
        .disabled(store.workspaceURL == nil || store.isBusy)

        Button {
            beginCreateFolder(in: nil)
        } label: {
            Label("New Folder", systemImage: MonknotWorkspaceIcons.newFolder)
        }
        .disabled(store.workspaceURL == nil || store.isBusy)

        if store.canPasteDocumentTransfer {
            Divider()

            Button {
                store.pasteDocumentTransfer()
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
        }

        if let workspaceURL = store.workspaceURL {
            Divider()

            Button {
                copyPath(workspaceURL)
            } label: {
                Label("Copy Path", systemImage: MonknotWorkspaceIcons.copyPath)
            }

            Button {
                revealInFinder(workspaceURL)
            } label: {
                Label("Reveal in Finder", systemImage: MonknotWorkspaceIcons.revealInFinder)
            }
        }
    }

    private func beginRename(_ document: WorkspaceDocument) {
        sidebarPrompt = SidebarNamePrompt(
            operation: .renameDocument(document.id),
            title: "Rename",
            message: "Enter a new file name.",
            placeholder: "File name",
            confirmTitle: "Rename",
            name: document.displayName
        )
    }

    private func beginRenameFolder(_ node: SidebarNode) {
        sidebarPrompt = SidebarNamePrompt(
            operation: .renameFolder(node.id),
            title: "Rename Folder",
            message: "Enter a new folder name.",
            placeholder: "Folder name",
            confirmTitle: "Rename",
            name: node.name
        )
    }

    private func handleSidebarNodeDragChanged(id: String, location: CGPoint) {
        guard store.workspaceURL != nil, !store.isBusy else { return }
        draggedSidebarNodeID = id
        guard sidebarNodeFrames[id] != nil else { return }
        updateMoveDropTarget(at: location, excluding: id)
    }

    private func handleSidebarNodeDragEnded(id: String, location: CGPoint) {
        defer {
            draggedSidebarNodeID = nil
            moveDropTargetFolderID = nil
            isMoveDropTargetingRoot = false
            sidebarTreeFrame = .zero
            sidebarNodeFrames = [:]
        }

        guard store.workspaceURL != nil, !store.isBusy, sidebarNodeFrames[id] != nil else { return }

        if let folderID = folderID(at: location, excluding: id),
           let folderURL = displayedVisibleNodes.first(where: { $0.dropTargetFolderID == folderID })?.dropTargetNode.url {
            store.moveItem(id: id, toDirectory: folderURL)
            return
        }

        guard isRootMoveTarget(at: location) else {
            return
        }

        store.moveItem(id: id, toDirectory: nil)
    }

    private func updateMoveDropTarget(at location: CGPoint, excluding draggedID: String) {
        let folderID = folderID(at: location, excluding: draggedID)
        moveDropTargetFolderID = folderID
        isMoveDropTargetingRoot = folderID == nil && isRootMoveTarget(at: location)
    }

    private func isRootMoveTarget(at location: CGPoint) -> Bool {
        let horizontalTarget: CGRect
        if sidebarTreeFrame.width > 0 {
            horizontalTarget = sidebarTreeFrame.insetBy(dx: -8, dy: 0)
        } else {
            guard let minX = sidebarNodeFrames.values.map(\.minX).min(),
                  let maxX = sidebarNodeFrames.values.map(\.maxX).max() else {
                return false
            }
            horizontalTarget = CGRect(x: minX - 8, y: 0, width: maxX - minX + 16, height: 1)
        }

        return location.x >= horizontalTarget.minX && location.x <= horizontalTarget.maxX
    }

    private func folderID(at location: CGPoint, excluding draggedID: String) -> String? {
        displayedVisibleNodes
            .filter { visibleNode in
                visibleNode.id != draggedID &&
                    visibleNode.node.kind == .folder &&
                    sidebarNodeFrames[visibleNode.id]?.contains(location) == true
            }
            .max { lhs, rhs in lhs.depth < rhs.depth }?
            .dropTargetFolderID
    }

    private func beginCreateFile(in directoryURL: URL?) {
        let directoryName = directoryURL?.lastPathComponent ?? "workspace root"
        sidebarPrompt = SidebarNamePrompt(
            operation: .createFile(directoryURL),
            title: "New File",
            message: "Create a file in \(directoryName).",
            placeholder: "example.txt",
            confirmTitle: "Create",
            name: store.suggestedNewFileName(in: directoryURL)
        )
    }

    private func beginCreateFolder(in directoryURL: URL?) {
        let directoryName = directoryURL?.lastPathComponent ?? "workspace root"
        sidebarPrompt = SidebarNamePrompt(
            operation: .createFolder(directoryURL),
            title: "New Folder",
            message: "Create a folder in \(directoryName).",
            placeholder: "Folder name",
            confirmTitle: "Create",
            name: store.suggestedNewFolderName(in: directoryURL)
        )
    }

    private func copyPath(_ document: WorkspaceDocument) {
        copyPath(document.url)
    }

    private func copyPath(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
    }

    private func revealInFinder(_ document: WorkspaceDocument) {
        revealInFinder(document.url)
    }

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copyDocument(_ document: WorkspaceDocument) {
        do {
            try WorkspacePasteboardExportService.copyFile(at: document.url)
            store.copyDocument(document)
        } catch {
            store.errorMessage = "Could not copy \(document.displayName): \(error.localizedDescription)"
        }
    }

    private func cutDocument(_ document: WorkspaceDocument) {
        WorkspacePasteboardExportService.clearFileTransferPasteboard()
        store.cutDocument(document)
    }

    private func submitPrompt(_ prompt: SidebarNamePrompt, name: String) {
        switch prompt.operation {
        case .renameDocument(let documentID):
            store.renameDocument(id: documentID, to: name)
        case .renameFolder(let folderID):
            store.renameFolder(id: folderID, to: name)
        case .createFile(let directoryURL):
            store.createFile(named: name, in: directoryURL)
        case .createFolder(let directoryURL):
            store.createFolder(named: name, in: directoryURL)
        }
    }
}

// MARK: - Supporting Types

private struct SidebarNamePrompt: Identifiable {
    enum Operation {
        case renameDocument(String)
        case renameFolder(String)
        case createFile(URL?)
        case createFolder(URL?)
    }

    let id = UUID()
    let operation: Operation
    let title: String
    let message: String
    let placeholder: String
    let confirmTitle: String
    var name: String
}

struct VisibleSidebarNode: Identifiable {
    let node: SidebarNode
    let depth: Int
    let folderNodes: [SidebarNode]

    var id: String { node.id }

    var folderNodeIDs: [String] {
        folderNodes.map(\.id)
    }

    var dropTargetNode: SidebarNode {
        folderNodes.last ?? node
    }

    var dropTargetFolderID: String {
        dropTargetNode.id
    }

    var displayName: String {
        guard folderNodes.count > 1 else { return node.name }
        return folderNodes.map(\.name).joined(separator: "/")
    }

    var displayRelativePath: String {
        dropTargetNode.relativePath.isEmpty ? displayName : dropTargetNode.relativePath
    }

    func isExpanded(in expandedFolderIDs: Set<String>) -> Bool {
        !folderNodeIDs.isEmpty && folderNodeIDs.allSatisfy(expandedFolderIDs.contains)
    }
}

enum SidebarTreePresentation {
    static func visibleNodes(
        from nodes: [SidebarNode],
        expandedFolderIDs: Set<String>
    ) -> [VisibleSidebarNode] {
        var result: [VisibleSidebarNode] = []

        func walk(_ nodes: [SidebarNode], depth: Int) {
            for node in nodes {
                guard node.kind == .folder else {
                    result.append(VisibleSidebarNode(node: node, depth: depth, folderNodes: []))
                    continue
                }

                let folderNodes = compactFolderChain(startingAt: node)
                let visibleNode = VisibleSidebarNode(
                    node: node,
                    depth: depth,
                    folderNodes: folderNodes
                )
                result.append(visibleNode)

                if visibleNode.isExpanded(in: expandedFolderIDs),
                   let children = visibleNode.dropTargetNode.children {
                    walk(children, depth: depth + 1)
                }
            }
        }

        walk(nodes, depth: 0)
        return result
    }

    private static func compactFolderChain(startingAt node: SidebarNode) -> [SidebarNode] {
        var chain = [node]
        var current = node

        while let children = current.children,
              children.count == 1,
              let child = children.first,
              child.kind == .folder {
            chain.append(child)
            current = child
        }

        return chain
    }
}

private enum SidebarMoveCoordinateSpace {
    static let name = "Monknot.SidebarMoveCoordinateSpace"
}

private struct SidebarTreeFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct SidebarTreeFrameReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: SidebarTreeFramePreferenceKey.self,
                value: proxy.frame(in: .named(SidebarMoveCoordinateSpace.name))
            )
        }
    }
}

private struct SidebarNodeFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

private struct SidebarNodeFrameReader: View {
    let id: String

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: SidebarNodeFramePreferenceKey.self, value: [
                id: proxy.frame(in: .named(SidebarMoveCoordinateSpace.name))
            ])
        }
    }
}

// MARK: - Sidebar Header

/// Workspace identity and its contextual search action.
private struct SidebarProjectHeader: View {
    let workspaceURL: URL?
    let canCreateMarkdown: Bool
    let canSearch: Bool
    let theme: AppTheme
    let zoomScale: Double
    let createMarkdown: () -> Void
    let showWorkspaceSearch: () -> Void

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    private func textScaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceText(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        HStack(spacing: scaled(6)) {
            HStack(spacing: scaled(3)) {
                Text(workspaceURL?.lastPathComponent ?? "Monknot")
                    .font(.system(size: textScaled(13), weight: .semibold))
                    .foregroundStyle(theme.sidebarColor(theme.foregroundColor, opacity: 0.92))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Image(systemName: "chevron.down")
                    .font(.system(size: textScaled(8), weight: .medium))
                    .foregroundStyle(theme.tertiaryForegroundColor)
            }
            .help(workspaceURL?.path ?? "No workspace open")

            Spacer(minLength: scaled(4))

            MonknotIconButton(
                systemImage: "plus",
                label: "New Markdown",
                theme: theme,
                zoomScale: zoomScale,
                isDisabled: !canCreateMarkdown,
                size: .sidebarHeader,
                action: createMarkdown
            )

            MonknotIconButton(
                systemImage: MonknotWorkspaceIcons.searchWorkspace,
                label: "Search Workspace",
                theme: theme,
                zoomScale: zoomScale,
                isDisabled: !canSearch,
                size: .sidebarHeader,
                action: showWorkspaceSearch
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, scaled(10))
        .frame(height: scaled(40))
    }
}

// MARK: - Sidebar Row

private struct SidebarNodeRow: View {
    let visibleNode: VisibleSidebarNode
    let selectedDocumentID: String?
    let saveState: DocumentSaveState
    let gitStatus: WorkspaceGitFileStatus?
    let isExpanded: Bool
    let tracksMoveFrame: Bool
    let theme: AppTheme
    let zoomScale: Double
    let toggleFolder: (VisibleSidebarNode) -> Void
    let selectDocument: (String) -> Void
    let createFileInFolder: (URL) -> Void
    let createFolderInFolder: (URL) -> Void
    let copyFolderPath: (URL) -> Void
    let copyFolderRelativePath: (URL) -> Void
    let revealFolderInFinder: (URL) -> Void
    let renameFolder: (SidebarNode) -> Void
    let isMoveSource: Bool
    let isMoveTarget: Bool
    let dragChanged: (String, CGPoint) -> Void
    let dragEnded: (String, CGPoint) -> Void
    let renameDocument: (WorkspaceDocument) -> Void
    let copyPath: (WorkspaceDocument) -> Void
    let copyRelativePath: (WorkspaceDocument) -> Void
    let revealInFinder: (WorkspaceDocument) -> Void
    let exportPDF: (WorkspaceDocument) -> Void
    let copyDocument: (WorkspaceDocument) -> Void
    let cutDocument: (WorkspaceDocument) -> Void
    let deleteDocument: (WorkspaceDocument) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var node: SidebarNode {
        visibleNode.node
    }

    private var isSelected: Bool {
        node.document?.id == selectedDocumentID
    }

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    private func textScaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceText(base, theme: theme, zoomScale: zoomScale)
    }

    private func glyphScaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceGlyph(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        if node.kind == .folder {
            folderRow
        } else {
            fileRow
        }
    }

    /// Folder row with a disclosure chevron.
    private var folderRow: some View {
        Button {
            withAnimation(MonknotMotion.outlineAnimation(reduceMotion: reduceMotion)) {
                toggleFolder(visibleNode)
            }
        } label: {
            HStack(spacing: scaled(8)) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: glyphScaled(10), weight: .semibold))
                    .foregroundStyle(theme.sidebarMutedColor())
                    .frame(width: glyphScaled(12))
                    .accessibilityHidden(true)

                Image(systemName: "folder")
                    .font(.system(
                        size: glyphScaled(MonknotMetrics.sidebarIconPointSizeBase),
                        weight: MonknotMetrics.sidebarIconWeight
                    ))
                    .foregroundStyle(theme.sidebarMutedColor(prominence: 0.72))
                    .accessibilityHidden(true)

                Text(visibleNode.displayName)
                    .font(.system(size: textScaled(13), weight: .regular))
                    .foregroundStyle(theme.sidebarColor(theme.foregroundColor, opacity: 0.88))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(visibleNode.depth) * scaled(16))
            .padding(.horizontal, scaled(5))
            .frame(height: scaled(30))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sidebarHoverRow(theme: theme, isSelected: false, cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
        .background {
            if tracksMoveFrame {
                SidebarNodeFrameReader(id: node.id)
            }
        }
        .overlay {
            if isMoveTarget {
                RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
                    .stroke(theme.accentColor.opacity(0.85), lineWidth: 1)
            }
        }
        .opacity(isMoveSource ? 0.45 : 1)
        .simultaneousGesture(sidebarMoveGesture)
        .help(visibleNode.displayRelativePath)
        .accessibilityLabel(folderAccessibilityLabel)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .contextMenu {
            folderContextMenu()
        }
    }

    private var folderAccessibilityLabel: String {
        if visibleNode.folderNodes.count > 1 {
            return "\(visibleNode.displayName), compact folder path"
        }
        return "\(node.name), folder"
    }

    /// File row — larger text, generous padding, Monknot-style selection highlight.
    private var fileRow: some View {
        Button {
            if let document = node.document {
                selectDocument(document.id)
            }
        } label: {
            HStack(spacing: scaled(7)) {
                Image(systemName: documentIconName)
                    .font(.system(
                        size: glyphScaled(MonknotMetrics.sidebarIconPointSizeBase),
                        weight: MonknotMetrics.sidebarIconWeight
                    ))
                    .foregroundStyle(
                        isSelected
                            ? theme.sidebarColor(theme.accentColor, opacity: 0.95)
                            : theme.sidebarMutedColor(prominence: 0.7)
                    )
                    .frame(width: glyphScaled(MonknotMetrics.sidebarIconPointSizeBase))
                    .accessibilityHidden(true)

                Text(node.name)
                    .font(.system(size: textScaled(13), weight: .regular))
                    .foregroundStyle(theme.sidebarColor(theme.foregroundColor, opacity: isSelected ? 0.98 : 0.88))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let gitStatus {
                    GitStatusBadge(status: gitStatus, theme: theme, zoomScale: zoomScale)
                }

                if !saveState.isClean {
                    SaveStateIndicator(
                        state: saveState,
                        theme: theme,
                        zoomScale: zoomScale,
                        size: glyphScaled(12)
                    )
                }
            }
            .padding(.leading, CGFloat(visibleNode.depth) * scaled(16) + scaled(8))
            .padding(.trailing, scaled(10))
            .frame(height: scaled(30))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sidebarHoverRow(theme: theme, isSelected: isSelected, cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
        .background {
            if tracksMoveFrame {
                SidebarNodeFrameReader(id: node.id)
            }
        }
        .opacity(isMoveSource ? 0.45 : 1)
        .simultaneousGesture(sidebarMoveGesture)
        .monknotHelp(isSelected ? nil : (node.relativePath.isEmpty ? node.name : node.relativePath))
        .accessibilityLabel(fileAccessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            if let document = node.document {
                documentContextMenu(for: document)
            }
        }
    }

    private var fileAccessibilityLabel: String {
        var parts = [node.name, "file"]
        if isSelected {
            parts.append("selected")
        }
        if !saveState.isClean {
            parts.append(saveState.accessibilityDescription)
        }
        if let gitStatus {
            parts.append(gitStatus.accessibilityDescription)
        }
        return parts.joined(separator: ", ")
    }

    private var documentIconName: String {
        node.document?.kind.resolvedSystemImage ?? WorkspaceDocumentKind.unsupported.resolvedSystemImage
    }

    @ViewBuilder
    private func folderContextMenu() -> some View {
        let targetNode = visibleNode.dropTargetNode

        Button {
            createFileInFolder(targetNode.url)
        } label: {
            Label("New File", systemImage: MonknotWorkspaceIcons.newFile)
        }

        Button {
            createFolderInFolder(targetNode.url)
        } label: {
            Label("New Folder", systemImage: MonknotWorkspaceIcons.newFolder)
        }

        Divider()

        Button {
            renameFolder(targetNode)
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button {
            copyFolderPath(targetNode.url)
        } label: {
            Label("Copy Path", systemImage: "link")
        }

        Button {
            copyFolderRelativePath(targetNode.url)
        } label: {
            Label("Copy Relative Path", systemImage: "doc.on.doc")
        }

        Button {
            revealFolderInFinder(targetNode.url)
        } label: {
            Label("Reveal in Finder", systemImage: MonknotWorkspaceIcons.revealInFinder)
        }
    }

    @ViewBuilder
    private func documentContextMenu(for document: WorkspaceDocument) -> some View {
        Button {
            renameDocument(document)
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button {
            copyPath(document)
        } label: {
            Label("Copy Path", systemImage: "link")
        }

        Button {
            copyRelativePath(document)
        } label: {
            Label("Copy Relative Path", systemImage: "doc.on.doc")
        }

        Button {
            revealInFinder(document)
        } label: {
            Label("Reveal in Finder", systemImage: MonknotWorkspaceIcons.revealInFinder)
        }

        if document.capabilities.canExportPDF {
            Button {
                exportPDF(document)
            } label: {
                Label("Export PDF...", systemImage: MonknotWorkspaceIcons.exportPDF)
            }
        }

        Divider()

        Button {
            copyDocument(document)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }

        Button {
            cutDocument(document)
        } label: {
            Label("Cut", systemImage: "scissors")
        }

        Divider()

        Button(role: .destructive) {
            deleteDocument(document)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private var sidebarMoveGesture: some Gesture {
        DragGesture(minimumDistance: scaled(4), coordinateSpace: .named(SidebarMoveCoordinateSpace.name))
            .onChanged { value in
                dragChanged(node.id, value.location)
            }
            .onEnded { value in
                dragEnded(node.id, value.location)
            }
    }
}

private struct SidebarScrollContainer<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> SidebarNativeScrollView<Content> {
        let scrollView = SidebarNativeScrollView<Content>()
        let hostingView = SidebarHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.setContentHuggingPriority(.required, for: .vertical)
        hostingView.setContentCompressionResistancePriority(.required, for: .vertical)

        scrollView.documentView = hostingView
        let minimumHeight = hostingView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor)
        minimumHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            hostingView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            minimumHeight
        ])

        context.coordinator.hostingView = hostingView
        return scrollView
    }

    func updateNSView(_ scrollView: SidebarNativeScrollView<Content>, context: Context) {
        context.coordinator.hostingView?.rootView = content
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
    }

    final class Coordinator {
        var hostingView: SidebarHostingView<Content>?
    }
}

private final class SidebarHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool {
        false
    }
}

private final class SidebarClipView: NSClipView {
    override var mouseDownCanMoveWindow: Bool {
        false
    }
}

private final class SidebarNativeScrollView<Content: View>: NSScrollView {
    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        let clipView = SidebarClipView(frame: bounds)
        clipView.drawsBackground = false
        contentView = clipView

        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .allowed
        MonknotScrollbarStyle.apply(to: self)
    }
}

private extension View {
    func sidebarHoverRow(theme: AppTheme, isSelected: Bool, cornerRadius: CGFloat) -> some View {
        modifier(SidebarHoverRowModifier(theme: theme, isSelected: isSelected, cornerRadius: cornerRadius))
    }
}

private struct SidebarHoverRowModifier: ViewModifier {
    let theme: AppTheme
    let isSelected: Bool
    let cornerRadius: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(selectionBackground)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
            .monknotPointerCursor(enabled: isEnabled)
    }

    @ViewBuilder
    private var selectionBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(underlayFill)
            if isSelected {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(theme.selectedRowColor)
            }
        }
    }

    private var underlayFill: Color {
        if isSelected {
            return theme.elevatedSurfaceColor
        }
        if isHovered {
            return theme.foregroundColor.opacity(theme.isDark ? 0.08 : 0.055)
        }
        return .clear
    }
}

private struct SidebarHoverButtonStyle: ButtonStyle {
    let theme: AppTheme
    let isSelected: Bool
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration, theme: theme, isSelected: isSelected, cornerRadius: cornerRadius)
    }

    fileprivate struct Body: View {
        let configuration: Configuration
        let theme: AppTheme
        let isSelected: Bool
        let cornerRadius: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(selectionBackground)
                .opacity(configuration.isPressed ? 0.88 : 1)
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
                .onHover { isHovered = $0 }
                .monknotPointerCursor(enabled: isEnabled)
        }

        @ViewBuilder
        private var selectionBackground: some View {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(underlayFill)
                if isSelected {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(theme.selectedRowColor)
                }
            }
        }

        private var underlayFill: Color {
            if isSelected {
                return theme.elevatedSurfaceColor
            }
            if isHovered {
                return theme.foregroundColor.opacity(theme.isDark ? 0.08 : 0.055)
            }
            return .clear
        }
    }
}

private struct SaveStateIndicator: View {
    let state: DocumentSaveState
    let theme: AppTheme
    let zoomScale: Double
    let size: CGFloat

    var body: some View {
        Group {
            switch state {
            case .clean:
                Color.clear
            case .edited:
                Circle()
                    .fill(theme.accentColor)
                    .frame(width: max(5, size * 0.48), height: max(5, size * 0.48))
            case .saving:
                MonknotProgressIndicator(size: size * 0.82, theme: theme)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: max(9, size * 0.82), weight: .semibold))
                    .foregroundStyle(Color(hex: theme.semanticColors.diffRemoved))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(state.accessibilityDescription)
    }
}

// MARK: - Settings Button

private struct SidebarSettingsButton: View {
    let theme: AppTheme
    let zoomScale: Double
    @Environment(\.openSettings) private var openSettings

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    private func textScaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceText(base, theme: theme, zoomScale: zoomScale)
    }

    private func glyphScaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceGlyph(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        Button {
            openSettings()
        } label: {
            HStack(spacing: scaled(8)) {
                Image(systemName: MonknotWorkspaceIcons.settings)
                    .font(.system(
                        size: MonknotMetrics.chromeGlyphSize(theme: theme, zoomScale: zoomScale),
                        weight: .medium
                    ))
                    .foregroundStyle(theme.sidebarMutedColor())

                Text("Settings")
                    .font(.system(size: textScaled(13), weight: .regular))
                    .foregroundStyle(theme.sidebarColor(theme.foregroundColor, opacity: 0.85))

                Spacer()

                Text("⌘,")
                    .font(.system(size: textScaled(11), weight: .regular, design: .monospaced))
                    .foregroundStyle(theme.tertiaryForegroundColor)
            }
            .padding(.horizontal, scaled(10))
            .padding(.vertical, scaled(8))
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarHoverButtonStyle(theme: theme, isSelected: false, cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale)))
        .padding(.horizontal, scaled(5))
        .padding(.vertical, scaled(4))
        .help("Open Settings (⌘,)")
    }
}

// MARK: - Git Status

private struct GitStatusBadge: View {
    let status: WorkspaceGitFileStatus
    let theme: AppTheme
    let zoomScale: Double

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        Text(status.label)
            .font(.system(size: scaled(9), weight: .bold, design: .rounded))
            .foregroundStyle(status.badgeForegroundColor(theme: theme))
            .padding(.horizontal, scaled(4))
            .padding(.vertical, scaled(2))
            .background(
                Capsule()
                    .fill(status.badgeBackgroundColor(theme: theme))
            )
            .help(status.accessibilityDescription)
            .accessibilityLabel(status.accessibilityDescription)
    }
}

enum SidebarRecentDocumentsLayoutPolicy {
    static let maximumVisibleRows = 5
    static let availableHeightFraction: CGFloat = 0.34

    static func visibleRowCount(
        entryCount: Int,
        availableSidebarHeight: CGFloat,
        rowHeight: CGFloat
    ) -> Int {
        guard entryCount > 0, rowHeight > 0 else { return 0 }

        let heightBudget = max(rowHeight, availableSidebarHeight * availableHeightFraction)
        let availableRows = max(1, Int(floor(heightBudget / rowHeight)))
        return min(entryCount, maximumVisibleRows, availableRows)
    }

    static func viewportHeight(
        entryCount: Int,
        availableSidebarHeight: CGFloat,
        rowHeight: CGFloat
    ) -> CGFloat {
        rowHeight * CGFloat(visibleRowCount(
            entryCount: entryCount,
            availableSidebarHeight: availableSidebarHeight,
            rowHeight: rowHeight
        ))
    }
}

private struct SidebarRecentDocumentsSection: View {
    let entries: [RecentDocumentEntry]
    let selectedDocumentID: String?
    let theme: AppTheme
    let zoomScale: Double
    let availableSidebarHeight: CGFloat
    let openDocument: (String) -> Void
    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    private func textScaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceText(base, theme: theme, zoomScale: zoomScale)
    }

    private func glyphScaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceGlyph(base, theme: theme, zoomScale: zoomScale)
    }

    private var rowHeight: CGFloat {
        scaled(30)
    }

    private var viewportHeight: CGFloat {
        SidebarRecentDocumentsLayoutPolicy.viewportHeight(
            entryCount: entries.count,
            availableSidebarHeight: availableSidebarHeight,
            rowHeight: rowHeight
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(MonknotMotion.outlineAnimation(reduceMotion: reduceMotion)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: scaled(7)) {
                    Text("Recents")
                        .font(.system(size: textScaled(13), weight: .regular))

                    Image(systemName: "chevron.right")
                        .font(.system(size: glyphScaled(10), weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))

                    Spacer(minLength: 0)

                    Text("\(entries.count)")
                        .font(.system(size: textScaled(11), weight: .regular, design: .monospaced))
                        .foregroundStyle(theme.tertiaryForegroundColor)
                }
                .foregroundStyle(theme.sidebarMutedColor(prominence: 0.82))
                .padding(.horizontal, scaled(10))
                .frame(height: scaled(30))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(SidebarHoverButtonStyle(
                theme: theme,
                isSelected: false,
                cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale)
            ))
            .padding(.horizontal, scaled(8))
            .help(isExpanded ? "Hide recent documents" : "Show recent documents")
            .accessibilityLabel("Recent documents")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                MonknotScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(entries, id: \.documentID) { entry in
                            Button {
                                openDocument(entry.documentID)
                            } label: {
                                HStack(spacing: scaled(8)) {
                                    Image(systemName: "clock")
                                        .font(.system(size: glyphScaled(11)))
                                        .foregroundStyle(theme.sidebarMutedColor(prominence: 0.75))

                                    Text(entry.displayName)
                                        .font(.system(size: textScaled(12), weight: .regular))
                                        .foregroundStyle(theme.sidebarColor(theme.foregroundColor, opacity: 0.9))
                                        .lineLimit(1)

                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, scaled(8))
                                .frame(height: rowHeight)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(SidebarHoverButtonStyle(
                                theme: theme,
                                isSelected: entry.documentID == selectedDocumentID,
                                cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale)
                            ))
                            .monknotPointerCursor()
                        }
                    }
                    .padding(.horizontal, scaled(5))
                }
                .padding(.bottom, scaled(5))
                .frame(height: viewportHeight)
                .transition(.opacity)
            }
        }
    }
}

private extension WorkspaceGitFileStatus {
    var label: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .untracked: return "?"
        case .renamed: return "R"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .modified: return "modified in git"
        case .added: return "added in git"
        case .deleted: return "deleted in git"
        case .untracked: return "untracked in git"
        case .renamed: return "renamed in git"
        }
    }

    func badgeForegroundColor(theme: AppTheme) -> Color {
        switch self {
        case .modified: return Color(hex: theme.semanticColors.skill)
        case .added: return Color(hex: theme.semanticColors.diffAdded)
        case .deleted: return Color(hex: theme.semanticColors.diffRemoved)
        case .untracked: return theme.sidebarMutedColor()
        case .renamed: return Color(hex: theme.semanticColors.skill)
        }
    }

    func badgeBackgroundColor(theme: AppTheme) -> Color {
        badgeForegroundColor(theme: theme).opacity(0.16)
    }
}

// MARK: - Empty Sidebar

private struct EmptySidebarView: View {
    let theme: AppTheme
    let zoomScale: Double
    let workspaceURL: URL?
    let hasWorkspace: Bool
    let isLoadingWorkspace: Bool
    let openRecentWorkspace: (URL) -> Void

    @State private var recentWorkspaces: [RecentWorkspaceEntry] = []

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        GeometryReader { geometry in
            MonknotScrollView {
                VStack(spacing: scaled(12)) {
                    if isLoadingWorkspace {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if isLoadingWorkspace {
                        Text("Opening workspace…")
                            .font(.system(size: scaled(12)))
                            .foregroundStyle(theme.sidebarMutedColor(prominence: 0.68))
                            .multilineTextAlignment(.center)
                    } else if !hasWorkspace {
                        Text("No folder open")
                            .font(.system(size: scaled(12)))
                            .foregroundStyle(theme.sidebarMutedColor(prominence: 0.68))
                            .multilineTextAlignment(.center)
                    }

                    if !isLoadingWorkspace, !recentWorkspaces.isEmpty {
                        VStack(alignment: .leading, spacing: scaled(4)) {
                            Text("RECENT WORKSPACES")
                                .font(.system(size: scaled(10), weight: .semibold))
                                .tracking(scaled(0.7))
                                .foregroundStyle(theme.sidebarMutedColor(prominence: 0.76))
                                .padding(.horizontal, scaled(10))
                                .padding(.bottom, scaled(3))

                            ForEach(recentWorkspaces.prefix(5), id: \.path) { entry in
                                Button {
                                    openRecentWorkspace(URL(fileURLWithPath: entry.path, isDirectory: true))
                                } label: {
                                    HStack(spacing: scaled(8)) {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .font(.system(size: scaled(12)))
                                        Text(entry.displayName)
                                            .font(.system(size: scaled(13), weight: .medium))
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .foregroundStyle(theme.sidebarColor(theme.foregroundColor, opacity: 0.9))
                                    .padding(.horizontal, scaled(10))
                                    .padding(.vertical, scaled(6))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(SidebarHoverButtonStyle(
                                    theme: theme,
                                    isSelected: false,
                                    cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale)
                                ))
                                .monknotPointerCursor()
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, scaled(8))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: max(0, geometry.size.height - scaled(24)), alignment: .top)
                .padding(.horizontal, scaled(6))
                .padding(.top, scaled(24))
                .padding(.bottom, scaled(12))
            }
            .scrollContentBackground(.hidden)
        }
        .onAppear(perform: refreshRecentWorkspaces)
        .onChange(of: workspaceURL?.standardizedFileURL.path ?? "") { _, _ in
            refreshRecentWorkspaces()
        }
    }

    private func refreshRecentWorkspaces() {
        let store = RecentWorkspaceStore()
        let activePath = workspaceURL?.standardizedFileURL.path
        recentWorkspaces = store.entries().filter { entry in
            var isDirectory = ObjCBool(false)
            let entryPath = URL(fileURLWithPath: entry.path, isDirectory: true).standardizedFileURL.path
            return entryPath != activePath
                && FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }
}

private struct MarkdownLinkMoveReviewSheet: View {
    let review: MarkdownLinkMoveReviewState
    let theme: AppTheme
    let zoomScale: Double
    let cancel: () -> Void
    let confirm: () -> Void

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: scaled(16)) {
            VStack(alignment: .leading, spacing: scaled(5)) {
                Text("Update Links Before Moving?")
                    .font(.system(size: scaled(16), weight: .semibold))
                    .foregroundStyle(theme.foregroundColor)

                Text(moveSummary)
                    .font(.system(size: scaled(13)))
                    .foregroundStyle(theme.mutedForegroundColor)
            }

            HStack(spacing: scaled(8)) {
                Text(review.plan.sourceURL.lastPathComponent)
                Image(systemName: "arrow.right")
                    .foregroundStyle(theme.mutedForegroundColor)
                    .accessibilityHidden(true)
                Text(review.plan.destinationURL.lastPathComponent)
            }
            .font(.system(size: scaled(12.5), design: .monospaced))
            .foregroundStyle(theme.foregroundColor)
            .lineLimit(1)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: scaled(12)) {
                    ForEach(Array(review.plan.rewriteFiles.enumerated()), id: \.offset) { _, filePlan in
                        VStack(alignment: .leading, spacing: scaled(6)) {
                            Text(relativePath(for: filePlan.finalURL))
                                .font(.system(size: scaled(12.5)))
                                .foregroundStyle(theme.foregroundColor)

                            ForEach(Array(filePlan.rewrites.enumerated()), id: \.offset) { _, rewrite in
                                HStack(alignment: .firstTextBaseline, spacing: scaled(6)) {
                                    Text(rewrite.oldDestination)
                                        .foregroundStyle(theme.mutedForegroundColor)
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: scaled(9)))
                                        .foregroundStyle(theme.mutedForegroundColor)
                                        .accessibilityHidden(true)
                                    Text(rewrite.newDestination)
                                        .foregroundStyle(theme.foregroundColor)
                                }
                                .font(.system(size: scaled(11.5), design: .monospaced))
                                .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if filePlan.originalURL != review.plan.rewriteFiles.last?.originalURL {
                            Divider()
                        }
                    }
                }
            }
            .frame(minHeight: scaled(110), maxHeight: scaled(300))

            HStack(spacing: scaled(8)) {
                Spacer()

                MonknotActionButton(
                    title: "Cancel",
                    role: .secondary,
                    theme: theme,
                    zoomScale: zoomScale,
                    action: cancel
                )
                .keyboardShortcut(.cancelAction)

                MonknotActionButton(
                    title: "Move and Update",
                    role: .primary,
                    theme: theme,
                    zoomScale: zoomScale,
                    action: confirm
                )
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(scaled(18))
        .frame(width: scaled(520))
        .background(theme.surfaceColor)
    }

    private var moveSummary: String {
        let linkNoun = review.plan.rewriteCount == 1 ? "link" : "links"
        let fileNoun = review.plan.rewriteFiles.count == 1 ? "file" : "files"
        return "\(review.plan.rewriteCount) \(linkNoun) in \(review.plan.rewriteFiles.count) \(fileNoun) will be updated."
    }

    private func relativePath(for url: URL) -> String {
        WorkspaceDocumentSupport.relativePath(for: url, in: review.workspaceURL)
    }
}

private struct SidebarNameInputSheet: View {
    let theme: AppTheme
    let zoomScale: Double
    let title: String
    let message: String
    let placeholder: String
    let confirmTitle: String
    let cancel: () -> Void
    let submitName: (String) -> Void
    @State private var name: String
    @FocusState private var isNameFocused: Bool

    init(
        theme: AppTheme,
        zoomScale: Double,
        title: String,
        message: String,
        placeholder: String,
        confirmTitle: String,
        initialName: String,
        cancel: @escaping () -> Void,
        submit: @escaping (String) -> Void
    ) {
        self.theme = theme
        self.zoomScale = zoomScale
        self.title = title
        self.message = message
        self.placeholder = placeholder
        self.confirmTitle = confirmTitle
        self.cancel = cancel
        self.submitName = submit
        _name = State(initialValue: initialName)
    }

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: scaled(16)) {
            VStack(alignment: .leading, spacing: scaled(5)) {
                Text(title)
                    .font(.system(size: scaled(16), weight: .semibold))
                    .foregroundStyle(theme.foregroundColor)

                Text(message)
                    .font(.system(size: scaled(13)))
                    .foregroundStyle(theme.mutedForegroundColor)
            }

            TextField(placeholder, text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: scaled(14)))
                .foregroundStyle(theme.foregroundColor)
                .focused($isNameFocused)
                .onSubmit(submit)
                .padding(.horizontal, scaled(10))
                .frame(height: scaled(34))
                .background(
                    RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
                        .fill(theme.insetFillColor)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
                        .strokeBorder(theme.borderColor, lineWidth: 1)
                }

            HStack(spacing: scaled(8)) {
                Spacer()

                MonknotActionButton(
                    title: "Cancel",
                    role: .secondary,
                    theme: theme,
                    zoomScale: zoomScale,
                    action: cancel
                )
                .keyboardShortcut(.cancelAction)

                MonknotActionButton(
                    title: confirmTitle,
                    role: .primary,
                    theme: theme,
                    zoomScale: zoomScale,
                    isDisabled: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    action: submit
                )
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(scaled(18))
        .frame(width: scaled(360))
        .background(theme.surfaceColor)
        .onAppear {
            isNameFocused = true
        }
    }

    private func submit() {
        submitName(name)
    }
}
