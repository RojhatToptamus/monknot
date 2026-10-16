import AVKit
import AppKit
import MonknotCore
import SwiftUI
import UniformTypeIdentifiers

/// Plays a video or audio document with AVKit's standard inline controls. The player exists only
/// while the document is the visible tab: it never starts on its own, and it stops and lets go of
/// the file when the tab is switched or closed or its window closes.
///
/// A video keeps its own proportions inside the pane, so the theme's surface surrounds it instead
/// of letterbox bars; audio shows the system's audio player at a fixed size.
struct MediaPlayerView: View {
    let document: WorkspaceDocument
    let theme: AppTheme
    let zoomScale: Double

    @State private var loadState = MediaLoadState.loading

    var body: some View {
        ZStack {
            MediaPlayerRepresentable(url: document.url, updateLoadState: updateLoadState(_:))
                .aspectRatio(playerAspectRatio, contentMode: .fit)
                .frame(maxWidth: playerMaximumSize.width, maxHeight: playerMaximumSize.height)
                .opacity(loadState.isReady ? 1 : 0)

            loadStatus
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surfaceColor)
    }

    private var videoSize: CGSize? {
        guard case .ready(let presentationSize) = loadState,
              presentationSize.width > 0,
              presentationSize.height > 0
        else { return nil }
        return presentationSize
    }

    private var playerAspectRatio: CGFloat {
        videoSize.map { $0.width / $0.height } ?? 16 / 9
    }

    private var playerMaximumSize: CGSize {
        guard videoSize == nil else {
            return CGSize(width: CGFloat.infinity, height: .infinity)
        }
        return CGSize(
            width: MonknotMetrics.scale(480, theme: theme, zoomScale: zoomScale),
            height: MonknotMetrics.scale(270, theme: theme, zoomScale: zoomScale)
        )
    }

    private func updateLoadState(_ state: MediaLoadState) {
        if loadState != state {
            loadState = state
        }
    }

    @ViewBuilder
    private var loadStatus: some View {
        switch loadState {
        case .loading:
            MonknotProgressIndicator(
                size: MonknotMetrics.interfaceGlyph(16, theme: theme, zoomScale: zoomScale),
                theme: theme
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(isVideo ? "Opening video" : "Opening audio")
        case .ready:
            EmptyView()
        case .failed:
            MonknotEmptyState(
                systemImage: "exclamationmark.triangle",
                title: isVideo ? "Unable to play video" : "Unable to play audio",
                detail: "The file may be damaged, incomplete, unavailable, or in a format macOS can't play.",
                theme: theme,
                zoomScale: zoomScale
            ) {
                EmptyView()
            }
        }
    }

    private var isVideo: Bool {
        document.contentTypeIdentifier
            .flatMap(UTType.init)?
            .conforms(to: .movie) == true
    }
}

enum MediaLoadState: Equatable {
    case loading
    /// Playable; a video reports its display size, audio a zero size.
    case ready(presentationSize: CGSize)
    case failed

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

struct MediaPlayerRepresentable: NSViewRepresentable {
    let url: URL
    let updateLoadState: (MediaLoadState) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MediaPlayerNSView {
        let view = MediaPlayerNSView()
        view.identifier = .monknotDocumentFocusTarget
        view.controlsStyle = .inline
        return view
    }

    func updateNSView(_ view: MediaPlayerNSView, context: Context) {
        context.coordinator.onLoadStateChange = updateLoadState
        if context.coordinator.url != url {
            context.coordinator.load(url, into: view)
        }
    }

    static func dismantleNSView(_ view: MediaPlayerNSView, coordinator: Coordinator) {
        coordinator.onLoadStateChange = { _ in }
        coordinator.unload(from: view)
    }

    final class Coordinator {
        private(set) var url: URL?
        var onLoadStateChange: (MediaLoadState) -> Void = { _ in }
        private var observations: [NSKeyValueObservation] = []

        /// AVFoundation opens the file on its own queues; the item reports the result.
        func load(_ url: URL, into view: AVPlayerView) {
            unload(from: view)
            self.url = url
            let item = AVPlayerItem(url: url)
            let report: (AVPlayerItem) -> Void = { [weak self] item in
                let state: MediaLoadState
                switch item.status {
                case .readyToPlay:
                    state = .ready(presentationSize: item.presentationSize)
                case .failed:
                    state = .failed
                default:
                    state = .loading
                }
                DispatchQueue.main.async {
                    self?.onLoadStateChange(state)
                }
            }
            observations = [
                item.observe(\.status, options: [.initial, .new]) { item, _ in report(item) },
                item.observe(\.presentationSize, options: [.new]) { item, _ in report(item) },
            ]
            view.player = AVPlayer(playerItem: item)
        }

        func unload(from view: AVPlayerView) {
            observations.forEach { $0.invalidate() }
            observations = []
            view.player?.pause()
            view.player?.replaceCurrentItem(with: nil)
            view.player = nil
            url = nil
        }
    }
}

/// The player view. Space plays and pauses while it has focus, and closing its window stops
/// playback, so sound never outlives the window it belongs to.
final class MediaPlayerNSView: AVPlayerView {
    private var windowCloseObserver: NSObjectProtocol?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.charactersIgnoringModifiers == " ",
              modifiers.subtracting(.capsLock).isEmpty,
              player != nil
        else {
            super.keyDown(with: event)
            return
        }
        togglePlayback()
    }

    /// Plays from the start again once the end has been reached.
    func togglePlayback() {
        guard let player else { return }
        guard player.rate == 0 else {
            player.pause()
            return
        }
        if let item = player.currentItem,
           item.duration.isNumeric,
           item.currentTime() >= item.duration {
            player.seek(to: .zero)
        }
        player.play()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
            self.windowCloseObserver = nil
        }
        guard let newWindow else {
            player?.pause()
            return
        }
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: newWindow,
            queue: nil
        ) { [weak self] _ in
            self?.player?.pause()
        }
    }

    deinit {
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
        }
    }
}
