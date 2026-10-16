import AppKit
import MonknotCore
import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var workspaceLibrary: WorkspaceLibraryStore
    @ObservedObject var workspaceSearch: WorkspaceSearchState
    @Binding var searchOptions: MonknotSearchOptions
    let theme: AppTheme
    let zoomScale: Double
    let openFolder: () -> Void
    let switchWorkspace: (SavedWorkspaceEntry) -> Void
    let removeWorkspace: (SavedWorkspaceEntry) -> Void
    let manageWorkspaces: () -> Void
    let newMarkdown: () -> Void
    let exportPDF: (WorkspaceDocument) -> Void
    let openDocument: (String) -> Void
    let openWorkspaceSearchResult: (WorkspaceSearchResult) -> Void
    let showWorkspaceSearch: () -> Void
    let dismissWorkspaceSearch: () -> Void
    let workspaceSearchFocusChanged: (Bool) -> Void
    let copyPath: (URL) -> Void
    let copyRelativePath: (URL) -> Void
    /// A New File or New Folder command from the menu, answered with the name prompt for the
    /// sidebar's target folder.
    @Binding var newItemRequest: SidebarNewItemRequest?
    @State private var isDropTargeted = false
    @State private var expandedFolderIDs: Set<String> = []
    @State private var expandedWorkspacePath: String?
    @State private var sidebarPrompt: SidebarNamePrompt?
    @State private var sidebarTreeSize: CGSize = .zero
    @State private var sidebarNodeFrames: [String: CGRect] = [:]
    @State private var draggedSidebarNodeID: String?
    @State private var moveDropTargetFolderID: String?
    @State private var isMoveDropTargetingRoot = false
    @State private var externalDropRowID: String?
    @State private var recentDocuments: [RecentDocumentEntry] = []
    @State private var visibleNodes: [VisibleSidebarNode] = []
    private let treeExpansionPersistence = WorkspaceTreeExpansionPersistence()

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
                        workspaces: workspaceLibrary.entries,
                        isBusy: store.isBusy,
                        canCreateMarkdown: store.workspaceURL != nil && !store.isBusy,
                        canSearch: store.workspaceURL != nil,
                        theme: theme,
                        zoomScale: zoomScale,
                        switchWorkspace: switchWorkspace,
                        addWorkspace: openFolder,
                        removeWorkspace: removeWorkspace,
                        manageWorkspaces: manageWorkspaces,
                        createMarkdown: newMarkdown,
                        showWorkspaceSearch: showWorkspaceSearch
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
            restoreExpandedFoldersIfNeeded()
        }
        .onChange(of: sidebarSelectionID) { _, selectionID in
            expandFolders(ancestorFolderIDs(of: selectionID))
        }
        .onChange(of: store.revealedFolder) { _, reveal in
            guard let reveal else { return }
            expandFolders(ancestorFolderIDs(of: reveal.folderID).union([reveal.folderID]))
        }
        .onChange(of: newItemRequest) { _, request in
            guard let request else { return }
            newItemRequest = nil
            guard store.workspaceURL != nil, !store.isBusy else { return }
            switch request {
            case .file:
                beginCreateFile(in: store.sidebarTargetFolderURL)
            case .folder:
                beginCreateFolder(in: store.sidebarTargetFolderURL)
            }
        }
        // The rows come from the tree, which also changes without the documents (an empty folder).
        .onChange(of: store.rootNodeRevision) { _, _ in
            refreshVisibleNodes()
        }
        .onChange(of: store.recentDocumentChangeSerial) { _, _ in
            refreshRecentDocuments()
        }
        .onChange(of: store.workspaceURL?.standardizedFileURL.path ?? "") { _, _ in
            expandedWorkspacePath = nil
            restoreExpandedFoldersIfNeeded()
            refreshRecentDocuments()
        }
        .onChange(of: expandedFolderIDs) { _, _ in
            persistExpandedFolders()
        }
        .onAppear(perform: handleSidebarAppear)
        .background {
            FileURLDropTarget(
                isTargeted: $isDropTargeted,
                operation: { urls in SidebarFileDrop.operation(for: urls, workspaceURL: store.workspaceURL) },
                handleURLs: { urls, operation in
                    store.dropFileURLs(urls, into: nil, copying: operation == .copy)
                }
            )
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
                validate: { newName in
                    validationMessage(for: prompt, name: newName)
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
                searchOptions: $searchOptions,
                theme: theme,
                zoomScale: zoomScale,
                close: dismissWorkspaceSearch,
                workspaceSearchFocusChanged: workspaceSearchFocusChanged,
                openResult: openWorkspaceSearchResult,
                replaceAll: {
                    workspaceSearch.clearReplaceStatus()
                    store.replaceInWorkspace(
                        find: workspaceSearch.query,
                        replacement: workspaceSearch.replaceText,
                        options: searchOptions,
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
                        SidebarScrollContainer(
                            theme: theme,
                            revealedRow: revealedRow(in: nodes),
                            keyDown: handleTreeKeyDown(_:)
                        ) {
                            LazyVStack(alignment: .leading, spacing: scaled(2)) {
                                ForEach(nodes) { visibleNode in
                                    SidebarNodeRow(
                                        visibleNode: visibleNode,
                                        isSelected: visibleNode.shows(sidebarSelectionID),
                                        saveState: visibleNode.node.document.map { store.saveState(for: $0.id) } ?? .clean,
                                        gitStatus: visibleNode.node.document.flatMap { document in
                                            store.gitStatusByRelativePath[document.relativePath]
                                        },
                                        isExpanded: visibleNode.isExpanded(in: expandedFolderIDs),
                                        tracksMoveFrame: tracksSidebarMoveFrames,
                                        isBusy: store.isBusy,
                                        isMoveSource: draggedSidebarNodeID == visibleNode.id,
                                        isMoveTarget: moveDropTargetFolderID == visibleNode.dropTargetFolderID,
                                        theme: theme,
                                        zoomScale: zoomScale,
                                        actions: rowActions
                                    )
                                    .equatable()
                                }
                            }
                            .padding(.horizontal, scaled(6))
                            .padding(.vertical, scaled(6))
                            // Inside the scroll view's hosting view, so the rows' drag gesture and
                            // frame readers measure in the same space.
                            .coordinateSpace(name: SidebarMoveCoordinateSpace.name)
                            .onPreferenceChange(SidebarNodeFramePreferenceKey.self) { frames in
                                sidebarNodeFrames = frames
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .layoutPriority(1)
                        .onGeometryChange(for: CGSize.self) { proxy in
                            proxy.size
                        } action: { size in
                            sidebarTreeSize = size
                        }

                        if !recentDocuments.isEmpty {
                            SidebarRecentDocumentsSection(
                                entries: recentDocuments,
                                theme: theme,
                                zoomScale: zoomScale,
                                availableSidebarHeight: geometry.size.height,
                                kindGlyph: { entry in
                                    (store.document(id: entry.documentID)?.kind ?? .markdown).resolvedSystemImage
                                },
                                openDocument: openDocument,
                                revealInFinder: revealInFinder(_:),
                                copyPath: copyPath
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
                    workspaces: workspaceLibrary.entries,
                    isLoadingWorkspace: store.isWorkspaceOpening,
                    switchWorkspace: switchWorkspace
                )
                    .contextMenu {
                        sidebarContextMenu
                    }
            }
        }
    }

    private func refreshWorkspaceSearch() {
        workspaceSearch.refresh(
            options: searchOptions,
            documents: store.documents,
            dirtyTextByDocumentID: store.dirtyTextByDocumentID,
            dirtyPDFDataByDocumentID: store.dirtyPDFDataByDocumentID
        )
    }

    private func handleSidebarAppear() {
        restoreExpandedFoldersIfNeeded()
        refreshRecentDocuments()
    }

    private func refreshVisibleNodes() {
        visibleNodes = SidebarTreePresentation.visibleNodes(
            from: store.rootNode?.children ?? [],
            expandedFolderIDs: expandedFolderIDs
        )
    }

    private func restoreExpandedFoldersIfNeeded() {
        guard let workspaceURL = store.workspaceURL?.standardizedFileURL else {
            expandedWorkspacePath = nil
            expandedFolderIDs = []
            refreshVisibleNodes()
            return
        }

        let path = workspaceURL.path
        if expandedWorkspacePath != path {
            expandedWorkspacePath = path
            expandedFolderIDs = treeExpansionPersistence.load(for: workspaceURL)
                ?? initialExpandedFolderIDs()
        }
        refreshVisibleNodes()
    }

    private func persistExpandedFolders() {
        guard let workspaceURL = store.workspaceURL?.standardizedFileURL,
              expandedWorkspacePath == workspaceURL.path
        else {
            return
        }
        treeExpansionPersistence.save(expandedFolderIDs, for: workspaceURL)
    }

    private func initialExpandedFolderIDs() -> Set<String> {
        ancestorFolderIDs(of: sidebarSelectionID ?? store.documents.first?.id)
    }

    /// The sidebar's one selection: the selected folder, otherwise the selected document.
    private var sidebarSelectionID: String? {
        store.selectedFolderID ?? store.selectedDocumentID
    }

    /// The folders between the workspace root and the item `itemID`, which is a path.
    private func ancestorFolderIDs(of itemID: String?) -> Set<String> {
        guard let itemID,
              let workspacePath = store.workspaceURL?.standardizedFileURL.path,
              itemID.hasPrefix(workspacePath + "/")
        else { return [] }

        var ancestorIDs: Set<String> = []
        var folderPath = (itemID as NSString).deletingLastPathComponent
        while folderPath.count > workspacePath.count {
            ancestorIDs.insert(folderPath)
            folderPath = (folderPath as NSString).deletingLastPathComponent
        }
        return ancestorIDs
    }

    private func expandFolders(_ folderIDs: Set<String>) {
        let nextExpandedFolderIDs = expandedFolderIDs.union(folderIDs)
        guard nextExpandedFolderIDs != expandedFolderIDs else { return }

        expandedFolderIDs = nextExpandedFolderIDs
        refreshVisibleNodes()
    }

    /// The selected row, which the tree scrolls into view when the selection changes.
    private func revealedRow(in nodes: [VisibleSidebarNode]) -> SidebarRevealedRow? {
        guard let selectionID = sidebarSelectionID,
              let index = nodes.firstIndex(where: { $0.shows(selectionID) })
        else { return nil }
        let rowPitch = scaled(30) + scaled(2)
        return SidebarRevealedRow(
            id: selectionID,
            frame: CGRect(x: 0, y: scaled(6) + CGFloat(index) * rowPitch, width: 1, height: scaled(30))
        )
    }

    /// The tree's own keys while it has keyboard focus: Return renames the selection, ⌘D
    /// duplicates it and ⌘⌫ moves it to the Trash. Cut, Copy and Paste come through the Edit menu.
    private func handleTreeKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let command: SidebarTreeKeyCommand?
        switch event.keyCode {
        case SidebarTreeKeyCommand.returnKeyCode, SidebarTreeKeyCommand.enterKeyCode:
            command = modifiers.isEmpty ? .rename : nil
        case SidebarTreeKeyCommand.deleteKeyCode:
            command = modifiers == .command ? .moveToTrash : nil
        default:
            command = modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "d"
                ? .duplicate
                : nil
        }
        guard let command else { return false }
        guard !store.isBusy,
              let selectionID = sidebarSelectionID,
              let item = store.rootNode?.node(withID: selectionID)
        else {
            NSSound.beep()
            return true
        }

        switch command {
        case .rename:
            beginRename(item)
        case .duplicate:
            store.duplicateItem(at: item.url)
        case .moveToTrash:
            moveToTrash(item)
        }
        return true
    }

    /// A click on a folder row selects the folder (the deepest of a compact row) and opens or
    /// closes it.
    private func clickFolder(_ visibleNode: VisibleSidebarNode) {
        store.selectFolder(id: visibleNode.dropTargetNode.id)
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
            options: searchOptions,
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

    private var rowActions: SidebarRowActions {
        SidebarRowActions(
            clickFolder: clickFolder(_:),
            openDocument: openDocument,
            createFile: beginCreateFile(in:),
            createFolder: beginCreateFolder(in:),
            rename: beginRename(_:),
            copyPath: copyPath,
            copyRelativePath: copyRelativePath,
            revealInFinder: revealInFinder(_:),
            exportPDF: exportPDF,
            copy: { store.putItemOnPasteboard(at: $0, cutting: false) },
            cut: { store.putItemOnPasteboard(at: $0, cutting: true) },
            paste: paste(into:),
            duplicate: store.duplicateItem(at:),
            moveToTrash: moveToTrash(_:),
            dragChanged: handleSidebarNodeDragChanged(id:location:),
            dragEnded: handleSidebarNodeDragEnded(id:location:),
            dropFileURLs: { urls, directoryURL, copying in
                store.dropFileURLs(urls, into: directoryURL, copying: copying)
            },
            dropTargetingChanged: handleExternalDropTargeting(rowID:directoryURL:isTargeted:),
            workspaceURL: { store.workspaceURL }
        )
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

        Divider()

        Button {
            paste(into: nil)
        } label: {
            Label("Paste", systemImage: "doc.on.clipboard")
        }
        .disabled(store.workspaceURL == nil || store.isBusy)

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

    /// Asks for a new name for a file or folder.
    private func beginRename(_ item: SidebarNode) {
        if let document = item.document {
            sidebarPrompt = SidebarNamePrompt(
                operation: .renameDocument(document.id),
                title: "Rename",
                message: "Enter a new file name.",
                placeholder: "File name",
                confirmTitle: "Rename",
                name: document.displayName
            )
        } else {
            sidebarPrompt = SidebarNamePrompt(
                operation: .renameFolder(item.id),
                title: "Rename Folder",
                message: "Enter a new folder name.",
                placeholder: "Folder name",
                confirmTitle: "Rename",
                name: item.name
            )
        }
    }

    private func moveToTrash(_ item: SidebarNode) {
        if let document = item.document {
            store.deleteDocument(document)
        } else {
            store.deleteFolder(at: item.url)
        }
    }

    private func paste(into directoryURL: URL?) {
        if !store.pasteFromPasteboard(into: directoryURL) {
            NSSound.beep()
        }
    }

    private func handleSidebarNodeDragChanged(id: String, location: CGPoint) {
        guard store.workspaceURL != nil, !store.isBusy else { return }
        draggedSidebarNodeID = id
        guard sidebarNodeFrames[id] != nil else { return }
        let target = moveDropTarget(forRow: id, at: location)
        moveDropTargetFolderID = target?.folderID
        isMoveDropTargetingRoot = target == .root
    }

    private func handleSidebarNodeDragEnded(id: String, location: CGPoint) {
        defer {
            draggedSidebarNodeID = nil
            moveDropTargetFolderID = nil
            isMoveDropTargetingRoot = false
            sidebarNodeFrames = [:]
        }

        guard !store.isBusy,
              sidebarNodeFrames[id] != nil,
              let row = displayedVisibleNodes.first(where: { $0.id == id }),
              let target = moveDropTarget(forRow: id, at: location)
        else { return }

        switch target {
        case .root:
            store.moveItem(id: row.dropTargetNode.id, toDirectory: nil)
        case .folder(let folderURL):
            store.moveItem(id: row.dropTargetNode.id, toDirectory: folderURL)
        }
    }

    private func moveDropTarget(forRow rowID: String, at location: CGPoint) -> SidebarMoveDropTarget? {
        guard let workspaceURL = store.workspaceURL else { return nil }
        return SidebarMoveDropTarget.resolve(
            draggedRowID: rowID,
            location: location,
            rows: displayedVisibleNodes,
            rowFrames: sidebarNodeFrames,
            treeSize: sidebarTreeSize,
            workspaceURL: workspaceURL
        )
    }

    /// Highlights the folder a Finder drag over a row would land in (the root for a root file).
    private func handleExternalDropTargeting(rowID: String, directoryURL: URL, isTargeted: Bool) {
        if isTargeted {
            externalDropRowID = rowID
            let isRoot = directoryURL.standardizedFileURL == store.workspaceURL?.standardizedFileURL
            moveDropTargetFolderID = isRoot ? nil : directoryURL.standardizedFileURL.path
            isMoveDropTargetingRoot = isRoot
        } else if externalDropRowID == rowID {
            externalDropRowID = nil
            moveDropTargetFolderID = nil
            isMoveDropTargetingRoot = false
        }
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

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func validationMessage(for prompt: SidebarNamePrompt, name: String) -> String? {
        switch prompt.operation {
        case .renameDocument(let documentID):
            guard let document = store.document(id: documentID) else { return nil }
            return store.validationMessage(forRenaming: document.url, to: name, isDirectory: false)
        case .renameFolder(let folderID):
            let folderURL = URL(fileURLWithPath: folderID, isDirectory: true)
            return store.validationMessage(forRenaming: folderURL, to: name, isDirectory: true)
        case .createFile(let directoryURL):
            return store.validationMessage(forNewItemNamed: name, in: directoryURL, isDirectory: false)
        case .createFolder(let directoryURL):
            return store.validationMessage(forNewItemNamed: name, in: directoryURL, isDirectory: true)
        }
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

    /// Where a Paste, a Finder drop or a moved row lands on this row: the folder itself (the
    /// deepest of a compact row), or a file's folder.
    var destinationURL: URL {
        node.kind == .folder ? dropTargetNode.url : node.url.deletingLastPathComponent()
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

    /// Whether this row shows the item `itemID`: a file row its document, a folder row any folder of
    /// its compact path.
    func shows(_ itemID: String?) -> Bool {
        guard let itemID else { return false }
        return node.kind == .folder ? folderNodeIDs.contains(itemID) : node.document?.id == itemID
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

/// Where a dragged sidebar row moves its item.
enum SidebarMoveDropTarget: Equatable {
    case folder(URL)
    case root

    var folderID: String? {
        guard case .folder(let url) = self else { return nil }
        return url.standardizedFileURL.path
    }

    /// The target under `location`, in the tree's coordinate space: a folder row is that folder (the
    /// deepest of a compact row), a file row is the file's folder, and empty tree space below the
    /// rows is the root. Nil where the item already is, on the item itself or anything inside it,
    /// and anywhere else.
    static func resolve(
        draggedRowID: String,
        location: CGPoint,
        rows: [VisibleSidebarNode],
        rowFrames: [String: CGRect],
        treeSize: CGSize,
        workspaceURL: URL
    ) -> SidebarMoveDropTarget? {
        guard let draggedRow = rows.first(where: { $0.id == draggedRowID }) else { return nil }
        let itemPath = draggedRow.dropTargetNode.url.standardizedFileURL.path

        let destinationURL: URL
        if let row = rows.first(where: { rowFrames[$0.id]?.contains(location) == true }) {
            guard row.id != draggedRowID else { return nil }
            destinationURL = row.destinationURL
        } else {
            let rowsBottom = rowFrames.values.map(\.maxY).max() ?? 0
            let isEmptyTreeSpace = location.y > rowsBottom
                && location.y <= max(treeSize.height, rowsBottom + 8)
                && location.x >= 0
                && location.x <= treeSize.width
            guard isEmptyTreeSpace else { return nil }
            destinationURL = workspaceURL
        }

        let destinationPath = destinationURL.standardizedFileURL.path
        guard destinationPath != (itemPath as NSString).deletingLastPathComponent,
              destinationPath != itemPath,
              !destinationPath.hasPrefix(itemPath + "/")
        else { return nil }
        return destinationPath == workspaceURL.standardizedFileURL.path
            ? .root
            : .folder(URL(fileURLWithPath: destinationPath, isDirectory: true))
    }
}

private enum SidebarMoveCoordinateSpace {
    static let name = "Monknot.SidebarMoveCoordinateSpace"
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
    let workspaces: [SavedWorkspaceEntry]
    let isBusy: Bool
    let canCreateMarkdown: Bool
    let canSearch: Bool
    let theme: AppTheme
    let zoomScale: Double
    let switchWorkspace: (SavedWorkspaceEntry) -> Void
    let addWorkspace: () -> Void
    let removeWorkspace: (SavedWorkspaceEntry) -> Void
    let manageWorkspaces: () -> Void
    let createMarkdown: () -> Void
    let showWorkspaceSearch: () -> Void
    @State private var isWorkspaceTitleHovered = false
    @State private var isSwitcherPresented = false

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    private func textScaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceText(base, theme: theme, zoomScale: zoomScale)
    }

    private var activeWorkspace: SavedWorkspaceEntry? {
        guard let path = workspaceURL?.standardizedFileURL.path else { return nil }
        return workspaces.first { $0.path == path }
    }

    private var workspaceName: String {
        activeWorkspace?.displayName ?? workspaceURL?.lastPathComponent ?? "No Workspace"
    }

    private var showsChevron: Bool {
        workspaces.count > 1 || isWorkspaceTitleHovered || isSwitcherPresented
    }

    var body: some View {
        HStack(spacing: scaled(6)) {
            if workspaceURL != nil {
                Button {
                    isSwitcherPresented.toggle()
                } label: {
                    HStack(spacing: scaled(6)) {
                        // Disabled while a workspace loads: `ink4`, and no hover ink (design.md §5.1).
                        Text(workspaceName)
                            .font(.system(size: textScaled(13), weight: .semibold))
                            .foregroundStyle(
                                isBusy
                                    ? theme.disabledForegroundColor
                                    : theme.sidebarColor(theme.foregroundColor, opacity: 0.92)
                            )
                            .lineLimit(1)
                            .truncationMode(.tail)

                        // Beside the name, like a pop-up button (design.md §10.4 "name + chevron").
                        Image(systemName: "chevron.down")
                            .font(.system(size: textScaled(10), weight: .regular))
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(
                                isBusy
                                    ? theme.disabledForegroundColor
                                    : (isWorkspaceTitleHovered || isSwitcherPresented
                                        ? theme.foregroundColor
                                        : theme.tertiaryForegroundColor)
                            )
                            .opacity(showsChevron ? 1 : 0)
                            .frame(width: scaled(11))
                            .animation(MonknotMotion.hoverAnimation, value: showsChevron)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, scaled(10))
                    .frame(maxWidth: .infinity)
                    .frame(height: scaled(30))
                }
                .buttonStyle(MonknotRowButtonStyle(
                    theme: theme,
                    isSelected: false,
                    isActive: isSwitcherPresented,
                    cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale)
                ))
                .disabled(isBusy)
                .onHover { isWorkspaceTitleHovered = $0 }
                .popover(isPresented: $isSwitcherPresented, arrowEdge: .top) {
                    WorkspaceSwitcherPopover(
                        workspaces: workspaces,
                        activeWorkspacePath: workspaceURL?.standardizedFileURL.path,
                        isBusy: isBusy,
                        theme: theme,
                        zoomScale: zoomScale,
                        switchWorkspace: { workspace in
                            isSwitcherPresented = false
                            switchWorkspace(workspace)
                        },
                        addWorkspace: {
                            isSwitcherPresented = false
                            addWorkspace()
                        },
                        removeWorkspace: removeWorkspace,
                        manageWorkspaces: {
                            isSwitcherPresented = false
                            manageWorkspaces()
                        }
                    )
                }
                .help(workspaceURL?.path ?? "No workspace open")
                .layoutPriority(1)
            } else {
                Text(workspaceName)
                    .font(.system(size: textScaled(13), weight: .semibold))
                    .foregroundStyle(theme.tertiaryForegroundColor)
                    .lineLimit(1)
                    .padding(.horizontal, scaled(2))
            }

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

private struct WorkspaceSwitcherPopover: View {
    let workspaces: [SavedWorkspaceEntry]
    let activeWorkspacePath: String?
    let isBusy: Bool
    let theme: AppTheme
    let zoomScale: Double
    let switchWorkspace: (SavedWorkspaceEntry) -> Void
    let addWorkspace: () -> Void
    let removeWorkspace: (SavedWorkspaceEntry) -> Void
    let manageWorkspaces: () -> Void

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    private func textScaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceText(base, theme: theme, zoomScale: zoomScale)
    }

    /// Up to seven 34 rows (design.md §5.7 overlay row), 2 apart, inside the list padding.
    private var workspaceListHeight: CGFloat {
        let visibleCount = CGFloat(min(workspaces.count, 7))
        return scaled(visibleCount * 34 + max(0, visibleCount - 1) * 2 + 12)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Workspaces")
                .font(MonknotTypography.eyebrow(theme: theme, zoomScale: zoomScale))
                .tracking(MonknotTypography.eyebrowTracking(theme: theme, zoomScale: zoomScale))
                .textCase(.uppercase)
                .foregroundStyle(theme.tertiaryForegroundColor)
                .padding(.horizontal, scaled(14))
                .frame(height: scaled(28), alignment: .bottomLeading)

            if workspaces.isEmpty {
                Text("No saved workspaces")
                    .font(.system(size: textScaled(12), weight: .regular))
                    .foregroundStyle(theme.tertiaryForegroundColor)
                    .padding(.horizontal, scaled(14))
                    .frame(height: scaled(42), alignment: .leading)
            } else {
                MonknotScrollView(theme: theme) {
                    LazyVStack(spacing: scaled(2)) {
                        ForEach(Array(workspaces.enumerated()), id: \.element.id) { index, workspace in
                            WorkspaceSwitcherRow(
                                workspace: workspace,
                                shortcutIndex: index < 9 ? index + 1 : nil,
                                isActive: workspace.path == activeWorkspacePath,
                                isBusy: isBusy,
                                theme: theme,
                                zoomScale: zoomScale,
                                open: { switchWorkspace(workspace) },
                                remove: { removeWorkspace(workspace) }
                            )
                        }
                    }
                    .padding(.horizontal, scaled(6))
                    .padding(.vertical, scaled(6))
                }
                .frame(height: workspaceListHeight)
            }

            Rectangle()
                .fill(theme.separatorColor)
                .frame(height: 1)
                .padding(.horizontal, scaled(14))
                .padding(.vertical, scaled(6))

            WorkspaceSwitcherActionRow(
                title: "Add Workspace…",
                systemImage: "folder.badge.plus",
                theme: theme,
                zoomScale: zoomScale,
                action: addWorkspace
            )

            WorkspaceSwitcherActionRow(
                title: "Manage Workspaces…",
                systemImage: "gearshape",
                theme: theme,
                zoomScale: zoomScale,
                action: manageWorkspaces
            )
        }
        .padding(.bottom, scaled(6))
        .frame(width: scaled(380))
        .background(theme.elevatedSurfaceColor)
    }
}

private struct WorkspaceSwitcherRow: View {
    let workspace: SavedWorkspaceEntry
    let shortcutIndex: Int?
    let isActive: Bool
    let isBusy: Bool
    let theme: AppTheme
    let zoomScale: Double
    let open: () -> Void
    let remove: () -> Void
    @State private var isHovered = false

    /// Another workspace is loading, so this one cannot open yet: `ink4` and no hover ink (design.md
    /// §5.1). The active workspace keeps its selected look.
    private var isUnavailable: Bool {
        isBusy && !isActive
    }

    private var isHighlighted: Bool {
        isHovered && !isUnavailable
    }

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    private func textScaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceText(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: open) {
                HStack(spacing: scaled(8)) {
                    MonknotSystemGlyph(
                        systemImage: isActive ? "folder.fill" : "folder",
                        nominalPointSizeBase: 15,
                        theme: theme,
                        zoomScale: zoomScale
                    )
                    .foregroundStyle(
                        isActive
                            ? theme.accentColor
                            : (isUnavailable
                                ? theme.disabledForegroundColor
                                : (isHighlighted ? theme.foregroundColor : theme.tertiaryForegroundColor))
                    )
                    .animation(MonknotMotion.hoverAnimation, value: isHovered)
                    .frame(width: scaled(18))

                    Text(workspace.displayName)
                        .font(.system(size: textScaled(13), weight: .regular))
                        .foregroundStyle(
                            isActive || isHighlighted
                                ? theme.foregroundColor
                                : (isUnavailable ? theme.disabledForegroundColor : theme.mutedForegroundColor)
                        )
                        .animation(MonknotMotion.hoverAnimation, value: isHovered)
                        .lineLimit(1)
                        .layoutPriority(1)

                    Text((workspace.path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: textScaled(12), weight: .regular))
                        .foregroundStyle(isUnavailable ? theme.disabledForegroundColor : theme.tertiaryForegroundColor)
                        .lineLimit(1)
                        .truncationMode(.head)

                    Spacer(minLength: scaled(8))

                    // The trailing slot keeps one width: the shortcut fades out under the remove
                    // button instead of leaving the layout, so the path never re-truncates on hover.
                    ZStack(alignment: .trailing) {
                        Color.clear.frame(width: scaled(22), height: scaled(22))
                        if let shortcutIndex {
                            MonknotShortcutLabel(
                                shortcut: "⌃⌘\(shortcutIndex)",
                                theme: theme,
                                zoomScale: zoomScale
                            )
                            .opacity(isHovered ? 0 : 1)
                        }
                    }
                }
                .padding(.horizontal, scaled(10))
                .frame(height: scaled(34))
                .contentShape(Rectangle())
            }
            .buttonStyle(MonknotRowButtonStyle(
                theme: theme,
                isSelected: isActive,
                cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale)
            ))
            .disabled(isBusy || isActive)

            if isHovered {
                MonknotIconButton(
                    systemImage: "xmark",
                    label: "Remove \(workspace.displayName)",
                    theme: theme,
                    zoomScale: zoomScale,
                    isDisabled: isBusy,
                    size: .smallAction,
                    focusRingPlacement: .contained,
                    action: remove
                )
                .padding(.trailing, scaled(10))
            }
        }
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
    }
}

private struct WorkspaceSwitcherActionRow: View {
    let title: String
    let systemImage: String
    let theme: AppTheme
    let zoomScale: Double
    let action: () -> Void

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: scaled(8)) {
                MonknotSystemGlyph(
                    systemImage: systemImage,
                    nominalPointSizeBase: 15,
                    theme: theme,
                    zoomScale: zoomScale
                )
                .frame(width: scaled(18))

                Text(title)
                    .font(MonknotTypography.rowTitle(theme: theme, zoomScale: zoomScale))

                Spacer()
            }
            .padding(.horizontal, scaled(10))
            .frame(height: scaled(30))
            .contentShape(Rectangle())
        }
        .buttonStyle(MonknotRowButtonStyle(
            theme: theme,
            isSelected: false,
            cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale)
        ))
        .padding(.horizontal, scaled(8))
    }
}

// MARK: - Sidebar Row

/// What a sidebar row's clicks, drags, drops and context menu do. Folder actions take the deepest
/// folder of a compact row ("A/B" acts on B).
private struct SidebarRowActions {
    let clickFolder: (VisibleSidebarNode) -> Void
    let openDocument: (String) -> Void
    let createFile: (URL) -> Void
    let createFolder: (URL) -> Void
    let rename: (SidebarNode) -> Void
    let copyPath: (URL) -> Void
    let copyRelativePath: (URL) -> Void
    let revealInFinder: (URL) -> Void
    let exportPDF: (WorkspaceDocument) -> Void
    let copy: (URL) -> Void
    let cut: (URL) -> Void
    let paste: (URL) -> Void
    let duplicate: (URL) -> Void
    let moveToTrash: (SidebarNode) -> Void
    let dragChanged: (String, CGPoint) -> Void
    let dragEnded: (String, CGPoint) -> Void
    let dropFileURLs: ([URL], URL, Bool) -> Void
    let dropTargetingChanged: (String, URL, Bool) -> Void
    let workspaceURL: () -> URL?
}

/// Rows compare only what they draw. Typing publishes the store on every keystroke, and without
/// this every row in the tree re-evaluated its body (glyph, help text and context menu) per key.
/// The action closures forward into the sidebar and the store, so they are deliberately ignored.
extension SidebarNodeRow: Equatable {
    static func == (lhs: SidebarNodeRow, rhs: SidebarNodeRow) -> Bool {
        lhs.visibleNode.depth == rhs.visibleNode.depth &&
            lhs.visibleNode.folderNodeIDs == rhs.visibleNode.folderNodeIDs &&
            lhs.visibleNode.node.id == rhs.visibleNode.node.id &&
            lhs.visibleNode.node.name == rhs.visibleNode.node.name &&
            lhs.visibleNode.node.relativePath == rhs.visibleNode.node.relativePath &&
            lhs.visibleNode.node.kind == rhs.visibleNode.node.kind &&
            lhs.visibleNode.node.document == rhs.visibleNode.node.document &&
            lhs.isSelected == rhs.isSelected &&
            lhs.saveState == rhs.saveState &&
            lhs.gitStatus == rhs.gitStatus &&
            lhs.isExpanded == rhs.isExpanded &&
            lhs.tracksMoveFrame == rhs.tracksMoveFrame &&
            lhs.isBusy == rhs.isBusy &&
            lhs.isMoveSource == rhs.isMoveSource &&
            lhs.isMoveTarget == rhs.isMoveTarget &&
            lhs.zoomScale == rhs.zoomScale &&
            lhs.theme == rhs.theme
    }
}

private struct SidebarNodeRow: View {
    let visibleNode: VisibleSidebarNode
    let isSelected: Bool
    let saveState: DocumentSaveState
    let gitStatus: WorkspaceGitFileStatus?
    let isExpanded: Bool
    let tracksMoveFrame: Bool
    let isBusy: Bool
    let isMoveSource: Bool
    let isMoveTarget: Bool
    let theme: AppTheme
    let zoomScale: Double
    let actions: SidebarRowActions

    private var node: SidebarNode {
        visibleNode.node
    }

    /// The file, or the deepest folder of a compact folder row.
    private var item: SidebarNode {
        visibleNode.dropTargetNode
    }

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
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

    /// Folder row: its disclosure chevron takes the glyph column (design.md §10.4).
    private var folderRow: some View {
        Button {
            actions.clickFolder(visibleNode)
        } label: {
            SidebarRowLabel(
                leading: .disclosure(isExpanded: isExpanded),
                title: visibleNode.displayName,
                depth: visibleNode.depth,
                isSelected: isSelected,
                theme: theme,
                zoomScale: zoomScale
            ) {
                EmptyView()
            }
        }
        .buttonStyle(SidebarRowButtonStyle(
            theme: theme,
            isSelected: isSelected,
            cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale)
        ))
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
        .highPriorityGesture(sidebarMoveGesture)
        .onDrop(of: [.fileURL], delegate: fileDropDelegate)
        .help(visibleNode.displayRelativePath)
        .accessibilityLabel(folderAccessibilityLabel)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
                actions.openDocument(document.id)
            }
        } label: {
            SidebarRowLabel(
                leading: .kind(systemImage: documentIconName),
                title: node.name,
                depth: visibleNode.depth,
                isSelected: isSelected,
                theme: theme,
                zoomScale: zoomScale
            ) {
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
        }
        .buttonStyle(SidebarRowButtonStyle(
            theme: theme,
            isSelected: isSelected,
            cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale)
        ))
        .background {
            if tracksMoveFrame {
                SidebarNodeFrameReader(id: node.id)
            }
        }
        .opacity(isMoveSource ? 0.45 : 1)
        .highPriorityGesture(sidebarMoveGesture)
        .onDrop(of: [.fileURL], delegate: fileDropDelegate)
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
        Button {
            actions.createFile(item.url)
        } label: {
            Label("New File", systemImage: MonknotWorkspaceIcons.newFile)
        }
        .disabled(isBusy)

        Button {
            actions.createFolder(item.url)
        } label: {
            Label("New Folder", systemImage: MonknotWorkspaceIcons.newFolder)
        }
        .disabled(isBusy)

        Divider()

        renameButton
        locationButtons

        Divider()

        clipboardButtons

        Divider()

        moveToTrashButton
    }

    @ViewBuilder
    private func documentContextMenu(for document: WorkspaceDocument) -> some View {
        renameButton
        locationButtons

        if document.capabilities.canExportPDF {
            Button {
                actions.exportPDF(document)
            } label: {
                Label("Export PDF…", systemImage: MonknotWorkspaceIcons.exportPDF)
            }
        }

        Divider()

        clipboardButtons

        Divider()

        moveToTrashButton
    }

    private var renameButton: some View {
        Button {
            actions.rename(item)
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        .disabled(isBusy)
    }

    @ViewBuilder
    private var locationButtons: some View {
        Button {
            actions.copyPath(item.url)
        } label: {
            Label("Copy Path", systemImage: MonknotWorkspaceIcons.copyPath)
        }

        Button {
            actions.copyRelativePath(item.url)
        } label: {
            Label("Copy Relative Path", systemImage: "doc.on.doc")
        }

        Button {
            actions.revealInFinder(item.url)
        } label: {
            Label("Reveal in Finder", systemImage: MonknotWorkspaceIcons.revealInFinder)
        }
    }

    /// Copy, Cut, Paste and Duplicate, the same for files and folders.
    @ViewBuilder
    private var clipboardButtons: some View {
        Button {
            actions.copy(item.url)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .disabled(isBusy)

        Button {
            actions.cut(item.url)
        } label: {
            Label("Cut", systemImage: "scissors")
        }
        .disabled(isBusy)

        Button {
            actions.paste(visibleNode.destinationURL)
        } label: {
            Label("Paste", systemImage: "doc.on.clipboard")
        }
        .disabled(isBusy)

        Button {
            actions.duplicate(item.url)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        .disabled(isBusy)
    }

    private var moveToTrashButton: some View {
        Button(role: .destructive) {
            actions.moveToTrash(item)
        } label: {
            Label("Move to Trash", systemImage: "trash")
        }
        .disabled(isBusy)
    }

    /// Takes precedence over the row's button, so a drag never also opens the file or toggles the
    /// folder; a click that does not move still does.
    private var sidebarMoveGesture: some Gesture {
        DragGesture(minimumDistance: scaled(4), coordinateSpace: .named(SidebarMoveCoordinateSpace.name))
            .onChanged { value in
                actions.dragChanged(node.id, value.location)
            }
            .onEnded { value in
                actions.dragEnded(node.id, value.location)
            }
    }

    private var fileDropDelegate: SidebarFileDropDelegate {
        SidebarFileDropDelegate(
            workspaceURL: actions.workspaceURL(),
            drop: { urls, copying in actions.dropFileURLs(urls, visibleNode.destinationURL, copying) },
            targetingChanged: { isTargeted in
                actions.dropTargetingChanged(node.id, visibleNode.destinationURL, isTargeted)
            }
        )
    }
}

/// What a Finder drop on the sidebar does, so the drag cursor and the drop agree. An item that is
/// already in the workspace moves, as within a Finder volume, and is copied while Option is held;
/// anything else is copied in.
enum SidebarFileDrop {
    static func copies(_ urls: [URL], workspaceURL: URL?, isOptionPressed: Bool) -> Bool {
        guard let workspaceURL, !isOptionPressed else { return true }
        return !urls.contains { url in
            url.standardizedFileURL != workspaceURL.standardizedFileURL
                && WorkspaceDocumentSupport.isURL(url, containedIn: workspaceURL)
        }
    }

    static func operation(for urls: [URL], workspaceURL: URL?) -> NSDragOperation {
        guard !urls.isEmpty else { return [] }
        let isOptionPressed = NSEvent.modifierFlags.contains(.option)
        return copies(urls, workspaceURL: workspaceURL, isOptionPressed: isOptionPressed) ? .copy : .move
    }

    /// The file URLs of the drag in progress.
    static func draggedFileURLs(on pasteboard: NSPasteboard = NSPasteboard(name: .drag)) -> [URL] {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        return objects.compactMap { ($0 as? NSURL) as URL? }
    }
}

/// A Finder drop on a sidebar row, proposing the operation `SidebarFileDrop` performs.
private struct SidebarFileDropDelegate: DropDelegate {
    let workspaceURL: URL?
    let drop: ([URL], Bool) -> Void
    let targetingChanged: (Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        targetingChanged(true)
    }

    func dropExited(info: DropInfo) {
        targetingChanged(false)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let operation = SidebarFileDrop.operation(
            for: SidebarFileDrop.draggedFileURLs(),
            workspaceURL: workspaceURL
        )
        return DropProposal(operation: operation == .move ? .move : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        targetingChanged(false)
        let urls = SidebarFileDrop.draggedFileURLs()
        guard !urls.isEmpty else { return false }
        drop(urls, SidebarFileDrop.operation(for: urls, workspaceURL: workspaceURL) == .copy)
        return true
    }
}

private struct SidebarScrollContainer<Content: View>: NSViewRepresentable {
    let thumbColor: NSColor
    let revealedRow: SidebarRevealedRow?
    let keyDown: (NSEvent) -> Bool
    let content: Content

    init(
        theme: AppTheme,
        revealedRow: SidebarRevealedRow?,
        keyDown: @escaping (NSEvent) -> Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.thumbColor = MonknotScrollbarStyle.thumbColor(for: theme)
        self.revealedRow = revealedRow
        self.keyDown = keyDown
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> SidebarNativeScrollView<Content> {
        let scrollView = SidebarNativeScrollView<Content>()
        scrollView.thumbColor = thumbColor
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
        guard let hostingView = context.coordinator.hostingView else { return }
        hostingView.rootView = content
        hostingView.keyDownHandler = keyDown
        scrollView.thumbColor = thumbColor

        // A new selection scrolls into view once, after the rows that show it are laid out.
        guard let revealedRow, revealedRow.id != context.coordinator.revealedRowID else { return }
        context.coordinator.revealedRowID = revealedRow.id
        DispatchQueue.main.async { [weak hostingView] in
            guard let hostingView else { return }
            // The hosting view is flipped, so the row's frame is measured from the top as laid out.
            hostingView.layoutSubtreeIfNeeded()
            hostingView.scrollToVisible(revealedRow.frame)
        }
    }

    final class Coordinator {
        var hostingView: SidebarHostingView<Content>?
        var revealedRowID: String?
    }
}

/// The selected row and its frame in the tree, which scrolls it into view.
private struct SidebarRevealedRow {
    let id: String
    let frame: CGRect
}

/// The tree takes keyboard focus when clicked, as a Finder or Xcode outline does, so the Edit
/// menu's Cut, Copy and Paste and the tree's own keys act on the sidebar's selection.
private final class SidebarHostingView<Content: View>: NSHostingView<Content> {
    var keyDownHandler: (NSEvent) -> Bool = { _ in false }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    /// Like a native control, the tree joins the Tab loop only with Full Keyboard Access, so a new
    /// window gives its first focus to the document rather than the sidebar.
    override var canBecomeKeyView: Bool {
        NSApp.isFullKeyboardAccessEnabled && super.canBecomeKeyView
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !keyDownHandler(event) {
            super.keyDown(with: event)
        }
    }
}

/// The keys the focused tree handles itself.
private enum SidebarTreeKeyCommand {
    case rename
    case duplicate
    case moveToTrash

    static let returnKeyCode: UInt16 = 36
    static let enterKeyCode: UInt16 = 76
    static let deleteKeyCode: UInt16 = 51
}

/// A New File or New Folder command for the sidebar's target folder.
enum SidebarNewItemRequest: Equatable {
    case file
    case folder
}

private final class SidebarClipView: NSClipView {
    override var mouseDownCanMoveWindow: Bool {
        false
    }
}

private final class SidebarNativeScrollView<Content: View>: NSScrollView {
    private let chromeScrollerBehavior = MonknotChromeScrollerBehavior()

    var thumbColor: NSColor {
        get { chromeScrollerBehavior.thumbColor }
        set { chromeScrollerBehavior.thumbColor = newValue }
    }

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
        chromeScrollerBehavior.attach(to: self)
    }
}

private extension EnvironmentValues {
    /// True while the pointer is over a sidebar row or the row is held down; its label and glyph
    /// then take one step up the ink ladder (design.md §1.4).
    @Entry var sidebarRowIsHighlighted = false
}

/// Fills a sidebar row: `sel` when selected, `press` while held, `hover` under the pointer.
private struct SidebarRowButtonStyle: ButtonStyle {
    let theme: AppTheme
    let isSelected: Bool
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, theme: theme, isSelected: isSelected, cornerRadius: cornerRadius)
    }

    private struct RowBody: View {
        let configuration: Configuration
        let theme: AppTheme
        let isSelected: Bool
        let cornerRadius: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            // Fill and ink changes animate colour only, here and in SidebarRowLabel, never a frame.
            configuration.label
                .environment(\.sidebarRowIsHighlighted, isHovered || configuration.isPressed)
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .animation(MonknotMotion.hoverAnimation) { $0.foregroundStyle(fill) }
                }
                .onHover { isHovered = $0 }
                .monknotPointerCursor(enabled: isEnabled)
        }

        private var fill: Color {
            MonknotRowButtonStyle.fill(
                theme: theme,
                isSelected: isSelected,
                isActive: false,
                isHovered: isHovered,
                isPressed: configuration.isPressed,
                isEnabled: isEnabled
            )
        }
    }
}

