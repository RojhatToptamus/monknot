import MarkprevCore
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @ObservedObject var store: WorkspaceStore
    let openFolder: () -> Void
    @State private var isDropTargeted = false

    private var selection: Binding<String?> {
        Binding(
            get: { store.selectedFileID },
            set: { store.selectFile(id: $0) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader

            if let rootNode = store.rootNode, let children = rootNode.children, !children.isEmpty {
                List(selection: selection) {
                    OutlineGroup(children, children: \.children) { node in
                        SidebarRow(node: node)
                            .tag(node.isFile ? node.id : "")
                    }
                }
                .listStyle(.sidebar)
            } else {
                EmptySidebarView(openFolder: openFolder)
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.blue, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .padding(8)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            loadDroppedURLs(from: providers)
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "sidebar.left")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(store.workspaceURL?.lastPathComponent ?? "Workspace")
                    .font(.headline)
                    .lineLimit(1)

                Text(store.workspaceURL?.path ?? "Drop a folder or Markdown file")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: openFolder) {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .help("Open Folder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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

private struct SidebarRow: View {
    let node: SidebarNode

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: node.isFile ? "doc.plaintext" : "folder")
                .foregroundStyle(node.isFile ? Color.secondary : Color.blue)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .lineLimit(1)

                if node.isFile {
                    Text(node.relativePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .help(node.relativePath.isEmpty ? node.name : node.relativePath)
    }
}

private struct EmptySidebarView: View {
    let openFolder: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text("No Markdown workspace")
                    .font(.headline)
                Text("Drop a folder here or open one from disk.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
