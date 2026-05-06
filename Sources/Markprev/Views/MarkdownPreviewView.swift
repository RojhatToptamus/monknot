import MarkprevCore
import SwiftUI
import WebKit

struct MarkdownPreviewView: NSViewRepresentable {
    let markdown: String
    let baseURL: URL?
    let theme: AppTheme
    let zoomScale: Double
    let onSourceJump: (MarkdownSourceLocation) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSourceJump: onSourceJump)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: Coordinator.sourceJumpHandlerName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onSourceJump = onSourceJump

        guard let service = context.coordinator.service else {
            webView.loadHTMLString(errorHTML("Preview resources could not be loaded."), baseURL: nil)
            return
        }

        do {
            let html = try service.htmlDocument(markdown: markdown, appTheme: theme, zoomScale: zoomScale, baseURL: baseURL)
            guard html != context.coordinator.lastHTML else { return }
            context.coordinator.lastHTML = html
            webView.loadHTMLString(html, baseURL: baseURL)
        } catch {
            webView.loadHTMLString(errorHTML(error.localizedDescription), baseURL: nil)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.sourceJumpHandlerName)
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

    final class Coordinator: NSObject, WKScriptMessageHandler {
        static let sourceJumpHandlerName = "markprevSourceJump"

        let service = try? MarkdownRenderService()
        var onSourceJump: (MarkdownSourceLocation) -> Void
        var lastHTML: String?

        init(onSourceJump: @escaping (MarkdownSourceLocation) -> Void) {
            self.onSourceJump = onSourceJump
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.sourceJumpHandlerName else { return }

            let line: Int?
            let offset: Int
            if let body = message.body as? [String: Any], let value = body["line"] as? NSNumber {
                line = value.intValue
                offset = (body["offset"] as? NSNumber)?.intValue ?? 0
            } else if let body = message.body as? [String: Any], let value = body["line"] as? Int {
                line = value
                offset = body["offset"] as? Int ?? 0
            } else {
                line = nil
                offset = 0
            }

            guard let line, line > 0 else { return }
            let location = MarkdownSourceLocation(line: line, offset: offset)

            DispatchQueue.main.async { [onSourceJump] in
                onSourceJump(location)
            }
        }
    }
}