/// A folder or group's disclosure chevron in the 18pt glyph column, nudged per design.md §8.6: the
/// right chevron's ink sits left of centre in its box.
struct SidebarDisclosureChevron: View {
    let isExpanded: Bool
    let theme: AppTheme
    let zoomScale: Double

    private func glyphScaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceGlyph(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: glyphScaled(10), weight: .regular))
            .offset(x: isExpanded ? 0 : glyphScaled(0.5))
            .frame(width: glyphScaled(MonknotMetrics.rowIconColumnWidthBase))
            .accessibilityHidden(true)
    }
}

/// The sidebar's row primitive, design.md §0 and §10.4: 10 padding · 16 per depth · glyph in the 18
/// column · 8 gap · 13 label · 10 padding. A folder's disclosure chevron takes the glyph column, so
/// every row has one glyph, names at one depth share an edge, and a child steps right by one indent.
private struct SidebarRowLabel<Trailing: View>: View {
    enum Leading {
        case disclosure(isExpanded: Bool)
        case kind(systemImage: String)
    }

    let leading: Leading
    let title: String
    let depth: Int
    let isSelected: Bool
    let theme: AppTheme
    let zoomScale: Double
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.sidebarRowIsHighlighted) private var isHighlighted

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        HStack(spacing: scaled(8)) {
            leadingGlyph
                .animation(MonknotMotion.hoverAnimation) { $0.foregroundStyle(glyphColor) }
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: MonknotMetrics.interfaceText(13, theme: theme, zoomScale: zoomScale), weight: .regular))
                .animation(MonknotMotion.hoverAnimation) { $0.foregroundStyle(labelColor) }
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            trailing()
        }
        .padding(.leading, scaled(10) + CGFloat(depth) * scaled(16))
        .padding(.trailing, scaled(10))
        .frame(height: scaled(30))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        switch leading {
        case .disclosure(let isExpanded):
            SidebarDisclosureChevron(isExpanded: isExpanded, theme: theme, zoomScale: zoomScale)
        case .kind(let systemImage):
            MonknotFileKindGlyph(systemImage: systemImage, theme: theme, zoomScale: zoomScale)
        }
    }

    // design.md §1.4: label `ink2` and glyph `ink3` at rest, both `ink` when hovered or held. The
    // selected row's label is `ink` and its glyph `accent` (§1.3). Quiet Sidebar subdues all of it.
    private var labelColor: Color {
        theme.sidebarColor(
            theme.foregroundColor,
            opacity: isSelected || isHighlighted ? 1 : AppTheme.mutedInkOpacity
        )
    }

    private var glyphColor: Color {
        if isSelected {
            return theme.sidebarColor(theme.accentColor)
        }
        return theme.sidebarColor(
            theme.foregroundColor,
            opacity: isHighlighted ? 1 : AppTheme.tertiaryInkOpacity
        )
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
                    .font(.system(size: max(9, size * 0.82), weight: .regular))
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

    var body: some View {
        Button {
            openSettings()
        } label: {
            SidebarRowLabel(
                leading: .kind(systemImage: MonknotWorkspaceIcons.settings),
                title: "Settings",
                depth: 0,
                isSelected: false,
                theme: theme,
                zoomScale: zoomScale
            ) {
                MonknotShortcutLabel(
                    shortcut: "⌘,",
                    theme: theme,
                    zoomScale: zoomScale
                )
            }
        }
        .buttonStyle(SidebarRowButtonStyle(
            theme: theme,
            isSelected: false,
            cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale)
        ))
        .padding(.horizontal, scaled(6))
        .padding(.vertical, scaled(5))
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

    /// Every status letter sits in one badge width, so a status change never moves the row's label.
    static let minimumWidthBase: CGFloat = 16

    var body: some View {
        Text(status.label)
            .font(.system(
                size: MonknotMetrics.interfaceText(10, theme: theme, zoomScale: zoomScale),
                weight: .regular,
                design: .monospaced
            ))
            .foregroundStyle(status.badgeForegroundColor(theme: theme))
            .padding(.horizontal, scaled(4))
            .padding(.vertical, scaled(2))
            .frame(minWidth: scaled(Self.minimumWidthBase))
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
        rowHeight: CGFloat,
        rowSpacing: CGFloat
    ) -> Int {
        guard entryCount > 0, rowHeight > 0 else { return 0 }

        let heightBudget = max(rowHeight, availableSidebarHeight * availableHeightFraction)
        let availableRows = max(1, Int(floor((heightBudget + rowSpacing) / (rowHeight + rowSpacing))))
        return min(entryCount, maximumVisibleRows, availableRows)
    }

    /// The height that shows the visible rows completely: each row plus the spacing between them.
    static func viewportHeight(
        entryCount: Int,
        availableSidebarHeight: CGFloat,
        rowHeight: CGFloat,
        rowSpacing: CGFloat
    ) -> CGFloat {
        let rows = visibleRowCount(
            entryCount: entryCount,
            availableSidebarHeight: availableSidebarHeight,
            rowHeight: rowHeight,
            rowSpacing: rowSpacing
        )
        guard rows > 0 else { return 0 }
        return rowHeight * CGFloat(rows) + rowSpacing * CGFloat(rows - 1)
    }
}

