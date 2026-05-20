import AppKit
import MonknotCore
import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var workspaceSearch: WorkspaceSearchState
    let theme: AppTheme
    let zoomScale: Double
    let uiFontSize: Double
    let openFolder: () -> Void
    let newMarkdown: () -> Void
    let exportPDF: (WorkspaceDocument) -> Void
    let openDocument: (String) -> Void
    let openWorkspaceSearchResult: (WorkspaceSearchResult) -> Void
    @State private var isDropTargeted = false
    @State private var expandedFolderIDs: Set<String> = []
    @State private var sidebarPrompt: SidebarNamePrompt?
    @State private var sidebarTreeFrame: CGRect = .zero
    @State private var sidebarNodeFrames: [String: CGRect] = [:]
    @State private var draggedSidebarNodeID: String?
    @State private var moveDropTargetFolderID: String?
    @State private var isMoveDropTargetingRoot = false
    private let nativeSidebarTopInsetCompensation: CGFloat = 8

    /// Scaled font size — all sidebar typography goes through this.
    private func scaled(_ base: CGFloat) -> CGFloat {
        max(base * zoomScale * CGFloat(uiFontSize / 16), base * 0.75)
    }

    private var visibleNodes: [VisibleSidebarNode] {
        flattenVisibleNodes(from: store.rootNode?.children ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            // Sidebar chrome row: leading reservation for the macOS traffic
            // lights, with workspace-level action icons aligned to the
            // split-view separator.
            SidebarChromeRow(
                openFolder: openFolder,
                createMarkdown: newMarkdown,
                showWorkspaceSearch: {
                    workspaceSearch.present(documents: store.documents)
                },
                canCreateMarkdown: store.workspaceURL != nil,
                canSearch: store.workspaceURL != nil,
                isBusy: store.isBusy,
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: uiFontSize
            )

            VStack(spacing: 0) {
                SidebarProjectHeader(
                    store: store,
                    theme: theme,
                    zoomScale: zoomScale,
                    uiFontSize: uiFontSize
                )

                sidebarMainContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .layoutPriority(1)

            Rectangle()
                .fill(theme.borderColor)
                .frame(height: 1)

            SidebarSettingsButton(theme: theme, zoomScale: zoomScale, uiFontSize: uiFontSize)
                .layoutPriority(2)
        }
        .padding(.top, -nativeSidebarTopInsetCompensation)
        .background {
            sidebarBackground
                .ignoresSafeArea(.container, edges: .top)
        }
        .ignoresSafeArea(.container, edges: .top)
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
        }
        .onChange(of: store.selectedDocumentID ?? "") {
            expandedFolderIDs.formUnion(ancestorFolderIDs(for: store.selectedDocumentID))
        }
        .onAppear {
            expandedFolderIDs = initialExpandedFolderIDs()
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
                uiFontSize: uiFontSize,
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
    }

    @ViewBuilder
    private var sidebarBackground: some View {
        theme.surfaceColor
    }

    @ViewBuilder
    private var sidebarMainContent: some View {
        if workspaceSearch.isPresented {
            WorkspaceSearchView(
                state: workspaceSearch,
                documents: store.documents,
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: uiFontSize,
                close: { workspaceSearch.dismiss() },
                openResult: openWorkspaceSearchResult
            )
        } else if !visibleNodes.isEmpty {
            SidebarScrollContainer {
                LazyVStack(alignment: .leading, spacing: scaled(1)) {
                    ForEach(visibleNodes) { visibleNode in
                        SidebarNodeRow(
                            visibleNode: visibleNode,
                            selectedDocumentID: store.selectedDocumentID,
                            saveState: visibleNode.node.document.map { store.saveState(for: $0.id) } ?? .clean,
                            isExpanded: expandedFolderIDs.contains(visibleNode.node.id),
                            theme: theme,
                            zoomScale: zoomScale,
                            uiFontSize: uiFontSize,
                            toggleFolder: toggleFolder(_:),
                            selectDocument: openDocument,
                            createFileInFolder: beginCreateFile(in:),
                            createFolderInFolder: beginCreateFolder(in:),
                            copyFolderPath: copyPath(_:),
                            revealFolderInFinder: revealInFinder(_:),
                            renameFolder: beginRenameFolder(_:),
                            isMoveSource: draggedSidebarNodeID == visibleNode.id,
                            isMoveTarget: moveDropTargetFolderID == visibleNode.id,
                            dragChanged: handleSidebarNodeDragChanged(id:location:),
                            dragEnded: handleSidebarNodeDragEnded(id:location:),
                            renameDocument: beginRename(_:),
                            copyPath: copyPath(_:),
                            revealInFinder: revealInFinder(_:),
                            exportPDF: exportPDF,
                            copyDocument: copyDocument(_:),
                            cutDocument: cutDocument(_:),
                            deleteDocument: store.deleteDocument(_:)
                        )
                    }
                }
                .padding(.horizontal, scaled(5))
                .padding(.vertical, scaled(6))
                .coordinateSpace(name: SidebarMoveCoordinateSpace.name)
                .background(SidebarTreeFrameReader())
                .onPreferenceChange(SidebarTreeFramePreferenceKey.self) { frame in
                    sidebarTreeFrame = frame
                }
                .onPreferenceChange(SidebarNodeFramePreferenceKey.self) { frames in
                    sidebarNodeFrames = frames
                }
            }
            .contextMenu {
                sidebarContextMenu
            }
        } else {
            EmptySidebarView(theme: theme, zoomScale: zoomScale, uiFontSize: uiFontSize, openFolder: openFolder)
                .contextMenu {
                    sidebarContextMenu
                }
        }
    }

    private func flattenVisibleNodes(from nodes: [SidebarNode]) -> [VisibleSidebarNode] {
        var visibleNodes: [VisibleSidebarNode] = []

        func walk(_ currentNodes: [SidebarNode], depth: Int) {
            for node in currentNodes {
                visibleNodes.append(VisibleSidebarNode(node: node, depth: depth))

                if node.kind == .folder, expandedFolderIDs.contains(node.id), let children = node.children {
                    walk(children, depth: depth + 1)
                }
            }
        }

        walk(nodes, depth: 0)
        return visibleNodes
    }

    private func initialExpandedFolderIDs() -> Set<String> {
        ancestorFolderIDs(for: store.selectedDocumentID ?? store.documents.first?.id)
    }

    private func ancestorFolderIDs(for fileID: String?) -> Set<String> {
        guard let fileID, let rootNode = store.rootNode else { return [] }
        return ancestorFolderIDs(for: fileID, in: rootNode).map(Set.init) ?? []
    }

    private func ancestorFolderIDs(for fileID: String, in node: SidebarNode) -> [String]? {
        if node.document?.id == fileID {
            return []
        }

        guard node.kind == .folder, let children = node.children else {
            return nil
        }

        for child in children {
            if let descendantIDs = ancestorFolderIDs(for: fileID, in: child) {
                return node.relativePath.isEmpty ? descendantIDs : [node.id] + descendantIDs
            }
        }

        return nil
    }

    private func toggleFolder(_ id: String) {
        if expandedFolderIDs.contains(id) {
            expandedFolderIDs.remove(id)
        } else {
            expandedFolderIDs.insert(id)
        }
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
            Label("New File", systemImage: "doc.badge.plus")
        }
        .disabled(store.workspaceURL == nil || store.isBusy)

        Button {
            beginCreateFolder(in: nil)
        } label: {
            Label("New Folder", systemImage: "folder.badge.plus")
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
                Label("Copy Path", systemImage: "link")
            }

            Button {
                revealInFinder(workspaceURL)
            } label: {
                Label("Reveal in Finder", systemImage: "magnifyingglass")
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
        guard store.workspaceURL != nil, !store.isBusy, sidebarNodeFrames[id] != nil else { return }
        draggedSidebarNodeID = id
        updateMoveDropTarget(at: location, excluding: id)
    }

    private func handleSidebarNodeDragEnded(id: String, location: CGPoint) {
        defer {
            draggedSidebarNodeID = nil
            moveDropTargetFolderID = nil
            isMoveDropTargetingRoot = false
        }

        guard store.workspaceURL != nil, !store.isBusy, sidebarNodeFrames[id] != nil else { return }

        if let folderID = folderID(at: location, excluding: id),
           let folderURL = visibleNodes.first(where: { $0.id == folderID })?.node.url {
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
        visibleNodes
            .filter { visibleNode in
                visibleNode.id != draggedID &&
                    visibleNode.node.kind == .folder &&
                    sidebarNodeFrames[visibleNode.id]?.contains(location) == true
            }
            .max { lhs, rhs in lhs.depth < rhs.depth }?
            .id
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

private struct VisibleSidebarNode: Identifiable {
    let node: SidebarNode
    let depth: Int

    var id: String { node.id }
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

/// Sidebar chrome row that lines up with the editor's top nav. Reserves
/// the leading width for the macOS traffic lights and exposes the
/// workspace-level action icons on the trailing side: New Markdown, Open
/// Folder, and Search Workspace.
private struct SidebarChromeRow: View {
    let openFolder: () -> Void
    let createMarkdown: () -> Void
    let showWorkspaceSearch: () -> Void
    let canCreateMarkdown: Bool
    let canSearch: Bool
    let isBusy: Bool
    let theme: AppTheme
    let zoomScale: Double
    let uiFontSize: Double

    private func scaled(_ base: CGFloat) -> CGFloat {
        max(base * zoomScale * CGFloat(uiFontSize / 16), base * 0.75)
    }

    var body: some View {
        HStack(spacing: scaled(2)) {
            Color.clear
                .frame(width: 78)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            WindowDoubleClickZoomArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)

            ChromeBarButton(
                systemImage: "square.and.pencil",
                label: "New Markdown",
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: uiFontSize,
                isDisabled: !canCreateMarkdown || isBusy,
                action: createMarkdown
            )

            ChromeBarButton(
                systemImage: "folder",
                label: "Open Folder",
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: uiFontSize,
                isDisabled: isBusy,
                action: openFolder
            )

            ChromeBarButton(
                systemImage: "magnifyingglass",
                label: "Search Workspace",
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: uiFontSize,
                isDisabled: !canSearch,
                action: showWorkspaceSearch
            )
        }
        .padding(.horizontal, scaled(10))
        .frame(height: scaled(44))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.borderColor)
                .frame(height: 1)
        }
    }
}

/// Workspace identity row. Rendered inside the sidebar's content area
/// (below the chrome row), now showing only the project name (search lives
/// in the chrome row alongside New Markdown / Open Folder).
private struct SidebarProjectHeader: View {
    @ObservedObject var store: WorkspaceStore
    let theme: AppTheme
    let zoomScale: Double
    let uiFontSize: Double

    private func scaled(_ base: CGFloat) -> CGFloat {
        max(base * zoomScale * CGFloat(uiFontSize / 16), base * 0.75)
    }

    var body: some View {
        HStack(spacing: scaled(8)) {
            Text(store.workspaceURL?.lastPathComponent ?? "monknot")
                .font(.system(size: scaled(13), weight: .semibold))
                .foregroundStyle(theme.sidebarColor(theme.foregroundColor, opacity: 0.92))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(store.workspaceURL?.path ?? "No workspace open")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, scaled(12))
        .padding(.top, scaled(8))
        .padding(.bottom, scaled(4))
    }
}

/// Shared chrome/toolbar button — used in both the sidebar window chrome
/// and the right-pane top navigation bar so sizing/styling is identical.
struct ChromeBarButton: View {
    let systemImage: String
    let label: String
    let theme: AppTheme
    let zoomScale: Double
    let uiFontSize: Double
    var isActive: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    private func scaled(_ base: CGFloat) -> CGFloat {
        max(base * zoomScale * CGFloat(uiFontSize / 16), base * 0.75)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: scaled(13), weight: .regular))
                .foregroundStyle(iconColor)
                .frame(width: scaled(28), height: scaled(28))
                .background(background, in: RoundedRectangle(cornerRadius: theme.chromeRadius(7, zoomScale: zoomScale)))
                .contentShape(RoundedRectangle(cornerRadius: theme.chromeRadius(7, zoomScale: zoomScale)))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .focusable(!isDisabled)
        .focused($isFocused)
        .opacity(isDisabled ? 0.4 : 1)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isActive)
        .help(label)
        .accessibilityLabel(label)
        .monknotPointerCursor(enabled: !isDisabled)
    }

    private var background: Color {
        if isActive {
            return theme.controlTrackFillColor
        }
        if isHovered && !isDisabled {
            return theme.foregroundColor.opacity(theme.isDark ? 0.065 : 0.048)
        }
        return .clear
    }

    private var iconColor: Color {
        if isActive {
            return theme.foregroundColor
        }
        if isHovered && !isDisabled {
            return theme.foregroundColor.opacity(0.92)
        }
        return theme.mutedForegroundColor
    }
}

