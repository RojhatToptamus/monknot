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
    /// Copies the paths of the items, one per line.
    let copyPath: ([URL]) -> Void
    let copyRelativePath: ([URL]) -> Void
    /// A New File or New Folder command from the menu, answered with the name prompt for the
    /// sidebar's target folder.
    @Binding var newItemRequest: SidebarNewItemRequest?
    /// Each change opens the workspace switcher.
    var workspaceSwitcherRequest = 0
    /// Each change selects every row the tree shows: Edit › Select All while the tree has focus.
    var selectAllRequest = 0
    /// The clipboard the sidebar's Copy, Cut and Paste use.
    var pasteboard: NSPasteboard = .general
    @State private var isDropTargeted = false
    @State private var expandedFolderIDs: Set<String> = []
    @State private var expandedWorkspacePath: String?
    @State private var sidebarPrompt: SidebarNamePrompt?
    @State private var sidebarTreeSize: CGSize = .zero
    @State private var sidebarNodeFrames: [String: CGRect] = [:]
    /// The row being dragged; it stays dimmed until its copy has glided back after a cancel.
    @State private var draggedSidebarNodeID: String?
    /// Every item the drag moves, when the dragged row is one of several selected: their rows dim
    /// with it.
    @State private var draggedItemPaths: Set<String> = []
    /// Where a drag over the tree would land, the tree's own or a file drag from elsewhere.
    @State private var moveTarget: SidebarMoveDropTarget?
    @State private var externalDropRowID: String?
    /// Option is held: the drop copies, so the dragged row stays at full strength.
    @State private var dragCopies = false
    @State private var dragSession = SidebarDragSession()
    /// A row whose drag Esc cancelled: the rest of that press drags nothing.
    @State private var cancelledDragRowID: String?
    /// An item a drop is moving or copying, which the tree shows and tints once it has landed.
    @State private var pendingLanding: SidebarPendingLanding?
    @State private var landing: SidebarLanding?
    @State private var recentDocuments: [RecentDocumentEntry] = []
    @State private var visibleNodes: [VisibleSidebarNode] = []
    /// Whether the clipboard held something to paste when a context menu last opened.
    @State private var treeMouse = SidebarTreeMouse()
    /// Names typed while the tree has focus, which select the row they start.
    @State private var typeSelect = SidebarTypeSelect()
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
        draggedSidebarNodeID != nil || externalDropRowID != nil || isDropTargeted || landing != nil
    }

    /// What the tree tints: the target under a drag, or the whole tree for a file drag over the
    /// sidebar that no row has taken.
    private var effectiveMoveTarget: SidebarMoveDropTarget? {
        moveTarget ?? (isDropTargeted ? .root : nil)
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
            .onChange(of: selectAllRequest) { _, _ in
                selectAllRows()
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
                resolvePendingLanding()
            }
            .onChange(of: store.documentIDRemapEvent?.serial ?? 0) { _, _ in
                followMovedFolders()
                resolvePendingLanding()
            }
            // An item Edit › Undo or Redo moved or copied lands as a dropped one does.
            .onChange(of: store.fileOperationLanding) { _, landing in
                guard let landing else { return }
                pendingLanding = SidebarPendingLanding(itemID: landing.itemID, deadline: Date().addingTimeInterval(10))
                resolvePendingLanding()
            }
            .onChange(of: store.isBusy) { _, isBusy in
                if !isBusy {
                    resolvePendingLanding()
                }
            }
            .onChange(of: store.errorMessage) { _, message in
                // A refused move or copy lands nowhere.
                if message != nil {
                    pendingLanding = nil
                }
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
        .background(SidebarDragBounds(session: dragSession))
        .onDisappear {
            dragSession.end()
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
                        let selectedRowIDs = selectedRowIDs(in: nodes)
                        LazyVStack(alignment: .leading, spacing: scaled(MonknotMetrics.rowGapBase)) {
                            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, visibleNode in
                                SidebarNodeRow(
                                    visibleNode: visibleNode,
                                    isSelected: selectedRowIDs.contains(visibleNode.id),
                                    joinsSelectionAbove: index > 0 && selectedRowIDs.contains(nodes[index - 1].id),
                                    joinsSelectionBelow: index + 1 < nodes.count && selectedRowIDs.contains(nodes[index + 1].id),
                                    saveState: visibleNode.node.document.map { store.saveState(for: $0.id) } ?? .clean,
                                    gitStatus: visibleNode.node.document.flatMap { document in
                                        store.gitStatusByRelativePath[document.relativePath]
                                    },
                                    isExpanded: visibleNode.isExpanded(in: expandedFolderIDs),
                                    tracksMoveFrame: tracksSidebarMoveFrames,
                                    isBusy: store.isBusy,
                                    isMoveSource: !dragCopies
                                        && (draggedSidebarNodeID == visibleNode.id || draggedItemPaths.contains(visibleNode.dropTargetNode.id)),
                                    theme: theme,
                                    zoomScale: zoomScale,
                                    actions: rowActions
                                )
                                .equatable()
                            }
                        }
                        .background(alignment: .topLeading) {
                            dropTargetLayer(nodes: nodes)
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
        // A row that just landed scrolls into view, as a new selection does.
        if let landing, landing.opacity > 0,
           let index = nodes.firstIndex(where: { $0.dropTargetFolderID == landing.itemID || $0.id == landing.itemID }) {
            let rowHeight = scaled(MonknotMetrics.rowHeightBase)
            let rowPitch = rowHeight + scaled(MonknotMetrics.rowGapBase)
            return SidebarRevealedRow(
                id: "landing:\(landing.itemID):\(landing.serial)",
                frame: CGRect(x: 0, y: scaled(MonknotMetrics.listTopInsetBase) + CGFloat(index) * rowPitch, width: 1, height: rowHeight)
            )
        }
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

    // MARK: Selecting and the keyboard (design.md §10.4)

    /// The tree's own keys while it has keyboard focus. ↑ and ↓ select the row above or below, ⇧
    /// adding to the selection; ← and → close and open a folder or go to its parent or first
    /// item, ⌥ for every folder inside, ⌘← closes every folder; Home and End go to the first and
    /// last rows; ⌘↑ selects the folder holding the item and ⌘↓ opens what is selected; ⌘A selects
    /// every row; typing a name selects the row it starts. Return renames the item, ⌘D duplicates
    /// and ⌘⌫ moves to the Trash what is selected, once per press however long the key is held.
    /// Cut, Copy and Paste come through the Edit menu, as Select All does in the app.
    private func handleTreeKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let command: SidebarTreeKeyCommand?
        switch event.keyCode {
        case SidebarTreeKeyCommand.returnKeyCode, SidebarTreeKeyCommand.enterKeyCode:
            command = modifiers.isEmpty ? .rename : nil
        case SidebarTreeKeyCommand.deleteKeyCode:
            command = modifiers == .command ? .moveToTrash : nil
        case SidebarTreeKeyCommand.upArrowKeyCode:
            command = switch modifiers {
            case []: .move(-1, extending: false)
            case .shift: .move(-1, extending: true)
            case .command: .selectParent
            default: nil
            }
        case SidebarTreeKeyCommand.downArrowKeyCode:
            command = switch modifiers {
            case []: .move(1, extending: false)
            case .shift: .move(1, extending: true)
            case .command: .open
            default: nil
            }
        case SidebarTreeKeyCommand.homeKeyCode:
            command = modifiers.isEmpty || modifiers == .shift ? .move(Int.min, extending: modifiers == .shift) : nil
        case SidebarTreeKeyCommand.endKeyCode:
            command = modifiers.isEmpty || modifiers == .shift ? .move(Int.max, extending: modifiers == .shift) : nil
        case SidebarTreeKeyCommand.leftArrowKeyCode:
            command = switch modifiers {
            case []: .collapse(recursively: false)
            case .option: .collapse(recursively: true)
            case .command: .collapseAll
            default: nil
            }
        case SidebarTreeKeyCommand.rightArrowKeyCode:
            command = switch modifiers {
            case []: .expand(recursively: false)
            case .option: .expand(recursively: true)
            default: nil
            }
        default:
            if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "d" {
                command = .duplicate
            } else if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "a" {
                command = .selectAll
            } else if modifiers.subtracting(.shift).isEmpty,
                      let characters = event.characters,
                      SidebarTreeKeyCommand.isTypeSelectText(characters),
                      characters != " " || typeSelect.continues(at: event.timestamp) {
                command = .typeSelect(characters)
            } else {
                command = nil
            }
        }
        guard let command else { return false }
        guard !event.isARepeat || command.repeats else { return true }
        // Moving the selection goes on while a file operation runs; changing files waits for it.
        guard !store.isBusy || !command.changesFiles else {
            NSSound.beep()
            return true
        }

        switch command {
        case .rename:
            guard store.sidebarSelectionIDs.count == 1,
                  let selectionID = sidebarSelectionID,
                  shownSelectionURLs() != nil,
                  let item = store.rootNode?.node(withID: selectionID)
            else {
                NSSound.beep()
                return true
            }
            beginRename(item)
        case .duplicate:
            guard let urls = shownSelectionURLs() else {
                NSSound.beep()
                return true
            }
            store.duplicateItems(at: urls)
        case .moveToTrash:
            guard let urls = shownSelectionURLs() else {
                NSSound.beep()
                return true
            }
            store.deleteItems(at: urls)
        case .move(let offset, let extending):
            moveSelection(by: offset, extending: extending)
        case .selectParent:
            selectParentRow()
        case .open:
            openSelection()
        case .collapse(let recursively):
            collapseLeadRow(recursively: recursively)
        case .expand(let recursively):
            expandLeadRow(recursively: recursively)
        case .collapseAll:
            collapseAllFolders()
        case .selectAll:
            selectAllRows()
        case .typeSelect(let characters):
            let nodes = displayedVisibleNodes
            if let itemID = typeSelect.type(
                characters,
                at: event.timestamp,
                rows: nodes.map(\.dropTargetNode.id),
                names: nodes.map(\.displayName),
                leadID: rowSelection(nodes).leadID
            ) {
                store.selectSidebarItems(SidebarSelection(single: itemID))
            }
        }
        return true
    }

    /// A click on a folder row selects the folder (the deepest of a compact row) and opens or
    /// closes it; with ⌘ or ⇧ it only picks the folder (`pickRow`).
    private func clickFolder(_ visibleNode: VisibleSidebarNode) {
        guard !pickRow(visibleNode) else { return }
        store.selectFolder(id: visibleNode.dropTargetNode.id)
        let folderIDs = Set(visibleNode.folderNodeIDs)
        if folderIDs.allSatisfy(expandedFolderIDs.contains) {
            expandedFolderIDs.subtract(folderIDs)
        } else {
            expandedFolderIDs.formUnion(folderIDs)
        }
        refreshVisibleNodes()
    }

    /// A click on a file row opens the file; with ⌘ or ⇧ it only picks the file (`pickRow`).
    private func clickFile(_ documentID: String) {
        if let row = displayedVisibleNodes.first(where: { $0.node.kind == .file && $0.node.id == documentID }),
           pickRow(row) {
            return
        }
        openDocument(documentID)
    }

    /// ⌘-click adds the row's item to the selection or takes it out; ⇧-click selects the rows from
    /// the anchor (the item last clicked) to it. Neither opens anything. True when the click held
    /// either key.
    private func pickRow(_ row: VisibleSidebarNode) -> Bool {
        let modifiers = clickModifiers
        guard modifiers.contains(.command) || modifiers.contains(.shift) else { return false }
        guard !store.isBusy else {
            NSSound.beep()
            return true
        }
        let nodes = displayedVisibleNodes
        let itemID = row.dropTargetNode.id
        if modifiers.contains(.shift) {
            // The rows from the anchor's row: every one of them is shown.
            store.selectSidebarItems(rowSelection(nodes).extending(to: itemID, rows: nodes.map(\.dropTargetNode.id)))
            return true
        }
        // ⌘ adds or takes out the item itself; the items already picked stay exactly as they are.
        let current = store.sidebarItemSelection.isEmpty ? shownOpenDocumentSelection(nodes) : store.sidebarItemSelection
        let shownByRow = current.itemIDs.filter { row.shows($0) }
        store.selectSidebarItems(shownByRow.isEmpty ? current.toggling(itemID) : current.filtered { !shownByRow.contains($0) })
        return true
    }

    /// The open document as a selection while the sidebar selects it and a row shows it.
    private func shownOpenDocumentSelection(_ nodes: [VisibleSidebarNode]) -> SidebarSelection {
        guard let documentID = store.sidebarSelectionID,
              nodes.contains(where: { $0.node.kind == .file && $0.node.id == documentID })
        else { return SidebarSelection() }
        return SidebarSelection(single: documentID)
    }

    /// The paths of every item a row of the tree shows, a compact row's folders included.
    private func shownItemIDs(in nodes: [VisibleSidebarNode]) -> Set<String> {
        var shownIDs = Set<String>()
        for node in nodes {
            shownIDs.insert(node.node.id)
            shownIDs.formUnion(node.folderNodeIDs)
        }
        return shownIDs
    }

    /// What Return, ⌘D and ⌘⌫ act on: the selected items, or nil unless a row shows every one of
    /// them, so a key never changes an item the tree does not show as selected.
    private func shownSelectionURLs() -> [URL]? {
        let selectedIDs = store.sidebarSelectionIDs
        let shownIDs = shownItemIDs(in: displayedVisibleNodes)
        guard !selectedIDs.isEmpty, selectedIDs.allSatisfy(shownIDs.contains) else { return nil }
        return store.sidebarSelectionURLs
    }

    /// Selected items a collapse hid leave the selection, so nothing acts on an item the tree no
    /// longer shows. When none stays shown, the row that now holds the lead is selected instead;
    /// that includes the open document the sidebar selects while nothing else is picked.
    private func dropHiddenSelectedItems() {
        let selection = store.sidebarItemSelection.isEmpty
            ? (store.sidebarSelectionID.map(SidebarSelection.init(single:)) ?? SidebarSelection())
            : store.sidebarItemSelection
        guard !selection.isEmpty else { return }
        let nodes = displayedVisibleNodes
        let shownIDs = shownItemIDs(in: nodes)
        let shown = selection.filtered { shownIDs.contains($0) }
        guard shown != selection else { return }
        if shown.isEmpty, let leadID = selection.leadID,
           let row = nodes.first(where: { WorkspaceDocumentSupport.isPath(leadID, containedIn: $0.node.id) }) {
            store.selectSidebarItems(SidebarSelection(single: row.dropTargetNode.id))
        } else {
            store.selectSidebarItems(shown)
        }
    }

    /// The keys held for the click being handled: those of the tree's latest mouse event, never a
    /// key press's (a button pressed from the keyboard is a plain click).
    private var clickModifiers: NSEvent.ModifierFlags {
        if let event = NSApp.currentEvent, event.type == .keyDown || event.type == .keyUp {
            return []
        }
        return treeMouse.modifierFlags.intersection([.command, .shift])
    }

    /// The rows that show a selected item, by row.
    private func selectedRowIDs(in nodes: [VisibleSidebarNode]) -> Set<String> {
        let selectedIDs = Set(store.sidebarSelectionIDs)
        guard !selectedIDs.isEmpty else { return [] }
        return Set(nodes.lazy.filter { node in
            node.node.kind == .folder
                ? node.folderNodeIDs.contains(where: selectedIDs.contains)
                : selectedIDs.contains(node.node.id)
        }.map(\.id))
    }

    /// The sidebar's selection in terms of rows: each item as the item of the row that shows it, or
    /// of the nearest folder above it the tree shows; the open document stands in when the sidebar
    /// picked nothing.
    private func rowSelection(_ nodes: [VisibleSidebarNode]) -> SidebarSelection {
        var rowItemIDs: [String: String] = [:]
        for node in nodes {
            let itemID = node.dropTargetNode.id
            rowItemIDs[node.node.id] = itemID
            for folderID in node.folderNodeIDs {
                rowItemIDs[folderID] = itemID
            }
        }
        let rootPath = store.rootNode?.id ?? ""
        let selection = store.sidebarItemSelection.isEmpty
            ? (store.sidebarSelectionID.map(SidebarSelection.init(single:)) ?? SidebarSelection())
            : store.sidebarItemSelection
        return selection.mapped { itemID in
            var path = itemID
            while path.count > rootPath.count {
                if let rowItemID = rowItemIDs[path] {
                    return rowItemID
                }
                path = (path as NSString).deletingLastPathComponent
            }
            return itemID
        }
    }

    private func leadRow(_ nodes: [VisibleSidebarNode]) -> VisibleSidebarNode? {
        guard let leadID = rowSelection(nodes).leadID else { return nil }
        return nodes.first { $0.dropTargetNode.id == leadID }
    }

    private func moveSelection(by offset: Int, extending: Bool) {
        let nodes = displayedVisibleNodes
        guard let next = rowSelection(nodes).moving(by: offset, rows: nodes.map(\.dropTargetNode.id), extending: extending) else {
            NSSound.beep()
            return
        }
        store.selectSidebarItems(next)
    }

    /// Edit › Select All in the tree: every row it shows.
    private func selectAllRows() {
        let nodes = displayedVisibleNodes
        guard !nodes.isEmpty, !store.isBusy else { return }
        store.selectSidebarItems(.all(nodes.map(\.dropTargetNode.id), leadID: rowSelection(nodes).leadID))
    }

    /// Selects the row of the folder holding the lead item; nothing at the top level.
    private func selectParentRow() {
        let nodes = displayedVisibleNodes
        guard let row = leadRow(nodes),
              let parent = nodes.first(where: { $0.shows((row.node.id as NSString).deletingLastPathComponent) })
        else {
            NSSound.beep()
            return
        }
        store.selectSidebarItems(SidebarSelection(single: parent.dropTargetNode.id))
    }

    /// ←: closes the lead folder, or else selects the folder holding the item. With ⌥ the folder
    /// and every folder inside it close.
    private func collapseLeadRow(recursively: Bool) {
        let nodes = displayedVisibleNodes
        guard let row = leadRow(nodes) else {
            NSSound.beep()
            return
        }
        if row.node.kind == .folder, row.isExpanded(in: expandedFolderIDs) || recursively {
            let rowPath = row.node.id
            let closing = recursively
                ? expandedFolderIDs.filter { WorkspaceDocumentSupport.isPath($0, containedIn: rowPath) }
                : Set(row.folderNodeIDs)
            expandedFolderIDs.subtract(closing)
            refreshVisibleNodes()
            dropHiddenSelectedItems()
            return
        }
        selectParentRow()
    }

    /// →: opens the lead folder, or else selects the first item inside it. With ⌥ the folder and
    /// every folder inside it open.
    private func expandLeadRow(recursively: Bool) {
        let nodes = displayedVisibleNodes
        guard let row = leadRow(nodes), row.node.kind == .folder else {
            NSSound.beep()
            return
        }
        if recursively {
            expandFolders(Set(row.folderNodeIDs).union(Self.folderIDs(inside: row.dropTargetNode)))
            return
        }
        guard row.isExpanded(in: expandedFolderIDs) else {
            expandFolders(Set(row.folderNodeIDs))
            return
        }
        guard let index = nodes.firstIndex(where: { $0.id == row.id }),
              index + 1 < nodes.count,
              nodes[index + 1].depth > row.depth
        else { return }
        store.selectSidebarItems(SidebarSelection(single: nodes[index + 1].dropTargetNode.id))
    }

    private static func folderIDs(inside node: SidebarNode) -> Set<String> {
        var found: Set<String> = []
        for child in node.children ?? [] where child.kind == .folder {
            found.insert(child.id)
            found.formUnion(folderIDs(inside: child))
        }
        return found
    }

    /// Closes every folder. Selected items inside leave the selection; when none is left shown, the
    /// top-level row holding the lead is selected, so the keyboard goes on from there.
    private func collapseAllFolders() {
        guard !expandedFolderIDs.isEmpty else { return }
        expandedFolderIDs = []
        refreshVisibleNodes()
        dropHiddenSelectedItems()
    }

    /// ⌘↓: opens the selected files, the lead last so its tab shows, and opens the selected
    /// folders in the tree.
    private func openSelection() {
        let nodes = displayedVisibleNodes
        let selection = rowSelection(nodes)
        guard !selection.isEmpty else {
            NSSound.beep()
            return
        }
        let ordered = selection.itemIDs.filter { $0 != selection.leadID } + [selection.leadID].compactMap { $0 }
        var folderIDs: Set<String> = []
        var documentIDs: [String] = []
        for itemID in ordered {
            if store.document(id: itemID) != nil {
                documentIDs.append(itemID)
            } else if let row = nodes.first(where: { $0.dropTargetNode.id == itemID }), row.node.kind == .folder {
                folderIDs.formUnion(row.folderNodeIDs)
            }
        }
        expandFolders(folderIDs)
        documentIDs.forEach(openDocument)
    }

    /// The items a row's menu acts on: every selected item when the row is one of several selected,
    /// otherwise the row's own.
    private func menuTargets(for url: URL) -> [URL] {
        let path = url.standardizedFileURL.path
        let selectedIDs = store.sidebarSelectionIDs
        guard selectedIDs.count > 1, selectedIDs.contains(path) else { return [url] }
        return store.sidebarSelectionURLs
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
            openDocument: clickFile(_:),
            createFile: beginCreateFile(in:),
            createFolder: beginCreateFolder(in:),
            rename: beginRename(_:),
            location: rowLocationActions,
            exportPDF: exportPDF,
            copy: { store.putItemsOnPasteboard(at: menuTargets(for: $0), cutting: false, pasteboard: pasteboard) },
            cut: { store.putItemsOnPasteboard(at: menuTargets(for: $0), cutting: true, pasteboard: pasteboard) },
            paste: paste(into:),
            duplicate: { store.duplicateItems(at: menuTargets(for: $0)) },
            moveToTrash: { item in
                let targets = menuTargets(for: item.url)
                if targets.count > 1 {
                    store.deleteItems(at: targets)
                } else {
                    moveToTrash(item)
                }
            },
            dragChanged: handleSidebarNodeDragChanged(id:location:),
            dragEnded: handleSidebarNodeDragEnded(id:location:),
            dropFileURLs: { urls, directoryURL, copying in
                store.dropFileURLs(urls, into: directoryURL, copying: copying)
            },
            dropTargetingChanged: handleExternalDropTargeting(rowID:directoryURL:isTargeted:),
            workspaceURL: { store.workspaceURL }
        )
    }

    /// The location items of the root's menu and of Recents, which act on that one item.
    private var locationActions: SidebarLocationActions {
        SidebarLocationActions(
            copyPath: { copyPath([$0]) },
            copyRelativePath: { copyRelativePath([$0]) },
            revealInFinder: { revealInFinder([$0]) }
        )
    }

    /// A row's location items, which act on every selected item when the row is one of several.
    private var rowLocationActions: SidebarLocationActions {
        SidebarLocationActions(
            copyPath: { copyPath(menuTargets(for: $0)) },
            copyRelativePath: { copyRelativePath(menuTargets(for: $0)) },
            revealInFinder: { revealInFinder(menuTargets(for: $0)) }
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

        if store.rootNode != nil {
            Divider()

            MonknotMenuCommandButton(.collapseAllFolders) {
                collapseAllFolders()
            }
            .disabled(expandedFolderIDs.isEmpty)
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

    // MARK: Moving files (design.md §10.4)

    private func handleSidebarNodeDragChanged(id: String, location: CGPoint) {
        guard store.workspaceURL != nil, !store.isBusy, cancelledDragRowID != id else { return }
        if dragSession.item == nil, draggedSidebarNodeID == nil {
            guard let row = displayedVisibleNodes.first(where: { $0.id == id }) else { return }
            beginDrag(row)
        }
        guard dragSession.isActive(for: id) else { return }
        dragSession.pointerMoved(toTreePoint: location)
        updateDragTarget()
    }

    /// Starts dragging a row: its item, or every selected item when the row is one of several
    /// selected, as one copy that names how many there are.
    private func beginDrag(_ row: VisibleSidebarNode) {
        let item = row.dropTargetNode
        let urls = menuTargets(for: item.url)
        let systemImage = urls.count > 1
            ? MonknotWorkspaceIcons.dragItems
            : item.kind == .folder
                ? MonknotWorkspaceIcons.openFolder
                : (item.document?.kind.resolvedSystemImage ?? WorkspaceDocumentKind.unsupported.resolvedSystemImage)
        let copies = treeMouse.modifierFlags.contains(.option)
        dragSession.treeView = treeMouse.treeView
        treeMouse.dragSession = dragSession
        draggedSidebarNodeID = row.id
        draggedItemPaths = urls.count > 1 ? Set(urls.map(\.standardizedFileURL.path)) : []
        dragCopies = copies
        dragSession.begin(
            item: SidebarDragSession.Item(
                rowID: row.id,
                url: item.url,
                urls: urls,
                title: urls.count > 1 ? "\(urls.count) Items" : row.displayName,
                systemImage: systemImage
            ),
            copies: copies,
            theme: theme,
            zoomScale: zoomScale,
            handlers: SidebarDragSession.Handlers(
                pointerMoved: { updateDragTarget() },
                copiesChanged: { copies in
                    dragCopies = copies
                    updateDragTarget()
                },
                springOpen: { folderID in expandFolders([folderID]) },
                cancelled: {
                    cancelledDragRowID = row.id
                    setMoveTarget(nil)
                    closeSpringOpenedFolders(keeping: [])
                },
                handedOff: {
                    // The file drag shows its own targets from here, through the rows' drop handling.
                    setMoveTarget(nil)
                },
                handOffEnded: {
                    endDrag()
                },
                returned: {
                    endDrag()
                }
            )
        )
    }

    /// Resolves the target under the pointer, lifts the copy once the row's frame is known, and
    /// springs open the closed folder the pointer rests on.
    private func updateDragTarget() {
        guard let id = draggedSidebarNodeID, dragSession.isActive(for: id), let location = dragSession.treePoint else { return }
        guard let rowFrame = sidebarNodeFrames[id] else { return }
        if let row = displayedVisibleNodes.first(where: { $0.id == id }) {
            dragSession.liftCopy(rowFrame: rowFrame, depth: row.depth)
        }
        let target = moveDropTarget(forRow: id, at: location)
        setMoveTarget(target)
        dragSession.springLoad(folderID: springLoadableFolderID(at: location, target: target))
    }

    /// The closed folder row under `location` that `target` would drop into, which spring-loading
    /// opens; nil anywhere else.
    private func springLoadableFolderID(at location: CGPoint, target: SidebarMoveDropTarget?) -> String? {
        guard let target, case .folder = target,
              let row = displayedVisibleNodes.first(where: { sidebarNodeFrames[$0.id]?.contains(location) == true }),
              row.node.kind == .folder,
              !row.isExpanded(in: expandedFolderIDs),
              row.dropTargetFolderID == target.folderID
        else { return nil }
        return row.dropTargetFolderID
    }

    /// A new target cross-fades with the last one; a frame that moves with the rows does not animate.
    private func setMoveTarget(_ target: SidebarMoveDropTarget?) {
        guard target != moveTarget else { return }
        withAnimation(.easeOut(duration: MonknotMotion.hoverDuration)) {
            moveTarget = target
        }
    }

    private func handleSidebarNodeDragEnded(id: String, location: CGPoint) {
        if cancelledDragRowID == id {
            cancelledDragRowID = nil
            return
        }
        guard dragSession.isActive(for: id) else { return }
        // The keys held as the button came up: the gesture ends before the tree's own mouse-up
        // handler runs, so the drag's live state is the one that is current.
        let copies = dragSession.copies
        let point = dragSession.treePoint ?? location
        guard !store.isBusy,
              sidebarNodeFrames[id] != nil,
              let dragged = dragSession.item,
              let target = moveDropTarget(forRow: id, at: point, copies: copies)
        else {
            // Nowhere to land: the copy glides back, and nothing changes on disk.
            setMoveTarget(nil)
            closeSpringOpenedFolders(keeping: [])
            dragSession.finishWithoutTarget()
            return
        }

        let folderURL: URL? = switch target {
        case .root: nil
        case .folder(let folderURL): folderURL
        }
        let urls = dragged.urls
        let destinationPath = (folderURL ?? store.workspaceURL)?.standardizedFileURL.path ?? ""
        let landedID = (destinationPath as NSString).appendingPathComponent(dragged.url.lastPathComponent)
        closeSpringOpenedFolders(keeping: ancestorFolderIDs(of: landedID))
        dragSession.finishDropped()
        endDrag()
        // As in Finder, holding Option when the drag ends copies the items instead of moving them.
        if copies {
            pendingLanding = SidebarPendingLanding(itemID: nil, deadline: Date().addingTimeInterval(10))
            store.duplicateItems(at: urls, into: folderURL)
        } else if urls.count > 1 {
            // The dragged row lands; the rest move one after another, as a drop of them does.
            pendingLanding = SidebarPendingLanding(itemID: landedID, deadline: Date().addingTimeInterval(10))
            store.dropFileURLs(urls, into: folderURL)
        } else {
            pendingLanding = SidebarPendingLanding(itemID: landedID, deadline: Date().addingTimeInterval(10))
            store.moveItem(id: dragged.url.standardizedFileURL.path, toDirectory: folderURL)
        }
        resolvePendingLanding()
    }

    private func endDrag() {
        draggedSidebarNodeID = nil
        draggedItemPaths = []
        dragCopies = false
        setMoveTarget(nil)
        dragSession.clearSpringOpenedFolders()
        if pendingLanding == nil, landing == nil, externalDropRowID == nil {
            sidebarNodeFrames = [:]
        }
    }

    /// Spring-opened folders close again, except those the drop landed in.
    private func closeSpringOpenedFolders(keeping keptIDs: Set<String>) {
        let closing = dragSession.springOpenedFolderIDs.subtracting(keptIDs)
        dragSession.clearSpringOpenedFolders()
        guard !closing.isEmpty else { return }
        expandedFolderIDs.subtract(closing)
        refreshVisibleNodes()
        dropHiddenSelectedItems()
    }

    /// Once a moved or copied item shows in the tree: its folders open, it scrolls into view and its
    /// row holds the drop tint, letting it go over 900 ms (design.md §10.4).
    private func resolvePendingLanding() {
        guard let pending = pendingLanding else { return }
        guard pending.deadline > Date() else {
            pendingLanding = nil
            return
        }
        // A copy is selected where it lands; a move keeps the selection, so it is found by its path.
        let itemID = pending.itemID ?? (store.isBusy ? nil : sidebarSelectionID)
        guard let itemID, !store.isBusy else { return }
        expandFolders(ancestorFolderIDs(of: itemID))
        guard displayedVisibleNodes.contains(where: { $0.dropTargetFolderID == itemID || $0.id == itemID }) else { return }
        pendingLanding = nil
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            landing = SidebarLanding(itemID: itemID, opacity: 0)
            return
        }
        let serial = (landing?.serial ?? 0) + 1
        landing = SidebarLanding(itemID: itemID, opacity: 1, serial: serial)
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: SidebarLanding.duration)) {
                landing?.opacity = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + SidebarLanding.duration + 0.1) {
            if landing?.serial == serial {
                landing = nil
                if draggedSidebarNodeID == nil, externalDropRowID == nil {
                    sidebarNodeFrames = [:]
                }
            }
        }
    }

    /// The drop target's region behind the rows, `accsoft` on the row radius inside the list inset:
    /// a folder's row with its open contents, or the whole tree for the root; and a landed row's tint.
    @ViewBuilder
    private func dropTargetLayer(nodes: [VisibleSidebarNode]) -> some View {
        let radius = theme.chromeRadius(MonknotMetrics.iconCornerRadiusBase, zoomScale: zoomScale)
        ZStack(alignment: .topLeading) {
            if let target = effectiveMoveTarget, let frame = dropRegionFrame(for: target, nodes: nodes) {
                RoundedRectangle(cornerRadius: radius)
                    .fill(theme.accentSoftFillColor)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .id(target)
                    .transition(.opacity)
            }
            if let landing,
               let row = nodes.first(where: { $0.dropTargetFolderID == landing.itemID || $0.id == landing.itemID }),
               let frame = sidebarNodeFrames[row.id] {
                RoundedRectangle(cornerRadius: radius)
                    .fill(theme.accentSoftFillColor)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .opacity(landing.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The region `target` covers, in the rows' coordinates (the background's own origin is the
    /// list's, inside its inset).
    private func dropRegionFrame(for target: SidebarMoveDropTarget, nodes: [VisibleSidebarNode]) -> CGRect? {
        let gutter = scaled(MonknotMetrics.listGutterBase)
        let top = scaled(MonknotMetrics.listTopInsetBase)
        func local(_ frame: CGRect) -> CGRect {
            frame.offsetBy(dx: -gutter, dy: -top)
        }
        switch target {
        case .root:
            let frames = nodes.compactMap { sidebarNodeFrames[$0.id] }
            guard let first = frames.first else { return nil }
            let union = frames.reduce(first) { $0.union($1) }
            // The root is the whole tree, its empty space below the rows included.
            let bottom = max(union.maxY, sidebarTreeSize.height - top)
            return local(CGRect(x: union.minX, y: union.minY, width: union.width, height: bottom - union.minY))
        case .folder(let url):
            let folderPath = url.standardizedFileURL.path
            let rows = nodes.filter { row in
                row.dropTargetFolderID == folderPath || row.node.url.standardizedFileURL.path.hasPrefix(folderPath + "/")
            }
            let frames = rows.compactMap { sidebarNodeFrames[$0.id] }
            guard let first = frames.first else { return nil }
            return local(frames.reduce(first) { $0.union($1) })
        }
    }

    private func moveDropTarget(forRow rowID: String, at location: CGPoint, copies: Bool? = nil) -> SidebarMoveDropTarget? {
        guard let workspaceURL = store.workspaceURL else { return nil }
        return SidebarMoveDropTarget.resolve(
            draggedRowID: rowID,
            draggedItemURLs: dragSession.item?.urls ?? [],
            location: location,
            rows: displayedVisibleNodes,
            rowFrames: sidebarNodeFrames,
            treeSize: sidebarTreeSize,
            workspaceURL: workspaceURL,
            copies: copies ?? dragCopies
        )
    }

    /// Tints the folder a file drag over a row would land in (the root for a root file), and springs
    /// a closed folder open as the tree's own drag does. A drop that would change nothing tints
    /// nothing (`SidebarFileDrop.changesNothing`).
    private func handleExternalDropTargeting(rowID: String, directoryURL: URL, isTargeted: Bool) {
        if isTargeted {
            externalDropRowID = rowID
            let isRoot = directoryURL.standardizedFileURL == store.workspaceURL?.standardizedFileURL
            let urls = NSPasteboard(name: .drag).fileURLs
            let changesNothing = SidebarFileDrop.changesNothing(urls, destinationURL: directoryURL)
            setMoveTarget(changesNothing ? nil : (isRoot ? .root : .folder(directoryURL.standardizedFileURL)))
            let row = displayedVisibleNodes.first { $0.id == rowID }
            let springFolderID = row.flatMap { row -> String? in
                guard !changesNothing, row.node.kind == .folder, !row.isExpanded(in: expandedFolderIDs) else { return nil }
                return row.dropTargetFolderID
            }
            dragSession.externalTargeting(folderID: springFolderID) { folderID in
                expandFolders([folderID])
            }
        } else if externalDropRowID == rowID {
            externalDropRowID = nil
            setMoveTarget(nil)
            dragSession.externalTargeting(folderID: nil) { _ in }
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

    private func revealInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
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

/// An item a drop is moving (found by the path it will have) or copying (found as the selection the
/// copy takes), until it shows in the tree or the deadline passes.
struct SidebarPendingLanding: Equatable {
    let itemID: String?
    let deadline: Date
}

/// A row that just landed: it holds the drop tint and lets it go.
struct SidebarLanding: Equatable {
    static let duration: Double = 0.9

    let itemID: String
    var opacity: Double
    var serial = 0
}

/// Where a dragged sidebar row moves its item.
enum SidebarMoveDropTarget: Hashable {
    case folder(URL)
    case root

    var folderID: String? {
        guard case .folder(let url) = self else { return nil }
        return url.standardizedFileURL.path
    }

    /// The target under `location`, in the tree's coordinate space: a folder row is that folder (the
    /// deepest of a compact row), a file row is the file's folder, and empty tree space below the
    /// rows is the root. Nil where every dragged item already is (unless `copies`, which duplicates
    /// them there, as Finder does), on a dragged item itself or anything inside one, and anywhere
    /// else. `draggedItemURLs` are the items dragged with the row when it is one of several selected.
    static func resolve(
        draggedRowID: String,
        draggedItemURLs: [URL] = [],
        location: CGPoint,
        rows: [VisibleSidebarNode],
        rowFrames: [String: CGRect],
        treeSize: CGSize,
        workspaceURL: URL,
        copies: Bool = false
    ) -> SidebarMoveDropTarget? {
        guard let draggedRow = rows.first(where: { $0.id == draggedRowID }) else { return nil }
        let itemPaths = Set([draggedRow.dropTargetNode.url.standardizedFileURL.path] + draggedItemURLs.map(\.standardizedFileURL.path))

        let destinationURL: URL
        if let row = rows.first(where: { rowFrames[$0.id]?.contains(location) == true }) {
            guard row.id != draggedRowID, !itemPaths.contains(row.dropTargetNode.url.standardizedFileURL.path) else { return nil }
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
        guard copies || itemPaths.contains(where: { destinationPath != ($0 as NSString).deletingLastPathComponent }),
              !itemPaths.contains(where: { destinationPath == $0 || destinationPath.hasPrefix($0 + "/") })
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

    private var switcher: WorkspaceSwitcherPopover {
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
                .monknotPopover(
                    isPresented: $isSwitcherPresented,
                    label: "Workspaces",
                    contentKind: .list,
                    listRows: switcher.listRows,
                    theme: theme,
                    zoomScale: zoomScale
                ) {
                    switcher
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
                    // A value control's chevron rests at `ink3` and goes to `ink` with its control
                    // (design.md §5.3), as the label beside it does.
                    : (isHighlighted ? theme.foregroundColor : theme.tertiaryForegroundColor)
            )
    }
}

/// The workspace's initial on an accent tile (design.md §10.4): it gives the header an anchor and
/// tells windows on different folders apart at a glance.
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

/// The workspace switcher (design.md §10.4): a list popover of the editor's menu rows, 340 wide, on
/// Monknot's popover surface (§5.9). The open workspace is the current row with the `accent` folder;
/// each row shows its path and its ⌃⌘ shortcut, which Remove replaces on the highlighted row and under
/// the pointer. The keys, the pointer and keyboard focus move one highlight (`MonknotPopoverListModel`).
private struct WorkspaceSwitcherPopover: View {
    static let widthBase: CGFloat = 340
    static let visibleRowLimit = 7
    static let addRowID = "add-workspace"
    static let manageRowID = "manage-workspaces"

    let workspaces: [SavedWorkspaceEntry]
    let activeWorkspacePath: String?
    let isBusy: Bool
    let theme: AppTheme
    let zoomScale: Double
    let switchWorkspace: (SavedWorkspaceEntry) -> Void
    let addWorkspace: () -> Void
    let removeWorkspace: (SavedWorkspaceEntry) -> Void
    let manageWorkspaces: () -> Void
    @EnvironmentObject private var list: MonknotPopoverListModel
    @FocusState private var focusedRow: String?
    /// The workspace row whose Remove has keyboard focus.
    @State private var focusedRemove: String?

    static func rowID(_ workspace: SavedWorkspaceEntry) -> String {
        workspace.id.uuidString
    }

    /// The rows the keys move over, in the order they show. The open workspace, and every workspace
    /// while one loads, cannot be chosen.
    var listRows: [MonknotPopoverListRow] {
        workspaces.map { workspace in
            MonknotPopoverListRow(
                id: Self.rowID(workspace),
                title: workspace.displayName,
                isEnabled: !isBusy && workspace.path != activeWorkspacePath,
                choose: { switchWorkspace(workspace) },
                remove: { removeWorkspace(workspace) }
            )
        } + [
            MonknotPopoverListRow(id: Self.addRowID, title: "Add Workspace…", choose: addWorkspace),
            MonknotPopoverListRow(id: Self.manageRowID, title: "Manage Workspaces…", choose: manageWorkspaces),
        ]
    }

    private var keyboardFocus: MonknotPopoverListModel.Focus? {
        if let focusedRow {
            return .row(focusedRow)
        }
        return focusedRemove == nil ? nil : .control
    }

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
                ScrollViewReader { proxy in
                    MonknotScrollView(theme: theme) {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(workspaces.enumerated()), id: \.element.id) { index, workspace in
                                let rowID = Self.rowID(workspace)
                                WorkspaceSwitcherRow(
                                    workspace: workspace,
                                    rowID: rowID,
                                    shortcutIndex: index < 9 ? index + 1 : nil,
                                    isActive: workspace.path == activeWorkspacePath,
                                    isBusy: isBusy,
                                    isHighlighted: list.highlighted == rowID,
                                    isUnderPointer: list.pointerRow == rowID,
                                    theme: theme,
                                    zoomScale: zoomScale,
                                    list: list,
                                    focus: $focusedRow,
                                    removeFocusChanged: { isFocused in
                                        if isFocused {
                                            focusedRemove = rowID
                                        } else if focusedRemove == rowID {
                                            focusedRemove = nil
                                        }
                                    },
                                    open: { switchWorkspace(workspace) },
                                    remove: { removeWorkspace(workspace) }
                                )
                                .id(rowID)
                            }
                        }
                    }
                    .frame(height: workspaceListHeight)
                    // Past seven rows the list scrolls: the keys keep their row in view.
                    .onChange(of: list.keyboardMoves) { _, _ in
                        if let id = list.highlighted {
                            proxy.scrollTo(id)
                        }
                    }
                }
            }

            MonknotMenuSeparator(theme: theme, zoomScale: zoomScale)

            VStack(spacing: 1) {
                WorkspaceSwitcherActionRow(
                    rowID: Self.addRowID,
                    title: "Add Workspace…",
                    systemImage: "folder.badge.plus",
                    isHighlighted: list.highlighted == Self.addRowID,
                    theme: theme,
                    zoomScale: zoomScale,
                    list: list,
                    focus: $focusedRow,
                    action: addWorkspace
                )

                WorkspaceSwitcherActionRow(
                    rowID: Self.manageRowID,
                    title: "Manage Workspaces…",
                    systemImage: "gearshape",
                    isHighlighted: list.highlighted == Self.manageRowID,
                    theme: theme,
                    zoomScale: zoomScale,
                    list: list,
                    focus: $focusedRow,
                    action: manageWorkspaces
                )
            }
        }
        .padding(scaled(MonknotMetrics.menuListInsetBase))
        .frame(width: scaled(Self.widthBase))
        .onChange(of: focusedRow) { _, _ in
            list.focusMoved(to: keyboardFocus)
        }
        .onChange(of: focusedRemove) { _, _ in
            list.focusMoved(to: keyboardFocus)
        }
        .onChange(of: list.keyboardMoves) { _, _ in
            // With Full Keyboard Access, focus follows the keys, so Tab goes on from the highlighted row.
            if keyboardFocus != nil, let id = list.highlighted, focusedRow != id {
                focusedRow = id
            }
        }
    }
}

private struct WorkspaceSwitcherRow: View {
    let workspace: SavedWorkspaceEntry
    let rowID: String
    let shortcutIndex: Int?
    let isActive: Bool
    let isBusy: Bool
    /// The list's one highlight is on this row (design.md §5.9).
    let isHighlighted: Bool
    /// The pointer last moved onto this row, which may be the open workspace's.
    let isUnderPointer: Bool
    let theme: AppTheme
    let zoomScale: Double
    let list: MonknotPopoverListModel
    let focus: FocusState<String?>.Binding
    let removeFocusChanged: (Bool) -> Void
    let open: () -> Void
    let remove: () -> Void
    @State private var isRemoveFocused = false

    /// Another workspace is loading, so this one cannot open yet: `ink4` and no hover ink (design.md
    /// §5.1). The active workspace keeps its current look.
    private var isUnavailable: Bool {
        isBusy && !isActive
    }

    /// Remove shows on the highlighted row, so ⌫ reads as removing it, under the pointer, and while it
    /// has keyboard focus, so Tab reaches it (design.md §5.9).
    private var showsRemove: Bool {
        isHighlighted || isUnderPointer || isRemoveFocused
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
                            .monknotStateOpacity(showsRemove ? 0 : 1)
                        }
                    }
                }
            }
            // The current workspace is marked by its accent `folder.fill` alone (design.md §1.3), so
            // the one highlight is the list's.
            .buttonStyle(MonknotMenuRowButtonStyle(theme: theme, zoomScale: zoomScale, isHighlighted: isHighlighted))
            .focused(focus, equals: rowID)
            .focusEffectDisabled()
            .disabled(isBusy || isActive)
            .accessibilityAction(named: "Remove") {
                if !isBusy {
                    remove()
                }
            }

            // Crossfades with the shortcut, as a tab's close button does with its glyph.
            MonknotIconButton(
                systemImage: "xmark",
                label: "Remove \(workspace.displayName)",
                theme: theme,
                zoomScale: zoomScale,
                isDisabled: isBusy || !showsRemove,
                size: .small,
                focusRingPlacement: .contained,
                onFocusChange: { isFocused in
                    isRemoveFocused = isFocused
                    removeFocusChanged(isFocused)
                },
                action: remove
            )
            // On the row's trailing padding minus the small button's own inset, so its glyph
            // sits where the shortcut's last character was.
            .padding(.trailing, MonknotMetrics.interfaceDensity(MonknotMetrics.menuRowPaddingBase - 4, theme: theme, zoomScale: zoomScale))
            .monknotStateOpacity(showsRemove ? 1 : 0)
            .allowsHitTesting(showsRemove)
            // VoiceOver reaches Remove through the row's action.
            .accessibilityHidden(true)
        }
        .monknotPopoverListHover(rowID, in: list)
        .accessibilityElement(children: .contain)
    }
}

