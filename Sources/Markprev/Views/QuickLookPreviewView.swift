import MarkprevCore
import QuickLookUI
import SwiftUI

struct QuickLookPreviewView: NSViewRepresentable {
    let url: URL
    let theme: AppTheme

    func makeNSView(context: Context) -> NSView {
        guard let previewView = QLPreviewView(frame: .zero, style: .normal) else {
            return QuickLookFallbackView(message: "Preview is not available.")
        }

        previewView.autostarts = true
        previewView.previewItem = url as NSURL
        return previewView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let previewView = nsView as? QLPreviewView {
            previewView.previewItem = url as NSURL
        } else if let fallback = nsView as? QuickLookFallbackView {
            fallback.message = "Preview is not available for \(url.lastPathComponent)."
        }
    }
}

private final class QuickLookFallbackView: NSView {
    var message: String {
        didSet {
            label.stringValue = message
        }
    }

    private let label = NSTextField(labelWithString: "")

    init(message: String) {
        self.message = message
        super.init(frame: .zero)

        wantsLayer = true
        label.stringValue = message
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