// MARK: - Sidebar Row

private struct SidebarNodeRow: View {
    let visibleNode: VisibleSidebarNode
    let selectedDocumentID: String?
    let saveState: DocumentSaveState
    let isExpanded: Bool
    let theme: AppTheme
    let zoomScale: Double
    let uiFontSize: Double
    let toggleFolder: (String) -> Void
    let selectDocument: (String) -> Void
    let createFileInFolder: (URL) -> Void
    let createFolderInFolder: (URL) -> Void
    let copyFolderPath: (URL) -> Void
    let revealFolderInFinder: (URL) -> Void
    let renameFolder: (SidebarNode) -> Void
    let isMoveSource: Bool
    let isMoveTarget: Bool
    let dragChanged: (String, CGPoint) -> Void
    let dragEnded: (String, CGPoint) -> Void
    let renameDocument: (WorkspaceDocument) -> Void
    let copyPath: (WorkspaceDocument) -> Void
    let revealInFinder: (WorkspaceDocument) -> Void
    let exportPDF: (WorkspaceDocument) -> Void
    let copyDocument: (WorkspaceDocument) -> Void
    let cutDocument: (WorkspaceDocument) -> Void
    let deleteDocument: (WorkspaceDocument) -> Void
    private var node: SidebarNode {
        visibleNode.node
    }

