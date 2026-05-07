import MarkprevCore
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @ObservedObject var store: WorkspaceStore
    let theme: AppTheme
    let zoomScale: Double
    let uiFontSize: Double
    let openFolder: () -> Void
    @State private var isDropTargeted = false
    @State private var expandedFolderIDs: Set<String> = []

    /// Scaled font size — all sidebar typography goes through this.
    private func scaled(_ base: CGFloat) -> CGFloat {
        max(base * zoomScale * CGFloat(uiFontSize / 16), base * 0.75)
    }

    private var visibleNodes: [VisibleSidebarNode] {
        flattenVisibleNodes(from: store.rootNode?.children ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader(store: store, theme: theme, zoomScale: zoomScale, uiFontSize: uiFontSize)

            Divider()
                .overlay(theme.borderColor)

            if !visibleNodes.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: scaled(2)) {
                        ForEach(visibleNodes) { visibleNode in
                            SidebarNodeRow(
                                visibleNode: visibleNode,
                                selectedFileID: store.selectedFileID,
                                isExpanded: expandedFolderIDs.contains(visibleNode.node.id),
                                theme: theme,
                                zoomScale: zoomScale,
                                uiFontSize: uiFontSize,
                                toggleFolder: toggleFolder(_:),
                                selectFile: store.selectFile(id:)
                            )
                        }
                    }
                    .padding(.horizontal, scaled(6))
                    .padding(.vertical, scaled(8))
                }
                .scrollContentBackground(.hidden)
            } else {
                EmptySidebarView(theme: theme, zoomScale: zoomScale, uiFontSize: uiFontSize, openFolder: openFolder)
            }

            Divider()
                .overlay(theme.borderColor)

            SidebarSettingsButton(theme: theme, zoomScale: zoomScale, uiFontSize: uiFontSize)
        }
        .background(theme.opaqueWindows ? theme.surfaceColor : theme.surfaceColor.opacity(0.96))
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(theme.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .padding(8)
            }
        }
        .onChange(of: store.rootNode?.id ?? "") {
            expandedFolderIDs = initialExpandedFolderIDs()
        }
        .onChange(of: store.selectedFileID ?? "") {
            expandedFolderIDs.formUnion(ancestorFolderIDs(for: store.selectedFileID))
        }
        .onAppear {
            expandedFolderIDs = initialExpandedFolderIDs()
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            loadDroppedURLs(from: providers)
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
        ancestorFolderIDs(for: store.selectedFileID ?? store.files.first?.id)
    }

    private func ancestorFolderIDs(for fileID: String?) -> Set<String> {
        guard let fileID, let rootNode = store.rootNode else { return [] }
        return ancestorFolderIDs(for: fileID, in: rootNode).map(Set.init) ?? []
    }

    private func ancestorFolderIDs(for fileID: String, in node: SidebarNode) -> [String]? {
        if node.file?.id == fileID {
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
}

// MARK: - Supporting Types

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

    private func scaled(_ base: CGFloat) -> CGFloat {
        max(base * zoomScale * CGFloat(uiFontSize / 16), base * 0.75)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: scaled(3)) {
            Text(store.workspaceURL?.lastPathComponent ?? "Markprev")
                .font(.system(size: scaled(15), weight: .semibold))
                .foregroundStyle(theme.foregroundColor)
                .lineLimit(1)

            Text(store.workspaceURL?.path ?? "No workspace open")
                .font(.system(size: scaled(12)))
                .foregroundStyle(theme.mutedForegroundColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, scaled(16))
        .padding(.vertical, scaled(14))
    }
}

// MARK: - Sidebar Row

private struct SidebarNodeRow: View {
    let visibleNode: VisibleSidebarNode
    let selectedFileID: String?
    let isExpanded: Bool
    let theme: AppTheme
    let zoomScale: Double
    let uiFontSize: Double
    let toggleFolder: (String) -> Void
    let selectFile: (String?) -> Void

    private var node: SidebarNode {
        visibleNode.node
    }

    private var isSelected: Bool {
        node.file?.id == selectedFileID
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
                    .foregroundStyle(theme.mutedForegroundColor)
                    .frame(width: scaled(12))

                Image(systemName: "folder.fill")
                    .font(.system(size: scaled(15)))
                    .foregroundStyle(theme.accentColor.opacity(0.8))

                Text(node.name)
                    .font(.system(size: scaled(14), weight: .semibold))
                    .foregroundStyle(theme.foregroundColor.opacity(0.9))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(visibleNode.depth) * scaled(16))
            .padding(.horizontal, scaled(6))
            .padding(.vertical, scaled(7))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, visibleNode.depth == 0 ? scaled(4) : 0)
        .help(node.relativePath.isEmpty ? node.name : node.relativePath)
    }

    /// File row — larger text, generous padding, Codex-style selection highlight.
    private var fileRow: some View {
        Button {
            if let file = node.file {
                selectFile(file.id)
            }
        } label: {
            HStack(spacing: scaled(10)) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: scaled(14)))
                    .foregroundStyle(isSelected ? Color(hex: theme.selectionForeground) : theme.mutedForegroundColor.opacity(0.7))
                    .frame(width: scaled(18))

                Text(node.name)
                    .font(.system(size: scaled(15), weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color(hex: theme.selectionForeground) : theme.foregroundColor.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(visibleNode.depth) * scaled(16) + scaled(12))
            .padding(.trailing, scaled(6))
            .padding(.vertical, scaled(7))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected
                    ? Color(hex: theme.selectionBackground)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: scaled(8))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(node.relativePath.isEmpty ? node.name : node.relativePath)
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
                    .foregroundStyle(theme.mutedForegroundColor)

                Text("Settings")
                    .font(.system(size: scaled(14), weight: .regular))
                    .foregroundStyle(theme.foregroundColor.opacity(0.85))

                Spacer()
            }
            .padding(.horizontal, scaled(12))
            .padding(.vertical, scaled(10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                .foregroundStyle(theme.mutedForegroundColor.opacity(0.5))

            VStack(spacing: scaled(6)) {
                Text("No workspace")
                    .font(.system(size: scaled(16), weight: .semibold))
                    .foregroundStyle(theme.foregroundColor)
                Text("Drop a folder here or open one.")
                    .font(.system(size: scaled(14)))
                    .foregroundStyle(theme.mutedForegroundColor)
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

            Text("⇧⌘O")
                .font(.system(size: scaled(12), weight: .medium, design: .rounded))
                .foregroundStyle(theme.mutedForegroundColor.opacity(0.5))

            Spacer()
        }
        .padding(scaled(24))
    }
}
