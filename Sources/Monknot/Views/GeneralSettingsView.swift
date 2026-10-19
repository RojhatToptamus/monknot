import Combine
import MonknotCore
import Sparkle
import SwiftUI

enum VisualExternalChangeReviewPreference {
    static let key = "Monknot.visualExternalChangeReview"
    static let defaultValue = true
}

@MainActor
final class SparkleUpdateSettings: ObservableObject {
    private let updater: SPUUpdater
    private var cancellables: Set<AnyCancellable> = []

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }

    var canChangeAutomaticallyDownloadsUpdates: Bool {
        updater.automaticallyChecksForUpdates && updater.allowsAutomaticUpdates
    }

    init(updater: SPUUpdater) {
        self.updater = updater

        updater.publisher(for: \.automaticallyChecksForUpdates, options: [.new])
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        updater.publisher(for: \.automaticallyDownloadsUpdates, options: [.new])
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        updater.publisher(for: \.allowsAutomaticUpdates, options: [.new])
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }
}

struct GeneralSettingsView: View {
    let uiTheme: AppTheme
    let zoomScale: Double
    @StateObject private var updateSettings: SparkleUpdateSettings
    @AppStorage("Monknot.usePointerCursors") private var usePointerCursors = false
    @AppStorage("Monknot.reopenLastWorkspace") private var reopenLastWorkspace = true
    @AppStorage(VisualExternalChangeReviewPreference.key)
    private var visualExternalChangeReviewEnabled = VisualExternalChangeReviewPreference.defaultValue
    @AppStorage("Monknot.fontSmoothing") private var fontSmoothing = true
    @AppStorage(ContentWidthPreference.key) private var contentWidthPercent = ContentWidthPreference.initialValue()
    @AppStorage(TerminalWorkingDirectoryPreference.key)
    private var terminalWorkingDirectory = TerminalWorkingDirectoryPreference.defaultValue.rawValue

    @MainActor
    init(uiTheme: AppTheme, zoomScale: Double, updater: SPUUpdater) {
        self.uiTheme = uiTheme
        self.zoomScale = zoomScale
        _updateSettings = StateObject(
            wrappedValue: SparkleUpdateSettings(updater: updater)
        )
    }

    var body: some View {
        SettingsPage(theme: uiTheme, zoomScale: zoomScale) {
            SettingsSectionHeader(theme: uiTheme, zoomScale: zoomScale, title: "Behavior", isFirst: true)
            SettingsGroupCard(theme: uiTheme, zoomScale: zoomScale) {
                SettingsToggleRow(
                    theme: uiTheme,
                    zoomScale: zoomScale,
                    title: "Pointer cursor on controls",
                    detail: "Non-standard on macOS; off by default",
                    isOn: $usePointerCursors
                )

                SettingsToggleRow(
                    theme: uiTheme,
                    zoomScale: zoomScale,
                    title: "Reopen last workspace on launch",
                    isOn: $reopenLastWorkspace
                )

                SettingsToggleRow(
                    theme: uiTheme,
                    zoomScale: zoomScale,
                    title: "Visual external change review",
                    detail: "Show a readable diff before reconciling text changed on disk",
                    isOn: $visualExternalChangeReviewEnabled
                )

                SettingsToggleRow(
                    theme: uiTheme,
                    zoomScale: zoomScale,
                    title: "Font smoothing",
                    detail: "Use native macOS anti-aliasing",
                    showsDivider: false,
                    isOn: $fontSmoothing
                )
            }

            SettingsSectionHeader(theme: uiTheme, zoomScale: zoomScale, title: "Updates")
            SettingsGroupCard(theme: uiTheme, zoomScale: zoomScale) {
                SettingsToggleRow(
                    theme: uiTheme,
                    zoomScale: zoomScale,
                    title: "Automatically check for updates",
                    isOn: Binding(
                        get: { updateSettings.automaticallyChecksForUpdates },
                        set: { updateSettings.automaticallyChecksForUpdates = $0 }
                    )
                )

                SettingsToggleRow(
                    theme: uiTheme,
                    zoomScale: zoomScale,
                    title: "Automatically download updates",
                    showsDivider: false,
                    isDisabled: !updateSettings.canChangeAutomaticallyDownloadsUpdates,
                    isOn: Binding(
                        get: { updateSettings.automaticallyDownloadsUpdates },
                        set: { updateSettings.automaticallyDownloadsUpdates = $0 }
                    )
                )
            }

            SettingsSectionHeader(theme: uiTheme, zoomScale: zoomScale, title: "Reading")
            SettingsGroupCard(theme: uiTheme, zoomScale: zoomScale) {
                SettingsSliderRow(
                    theme: uiTheme,
                    zoomScale: zoomScale,
                    title: "Content width",
                    detail: "Share of the pane, up to a comfortable line length; 100% fills it",
                    value: $contentWidthPercent,
                    range: ContentWidthPreference.allowedRange,
                    suffix: "%"
                )

                SettingsRow(
                    theme: uiTheme,
                    zoomScale: zoomScale,
                    title: "Terminal working directory",
                    detail: "Used when a new terminal is created",
                    showsDivider: false
                ) {
                    MonknotPopUpButton(
                        label: "Terminal working directory",
                        selection: $terminalWorkingDirectory,
                        items: TerminalWorkingDirectoryPreference.allCases.map {
                            MonknotPopUpItem(id: $0.rawValue, title: $0.title)
                        },
                        theme: uiTheme,
                        zoomScale: zoomScale
                    )
                }
            }
        }
    }
}