    private var isSelected: Bool {
        node.document?.id == selectedDocumentID
    }

    private func scaled(_ base: CGFloat) -> CGFloat {
        max(base * zoomScale * CGFloat(uiFontSize / 16), base * 0.75)
    }

    var body: some View {
        if node.kind == .folder {
            folderRow
        } else {
            fileRow
        }
    }

    /// Folder row — styled like a Codex section header with a disclosure chevron.
    private var folderRow: some View {
        HStack(spacing: scaled(8)) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: scaled(10), weight: .semibold))
                .foregroundStyle(theme.sidebarColor(theme.mutedForegroundColor))
                .frame(width: scaled(12))

            Image(systemName: "folder")
                .font(.system(size: scaled(14)))
                .foregroundStyle(theme.sidebarColor(theme.accentColor, opacity: 0.8))

            Text(node.name)
                .font(.system(size: scaled(13), weight: .semibold))
                .foregroundStyle(theme.sidebarColor(theme.foregroundColor, opacity: 0.9))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(visibleNode.depth) * scaled(14))
        .padding(.horizontal, scaled(5))
        .padding(.vertical, scaled(5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .sidebarHoverRow(theme: theme, isSelected: false, cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
        .background(SidebarNodeFrameReader(id: node.id))
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) {
                toggleFolder(node.id)
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
        .help(node.relativePath.isEmpty ? node.name : node.relativePath)
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            folderContextMenu()
        }
    }

    /// File row — larger text, generous padding, Codex-style selection highlight.
    private var fileRow: some View {
        HStack(spacing: scaled(10)) {
            Image(systemName: documentIconName)
                .font(.system(size: scaled(13)))
                .foregroundStyle(
                    isSelected
                        ? theme.sidebarColor(theme.accentColor, opacity: 0.95)
                        : theme.sidebarColor(theme.mutedForegroundColor, opacity: 0.7)
                )
                .frame(width: scaled(16))

            Text(node.name)
                .font(.system(size: scaled(14), weight: .regular))
                .foregroundStyle(theme.sidebarColor(theme.foregroundColor, opacity: isSelected ? 0.98 : 0.88))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            SaveStateIndicator(
                state: saveState,
                theme: theme,
                zoomScale: zoomScale,
                size: scaled(12)
            )
        }
        .padding(.leading, CGFloat(visibleNode.depth) * scaled(14) + scaled(8))
        .padding(.trailing, scaled(5))
        .padding(.vertical, scaled(5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .sidebarHoverRow(theme: theme, isSelected: isSelected, cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale))
        .background(SidebarNodeFrameReader(id: node.id))
        .onTapGesture {
            if let document = node.document {
                selectDocument(document.id)
            }
        }
        .opacity(isMoveSource ? 0.45 : 1)
        .simultaneousGesture(sidebarMoveGesture)
        .help(node.relativePath.isEmpty ? node.name : node.relativePath)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            if let document = node.document {
                documentContextMenu(for: document)
            }
        }
    }

    private var documentIconName: String {
        switch node.document?.kind {
        case .pdf:
            return "doc.richtext"
        case .markdown:
            return "chevron.left.forwardslash.chevron.right"
        case .text:
            return "doc.plaintext"
        case .media:
            return "play.rectangle"
        case .nativePreview:
            return "doc.viewfinder"
        case .unsupported, nil:
            return "doc"
        }
    }

    @ViewBuilder
    private func folderContextMenu() -> some View {
        Button {
            createFileInFolder(node.url)
        } label: {
            Label("New File", systemImage: "doc.badge.plus")
        }

        Button {
            createFolderInFolder(node.url)
        } label: {
            Label("New Folder", systemImage: "folder.badge.plus")
        }

        Divider()

        Button {
            renameFolder(node)
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button {
            copyFolderPath(node.url)
        } label: {
            Label("Copy Path", systemImage: "link")
        }

        Button {
            revealFolderInFinder(node.url)
        } label: {
            Label("Reveal in Finder", systemImage: "magnifyingglass")
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
            revealInFinder(document)
        } label: {
            Label("Reveal in Finder", systemImage: "magnifyingglass")
        }

        if document.kind == .markdown {
            Button {
                exportPDF(document)
            } label: {
                Label("Export PDF...", systemImage: "doc.richtext")
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
        autohidesScrollers = true
        scrollerStyle = .overlay
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .allowed
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
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(theme.borderColor, lineWidth: 1)
                }
            }
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
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(theme.borderColor, lineWidth: 1)
                    }
                }
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
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(max(0.65, zoomScale * 0.78))
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
    let uiFontSize: Double
    @Environment(\.openSettings) private var openSettings

    private func scaled(_ base: CGFloat) -> CGFloat {
        max(base * zoomScale * CGFloat(uiFontSize / 16), base * 0.75)
    }

    var body: some View {
        Button {
            openSettings()
        } label: {
            HStack(spacing: scaled(8)) {
                Image(systemName: "gearshape")
                    .font(.system(size: scaled(15)))
                    .foregroundStyle(theme.sidebarColor(theme.mutedForegroundColor))

                Text("Settings")
                    .font(.system(size: scaled(14), weight: .regular))
                    .foregroundStyle(theme.sidebarColor(theme.foregroundColor, opacity: 0.85))

                Spacer()
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

// MARK: - Empty Sidebar

private struct EmptySidebarView: View {
    let theme: AppTheme
    let zoomScale: Double
    let uiFontSize: Double
    let openFolder: () -> Void

    private func scaled(_ base: CGFloat) -> CGFloat {
        max(base * zoomScale * CGFloat(uiFontSize / 16), base * 0.75)
    }

    var body: some View {
        VStack(spacing: scaled(16)) {
            Spacer()

            Image(systemName: "folder.badge.plus")
                .font(.system(size: scaled(36), weight: .medium))
                .foregroundStyle(theme.sidebarColor(theme.mutedForegroundColor, opacity: 0.5))

            VStack(spacing: scaled(6)) {
                Text("No workspace")
                    .font(.system(size: scaled(16), weight: .semibold))
                    .foregroundStyle(theme.sidebarColor(theme.foregroundColor))
                Text("Drop a folder here or open one.")
                    .font(.system(size: scaled(14)))
                    .foregroundStyle(theme.sidebarColor(theme.mutedForegroundColor))
                    .multilineTextAlignment(.center)
            }

            Button(action: openFolder) {
                Label("Open Folder", systemImage: "folder")
                    .font(.system(size: scaled(14), weight: .medium))
                    .padding(.horizontal, scaled(16))
                    .padding(.vertical, scaled(8))
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accentColor)
            .monknotPointerCursor()

            Text("⇧⌘O")
                .font(.system(size: scaled(12), weight: .medium, design: .rounded))
                .foregroundStyle(theme.sidebarColor(theme.mutedForegroundColor, opacity: 0.5))

            Spacer()
        }
        .padding(scaled(24))
    }
}

private struct SidebarNameInputSheet: View {
    let theme: AppTheme
    let zoomScale: Double
    let uiFontSize: Double
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
        uiFontSize: Double,
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
        self.uiFontSize = uiFontSize
        self.title = title
        self.message = message
        self.placeholder = placeholder
        self.confirmTitle = confirmTitle
        self.cancel = cancel
        self.submitName = submit
        _name = State(initialValue: initialName)
    }

    private func scaled(_ base: CGFloat) -> CGFloat {
        max(base * zoomScale * CGFloat(uiFontSize / 16), base * 0.75)
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

                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)

                Button(confirmTitle, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
