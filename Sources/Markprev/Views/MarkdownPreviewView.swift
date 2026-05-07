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
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onSourceJump = onSourceJump

        guard let service = context.coordinator.service else {
            webView.loadHTMLString(Self.errorHTML("Preview resources could not be loaded."), baseURL: nil)
            return
        }

        let shellRequest = PreviewShellRequest(
            baseURL: baseURL,
            theme: theme,
            zoomScale: zoomScale
        )
        let contentRequest = PreviewContentRequest(
            markdown: markdown,
            themeName: theme.isDark ? "dark" : "light"
        )

        if context.coordinator.shouldLoadShell(shellRequest, pendingContent: contentRequest) {
            let renderTask = Task { [weak webView, service] in
                do {
                    let html = try await Task.detached(priority: .userInitiated) {
                        try service.htmlDocument(
                            markdown: "",
                            appTheme: shellRequest.theme,
                            zoomScale: shellRequest.zoomScale,
                            baseURL: shellRequest.baseURL
                        )
                    }.value

                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        _ = webView?.loadHTMLString(html, baseURL: shellRequest.baseURL)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    let html = Self.errorHTML(error.localizedDescription)
                    await MainActor.run {
                        _ = webView?.loadHTMLString(html, baseURL: nil)
                    }
                }
            }
            context.coordinator.setShellTask(renderTask)
            return
        }

        guard context.coordinator.shouldRenderContent(contentRequest) else { return }
        renderContent(contentRequest, in: webView, coordinator: context.coordinator)
    }

    private func renderContent(_ request: PreviewContentRequest, in webView: WKWebView, coordinator: Coordinator) {
        coordinator.setPendingContent(request)

        guard coordinator.isShellLoaded else { return }

        do {
            let payload = try Self.javaScriptPayload(markdown: request.markdown, themeName: request.themeName)
            webView.evaluateJavaScript("window.markprevRender && window.markprevRender(\(payload));") { _, error in
                if error != nil {
                    coordinator.markShellNeedsReload()
                } else {
                    coordinator.markRenderedContent(request)
                }
            }
        } catch {
            webView.loadHTMLString(Self.errorHTML(error.localizedDescription), baseURL: nil)
        }
    }

    private static func javaScriptPayload(markdown: String, themeName: String) throws -> String {
        let payload = ["markdown": markdown, "theme": themeName]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard var literal = String(data: data, encoding: .utf8) else {
            throw PreviewRenderError.invalidPayload
        }

        literal = literal.replacingOccurrences(of: "</", with: "<\\/")
        return literal
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.cancelShellLoad()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.sourceJumpHandlerName)
    }

    private static func errorHTML(_ message: String) -> String {
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

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let sourceJumpHandlerName = "markprevSourceJump"

        let service = try? MarkdownRenderService()
        var onSourceJump: (MarkdownSourceLocation) -> Void
        private var shellTask: Task<Void, Never>?
        private var lastShellRequest: PreviewShellRequest?
        private var lastRenderedContent: PreviewContentRequest?
        private var pendingContent: PreviewContentRequest?
        private(set) var isShellLoaded = false

        init(onSourceJump: @escaping (MarkdownSourceLocation) -> Void) {
            self.onSourceJump = onSourceJump
        }

        fileprivate func shouldLoadShell(_ request: PreviewShellRequest, pendingContent: PreviewContentRequest) -> Bool {
            self.pendingContent = pendingContent
            if request == lastShellRequest {
                if isShellLoaded || shellTask != nil {
                    return false
                }
            }

            lastShellRequest = request
            isShellLoaded = false
            lastRenderedContent = nil
            shellTask?.cancel()
            return true
        }

        fileprivate func shouldRenderContent(_ request: PreviewContentRequest) -> Bool {
            guard request != lastRenderedContent else { return false }
            return true
        }

        fileprivate func setPendingContent(_ request: PreviewContentRequest) {
            pendingContent = request
        }

        func setShellTask(_ task: Task<Void, Never>) {
            shellTask = task
        }

        func cancelShellLoad() {
            shellTask?.cancel()
            shellTask = nil
        }

        func markShellNeedsReload() {
            isShellLoaded = false
            lastShellRequest = nil
            shellTask = nil
        }

        fileprivate func markRenderedContent(_ request: PreviewContentRequest) {
            lastRenderedContent = request
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            shellTask = nil
            isShellLoaded = true
            guard let pendingContent else { return }

            do {
                let payload = try MarkdownPreviewView.javaScriptPayload(
                    markdown: pendingContent.markdown,
                    themeName: pendingContent.themeName
                )
                webView.evaluateJavaScript("window.markprevRender && window.markprevRender(\(payload));")
                lastRenderedContent = pendingContent
            } catch {
                webView.loadHTMLString(MarkdownPreviewView.errorHTML(error.localizedDescription), baseURL: nil)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            shellTask = nil
            isShellLoaded = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            shellTask = nil
            isShellLoaded = false
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

fileprivate struct PreviewShellRequest: Equatable {
    let baseURL: URL?
    let theme: AppTheme
    let zoomScale: Double
}

fileprivate struct PreviewContentRequest: Equatable {
    let markdown: String
    let themeName: String
}

private enum PreviewRenderError: Error, LocalizedError {
    case invalidPayload

    var errorDescription: String? {
        "Could not encode Markdown preview payload."
    }
}
