import AppKit
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
            SidebarWindowChrome(theme: theme, zoomScale: zoomScale, uiFontSize: uiFontSize)

            SidebarHeader(store: store, theme: theme, zoomScale: zoomScale, uiFontSize: uiFontSize)

            Divider()
                .overlay(theme.borderColor)

            if !visibleNodes.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: scaled(1)) {
                        ForEach(visibleNodes) { visibleNode in
                            SidebarNodeRow(
                                visibleNode: visibleNode,
                                selectedDocumentID: store.selectedDocumentID,
                                isExpanded: expandedFolderIDs.contains(visibleNode.node.id),
                                theme: theme,
                                zoomScale: zoomScale,
                                uiFontSize: uiFontSize,
                                toggleFolder: toggleFolder(_:),
                                selectDocument: store.selectDocument(id:)
                            )
                        }
                    }
                    .padding(.horizontal, scaled(5))
                    .padding(.vertical, scaled(6))
                }
                .scrollContentBackground(.hidden)
            } else {
                EmptySidebarView(theme: theme, zoomScale: zoomScale, uiFontSize: uiFontSize, openFolder: openFolder)
            }

            Divider()
                .overlay(theme.borderColor)

            SidebarSettingsButton(theme: theme, zoomScale: zoomScale, uiFontSize: uiFontSize)
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
    }

    @ViewBuilder
    private var sidebarBackground: some View {
        theme.surfaceColor
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
                .foregroundStyle(theme.sidebarColor(theme.foregroundColor))
                .lineLimit(1)

            Text(store.workspaceURL?.path ?? "No workspace open")
                .font(.system(size: scaled(12)))
                .foregroundStyle(theme.sidebarColor(theme.mutedForegroundColor))
                .lineLimit(1)
                .truncationMode(.middle)
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
    let isExpanded: Bool
    let theme: AppTheme
    let zoomScale: Double
    let uiFontSize: Double
    let toggleFolder: (String) -> Void
    let selectDocument: (String?) -> Void

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
            }
            .padding(.leading, CGFloat(visibleNode.depth) * scaled(14) + scaled(8))
            .padding(.trailing, scaled(5))
            .padding(.vertical, scaled(5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarHoverButtonStyle(theme: theme, isSelected: isSelected, cornerRadius: theme.chromeRadius(8, zoomScale: zoomScale)))
        .help(node.relativePath.isEmpty ? node.name : node.relativePath)
    }

    private var documentIconName: String {
        switch node.document?.kind {
        case .pdf:
            return "doc.richtext"
        case .markdown, nil:
            return "doc.text.fill"
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
