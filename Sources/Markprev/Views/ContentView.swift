import AppKit
import MarkprevCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: WorkspaceStore
    @AppStorage("Markprev.editorMode") private var editorModeRawValue = EditorMode.preview.rawValue
    @AppStorage("Markprev.themePreference") private var themePreferenceRawValue = ThemePreference.system.rawValue
    @AppStorage("Markprev.lightThemeID") private var lightThemeID = AppTheme.codexLight.id
    @AppStorage("Markprev.darkThemeID") private var darkThemeID = AppTheme.codexDark.id
    @AppStorage("Markprev.zoomScale") private var zoomScale = 1.0
    @AppStorage("Markprev.codeFontSize") private var codeFontSize = 15.0
    @State private var pendingSourceLocation: MarkdownSourceLocation?
    @Environment(\.colorScheme) private var systemColorScheme

    private var editorMode: EditorMode {
        get { EditorMode(rawValue: editorModeRawValue) ?? .preview }
        nonmutating set { editorModeRawValue = newValue.rawValue }
    }

    private var themePreference: ThemePreference {
        get { ThemePreference(rawValue: themePreferenceRawValue) ?? .system }
        nonmutating set { themePreferenceRawValue = newValue.rawValue }
    }

    private var activeTheme: AppTheme {
        themePreference.appTheme(
            systemColorScheme: systemColorScheme,
            lightThemeID: lightThemeID,
            darkThemeID: darkThemeID
        )
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store, theme: activeTheme, zoomScale: zoomScale, openFolder: openFolderPanel)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 440)
        } detail: {
            EditorPaneView(
                store: store,
                editorMode: editorMode,
                theme: activeTheme,
                zoomScale: zoomScale,
                codeFontSize: CGFloat(codeFontSize),
                sourceLocation: $pendingSourceLocation,
                onPreviewSourceJump: openSourceFromPreview(location:)
            )
        }
        .background(activeTheme.surfaceColor)
        .preferredColorScheme(themePreference.preferredColorScheme)
        .accentColor(activeTheme.accentColor)
        .navigationTitle(store.selectedFile?.displayName ?? "Markprev")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    openFolderPanel()
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                .disabled(store.isBusy)
                .help("Open Folder")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if store.isBusy || store.isDocumentLoading || store.isSaving {
                    ProgressView()
                        .controlSize(.small)
                }

                Picker("View Mode", selection: Binding(
                    get: { editorMode },
                    set: { editorMode = $0 }
                )) {
                    ForEach(EditorMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 148)
                .disabled(store.selectedFile == nil || store.isDocumentLoading)

                Divider()

                Button {
                    adjustZoom(by: -0.1)
                } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                .help("Zoom Out")

                Button {
                    zoomScale = 1.0
                } label: {
                    Text("\(Int((zoomScale * 100).rounded()))%")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .frame(width: 42)
                }
                .buttonStyle(.plain)
                .help("Actual Size")

                Button {
                    adjustZoom(by: 0.1)
                } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                .help("Zoom In")
            }
        }
        .task {
            store.restoreWorkspace()
        }
        .onReceive(NotificationCenter.default.publisher(for: .markprevOpenFolder)) { _ in
            openFolderPanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .markprevNewMarkdown)) { _ in
            store.createMarkdownFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .markprevSaveDocument)) { _ in
            store.saveSelectedFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .markprevRefreshWorkspace)) { _ in
            store.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .markprevZoomIn)) { _ in
            adjustZoom(by: 0.1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .markprevZoomOut)) { _ in
            adjustZoom(by: -0.1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .markprevResetZoom)) { _ in
            zoomScale = 1.0
        }
        .alert("Markprev", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {
                store.errorMessage = nil
            }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.prompt = "Open"
        panel.message = "Choose a folder containing Markdown files."

        if panel.runModal() == .OK, let url = panel.url {
            store.openWorkspace(url)
        }
    }

    private func adjustZoom(by delta: Double) {
        let stepped = ((zoomScale + delta) * 10).rounded() / 10
        zoomScale = min(1.8, max(0.7, stepped))
    }

    private func openSourceFromPreview(location: MarkdownSourceLocation) {
        pendingSourceLocation = location
        editorMode = .source
    }
}
