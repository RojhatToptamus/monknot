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
    @StateObject private var updateSettings: SparkleUpdateSettings
    @AppStorage("Monknot.usePointerCursors") private var usePointerCursors = false
    @AppStorage("Monknot.reopenLastWorkspace") private var reopenLastWorkspace = true
    @AppStorage(VisualExternalChangeReviewPreference.key)
    private var visualExternalChangeReviewEnabled = VisualExternalChangeReviewPreference.defaultValue
    @AppStorage("Monknot.fontSmoothing") private var fontSmoothing = true
    @AppStorage(ContentWidthPreference.key) private var contentWidthPercent = ContentWidthPreference.initialValue()
    @AppStorage(TerminalWorkingDirectoryPreference.key)
    private var terminalWorkingDirectory = TerminalWorkingDirectoryPreference.defaultValue.rawValue
    @Environment(\.monknotSettingsZoomScale) private var settingsZoomScale

    @MainActor
    init(uiTheme: AppTheme, updater: SPUUpdater) {
        self.uiTheme = uiTheme
        _updateSettings = StateObject(
            wrappedValue: SparkleUpdateSettings(updater: updater)
        )
    }

    private func scaled(_ base: CGFloat) -> CGFloat {
        MonknotMetrics.interfaceDensity(base, theme: uiTheme, zoomScale: settingsZoomScale)
    }

    var body: some View {
        SettingsPage(theme: uiTheme) {
            SettingsSectionHeader(theme: uiTheme, title: "Behavior")
            SettingsGroupCard(theme: uiTheme) {
                SettingsToggleRow(
                    theme: uiTheme,
                    title: "Pointer cursor on controls",
                    detail: "Non-standard on macOS; off by default",
                    isOn: $usePointerCursors
                )

                SettingsToggleRow(
                    theme: uiTheme,
                    title: "Reopen last workspace on launch",
                    isOn: $reopenLastWorkspace
                )

                SettingsToggleRow(
                    theme: uiTheme,
                    title: "Visual External Change Review",
                    detail: "Show a readable diff before reconciling text changed on disk",
                    isOn: $visualExternalChangeReviewEnabled
                )

                SettingsToggleRow(
                    theme: uiTheme,
                    title: "Font smoothing",
                    detail: "Use native macOS anti-aliasing",
                    showsDivider: false,
                    isOn: $fontSmoothing
                )
            }

            SettingsSectionHeader(theme: uiTheme, title: "Updates")
                .padding(.top, scaled(22))
            SettingsGroupCard(theme: uiTheme) {
                SettingsToggleRow(
                    theme: uiTheme,
                    title: "Automatically check for updates",
                    isOn: Binding(
                        get: { updateSettings.automaticallyChecksForUpdates },
                        set: { updateSettings.automaticallyChecksForUpdates = $0 }
                    )
                )

                SettingsToggleRow(
                    theme: uiTheme,
                    title: "Automatically download updates",
                    showsDivider: false,
                    isDisabled: !updateSettings.canChangeAutomaticallyDownloadsUpdates,
                    isOn: Binding(
                        get: { updateSettings.automaticallyDownloadsUpdates },
                        set: { updateSettings.automaticallyDownloadsUpdates = $0 }
                    )
                )
            }

            SettingsSectionHeader(theme: uiTheme, title: "Reading")
                .padding(.top, scaled(22))
            SettingsGroupCard(theme: uiTheme) {
                SettingsSliderRow(
                    theme: uiTheme,
                    title: "Content Width",
                    detail: "Share of the document pane",
                    value: $contentWidthPercent,
                    range: ContentWidthPreference.allowedRange,
                    suffix: "%"
                )

                SettingsRow(
                    theme: uiTheme,
                    title: "Terminal working directory",
                    detail: "Used when a new terminal is created",
                    showsDivider: false
                ) {
                    MonknotSettingsMenuPicker(
                        title: "Terminal working directory",
                        selection: $terminalWorkingDirectory,
                        options: TerminalWorkingDirectoryPreference.allCases.map {
                            ($0.rawValue, $0.title)
                        },
                        theme: uiTheme
                    )
                    .frame(minWidth: scaled(172))
                }
            }
        }
    }
}
