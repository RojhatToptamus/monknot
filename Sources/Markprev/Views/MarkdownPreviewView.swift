import MarkprevCore
import SwiftUI
import WebKit

struct MarkdownPreviewView: NSViewRepresentable {
    let documentID: String
    let markdown: String
    let baseURL: URL?
    let theme: AppTheme
    let zoomScale: Double
    let codeFontSize: Double
    let previewWidthPercent: Double
    let usePointerCursors: Bool
    let fontSmoothing: Bool
    let scrollPosition: DocumentScrollPosition?
    @Binding var sourceLocation: MarkdownSourceLocation?
    @Binding var searchState: DocumentSearchState
    let onSourceJump: (MarkdownSourceLocation) -> Void
    let onScrollPositionChange: (DocumentScrollPosition) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSourceJump: onSourceJump)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: Coordinator.sourceJumpHandlerName)
        configuration.userContentController.add(context.coordinator, name: Coordinator.scrollPositionHandlerName)
        configuration.userContentController.addUserScript(Coordinator.scrollTrackingScript)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let didChangeDocument = context.coordinator.prepareForDocument(documentID, in: webView)
        context.coordinator.onSourceJump = onSourceJump
        context.coordinator.onScrollPositionChange = onScrollPositionChange
        context.coordinator.onSearchResult = { result in
            DispatchQueue.main.async {
                let current = DocumentSearchResult(
                    currentIndex: self.searchState.currentIndex,
                    totalCount: self.searchState.totalCount
                )
                if current != result {
                    self.searchState.updateResult(result)
                }
            }
        }
        context.coordinator.onSourceRevealConsumed = {
            DispatchQueue.main.async {
                self.sourceLocation = nil
            }
        }
        context.coordinator.setPendingSourceReveal(sourceLocation)
        context.coordinator.setPendingScrollPosition(scrollPosition, force: didChangeDocument)

        guard let service = context.coordinator.service else {
            webView.loadHTMLString(Self.errorHTML("Preview resources could not be loaded."), baseURL: nil)
            return
        }

        let shellRequest = PreviewShellRequest(
            baseURL: baseURL
        )
        let appearanceRequest = PreviewAppearanceRequest(
            theme: theme,
            zoomScale: zoomScale,
            codeFontSize: codeFontSize,
            previewWidthPercent: previewWidthPercent,
            usePointerCursors: usePointerCursors,
            fontSmoothing: fontSmoothing
        )
        let contentRequest = PreviewContentRequest(
            documentID: documentID,
            markdown: markdown
        )

        if context.coordinator.shouldLoadShell(
            shellRequest,
            pendingAppearance: appearanceRequest,
            pendingContent: contentRequest,
            pendingSearch: searchState,
            pendingSourceReveal: sourceLocation
        ) {
            let renderTask = Task { [weak webView, service] in
                do {
                    let html = try await Task.detached(priority: .userInitiated) {
                        try service.htmlDocument(
                            markdown: "",
                            appTheme: appearanceRequest.theme,
                            zoomScale: appearanceRequest.zoomScale,
                            baseFontSize: appearanceRequest.codeFontSize,
                            previewWidthPercent: appearanceRequest.previewWidthPercent,
                            usePointerCursors: appearanceRequest.usePointerCursors,
                            fontSmoothing: appearanceRequest.fontSmoothing,
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

        applyAppearance(appearanceRequest, in: webView, coordinator: context.coordinator)

        guard context.coordinator.shouldRenderContent(contentRequest) else {
            applySearch(searchState, in: webView, coordinator: context.coordinator)
            applySourceReveal(in: webView, coordinator: context.coordinator)
            applyScrollPositionIfNeeded(in: webView, coordinator: context.coordinator)
            return
        }
        renderContent(
            contentRequest,
            themeName: appearanceRequest.themeName,
            searchState: searchState,
            sourceLocation: sourceLocation,
            in: webView,
            coordinator: context.coordinator
        )
    }

    private func applyAppearance(_ request: PreviewAppearanceRequest, in webView: WKWebView, coordinator: Coordinator) {
        coordinator.setPendingAppearance(request)
        guard coordinator.isShellLoaded else { return }
        guard coordinator.shouldApplyAppearance(request) else { return }
        coordinator.applyAppearance(request, in: webView)
    }

    private func renderContent(
        _ request: PreviewContentRequest,
        themeName: String,
        searchState: DocumentSearchState,
        sourceLocation: MarkdownSourceLocation?,
        in webView: WKWebView,
        coordinator: Coordinator
    ) {
        coordinator.setPendingContent(request)
        coordinator.setPendingScrollPosition(scrollPosition)

        guard coordinator.isShellLoaded else { return }

        do {
            let payload = try Self.javaScriptPayload(markdown: request.markdown, themeName: themeName)
            webView.evaluateJavaScript("window.markprevRender && window.markprevRender(\(payload));") { _, error in
                if error != nil {
                    coordinator.markShellNeedsReload()
                } else {
                    coordinator.markRenderedContent(request)
                    coordinator.applySearch(searchState, in: webView)
                    coordinator.setPendingSourceReveal(sourceLocation)
                    let isRevealingSource = sourceLocation != nil
                    coordinator.applyPendingSourceReveal(in: webView) {
                        self.sourceLocation = nil
                    }
                    if !isRevealingSource {
                        coordinator.applyPendingScrollPositionIfNeeded(in: webView)
                    }
                }
            }
        } catch {
            webView.loadHTMLString(Self.errorHTML(error.localizedDescription), baseURL: nil)
        }
    }

    private func applySearch(_ state: DocumentSearchState, in webView: WKWebView, coordinator: Coordinator) {
        guard coordinator.isShellLoaded else { return }
        coordinator.applySearch(state, in: webView)
    }

    private func applySourceReveal(in webView: WKWebView, coordinator: Coordinator) {
        guard coordinator.isShellLoaded else { return }
        coordinator.applyPendingSourceReveal(in: webView) {
            self.sourceLocation = nil
        }
    }

    private func applyScrollPositionIfNeeded(in webView: WKWebView, coordinator: Coordinator) {
        guard coordinator.isShellLoaded, sourceLocation == nil else { return }
        coordinator.applyPendingScrollPositionIfNeeded(in: webView)
    }

    private static func javaScriptPayload(markdown: String, themeName: String) throws -> String {
        let payload = ["markdown": markdown, "theme": themeName]
        return try javaScriptPayload(payload)
    }

    private static func javaScriptPayload(_ payload: Any) throws -> String {
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
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.scrollPositionHandlerName)
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
        static let scrollPositionHandlerName = "markprevScrollPosition"
        static let scrollTrackingScript = WKUserScript(
            source: """
            (() => {
              let pending = false;
              const publish = () => {
                pending = false;
                window.webkit.messageHandlers.markprevScrollPosition.postMessage({
                  x: window.scrollX || 0,
                  y: window.scrollY || 0
                });
              };
              window.addEventListener('scroll', () => {
                if (pending) return;
                pending = true;
                window.requestAnimationFrame(publish);
              }, { passive: true });
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )

        let service = try? MarkdownRenderService()
        var onSourceJump: (MarkdownSourceLocation) -> Void
        var onScrollPositionChange: (DocumentScrollPosition) -> Void = { _ in }
        var onSearchResult: (DocumentSearchResult) -> Void = { _ in }
        var onSourceRevealConsumed: () -> Void = {}
        private var shellTask: Task<Void, Never>?
        private var documentID: String?
        private var lastShellRequest: PreviewShellRequest?
        private var lastAppliedAppearance: PreviewAppearanceRequest?
        private var lastRenderedContent: PreviewContentRequest?
        private var lastSearchRequest: DocumentSearchRequest?
        private var loadingAppearance: PreviewAppearanceRequest?
        private var pendingAppearance: PreviewAppearanceRequest?
        private var pendingContent: PreviewContentRequest?
        private var pendingSearch: DocumentSearchState?
        private var pendingSourceReveal: MarkdownSourceLocation?
        private var pendingScrollPosition: DocumentScrollPosition?
        private var shouldRestorePendingScrollPosition = false
        private var lastPublishedScrollPosition: DocumentScrollPosition?
        private(set) var isShellLoaded = false

        init(onSourceJump: @escaping (MarkdownSourceLocation) -> Void) {
            self.onSourceJump = onSourceJump
        }

        fileprivate func prepareForDocument(_ nextDocumentID: String, in webView: WKWebView) -> Bool {
            guard documentID != nextDocumentID else { return false }
            let publishPreviousScrollPosition = onScrollPositionChange
            webView.evaluateJavaScript("({ x: window.scrollX || 0, y: window.scrollY || 0 })") { value, error in
                guard error == nil else { return }
                publishPreviousScrollPosition(Self.scrollPosition(from: value))
            }
            documentID = nextDocumentID
            lastPublishedScrollPosition = nil
            shouldRestorePendingScrollPosition = true
            return true
        }

        fileprivate func shouldLoadShell(
            _ request: PreviewShellRequest,
            pendingAppearance: PreviewAppearanceRequest,
            pendingContent: PreviewContentRequest,
            pendingSearch: DocumentSearchState,
            pendingSourceReveal: MarkdownSourceLocation?
        ) -> Bool {
            self.pendingAppearance = pendingAppearance
            self.pendingContent = pendingContent
            self.pendingSearch = pendingSearch
            self.pendingSourceReveal = pendingSourceReveal ?? self.pendingSourceReveal
            if request == lastShellRequest {
                if isShellLoaded || shellTask != nil {
                    return false
                }
            }

            lastShellRequest = request
            isShellLoaded = false
            lastRenderedContent = nil
            lastAppliedAppearance = nil
            lastSearchRequest = nil
            loadingAppearance = pendingAppearance
            shellTask?.cancel()
            return true
        }

        fileprivate func shouldApplyAppearance(_ request: PreviewAppearanceRequest) -> Bool {
            request != lastAppliedAppearance
        }

        fileprivate func shouldRenderContent(_ request: PreviewContentRequest) -> Bool {
            guard request != lastRenderedContent else { return false }
            return true
        }

        fileprivate func setPendingAppearance(_ request: PreviewAppearanceRequest) {
            pendingAppearance = request
        }

        fileprivate func setPendingContent(_ request: PreviewContentRequest) {
            pendingContent = request
        }

        fileprivate func setPendingSourceReveal(_ location: MarkdownSourceLocation?) {
            guard let location else { return }
            pendingSourceReveal = location
        }

        fileprivate func setPendingScrollPosition(_ position: DocumentScrollPosition?, force: Bool = false) {
            pendingScrollPosition = position
            if force {
                shouldRestorePendingScrollPosition = true
            }
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
            lastSearchRequest = nil
        }

        fileprivate func markAppliedAppearance(_ request: PreviewAppearanceRequest) {
            lastAppliedAppearance = request
        }

        fileprivate func applyAppearance(_ request: PreviewAppearanceRequest, in webView: WKWebView) {
            guard let service else { return }
            let variables = Dictionary(uniqueKeysWithValues: service.themeVariableValues(
                for: request.theme,
                zoomScale: request.zoomScale,
                baseFontSize: request.codeFontSize,
                previewWidthPercent: request.previewWidthPercent,
                usePointerCursors: request.usePointerCursors,
                fontSmoothing: request.fontSmoothing
            ))
            let payload: [String: Any] = [
                "theme": request.themeName,
                "variables": variables
            ]

            do {
                let json = try MarkdownPreviewView.javaScriptPayload(payload)
                webView.evaluateJavaScript("window.markprevApplyAppearance && window.markprevApplyAppearance(\(json));") { [weak self] _, error in
                    if error == nil {
                        self?.markAppliedAppearance(request)
                    }
                }
            } catch {
                webView.loadHTMLString(MarkdownPreviewView.errorHTML(error.localizedDescription), baseURL: nil)
            }
        }

        fileprivate func applySearch(_ state: DocumentSearchState, in webView: WKWebView) {
            let request = DocumentSearchRequest(state)
            guard request != lastSearchRequest else { return }
            lastSearchRequest = request

            let payload: [String: Any] = [
                "query": request.query,
                "direction": request.navigationDirection.rawValue,
                "navigationSerial": request.navigationSerial,
                "isPresented": request.isPresented
            ]

            do {
                let json = try MarkdownPreviewView.javaScriptPayload(payload)
                webView.evaluateJavaScript("window.markprevSearch && window.markprevSearch(\(json));") { [weak self] value, _ in
                    let result = Self.parseSearchResult(value)
                    self?.onSearchResult(result)
                }
            } catch {
                onSearchResult(.init())
            }
        }

        fileprivate func applyPendingSourceReveal(in webView: WKWebView, onConsumed: @escaping () -> Void) {
            guard let location = pendingSourceReveal, lastRenderedContent != nil else { return }

            let payload: [String: Any] = [
                "line": location.line,
                "offset": location.offset
            ]

            do {
                let json = try MarkdownPreviewView.javaScriptPayload(payload)
                webView.evaluateJavaScript("window.markprevRevealSourceLine && window.markprevRevealSourceLine(\(json));") { [weak self] value, _ in
                    let didReveal = (value as? NSNumber)?.boolValue ?? value as? Bool ?? false
                    guard didReveal else { return }
                    self?.pendingSourceReveal = nil
                    DispatchQueue.main.async {
                        onConsumed()
                    }
                }
            } catch {
                onConsumed()
            }
        }

        fileprivate func applyPendingScrollPositionIfNeeded(in webView: WKWebView) {
            guard shouldRestorePendingScrollPosition else { return }
            shouldRestorePendingScrollPosition = false

            let position = pendingScrollPosition ?? DocumentScrollPosition(x: 0, y: 0)
            guard position.x.isFinite, position.y.isFinite else {
                webView.evaluateJavaScript("window.scrollTo(0, 0);")
                return
            }

            webView.evaluateJavaScript("window.scrollTo(\(position.x), \(position.y));")
        }

        private static func parseSearchResult(_ value: Any?) -> DocumentSearchResult {
            guard let payload = value as? [String: Any] else {
                return .init()
            }

            let current = (payload["currentIndex"] as? NSNumber)?.intValue
                ?? payload["currentIndex"] as? Int
                ?? 0
            let total = (payload["totalCount"] as? NSNumber)?.intValue
                ?? payload["totalCount"] as? Int
                ?? 0

            return DocumentSearchResult(currentIndex: current, totalCount: total)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            shellTask = nil
            isShellLoaded = true
            lastAppliedAppearance = loadingAppearance
            if let pendingAppearance, pendingAppearance != loadingAppearance {
                applyAppearance(pendingAppearance, in: webView)
            }
            loadingAppearance = nil

            guard let pendingContent else { return }

            do {
                let payload = try MarkdownPreviewView.javaScriptPayload(
                    markdown: pendingContent.markdown,
                    themeName: pendingAppearance?.themeName ?? "light"
                )
                webView.evaluateJavaScript("window.markprevRender && window.markprevRender(\(payload));") { [weak self] _, _ in
                    guard let self else { return }
                    self.lastRenderedContent = pendingContent
                    self.lastSearchRequest = nil
                    if let pendingSearch = self.pendingSearch {
                        self.applySearch(pendingSearch, in: webView)
                    }
                    let isRevealingSource = self.pendingSourceReveal != nil
                    self.applyPendingSourceReveal(in: webView, onConsumed: self.onSourceRevealConsumed)
                    if !isRevealingSource {
                        self.applyPendingScrollPositionIfNeeded(in: webView)
                    }
                }
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
            if message.name == Self.scrollPositionHandlerName {
                publishScrollPosition(from: message.body)
                return
            }

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

        private func publishScrollPosition(from body: Any) {
            let position = Self.scrollPosition(from: body)
            guard position.isMeaningfullyDifferent(from: lastPublishedScrollPosition) else { return }
            lastPublishedScrollPosition = position
            onScrollPositionChange(position)
        }

        private static func scrollPosition(from body: Any?) -> DocumentScrollPosition {
            guard let body = body as? [String: Any] else {
                return DocumentScrollPosition(x: 0, y: 0)
            }

            let x = (body["x"] as? NSNumber)?.doubleValue ?? body["x"] as? Double ?? 0
            let y = (body["y"] as? NSNumber)?.doubleValue ?? body["y"] as? Double ?? 0
            return DocumentScrollPosition(x: x, y: y)
        }
    }
}

fileprivate struct PreviewShellRequest: Equatable {
    let baseURL: URL?
}

fileprivate struct PreviewAppearanceRequest: Equatable {
    let theme: AppTheme
    let zoomScale: Double
    let codeFontSize: Double
    let previewWidthPercent: Double
    let usePointerCursors: Bool
    let fontSmoothing: Bool

    var themeName: String {
        theme.isDark ? "dark" : "light"
    }
}

fileprivate struct PreviewContentRequest: Equatable {
    let documentID: String
    let markdown: String
}

private enum PreviewRenderError: Error, LocalizedError {
    case invalidPayload

    var errorDescription: String? {
        "Could not encode Markdown preview payload."
    }
}
