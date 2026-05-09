import AVKit
import MarkprevCore
import SwiftUI

struct MediaPreviewView: NSViewRepresentable {
    let url: URL
    let theme: AppTheme

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        view.wantsLayer = true
        context.coordinator.configure(view, url: url, theme: theme)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        context.coordinator.configure(view, url: url, theme: theme)
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        view.player?.pause()
        view.player = nil
        coordinator.player = nil
        coordinator.url = nil
    }

    final class Coordinator {
        var url: URL?
        var player: AVPlayer?

        func configure(_ view: AVPlayerView, url: URL, theme: AppTheme) {
            let standardizedURL = url.standardizedFileURL
            if self.url != standardizedURL {
                player?.pause()
                let nextPlayer = AVPlayer(url: standardizedURL)
                player = nextPlayer
                view.player = nextPlayer
                self.url = standardizedURL
            }

            view.layer?.backgroundColor = NSColor(hex: theme.background).cgColor
        }
    }
}
