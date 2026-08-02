import MonknotCore
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
    let syncScrollEnabled: Bool
    let syncScrollTargetLine: Int?
    @Binding var sourceLocation: MarkdownSourceLocation?
    @Binding var searchState: DocumentSearchState
    let onSourceJump: (MarkdownSourceLocation) -> Void
    let onScrollPositionChange: (DocumentScrollPosition) -> Void
    let onVisibleSourceLineChange: ((Int) -> Void)?

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
        webView.identifier = .monknotDocumentFocusTarget
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let didChangeDocument = context.coordinator.prepareForDocument(documentID, in: webView)
        context.coordinator.onSourceJump = onSourceJump
        context.coordinator.onScrollPositionChange = onScrollPositionChange
        context.coordinator.onVisibleSourceLineChange = onVisibleSourceLineChange
        context.coordinator.syncScrollEnabled = syncScrollEnabled
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
        context.coordinator.applySyncScrollTargetLine(syncScrollTargetLine, in: webView)

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

        coordinator.scheduleContentRender(
            request,
            themeName: themeName,
            searchState: searchState,
            sourceLocation: sourceLocation,
            in: webView
        ) {
            self.sourceLocation = nil
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
        static let sourceJumpHandlerName = "monknotSourceJump"
        static let scrollPositionHandlerName = "monknotScrollPosition"
        static let scrollTrackingScript = WKUserScript(
            source: """
            (() => {
              let pending = false;
              const publish = () => {
                pending = false;
                const payload = {
                  x: window.scrollX || 0,
                  y: window.scrollY || 0
                };
                if (window.monknotVisibleSourceLine) {
                  payload.sourceLine = window.monknotVisibleSourceLine();
                }
                window.webkit.messageHandlers.monknotScrollPosition.postMessage(payload);
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
        var onVisibleSourceLineChange: ((Int) -> Void)?
        var syncScrollEnabled = false
        var onSearchResult: (DocumentSearchResult) -> Void = { _ in }
        var onSourceRevealConsumed: () -> Void = {}
        private var shellTask: Task<Void, Never>?
        private var renderTask: Task<Void, Never>?
        private var renderSerial = 0
        private var documentID: String?
        private var lastShellRequest: PreviewShellRequest?
        private var lastAppliedAppearance: PreviewAppearanceRequest?
        private var lastRenderedContent: PreviewContentRequest?
        private var scheduledRenderContent: PreviewContentRequest?
        private var lastSearchRequest: DocumentSearchRequest?
        private var loadingAppearance: PreviewAppearanceRequest?
        private var pendingAppearance: PreviewAppearanceRequest?
        private var pendingContent: PreviewContentRequest?
        private var pendingSearch: DocumentSearchState?
        private var pendingSourceReveal: MarkdownSourceLocation?
        private var pendingScrollPosition: DocumentScrollPosition?
        private var shouldRestorePendingScrollPosition = false
        private var lastPublishedScrollPosition: DocumentScrollPosition?
        private var lastPublishedSourceLine: Int?
        private var lastAppliedSyncScrollLine: Int?
        private var isApplyingSyncScroll = false
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
            scheduledRenderContent = nil
            lastAppliedAppearance = nil
            lastSearchRequest = nil
            loadingAppearance = pendingAppearance
            shellTask?.cancel()
            renderTask?.cancel()
            renderSerial += 1
            return true
        }

        fileprivate func shouldApplyAppearance(_ request: PreviewAppearanceRequest) -> Bool {
            request != lastAppliedAppearance
        }

        fileprivate func shouldRenderContent(_ request: PreviewContentRequest) -> Bool {
            guard request != lastRenderedContent else { return false }
            guard request != scheduledRenderContent else { return false }
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
            renderTask?.cancel()
            renderTask = nil
            scheduledRenderContent = nil
            renderSerial += 1
        }

        func markShellNeedsReload() {
            isShellLoaded = false
            lastShellRequest = nil
            shellTask = nil
            renderTask?.cancel()
            renderTask = nil
            scheduledRenderContent = nil
            renderSerial += 1
        }

        fileprivate func markRenderedContent(_ request: PreviewContentRequest) {
            lastRenderedContent = request
            scheduledRenderContent = nil
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
                webView.evaluateJavaScript("window.monknotApplyAppearance && window.monknotApplyAppearance(\(json));") { [weak self] _, error in
                    if error == nil {
                        self?.markAppliedAppearance(request)
                    }
                }
            } catch {
                webView.loadHTMLString(MarkdownPreviewView.errorHTML(error.localizedDescription), baseURL: nil)
            }
        }

        fileprivate func applySearch(_ state: DocumentSearchState, in webView: WKWebView) {
            pendingSearch = state
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
                webView.evaluateJavaScript("window.monknotSearch && window.monknotSearch(\(json));") { [weak self] value, _ in
                    let result = Self.parseSearchResult(value)
                    self?.onSearchResult(result)
                }
            } catch {
                onSearchResult(.init())
            }
        }

        fileprivate func scheduleContentRender(
            _ request: PreviewContentRequest,
            themeName: String,
            searchState: DocumentSearchState,
            sourceLocation: MarkdownSourceLocation?,
            in webView: WKWebView,
            onSourceRevealConsumed: @escaping () -> Void
        ) {
            guard isShellLoaded else { return }

            renderSerial += 1
            let serial = renderSerial
            scheduledRenderContent = request
            pendingSearch = searchState
            setPendingSourceReveal(sourceLocation)
            renderTask?.cancel()

            let delayNanoseconds = Self.renderDebounceNanoseconds(
                for: request,
                lastRenderedContent: lastRenderedContent
            )
            renderTask = Task { [weak self, weak webView] in
                if delayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: delayNanoseconds)
                }

                guard !Task.isCancelled else { return }

                let latestThemeName = await MainActor.run {
                    self?.pendingAppearance?.themeName ?? themeName
                }

                let payload: String
                do {
                    payload = try MarkdownPreviewView.javaScriptPayload(
                        markdown: request.markdown,
                        themeName: latestThemeName
                    )
                } catch {
                    await MainActor.run {
                        _ = webView?.loadHTMLString(MarkdownPreviewView.errorHTML(error.localizedDescription), baseURL: nil)
                    }
                    return
                }

                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard let self, self.renderSerial == serial, let webView else { return }
                    webView.evaluateJavaScript("window.monknotRender && window.monknotRender(\(payload));") { [weak self, weak webView] _, error in
                        guard let self, self.renderSerial == serial, let webView else { return }
                        self.renderTask = nil
                        if error != nil {
                            self.markShellNeedsReload()
                            return
                        }

                        self.markRenderedContent(request)
                        self.applySearch(self.pendingSearch ?? searchState, in: webView)
                        self.setPendingSourceReveal(sourceLocation)
                        let isRevealingSource = sourceLocation != nil
                        self.applyPendingSourceReveal(in: webView, onConsumed: onSourceRevealConsumed)
                        if !isRevealingSource {
                            self.applyPendingScrollPositionIfNeeded(in: webView)
                        }
                    }
                }
            }
        }

        private static func renderDebounceNanoseconds(
            for request: PreviewContentRequest,
            lastRenderedContent: PreviewContentRequest?
        ) -> UInt64 {
            guard lastRenderedContent?.documentID == request.documentID else {
                return 0
            }

            let byteCount = request.markdown.utf8.count
            if byteCount >= 500_000 {
                return 450_000_000
            }
            if byteCount >= 100_000 {
                return 180_000_000
            }
            return 0
        }

        fileprivate func applyPendingSourceReveal(in webView: WKWebView, onConsumed: @escaping () -> Void) {
            guard let location = pendingSourceReveal, lastRenderedContent != nil else { return }

            let payload: [String: Any] = [
                "line": location.line,
                "offset": location.offset
            ]

            do {
                let json = try MarkdownPreviewView.javaScriptPayload(payload)
                webView.evaluateJavaScript("window.monknotRevealSourceLine && window.monknotRevealSourceLine(\(json));") { [weak self] value, _ in
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

        fileprivate func applySyncScrollTargetLine(_ line: Int?, in webView: WKWebView) {
            guard syncScrollEnabled, isShellLoaded, lastRenderedContent != nil else { return }
            guard let line, line > 0, line != lastAppliedSyncScrollLine else { return }

            lastAppliedSyncScrollLine = line
            isApplyingSyncScroll = true

            let payload: [String: Any] = ["line": line]
            do {
                let json = try MarkdownPreviewView.javaScriptPayload(payload)
                webView.evaluateJavaScript("window.monknotScrollToLine && window.monknotScrollToLine(\(json));") { [weak self] _, _ in
                    self?.isApplyingSyncScroll = false
                }
            } catch {
                isApplyingSyncScroll = false
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
            scheduleContentRender(
                pendingContent,
                themeName: pendingAppearance?.themeName ?? "light",
                searchState: pendingSearch ?? DocumentSearchState(),
                sourceLocation: pendingSourceReveal,
                in: webView,
                onSourceRevealConsumed: onSourceRevealConsumed
            )
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

            guard syncScrollEnabled, !isApplyingSyncScroll else { return }
            let sourceLine = Self.sourceLine(from: body)
            guard sourceLine > 0, sourceLine != lastPublishedSourceLine else { return }
            lastPublishedSourceLine = sourceLine
            onVisibleSourceLineChange?(sourceLine)
        }

        private static func sourceLine(from body: Any?) -> Int {
            guard let body = body as? [String: Any] else { return 0 }
            return (body["sourceLine"] as? NSNumber)?.intValue ?? body["sourceLine"] as? Int ?? 0
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
