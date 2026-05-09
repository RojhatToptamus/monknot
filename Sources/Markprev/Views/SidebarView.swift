import AppKit
import MarkprevCore
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var workspaceSearch: WorkspaceSearchState
    let theme: AppTheme
    let zoomScale: Double
    let uiFontSize: Double
    let openFolder: () -> Void
    let exportPDF: (WorkspaceDocument) -> Void
    let openWorkspaceSearchResult: (WorkspaceSearchResult) -> Void
    @State private var isDropTargeted = false
    @State private var expandedFolderIDs: Set<String> = []
    @State private var sidebarPrompt: SidebarNamePrompt?

    /// Scaled font size — all sidebar typography goes through this.
    private func scaled(_ base: CGFloat) -> CGFloat {
        max(base * zoomScale * CGFloat(uiFontSize / 16), base * 0.75)
    }

    private var visibleNodes: [VisibleSidebarNode] {
        flattenVisibleNodes(from: store.rootNode?.children ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            SidebarWindowChrome(theme: theme, zoomScale: zoomScale, uiFontSize: uiFontSize)

            SidebarHeader(
                store: store,
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: uiFontSize,
                showWorkspaceSearch: {
                    workspaceSearch.present(documents: store.documents)
                }
            )

            Divider()
                .overlay(theme.borderColor)

            sidebarMainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .layoutPriority(1)

            Divider()
                .overlay(theme.borderColor)

            SidebarSettingsButton(theme: theme, zoomScale: zoomScale, uiFontSize: uiFontSize)
                .layoutPriority(2)
        }
        .background {
            sidebarBackground
                .ignoresSafeArea(.container, edges: .top)
        }
        .overlay {
            if isDropTargeted {
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
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            loadDroppedURLs(from: providers)
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
            ScrollView {
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
                            selectDocument: store.selectDocument(id:),
                            createFileInFolder: beginCreateFile(in:),
                            createFolderInFolder: beginCreateFolder(in:),
                            copyFolderPath: copyPath(_:),
                            revealFolderInFinder: revealInFinder(_:),
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
            }
            .scrollContentBackground(.hidden)
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

    private func loadDroppedURLs(from providers: [NSItemProvider]) -> Bool {
        var didHandleProvider = false

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            didHandleProvider = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?

                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }

                guard let url else { return }

                Task { @MainActor in
                    store.handleDroppedURL(url)
                }
            }
        }

        return didHandleProvider
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
        writeFileURLToPasteboard(document.url)
        store.copyDocument(document)
    }

    private func cutDocument(_ document: WorkspaceDocument) {
        writeFileURLToPasteboard(document.url)
        store.cutDocument(document)
    }

    private func writeFileURLToPasteboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    private func submitPrompt(_ prompt: SidebarNamePrompt, name: String) {
        switch prompt.operation {
        case .renameDocument(let documentID):
            store.renameDocument(id: documentID, to: name)
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

// MARK: - Sidebar Header

private struct SidebarHeader: View {
    @ObservedObject var store: WorkspaceStore
    let theme: AppTheme
    let zoomScale: Double
    let uiFontSize: Double
    let showWorkspaceSearch: () -> Void

    private func scaled(_ base: CGFloat) -> CGFloat {
        max(base * zoomScale * CGFloat(uiFontSize / 16), base * 0.75)
    }

    var body: some View {
        HStack(spacing: scaled(8)) {
            VStack(alignment: .leading, spacing: scaled(3)) {
                Text(store.workspaceURL?.lastPathComponent ?? "Markprev")
                    .font(.system(size: scaled(15), weight: .semibold))
                    .foregroundStyle(theme.sidebarColor(theme.foregroundColor))
                    .lineLimit(1)

                Text(store.workspaceURL?.path ?? "No workspace open")
                    .font(.system(size: scaled(12)))
                    .foregroundStyle(theme.sidebarColor(theme.mutedForegroundColor))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            ChromeBarButton(
                systemImage: "magnifyingglass",
                label: "Search Workspace",
                theme: theme,
                zoomScale: zoomScale,
                uiFontSize: uiFontSize,
                isDisabled: store.workspaceURL == nil,
                action: showWorkspaceSearch
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, scaled(12))
        .padding(.vertical, scaled(10))
    }
}

/// Reserves the same 44pt height the detail-pane top nav uses, so the
/// traffic lights have somewhere to sit and the sidebar header aligns
/// with the toolbar on the right.
///
/// This is only a spacer for the traffic-light area. The parent paints the
/// sidebar surface through the title-bar region so the left column has one
/// continuous background.
private struct SidebarWindowChrome: View {
    let theme: AppTheme
    let zoomScale: Double
    let uiFontSize: Double

    private func scaled(_ base: CGFloat) -> CGFloat {
        max(base * zoomScale * CGFloat(uiFontSize / 16), base * 0.75)
    }

    var body: some View {
        Color.clear
            .frame(height: scaled(44))
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
                .frame(width: scaled(28), height: scaled(26))
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
        .markprevPointerCursor(enabled: !isDisabled)
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
    let selectDocument: (String?) -> Void
    let createFileInFolder: (URL) -> Void
    let createFolderInFolder: (URL) -> Void
    let copyFolderPath: (URL) -> Void
    let revealFolderInFinder: (URL) -> Void
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
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                toggleFolder(node.id)
            }
        } label: {
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
        }
        .buttonStyle(SidebarHoverButtonStyle(theme: theme, isSelected: false, cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale)))
        .padding(.top, visibleNode.depth == 0 ? scaled(3) : 0)
        .help(node.relativePath.isEmpty ? node.name : node.relativePath)
        .contextMenu {
            folderContextMenu()
        }
    }

    /// File row — larger text, generous padding, Codex-style selection highlight.
    private var fileRow: some View {
        Button {
            if let document = node.document {
                selectDocument(document.id)
            }
        } label: {
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
                    .font(.system(size: scaled(14), weight: isSelected ? .medium : .regular))
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
        }
        .buttonStyle(SidebarHoverButtonStyle(theme: theme, isSelected: isSelected, cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale)))
        .help(node.relativePath.isEmpty ? node.name : node.relativePath)
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
            return "doc.text.fill"
        case .text:
            return "doc.plaintext"
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
                .markprevPointerCursor(enabled: isEnabled)
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
            .markprevPointerCursor()

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