/// A jump list of recently opened documents. It never marks a selection: the open document is always its
/// first entry and the tree already marks it, and design.md §1.3 gives the selected-row accent to one row.
private struct SidebarRecentDocumentsSection: View {
    let entries: [RecentDocumentEntry]
    let theme: AppTheme
    let zoomScale: Double
    let availableSidebarHeight: CGFloat
    let kindGlyph: (RecentDocumentEntry) -> String
    let openDocument: (String) -> Void
    let revealInFinder: (URL) -> Void
    let copyPath: (URL) -> Void
    @State private var isExpanded = false

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    private var rowHeight: CGFloat {
        scaled(30)
    }

    private var rowSpacing: CGFloat {
        scaled(2)
    }

    private var viewportHeight: CGFloat {
        SidebarRecentDocumentsLayoutPolicy.viewportHeight(
            entryCount: entries.count,
            availableSidebarHeight: availableSidebarHeight,
            rowHeight: rowHeight,
            rowSpacing: rowSpacing
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                SidebarGroupHeaderLabel(
                    title: "Recents",
                    count: entries.count,
                    isExpanded: isExpanded,
                    theme: theme,
                    zoomScale: zoomScale
                )
            }
            .buttonStyle(SidebarRowButtonStyle(
                theme: theme,
                isSelected: false,
                cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale)
            ))
            .padding(.horizontal, scaled(6))
            .help(isExpanded ? "Hide recent documents" : "Show recent documents")
            .accessibilityLabel("Recent documents")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                MonknotScrollView(theme: theme) {
                    VStack(alignment: .leading, spacing: rowSpacing) {
                        ForEach(entries, id: \.documentID) { entry in
                            Button {
                                openDocument(entry.documentID)
                            } label: {
                                SidebarRowLabel(
                                    leading: .kind(systemImage: kindGlyph(entry)),
                                    title: entry.displayName,
                                    depth: 1,
                                    isSelected: false,
                                    theme: theme,
                                    zoomScale: zoomScale
                                ) {
                                    EmptyView()
                                }
                            }
                            .buttonStyle(SidebarRowButtonStyle(
                                theme: theme,
                                isSelected: false,
                                cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale)
                            ))
                            .help(entry.relativePath)
                            .contextMenu {
                                recentDocumentContextMenu(for: entry)
                            }
                        }
                    }
                    .padding(.horizontal, scaled(6))
                }
                .frame(height: viewportHeight)
                .padding(.bottom, scaled(6))
            }
        }
    }

    @ViewBuilder
    private func recentDocumentContextMenu(for entry: RecentDocumentEntry) -> some View {
        let url = URL(fileURLWithPath: entry.documentID)

        Button {
            openDocument(entry.documentID)
        } label: {
            Label("Open", systemImage: "doc")
        }

        Divider()

        Button {
            revealInFinder(url)
        } label: {
            Label("Reveal in Finder", systemImage: MonknotWorkspaceIcons.revealInFinder)
        }

        Button {
            copyPath(url)
        } label: {
            Label("Copy Path", systemImage: MonknotWorkspaceIcons.copyPath)
        }
    }
}

