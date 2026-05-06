import MarkprevCore
import SwiftUI
import WebKit

struct MarkdownPreviewView: NSViewRepresentable {
    let markdown: String
    let baseURL: URL?
    let theme: RenderTheme

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard let service = context.coordinator.service else {
            webView.loadHTMLString(errorHTML("Preview resources could not be loaded."), baseURL: nil)
            return
        }

        do {
            let html = try service.htmlDocument(markdown: markdown, theme: theme, baseURL: baseURL)
            guard html != context.coordinator.lastHTML else { return }
            context.coordinator.lastHTML = html
            webView.loadHTMLString(html, baseURL: baseURL)
        } catch {
            webView.loadHTMLString(errorHTML(error.localizedDescription), baseURL: nil)
        }
    }

    private func errorHTML(_ message: String) -> String {
        """
        <!doctype html>
        <html>
        <body style="font: 14px -apple-system; padding: 24px;">
          <strong>Preview error</strong>
          <p>\(message.replacingOccurrences(of: "<", with: "&lt;"))</p>
        </body>
        </html>
        """
    }

    final class Coordinator {
        let service = try? MarkdownRenderService()
        var lastHTML: String?
    }
}
