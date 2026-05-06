import AppKit
import MarkprevCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: WorkspaceStore
    @AppStorage("Markprev.editorMode") private var editorModeRawValue = EditorMode.preview.rawValue
    @AppStorage("Markprev.themePreference") private var themePreferenceRawValue = ThemePreference.system.rawValue
    @Environment(\.colorScheme) private var systemColorScheme

    private var editorMode: EditorMode {
        get { EditorMode(rawValue: editorModeRawValue) ?? .preview }
        nonmutating set { editorModeRawValue = newValue.rawValue }
    }

    private var themePreference: ThemePreference {
        get { ThemePreference(rawValue: themePreferenceRawValue) ?? .system }
        nonmutating set { themePreferenceRawValue = newValue.rawValue }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store, openFolder: openFolderPanel)
                .navigationSplitViewColumnWidth(min: 220, ideal: 286, max: 380)
        } detail: {
            EditorPaneView(
                store: store,
                editorMode: editorMode,
                renderTheme: themePreference.renderTheme(systemColorScheme: systemColorScheme)
            )
        }
        .preferredColorScheme(themePreference.preferredColorScheme)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("View Mode", selection: Binding(
                    get: { editorMode },
                    set: { editorMode = $0 }
                )) {
                    ForEach(EditorMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 164)
                .disabled(store.selectedFile == nil)

                Picker("Theme", selection: Binding(
                    get: { themePreference },
                    set: { themePreference = $0 }
                )) {
                    ForEach(ThemePreference.allCases) { theme in
                        Label(theme.title, systemImage: theme.systemImage).tag(theme)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 118)

                Button {
                    store.saveSelectedFile()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .disabled(store.selectedFile == nil || !store.hasUnsavedChanges)

                Button {
                    store.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.workspaceURL == nil)
            }
        }
        .task {
            store.restoreWorkspace()
        }
        .onReceive(NotificationCenter.default.publisher(for: .markprevOpenFolder)) { _ in
            openFolderPanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .markprevSaveDocument)) { _ in
            store.saveSelectedFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .markprevRefreshWorkspace)) { _ in
            store.refresh()
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
}
