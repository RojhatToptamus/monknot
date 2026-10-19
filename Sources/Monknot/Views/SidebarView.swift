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
    /// Each change opens the workspace switcher.
    var workspaceSwitcherRequest = 0
    /// The clipboard the sidebar's Copy, Cut and Paste use.
    var pasteboard: NSPasteboard = .general
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
    /// Whether the clipboard held something to paste when a context menu last opened.
    @State private var treeMouse = SidebarTreeMouse()
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
        followingTree(sidebarColumn)
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
            .onChange(of: store.recentDocumentChangeSerial) { _, _ in
                refreshRecentDocuments()
            }
            .onChange(of: store.workspaceURL?.standardizedFileURL.path ?? "") { _, _ in
                expandedWorkspacePath = nil
                restoreExpandedFoldersIfNeeded()
                refreshRecentDocuments()
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

    /// Keeps the rows and open folders in step with the store's tree, selection and moves.
    private func followingTree(_ content: some View) -> some View {
        content
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
            // The rows come from the tree, which also changes without the documents (an empty folder).
            .onChange(of: store.rootNodeRevision) { _, _ in
                refreshVisibleNodes()
            }
            .onChange(of: store.documentIDRemapEvent?.serial ?? 0) { _, _ in
                followMovedFolders()
            }
            .onChange(of: expandedFolderIDs) { _, _ in
                persistExpandedFolders()
            }
    }

    private var sidebarColumn: some View {
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
                        showWorkspaceSearch: showWorkspaceSearch,
                        switcherRequest: workspaceSwitcherRequest
                    )
                }

                sidebarMainContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .layoutPriority(1)

            SidebarSettingsButton(theme: theme, zoomScale: zoomScale)
                .layoutPriority(2)
        }
        .background(theme.chromeSurfaceColor)
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
            // A right-click anywhere here, as in the tree, checks the clipboard as its menu opens.
            SidebarMenuRegion(canPaste: canPaste) {
                workspaceContent
            }
        }
    }

    /// The tree and Recents, or the empty sidebar.
    @ViewBuilder
    private var workspaceContent: some View {
        let nodes = displayedVisibleNodes

        if !nodes.isEmpty {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    SidebarScrollContainer(
                        theme: theme,
                        revealedRow: revealedRow(in: nodes),
                        keyDown: handleTreeKeyDown(_:),
                        canPaste: canPaste,
                        mouse: treeMouse
                    ) {
                        LazyVStack(alignment: .leading, spacing: scaled(MonknotMetrics.rowGapBase)) {
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
                        .padding(.horizontal, scaled(MonknotMetrics.listGutterBase))
                        .padding(.vertical, scaled(MonknotMetrics.listTopInsetBase))
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
                            location: locationActions
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

    private var sidebarSelectionID: String? {
        store.sidebarSelectionID
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

    /// Keeps a renamed or moved folder, and the folders inside it, open at their new paths.
    private func followMovedFolders() {
        guard let event = store.documentIDRemapEvent else { return }
        let followedFolderIDs = Set(expandedFolderIDs.map(event.remappedPath))
        guard followedFolderIDs != expandedFolderIDs else { return }
        expandedFolderIDs = followedFolderIDs
        refreshVisibleNodes()
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
        let rowHeight = scaled(MonknotMetrics.rowHeightBase)
        let rowPitch = rowHeight + scaled(MonknotMetrics.rowGapBase)
        return SidebarRevealedRow(
            id: selectionID,
            frame: CGRect(x: 0, y: scaled(MonknotMetrics.listTopInsetBase) + CGFloat(index) * rowPitch, width: 1, height: rowHeight)
        )
    }

    /// The tree's own keys while it has keyboard focus: Return renames the selection, ⌘D
    /// duplicates it and ⌘⌫ moves it to the Trash. Cut, Copy and Paste come through the Edit menu.
    /// A held key acts once: its repeats are ignored.
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
        guard !event.isARepeat else { return true }
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
            location: locationActions,
            exportPDF: exportPDF,
            copy: { store.putItemOnPasteboard(at: $0, cutting: false, pasteboard: pasteboard) },
            cut: { store.putItemOnPasteboard(at: $0, cutting: true, pasteboard: pasteboard) },
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

    private var locationActions: SidebarLocationActions {
        SidebarLocationActions(
            copyPath: copyPath,
            copyRelativePath: copyRelativePath,
            revealInFinder: revealInFinder(_:)
        )
    }

    /// The menu of the space around the rows, which acts on the workspace root.
    @ViewBuilder
    private var sidebarContextMenu: some View {
        let isDisabled = store.workspaceURL == nil || store.isBusy
        SidebarMenuItems.newItems(
            isDisabled: isDisabled,
            createFile: { beginCreateFile(in: nil) },
            createFolder: { beginCreateFolder(in: nil) }
        )

        Divider()

        SidebarMenuItems.paste(isDisabled: isDisabled) {
            paste(into: nil)
        }

        if let workspaceURL = store.workspaceURL {
            Divider()

            locationActions.menuItems(for: workspaceURL, includesRelativePath: false)
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

    private func canPaste() -> Bool {
        store.canPaste(from: pasteboard)
    }

    private func paste(into directoryURL: URL?) {
        if !store.pasteFromPasteboard(pasteboard, into: directoryURL) {
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

        let folderURL: URL? = switch target {
        case .root: nil
        case .folder(let folderURL): folderURL
        }
        // As in Finder, holding Option when the drag ends copies the item instead of moving it.
        if treeMouse.modifierFlags.contains(.option) {
            store.duplicateItem(at: row.dropTargetNode.url, into: folderURL)
        } else {
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
            placeholder: "Untitled.md",
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
    var switcherRequest = 0
    @State private var isSwitcherPresented = false

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    private var activeWorkspace: SavedWorkspaceEntry? {
        guard let path = workspaceURL?.standardizedFileURL.path else { return nil }
        return workspaces.first { $0.path == path }
    }

    private var workspaceName: String {
        activeWorkspace?.displayName ?? workspaceURL?.lastPathComponent ?? "No Workspace"
    }

    /// A bar in the list inset (design.md §10.4): the monogram in the rows' glyph column, the name on
    /// their text edge, and the last action ending on the list's edge.
    var body: some View {
        MonknotBar(theme: theme, zoomScale: zoomScale, inset: .list) {
            if workspaceURL != nil {
                Button {
                    isSwitcherPresented.toggle()
                } label: {
                    HStack(spacing: scaled(MonknotMetrics.rowGlyphGapBase)) {
                        // The monogram sits in the rows' glyph column and the name on their text edge.
                        SidebarWorkspaceMonogram(name: workspaceName, isDisabled: isBusy, theme: theme, zoomScale: zoomScale)

                        HStack(spacing: scaled(5)) {
                            // Disabled while a workspace loads: `ink4`, and no hover ink (design.md §5.1).
                            Text(workspaceName)
                                .font(MonknotTypography.panelTitle(theme: theme, zoomScale: zoomScale))
                                .foregroundStyle(
                                    isBusy
                                        ? theme.disabledForegroundColor
                                        : theme.sidebarColor(theme.foregroundColor)
                                )
                                .lineLimit(1)
                                .truncationMode(.tail)

                            // Beside the name, like a pop-up button (design.md §10.4 "name + chevron").
                            SidebarWorkspaceChevron(theme: theme, zoomScale: zoomScale)
                        }
                        .layoutPriority(1)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, scaled(MonknotMetrics.rowPaddingBase))
                    .frame(maxWidth: .infinity)
                    .frame(height: scaled(MonknotMetrics.rowHeightBase))
                }
                .buttonStyle(MonknotListRowButtonStyle(theme: theme, zoomScale: zoomScale, isOpen: isSwitcherPresented))
                .disabled(isBusy)
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
                // On the same edge as a workspace's name, which sits inside a row's padding.
                Text(workspaceName)
                    .font(MonknotTypography.panelTitle(theme: theme, zoomScale: zoomScale))
                    .foregroundStyle(theme.tertiaryForegroundColor)
                    .lineLimit(1)
                    .padding(.horizontal, scaled(MonknotMetrics.rowPaddingBase))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: scaled(MonknotMetrics.rowHeightBase))
                    .layoutPriority(1)
            }

            MonknotIconButton(
                systemImage: MonknotWorkspaceIcons.searchWorkspace,
                label: "Search Workspace",
                theme: theme,
                zoomScale: zoomScale,
                isDisabled: !canSearch,
                action: showWorkspaceSearch
            )

            MonknotIconButton(
                systemImage: "square.and.pencil",
                label: "New Markdown",
                theme: theme,
                zoomScale: zoomScale,
                isDisabled: !canCreateMarkdown,
                action: createMarkdown
            )
        }
        .onChange(of: switcherRequest) { _, _ in
            if workspaceURL != nil, !isBusy {
                isSwitcherPresented = true
            }
        }
    }
}

/// The switcher's chevron beside the workspace name: `ink3` at rest, `ink2` while its row is hovered,
/// held or open, `ink4` while a workspace loads.
private struct SidebarWorkspaceChevron: View {
    let theme: AppTheme
    let zoomScale: Double
    @Environment(\.monknotRowIsHighlighted) private var isHighlighted
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(
                size: MonknotMetrics.interfaceGlyph(MonknotMetrics.chevronPointSizeBase, theme: theme, zoomScale: zoomScale),
                weight: .semibold
            ))
            .symbolRenderingMode(.monochrome)
            .monknotStateStyle(
                !isEnabled
                    ? theme.disabledForegroundColor
                    : (isHighlighted ? theme.mutedForegroundColor : theme.tertiaryForegroundColor)
            )
    }
}

/// The workspace's initial on an accent tile, as Linear marks a workspace (design.md §10.4): it gives
/// the header an anchor and tells windows on different folders apart at a glance.
private struct SidebarWorkspaceMonogram: View {
    let name: String
    let isDisabled: Bool
    let theme: AppTheme
    let zoomScale: Double

    static func initial(of name: String) -> String {
        guard let first = name.first(where: { $0.isLetter || $0.isNumber }) else { return "•" }
        return String(first).uppercased()
    }

    var body: some View {
        let side = MonknotMetrics.interfaceGlyph(18, theme: theme, zoomScale: zoomScale)
        Text(Self.initial(of: name))
            .font(.system(size: MonknotMetrics.interfaceText(10.5, theme: theme, zoomScale: zoomScale), weight: .semibold))
            .foregroundStyle(isDisabled ? theme.disabledForegroundColor : theme.onAccentForegroundColor)
            .frame(width: side, height: side)
            .background(
                isDisabled ? theme.controlTrackFillColor : theme.accentColor,
                in: RoundedRectangle(cornerRadius: theme.chromeRadius(6, zoomScale: zoomScale), style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

/// The workspace switcher (design.md §10.4): a popover menu of the editor's menu rows, 340 wide. The
/// open workspace is the current row with the `accent` folder; each row shows its path and its ⌃⌘
/// shortcut, which Remove replaces under the pointer.
private struct WorkspaceSwitcherPopover: View {
    static let widthBase: CGFloat = 340
    static let visibleRowLimit = 7

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
        MonknotMetrics.interfaceDensity(base, theme: theme, zoomScale: zoomScale)
    }

    /// Up to seven menu rows, 1 apart as in the editor's menus.
    private var workspaceListHeight: CGFloat {
        let visibleCount = CGFloat(min(workspaces.count, Self.visibleRowLimit))
        return scaled(visibleCount * MonknotMetrics.menuRowHeightBase + max(0, visibleCount - 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonknotMenuGroupHeader(title: "Workspaces", theme: theme, zoomScale: zoomScale)

            if workspaces.isEmpty {
                Text("No saved workspaces")
                    .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
                    .foregroundStyle(theme.tertiaryForegroundColor)
                    .padding(.horizontal, scaled(10))
                    .frame(height: scaled(MonknotMetrics.menuRowHeightBase), alignment: .leading)
            } else {
                MonknotScrollView(theme: theme) {
                    LazyVStack(spacing: 1) {
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
                }
                .frame(height: workspaceListHeight)
            }

            MonknotMenuSeparator(theme: theme, zoomScale: zoomScale)

            VStack(spacing: 1) {
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
        }
        .padding(scaled(MonknotMetrics.menuListInsetBase))
        .frame(width: scaled(Self.widthBase))
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
    /// §5.1). The active workspace keeps its current look.
    private var isUnavailable: Bool {
        isBusy && !isActive
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: open) {
                MonknotMenuRowLabel(
                    leading: .glyph(isActive ? "folder.fill" : "folder"),
                    title: workspace.displayName,
                    detail: (workspace.path as NSString).abbreviatingWithTildeInPath,
                    isCurrent: isActive,
                    isDisabled: isUnavailable,
                    theme: theme,
                    zoomScale: zoomScale
                ) {
                    // One width for the trailing slot: the shortcut fades out under Remove instead of
                    // leaving the layout, so the path never re-truncates on hover.
                    ZStack(alignment: .trailing) {
                        Color.clear.frame(
                            width: MonknotIconButton.IconButtonSize.small.dimension(theme: theme, zoomScale: zoomScale),
                            height: 1
                        )
                        if let shortcutIndex {
                            MonknotShortcutLabel(
                                shortcut: "⌃⌘\(shortcutIndex)",
                                theme: theme,
                                zoomScale: zoomScale
                            )
                            .monknotStateOpacity(isHovered ? 0 : 1)
                        }
                    }
                }
            }
            .buttonStyle(MonknotMenuRowButtonStyle(theme: theme, zoomScale: zoomScale, isSelected: isActive))
            .disabled(isBusy || isActive)

            // Crossfades with the shortcut, as a tab's close button does with its glyph.
            MonknotIconButton(
                systemImage: "xmark",
                label: "Remove \(workspace.displayName)",
                theme: theme,
                zoomScale: zoomScale,
                isDisabled: isBusy || !isHovered,
                size: .small,
                focusRingPlacement: .contained,
                action: remove
            )
            // On the row's trailing padding minus the small button's own inset, so its glyph
            // sits where the shortcut's last character was.
            .padding(.trailing, MonknotMetrics.interfaceDensity(MonknotMetrics.menuRowPaddingBase - 4, theme: theme, zoomScale: zoomScale))
            .monknotStateOpacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .accessibilityHidden(!isHovered)
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

    var body: some View {
        Button(action: action) {
            MonknotMenuRowLabel(
                leading: .glyph(systemImage),
                title: title,
                theme: theme,
                zoomScale: zoomScale
            )
        }
        .buttonStyle(MonknotMenuRowButtonStyle(theme: theme, zoomScale: zoomScale))
    }
}

// MARK: - Sidebar Row

/// Copy Path, Copy Relative Path and Reveal in Finder, which every sidebar menu offers for its item.
private struct SidebarLocationActions {
    let copyPath: (URL) -> Void
    let copyRelativePath: (URL) -> Void
    let revealInFinder: (URL) -> Void

    @ViewBuilder
    func menuItems(for url: URL, includesRelativePath: Bool = true) -> some View {
        Button {
            copyPath(url)
        } label: {
            Label("Copy Path", systemImage: MonknotWorkspaceIcons.copyPath)
        }

        if includesRelativePath {
            Button {
                copyRelativePath(url)
            } label: {
                Label("Copy Relative Path", systemImage: "doc.on.doc")
            }
        }

        Button {
            revealInFinder(url)
        } label: {
            Label("Reveal in Finder", systemImage: MonknotWorkspaceIcons.revealInFinder)
        }
    }
}

/// Menu items shared by the row menus and the menu of the space around the rows.
private enum SidebarMenuItems {
    @ViewBuilder
    static func newItems(
        isDisabled: Bool,
        createFile: @escaping () -> Void,
        createFolder: @escaping () -> Void
    ) -> some View {
        Button(action: createFile) {
            Label("New File", systemImage: MonknotWorkspaceIcons.newFile)
        }
        .disabled(isDisabled)

        Button(action: createFolder) {
            Label("New Folder", systemImage: MonknotWorkspaceIcons.newFolder)
        }
        .disabled(isDisabled)
    }

    /// The menu's host disables Paste as the menu opens when the clipboard holds nothing to paste.
    static let pasteTitle = "Paste"

    static func paste(isDisabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(pasteTitle, systemImage: "doc.on.clipboard")
        }
        .disabled(isDisabled)
    }
}

/// What a sidebar row's clicks, drags, drops and context menu do. Folder actions take the deepest
/// folder of a compact row ("A/B" acts on B).
private struct SidebarRowActions {
    let clickFolder: (VisibleSidebarNode) -> Void
    let openDocument: (String) -> Void
    let createFile: (URL) -> Void
    let createFolder: (URL) -> Void
    let rename: (SidebarNode) -> Void
    let location: SidebarLocationActions
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


    var body: some View {
        if node.kind == .folder {
            folderRow
        } else {
            fileRow
        }
    }

    /// Folder row: its disclosure chevron takes the glyph column (design.md §10.4).
    private var folderRow: some View {
        rowButton(
            leading: .disclosure(isExpanded: isExpanded),
            title: visibleNode.displayName,
            action: { actions.clickFolder(visibleNode) }
        ) {
            EmptyView()
        }
        .help(visibleNode.displayRelativePath)
        .accessibilityLabel(folderAccessibilityLabel)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            contextMenuItems
        }
    }

    private var folderAccessibilityLabel: String {
        if visibleNode.folderNodes.count > 1 {
            return "\(visibleNode.displayName), compact folder path"
        }
        return "\(node.name), folder"
    }

    private var fileRow: some View {
        rowButton(
            leading: .kind(systemImage: documentIconName),
            title: node.name,
            action: {
                if let document = node.document {
                    actions.openDocument(document.id)
                }
            }
        ) {
            if let gitStatus {
                GitStatusBadge(status: gitStatus, theme: theme, zoomScale: zoomScale)
            }
        }
        .monknotHelp(isSelected ? nil : (node.relativePath.isEmpty ? node.name : node.relativePath))
        .accessibilityLabel(fileAccessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            if node.document != nil {
                contextMenuItems
            }
        }
    }

    /// The row's button with what folder and file rows share: the move drag, the move-target
    /// outline, its frame while a move is tracked, and Finder drops.
    private func rowButton<Trailing: View>(
        leading: MonknotListRowGlyph,
        title: String,
        action: @escaping () -> Void,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) -> some View {
        Button(action: action) {
            MonknotListRowLabel(
                leading: leading,
                title: title,
                depth: visibleNode.depth,
                isSelected: isSelected,
                status: node.kind == .folder ? .clean : MonknotDocumentStatus(saveState),
                theme: theme,
                zoomScale: zoomScale,
                trailing: trailing
            )
        }
        .buttonStyle(MonknotListRowButtonStyle(theme: theme, zoomScale: zoomScale, isSelected: isSelected))
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

    /// New File and New Folder (in the folder, or beside the file), Rename and the location items,
    /// the clipboard items, then Move to Trash (design.md §10.4).
    @ViewBuilder
    private var contextMenuItems: some View {
        SidebarMenuItems.newItems(
            isDisabled: isBusy,
            createFile: { actions.createFile(visibleNode.destinationURL) },
            createFolder: { actions.createFolder(visibleNode.destinationURL) }
        )

        Divider()

        Button {
            actions.rename(item)
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        .disabled(isBusy)

        actions.location.menuItems(for: item.url)

        if let document = node.document, document.capabilities.canExportPDF {
            Button {
                actions.exportPDF(document)
            } label: {
                Label("Export PDF…", systemImage: MonknotWorkspaceIcons.exportPDF)
            }
        }

        Divider()

        clipboardButtons

        Divider()

        Button(role: .destructive) {
            actions.moveToTrash(item)
        } label: {
            Label("Move to Trash", systemImage: "trash")
        }
        .disabled(isBusy)
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

        SidebarMenuItems.paste(isDisabled: isBusy) {
            actions.paste(visibleNode.destinationURL)
        }

        Button {
            actions.duplicate(item.url)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
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

    /// `DropInfo` hands over file URLs only asynchronously, so the drag pasteboard is read directly.
    private var draggedFileURLs: [URL] {
        NSPasteboard(name: .drag).fileURLs
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let operation = SidebarFileDrop.operation(for: draggedFileURLs, workspaceURL: workspaceURL)
        return DropProposal(operation: operation == .move ? .move : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        targetingChanged(false)
        let urls = draggedFileURLs
        guard !urls.isEmpty else { return false }
        drop(urls, SidebarFileDrop.operation(for: urls, workspaceURL: workspaceURL) == .copy)
        return true
    }
}

private struct SidebarScrollContainer<Content: View>: NSViewRepresentable {
    let thumbColor: NSColor
    let revealedRow: SidebarRevealedRow?
    let keyDown: (NSEvent) -> Bool
    let canPaste: () -> Bool
    let mouse: SidebarTreeMouse
    let content: Content

    init(
        theme: AppTheme,
        revealedRow: SidebarRevealedRow?,
        keyDown: @escaping (NSEvent) -> Bool,
        canPaste: @escaping () -> Bool,
        mouse: SidebarTreeMouse,
        @ViewBuilder content: () -> Content
    ) {
        self.thumbColor = MonknotScrollbarStyle.thumbColor(for: theme)
        self.revealedRow = revealedRow
        self.keyDown = keyDown
        self.canPaste = canPaste
        self.mouse = mouse
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
        hostingView.canPaste = canPaste
        hostingView.mouse = mouse
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

/// The modifier keys of the latest mouse event in the tree, so a row drag that ends reads the keys
/// held as the mouse went up rather than whenever its handler runs.
private final class SidebarTreeMouse {
    var modifierFlags: NSEvent.ModifierFlags = []
}

/// The selected row and its frame in the tree, which scrolls it into view.
private struct SidebarRevealedRow {
    let id: String
    let frame: CGRect
}

/// Sidebar content in its own hosting view, so a right-click in it checks the clipboard as the
/// menu opens.
private struct SidebarMenuRegion<Content: View>: NSViewRepresentable {
    let canPaste: () -> Bool
    let content: Content

    init(canPaste: @escaping () -> Bool, @ViewBuilder content: () -> Content) {
        self.canPaste = canPaste
        self.content = content()
    }

    func makeNSView(context: Context) -> SidebarMenuHostingView<Content> {
        let hostingView = SidebarMenuHostingView(rootView: content)
        // The region fills the space the sidebar gives it, whatever its content measures.
        hostingView.sizingOptions = []
        hostingView.canPaste = canPaste
        return hostingView
    }

    func updateNSView(_ hostingView: SidebarMenuHostingView<Content>, context: Context) {
        hostingView.rootView = content
        hostingView.canPaste = canPaste
    }
}

/// Hosts sidebar content whose context menus offer Paste. SwiftUI builds a menu from the view's
/// last update, which can be older than the clipboard, so Paste is checked as the menu opens.
private class SidebarMenuHostingView<Content: View>: NSHostingView<Content> {
    var canPaste: () -> Bool = { false }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        if let paste = menu?.items.first(where: { $0.title == SidebarMenuItems.pasteTitle }),
           !canPaste() {
            // Without an action the item stays disabled whether or not the menu validates items.
            paste.isEnabled = false
            paste.action = nil
            paste.target = nil
        }
        return menu
    }
}

/// The tree takes keyboard focus when clicked, as a Finder or Xcode outline does, so the Edit
/// menu's Cut, Copy and Paste and the tree's own keys act on the sidebar's selection.
private final class SidebarHostingView<Content: View>: SidebarMenuHostingView<Content> {
    var keyDownHandler: (NSEvent) -> Bool = { _ in false }
    var mouse: SidebarTreeMouse?

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
        mouse?.modifierFlags = event.modifierFlags
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        mouse?.modifierFlags = event.modifierFlags
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        mouse?.modifierFlags = event.modifierFlags
        super.mouseUp(with: event)
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
            MonknotListRowLabel(
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
        .buttonStyle(MonknotListRowButtonStyle(theme: theme, zoomScale: zoomScale))
        .padding(.horizontal, scaled(MonknotMetrics.listGutterBase))
        .padding(.vertical, scaled(6))
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
    let location: SidebarLocationActions
    @State private var isExpanded = false

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    private var rowHeight: CGFloat {
        scaled(MonknotMetrics.rowHeightBase)
    }

    private var rowSpacing: CGFloat {
        scaled(MonknotMetrics.rowGapBase)
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
            .buttonStyle(MonknotListRowButtonStyle(theme: theme, zoomScale: zoomScale))
            .padding(.horizontal, scaled(MonknotMetrics.listGutterBase))
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
                                MonknotListRowLabel(
                                    leading: .kind(systemImage: kindGlyph(entry)),
                                    title: entry.displayName,
                                    depth: 1,
                                    theme: theme,
                                    zoomScale: zoomScale
                                )
                            }
                            .buttonStyle(MonknotListRowButtonStyle(theme: theme, zoomScale: zoomScale))
                            .help(entry.relativePath)
                            .contextMenu {
                                recentDocumentContextMenu(for: entry)
                            }
                        }
                    }
                    .padding(.horizontal, scaled(MonknotMetrics.listGutterBase))
                }
                .frame(height: viewportHeight)
                .padding(.bottom, scaled(6))
            }
        }
    }

    @ViewBuilder
    private func recentDocumentContextMenu(for entry: RecentDocumentEntry) -> some View {
        Button {
            openDocument(entry.documentID)
        } label: {
            Label("Open", systemImage: "doc")
        }

        Divider()

        location.menuItems(for: URL(fileURLWithPath: entry.documentID))
    }
}

/// A collapsible group header in the sidebar: the disclosure chevron in the glyph column, a group
/// header title (design.md §4.3) and a trailing count, on the row primitive's geometry.
private struct SidebarGroupHeaderLabel: View {
    let title: String
    let count: Int
    let isExpanded: Bool
    let theme: AppTheme
    let zoomScale: Double
    @Environment(\.monknotRowIsHighlighted) private var isHighlighted

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.scale(base, theme: theme, zoomScale: zoomScale)
    }

    var body: some View {
        let ink = theme.sidebarColor(
            theme.foregroundColor,
            opacity: isHighlighted ? theme.labelInkOpacity : theme.glyphInkOpacity
        )
        HStack(spacing: scaled(MonknotMetrics.rowGlyphGapBase)) {
            MonknotDisclosureChevron(isExpanded: isExpanded, theme: theme, zoomScale: zoomScale)

            Text(title)
                .font(MonknotTypography.groupHeader(theme: theme, zoomScale: zoomScale))

            Spacer(minLength: 0)

            Text("\(count)")
                .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
                .monospacedDigit()
        }
        .foregroundStyle(ink)
        .padding(.horizontal, scaled(MonknotMetrics.rowPaddingBase))
        .frame(height: scaled(MonknotMetrics.rowHeightBase))
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
        case .deleted: return theme.dangerColor
        case .untracked: return theme.sidebarColor(theme.foregroundColor, opacity: theme.glyphInkOpacity)
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
            VStack(alignment: .leading, spacing: scaled(MonknotMetrics.rowGapBase)) {
                if isLoadingWorkspace {
                    Text("Opening workspace…")
                        .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
                        .foregroundStyle(theme.tertiaryForegroundColor)
                        .padding(.horizontal, scaled(MonknotMetrics.rowPaddingBase))
                        .frame(height: scaled(MonknotMetrics.rowHeightBase))
                } else if !availableWorkspaces.isEmpty {
                    Text("Workspaces")
                        .font(MonknotTypography.groupHeader(theme: theme, zoomScale: zoomScale))
                        .foregroundStyle(theme.tertiaryForegroundColor)
                        .padding(.horizontal, scaled(MonknotMetrics.rowPaddingBase))
                        .frame(height: scaled(MonknotMetrics.rowHeightBase))
                        .accessibilityAddTraits(.isHeader)

                    ForEach(availableWorkspaces.prefix(5)) { entry in
                        Button {
                            switchWorkspace(entry)
                        } label: {
                            MonknotListRowLabel(
                                leading: .kind(systemImage: "folder"),
                                title: entry.displayName,
                                depth: 0,
                                theme: theme,
                                zoomScale: zoomScale
                            )
                        }
                        .buttonStyle(MonknotListRowButtonStyle(theme: theme, zoomScale: zoomScale))
                        .help((entry.path as NSString).abbreviatingWithTildeInPath)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, scaled(MonknotMetrics.listGutterBase))
            .padding(.vertical, scaled(4))
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
                    .monknotField(isFocused: isNameFocused, isInvalid: validationMessage != nil, theme: theme, zoomScale: zoomScale)
                    .onChange(of: name) { _, _ in
                        validationMessage = nil
                    }

                if let validationMessage {
                    Text(validationMessage)
                        .font(MonknotTypography.rowDetail(theme: theme, zoomScale: zoomScale))
                        .foregroundStyle(theme.dangerColor)
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