private struct WorkspaceSwitcherActionRow: View {
    let rowID: String
    let title: String
    let systemImage: String
    let isHighlighted: Bool
    let theme: AppTheme
    let zoomScale: Double
    let list: MonknotPopoverListModel
    let focus: FocusState<String?>.Binding
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
        .buttonStyle(MonknotMenuRowButtonStyle(theme: theme, zoomScale: zoomScale, isHighlighted: isHighlighted))
        .focused(focus, equals: rowID)
        .focusEffectDisabled()
        .monknotPopoverListHover(rowID, in: list)
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
        MonknotMenuCommandButton(.copyPath) {
            copyPath(url)
        }

        if includesRelativePath {
            MonknotMenuCommandButton(.copyRelativePath) {
                copyRelativePath(url)
            }
        }

        MonknotMenuCommandButton(.revealInFinder) {
            revealInFinder(url)
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
        MonknotMenuCommandButton(.newFile, action: createFile)
            .disabled(isDisabled)

        MonknotMenuCommandButton(.newFolder, action: createFolder)
            .disabled(isDisabled)
    }

    /// The menu's host disables Paste as the menu opens when the clipboard holds nothing to paste.
    static let pasteTitle = MonknotMenuCommand.paste.title

    static func paste(isDisabled: Bool, action: @escaping () -> Void) -> some View {
        MonknotMenuCommandButton(.paste, action: action)
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
            lhs.joinsSelectionAbove == rhs.joinsSelectionAbove &&
            lhs.joinsSelectionBelow == rhs.joinsSelectionBelow &&
            lhs.saveState == rhs.saveState &&
            lhs.gitStatus == rhs.gitStatus &&
            lhs.isExpanded == rhs.isExpanded &&
            lhs.tracksMoveFrame == rhs.tracksMoveFrame &&
            lhs.isBusy == rhs.isBusy &&
            lhs.isMoveSource == rhs.isMoveSource &&
            lhs.zoomScale == rhs.zoomScale &&
            lhs.theme == rhs.theme
    }
}