/// A collapsible group header in the sidebar: the disclosure chevron in the glyph column, an eyebrow
/// title (design.md §4.3) and a trailing count, on the row primitive's geometry.
private struct SidebarGroupHeaderLabel: View {
    let title: String
    let count: Int
    let isExpanded: Bool
    let theme: AppTheme
    let zoomScale: Double
    @Environment(\.sidebarRowIsHighlighted) private var isHighlighted

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        let ink = theme.sidebarColor(
            theme.foregroundColor,
            opacity: isHighlighted ? 1 : AppTheme.tertiaryInkOpacity
        )
        HStack(spacing: scaled(8)) {
            SidebarDisclosureChevron(isExpanded: isExpanded, theme: theme, zoomScale: zoomScale)

            Text(title)
                .font(MonknotTypography.eyebrow(theme: theme, zoomScale: zoomScale))
                .tracking(MonknotTypography.eyebrowTracking(theme: theme, zoomScale: zoomScale))
                .textCase(.uppercase)

            Spacer(minLength: 0)

            Text("\(count)")
                .font(.system(size: MonknotMetrics.interfaceText(12, theme: theme, zoomScale: zoomScale), weight: .regular))
                .monospacedDigit()
        }
        .foregroundStyle(ink)
        .padding(.horizontal, scaled(10))
        .frame(height: scaled(30))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
    let workspaces: [SavedWorkspaceEntry]
    let isLoadingWorkspace: Bool
    let switchWorkspace: (SavedWorkspaceEntry) -> Void

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    /// The editor area carries the empty state; the sidebar only offers the saved workspaces, as rows
    /// like every other, or a quiet line while one opens.
    var body: some View {
        MonknotScrollView(theme: theme) {
            VStack(alignment: .leading, spacing: scaled(2)) {
                if isLoadingWorkspace {
                    Text("Opening workspace…")
                        .font(.system(size: MonknotMetrics.interfaceText(12, theme: theme, zoomScale: zoomScale)))
                        .foregroundStyle(theme.tertiaryForegroundColor)
                        .padding(.horizontal, scaled(10))
                        .frame(height: scaled(30))
                } else if !availableWorkspaces.isEmpty {
                    Text("Workspaces")
                        .font(MonknotTypography.eyebrow(theme: theme, zoomScale: zoomScale))
                        .tracking(MonknotTypography.eyebrowTracking(theme: theme, zoomScale: zoomScale))
                        .textCase(.uppercase)
                        .foregroundStyle(theme.tertiaryForegroundColor)
                        .padding(.horizontal, scaled(10))
                        .frame(height: scaled(30))
                        .accessibilityAddTraits(.isHeader)

                    ForEach(availableWorkspaces.prefix(5)) { entry in
                        Button {
                            switchWorkspace(entry)
                        } label: {
                            SidebarRowLabel(
                                leading: .kind(systemImage: "folder"),
                                title: entry.displayName,
                                depth: 0,
                                isSelected: false,
                                theme: theme,
                                zoomScale: zoomScale
                            ) {
                                EmptyView()
                            }
                        }
                        .buttonStyle(SidebarRowButtonStyle(
                            theme: theme,
                            isSelected: false,
                            cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale)
                        ))
                        .help((entry.path as NSString).abbreviatingWithTildeInPath)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, scaled(6))
            .padding(.vertical, scaled(6))
        }
        .scrollContentBackground(.hidden)
    }

    private var availableWorkspaces: [SavedWorkspaceEntry] {
        let activePath = workspaceURL?.standardizedFileURL.path
        return workspaces.filter { entry in
            var isDirectory = ObjCBool(false)
            return entry.path != activePath
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
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        MonknotSheetLayout(
            title: "Update Links Before Moving?",
            message: moveSummary,
            theme: theme,
            zoomScale: zoomScale,
            width: 520
        ) {
            VStack(alignment: .leading, spacing: scaled(12)) {
                HStack(spacing: scaled(8)) {
                    Text(review.plan.sourceURL.lastPathComponent)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(theme.tertiaryForegroundColor)
                        .accessibilityHidden(true)
                    Text(review.plan.destinationURL.lastPathComponent)
                }
                .font(MonknotTypography.rowTitle(theme: theme, zoomScale: zoomScale))
                .foregroundStyle(theme.foregroundColor)
                .lineLimit(1)

                MonknotScrollView(theme: theme) {
                    LazyVStack(alignment: .leading, spacing: scaled(12)) {
                        ForEach(Array(review.plan.rewriteFiles.enumerated()), id: \.offset) { _, filePlan in
                            VStack(alignment: .leading, spacing: scaled(6)) {
                                Text(relativePath(for: filePlan.finalURL))
                                    .font(MonknotTypography.rowTitle(theme: theme, zoomScale: zoomScale))
                                    .foregroundStyle(theme.foregroundColor)

                                ForEach(Array(filePlan.rewrites.enumerated()), id: \.offset) { _, rewrite in
                                    HStack(alignment: .firstTextBaseline, spacing: scaled(6)) {
                                        Text(rewrite.oldDestination)
                                            .foregroundStyle(theme.tertiaryForegroundColor)
                                        Image(systemName: "arrow.right")
                                            .font(.system(
                                                size: MonknotMetrics.interfaceGlyph(10, theme: theme, zoomScale: zoomScale)
                                            ))
                                            .foregroundStyle(theme.tertiaryForegroundColor)
                                            .accessibilityHidden(true)
                                        Text(rewrite.newDestination)
                                            .foregroundStyle(theme.foregroundColor)
                                    }
                                    .font(.system(
                                        size: MonknotMetrics.interfaceText(12, theme: theme, zoomScale: zoomScale),
                                        design: .monospaced
                                    ))
                                    .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            if filePlan.originalURL != review.plan.rewriteFiles.last?.originalURL {
                                Rectangle().fill(theme.separatorColor).frame(height: 1)
                            }
                        }
                    }
                }
                .frame(minHeight: scaled(110), maxHeight: scaled(300))
            }
        } buttons: {
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
    let validate: (String) -> String?
    let submitName: (String) -> Void
    @State private var name: String
    @State private var validationMessage: String?
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
        validate: @escaping (String) -> String?,
        submit: @escaping (String) -> Void
    ) {
        self.theme = theme
        self.zoomScale = zoomScale
        self.title = title
        self.message = message
        self.placeholder = placeholder
        self.confirmTitle = confirmTitle
        self.cancel = cancel
        self.validate = validate
        self.submitName = submit
        _name = State(initialValue: initialName)
    }

    private var isNameEmpty: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        MonknotSheetLayout(title: title, message: message, theme: theme, zoomScale: zoomScale, width: 360) {
            VStack(alignment: .leading, spacing: scaled(6)) {
                TextField(placeholder, text: $name)
                    .textFieldStyle(.plain)
                    .font(MonknotTypography.rowTitle(theme: theme, zoomScale: zoomScale))
                    .foregroundStyle(theme.foregroundColor)
                    .focused($isNameFocused)
                    .onSubmit(submit)
                    .padding(.horizontal, scaled(10))
                    .frame(height: MonknotMetrics.interfaceControl(28, theme: theme, zoomScale: zoomScale))
                    .background(
                        RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
                            .fill(theme.insetFillColor)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
                            .strokeBorder(isNameFocused ? theme.accentColor : theme.borderColor, lineWidth: 1)
                    }
                    .onChange(of: name) { _, _ in
                        validationMessage = nil
                    }

                if let validationMessage {
                    Text(validationMessage)
                        .font(.system(size: MonknotMetrics.interfaceText(12, theme: theme, zoomScale: zoomScale)))
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } buttons: {
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
                isDisabled: isNameEmpty,
                action: submit
            )
            .keyboardShortcut(.defaultAction)
        }
        .onAppear {
            isNameFocused = true
        }
    }

    /// Keeps the sheet open with the reason inline when the name cannot be used.
    private func submit() {
        guard !isNameEmpty else { return }
        if let message = validate(name) {
            validationMessage = message
            return
        }
        submitName(name)
    }
}
