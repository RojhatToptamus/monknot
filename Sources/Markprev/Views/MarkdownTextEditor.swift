import AppKit
import MarkprevCore
import SwiftUI

struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    let theme: RenderTheme

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 24, height: 24)
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        applyTheme(theme, to: textView, in: scrollView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
        }

        applyTheme(theme, to: textView, in: scrollView)
    }

    private func applyTheme(_ theme: RenderTheme, to textView: NSTextView, in scrollView: NSScrollView) {
        switch theme {
        case .light:
            let background = NSColor.textBackgroundColor
            textView.backgroundColor = background
            scrollView.backgroundColor = background
            textView.textColor = NSColor.labelColor
            textView.insertionPointColor = NSColor.controlAccentColor
        case .dark:
            let background = NSColor(calibratedRed: 0.075, green: 0.078, blue: 0.085, alpha: 1)
            textView.backgroundColor = background
            scrollView.backgroundColor = background
            textView.textColor = NSColor(calibratedWhite: 0.94, alpha: 1)
            textView.insertionPointColor = NSColor.controlAccentColor
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        weak var textView: NSTextView?

        init(text: Binding<String>) {
            self._text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}