private struct SidebarNodeRow: View {
    let visibleNode: VisibleSidebarNode
    let isSelected: Bool
    /// The rows above and below are selected too, so the selection fills join (design.md §10.4).
    let joinsSelectionAbove: Bool
    let joinsSelectionBelow: Bool
    let saveState: DocumentSaveState
    let gitStatus: WorkspaceGitFileStatus?
    let isExpanded: Bool
    let tracksMoveFrame: Bool
    let isBusy: Bool
    /// Being dragged to move: the row stays where it is at 35 % until the move lands.
    let isMoveSource: Bool
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

    /// The row's button with what folder and file rows share: the move drag, its frame while a move
    /// is tracked, and file drops.
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
        .buttonStyle(MonknotListRowButtonStyle(
            theme: theme,
            zoomScale: zoomScale,
            isSelected: isSelected,
            hasContextMenu: true,
            joinsSelectionAbove: joinsSelectionAbove,
            joinsSelectionBelow: joinsSelectionBelow
        ))
        .background {
            if tracksMoveFrame {
                SidebarNodeFrameReader(id: node.id)
            }
        }
        .monknotStateOpacity(isMoveSource ? 0.35 : 1)
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

        MonknotMenuCommandButton(.rename) {
            actions.rename(item)
        }
        .disabled(isBusy)

