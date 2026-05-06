import MarkprevCore
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @ObservedObject var store: WorkspaceStore
    let theme: AppTheme
    let openFolder: () -> Void
    @State private var isDropTargeted = false
    @State private var expandedFolderIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader(store: store, theme: theme, openFolder: openFolder)

            Divider()
                .overlay(theme.borderColor)

            if let rootNode = store.rootNode, let children = rootNode.children, !children.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(children) { node in
                            SidebarNodeRow(
                                node: node,
                                depth: 0,
                                selectedFileID: store.selectedFileID,
                                expandedFolderIDs: $expandedFolderIDs,
                                theme: theme
                            ) { id in
                                store.selectFile(id: id)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                }
                .scrollContentBackground(.hidden)
            } else {
                EmptySidebarView(theme: theme, openFolder: openFolder)
            }
        }
        .background {
            theme.surfaceColor
                .overlay(theme.foregroundColor.opacity(theme.isDark ? 0.035 : 0.025))
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(theme.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .padding(8)
            }
        }
        .onChange(of: store.rootNode?.id ?? "") {
            expandedFolderIDs = collectFolderIDs(from: store.rootNode)
        }
        .onAppear {
            expandedFolderIDs = collectFolderIDs(from: store.rootNode)
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            loadDroppedURLs(from: providers)
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

    private func collectFolderIDs(from node: SidebarNode?) -> Set<String> {
        guard let node else { return [] }

        var ids = Set<String>()

        func walk(_ current: SidebarNode) {
            guard current.kind == .folder else { return }
            ids.insert(current.id)
            current.children?.forEach(walk)
        }

        walk(node)
        return ids
    }
}

private struct SidebarHeader: View {
    @ObservedObject var store: WorkspaceStore
    let theme: AppTheme
    let openFolder: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.mutedForegroundColor)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(store.workspaceURL?.lastPathComponent ?? "Markprev")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.foregroundColor)
                    .lineLimit(1)

                Text(store.workspaceURL?.path ?? "Drop a folder or Markdown file")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.mutedForegroundColor)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                store.createMarkdownFile()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.mutedForegroundColor)
            .disabled(store.workspaceURL == nil)
            .help("New Markdown")

            Button(action: openFolder) {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.mutedForegroundColor)
            .help("Open Folder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct SidebarNodeRow: View {
    let node: SidebarNode
    let depth: Int
    let selectedFileID: String?
    @Binding var expandedFolderIDs: Set<String>
    let theme: AppTheme
    let selectFile: (String) -> Void

    private var isExpanded: Bool {
        expandedFolderIDs.contains(node.id)
    }

    private var isSelected: Bool {
        node.file?.id == selectedFileID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                if node.kind == .folder {
                    toggleFolder()
                } else if let file = node.file {
                    selectFile(file.id)
                }
            } label: {
                HStack(spacing: 8) {
                    if node.kind == .folder {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(theme.mutedForegroundColor)
                            .frame(width: 10)
                    } else {
                        Spacer()
                            .frame(width: 10)
                    }

                    Image(systemName: node.kind == .folder ? "folder" : "doc.text")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(node.kind == .folder ? theme.mutedForegroundColor : theme.mutedForegroundColor.opacity(0.88))
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.name)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? theme.foregroundColor : theme.foregroundColor.opacity(0.90))
                            .lineLimit(1)

                        if node.kind == .file {
                            Text(node.relativePath)
                                .font(.system(size: 11))
                                .foregroundStyle(theme.mutedForegroundColor)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(depth) * 16)
                .padding(.horizontal, 8)
                .padding(.vertical, node.kind == .file ? 7 : 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isSelected ? theme.foregroundColor.opacity(theme.isDark ? 0.11 : 0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help(node.relativePath.isEmpty ? node.name : node.relativePath)

            if node.kind == .folder, isExpanded {
                ForEach(node.children ?? []) { child in
                    SidebarNodeRow(
                        node: child,
                        depth: depth + 1,
                        selectedFileID: selectedFileID,
                        expandedFolderIDs: $expandedFolderIDs,
                        theme: theme,
                        selectFile: selectFile
                    )
                }
            }
        }
    }

    private func toggleFolder() {
        if expandedFolderIDs.contains(node.id) {
            expandedFolderIDs.remove(node.id)
        } else {
            expandedFolderIDs.insert(node.id)
        }
    }
}

private struct EmptySidebarView: View {
    let theme: AppTheme
    let openFolder: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(theme.mutedForegroundColor)

            VStack(spacing: 6) {
                Text("No workspace")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.foregroundColor)
                Text("Drop a folder here or open one from disk.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.mutedForegroundColor)
                    .multilineTextAlignment(.center)
            }

            Button(action: openFolder) {
                Label("Open Folder", systemImage: "folder")
            }

            Spacer()
        }
        .padding(24)
    }
}