        actions.location.menuItems(for: item.url)

        if let document = node.document, document.capabilities.canExportPDF {
            MonknotMenuCommandButton(.exportPDF) {
                actions.exportPDF(document)
            }
        }

        Divider()

        clipboardButtons

        Divider()

        MonknotMenuCommandButton(.moveToTrash) {
            actions.moveToTrash(item)
        }
        .disabled(isBusy)
    }

    /// Copy, Cut, Paste and Duplicate, the same for files and folders.
    @ViewBuilder
    private var clipboardButtons: some View {
        MonknotMenuCommandButton(.copy) {
            actions.copy(item.url)
        }
        .disabled(isBusy)

        MonknotMenuCommandButton(.cut) {
            actions.cut(item.url)
        }
        .disabled(isBusy)

        SidebarMenuItems.paste(isDisabled: isBusy) {
            actions.paste(visibleNode.destinationURL)
        }

        MonknotMenuCommandButton(.duplicate) {
            actions.duplicate(item.url)
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
            destinationURL: visibleNode.destinationURL,
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

    /// A drop of `urls` into `destinationURL` would change nothing, or cannot happen: an item into
    /// the folder it is already in, onto itself, or a folder into a folder inside it.
    static func changesNothing(_ urls: [URL], destinationURL: URL) -> Bool {
        guard !urls.isEmpty else { return false }
        let destination = destinationURL.standardizedFileURL.path
        return urls.allSatisfy { url in
            let path = url.standardizedFileURL.path
            return destination == (path as NSString).deletingLastPathComponent
                || destination == path
                || destination.hasPrefix(path + "/")
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
    let destinationURL: URL
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
        let urls = draggedFileURLs
        // Where it already is, or into itself: no badge, and a release slides the drag back.
        if SidebarFileDrop.changesNothing(urls, destinationURL: destinationURL),
           SidebarFileDrop.operation(for: urls, workspaceURL: workspaceURL) == .move {
            return DropProposal(operation: .forbidden)
        }
        let operation = SidebarFileDrop.operation(for: urls, workspaceURL: workspaceURL)
        return DropProposal(operation: operation == .move ? .move : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        targetingChanged(false)
        let urls = draggedFileURLs
        guard !urls.isEmpty else { return false }
        if SidebarFileDrop.changesNothing(urls, destinationURL: destinationURL),
           SidebarFileDrop.operation(for: urls, workspaceURL: workspaceURL) == .move {
            return false
        }
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
        mouse.treeView = hostingView
        return scrollView
    }

    func updateNSView(_ scrollView: SidebarNativeScrollView<Content>, context: Context) {
        guard let hostingView = context.coordinator.hostingView else { return }
        hostingView.rootView = content
        hostingView.keyDownHandler = keyDown
        hostingView.canPaste = canPaste
        hostingView.mouse = mouse
        mouse.treeView = hostingView
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
    /// The tree's hosting view, in whose coordinates the rows lie.
    weak var treeView: NSView?
    /// The drag under way, which the hosting view hands to a file drag when it leaves the sidebar.
    weak var dragSession: SidebarDragSession?
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
        if let session = mouse?.dragSession, session.isActive {
            session.setCopies(event.modifierFlags.contains(.option))
            // Out of the sidebar the item becomes a file drag, for the terminal, an editor or Finder.
            if session.leavesSidebar(at: event.locationInWindow) {
                session.handOff(event, from: self)
                return
            }
        }
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
    /// ↑ ↓ (−1, 1), Home and End (past either end), with ⇧ `extending` the selection.
    case move(Int, extending: Bool)
    case selectParent
    case open
    case collapse(recursively: Bool)
    case expand(recursively: Bool)
    case collapseAll
    case selectAll
    case typeSelect(String)

    static let returnKeyCode: UInt16 = 36
    static let enterKeyCode: UInt16 = 76
    static let deleteKeyCode: UInt16 = 51
    static let leftArrowKeyCode: UInt16 = 123
    static let rightArrowKeyCode: UInt16 = 124
    static let downArrowKeyCode: UInt16 = 125
    static let upArrowKeyCode: UInt16 = 126
    static let homeKeyCode: UInt16 = 115
    static let endKeyCode: UInt16 = 119

    /// Moving the selection and typing go on while a key is held; the commands that change files
    /// act once per press.
    var repeats: Bool {
        switch self {
        case .move, .collapse, .expand, .typeSelect: true
        case .rename, .duplicate, .moveToTrash, .selectParent, .open, .collapseAll, .selectAll: false
        }
    }

    /// Renaming, duplicating, trashing and opening, which wait while a file operation runs.
    var changesFiles: Bool {
        switch self {
        case .rename, .duplicate, .moveToTrash, .open: true
        case .move, .selectParent, .collapse, .expand, .collapseAll, .selectAll, .typeSelect: false
        }
    }

    /// Text a name can start with: no control characters and none of the function keys' private
    /// characters (arrows, Home, F1…).
    static func isTypeSelectText(_ characters: String) -> Bool {
        !characters.isEmpty && characters.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }
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
                            .buttonStyle(MonknotListRowButtonStyle(theme: theme, zoomScale: zoomScale, hasContextMenu: true))
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
        MonknotMenuCommandButton(.open) {
            openDocument(entry.documentID)
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
        // A group header rests at `ink3` and rises to `ink` under the pointer, as a row does.
        let ink = theme.sidebarColor(
            theme.foregroundColor,
            opacity: isHighlighted ? 1 : theme.glyphInkOpacity
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
        .monknotStateStyle(ink)
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
