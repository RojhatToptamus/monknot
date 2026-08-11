import MonknotCore
import SwiftUI
import WebKit

struct MarkdownPreviewRenderIdentity: Equatable, Hashable {
    let documentID: String
    let renderID: Int
}

struct MarkdownPreviewLinkRequest: Equatable {
    let identity: MarkdownPreviewRenderIdentity
    let kind: MarkdownWorkspaceLinkKind
    let destination: String
}

struct MarkdownPreviewTaskRequest: Equatable {
    let identity: MarkdownPreviewRenderIdentity
    let sourceLine: Int
    let expectedChecked: Bool
    let desiredChecked: Bool
}

enum MarkdownPreviewBridgeInteraction: Equatable {
    case link(MarkdownPreviewLinkRequest)
    case task(MarkdownPreviewTaskRequest)
}

struct MarkdownPreviewView: NSViewRepresentable {
    let documentID: String
    let markdown: String
    let baseURL: URL?
    let theme: AppTheme
    let zoomScale: Double
    let codeFontSize: Double
    let contentWidthPercent: Double
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
    let onLinkRequest: (MarkdownPreviewLinkRequest) -> Void
    let onTaskRequest: (MarkdownPreviewTaskRequest) -> Void

    init(
        documentID: String,
        markdown: String,
        baseURL: URL?,
        theme: AppTheme,
        zoomScale: Double,
        codeFontSize: Double,
        contentWidthPercent: Double,
        usePointerCursors: Bool,
        fontSmoothing: Bool,
        scrollPosition: DocumentScrollPosition?,
        syncScrollEnabled: Bool,
        syncScrollTargetLine: Int?,
        sourceLocation: Binding<MarkdownSourceLocation?>,
        searchState: Binding<DocumentSearchState>,
        onSourceJump: @escaping (MarkdownSourceLocation) -> Void,
        onLinkRequest: @escaping (MarkdownPreviewLinkRequest) -> Void = { _ in },
        onTaskRequest: @escaping (MarkdownPreviewTaskRequest) -> Void = { _ in },
        onScrollPositionChange: @escaping (DocumentScrollPosition) -> Void,
        onVisibleSourceLineChange: ((Int) -> Void)?
    ) {
        self.documentID = documentID
        self.markdown = markdown
        self.baseURL = baseURL
        self.theme = theme
        self.zoomScale = zoomScale
        self.codeFontSize = codeFontSize
        self.contentWidthPercent = contentWidthPercent
        self.usePointerCursors = usePointerCursors
        self.fontSmoothing = fontSmoothing
        self.scrollPosition = scrollPosition
        self.syncScrollEnabled = syncScrollEnabled
        self.syncScrollTargetLine = syncScrollTargetLine
        self._sourceLocation = sourceLocation
        self._searchState = searchState
        self.onSourceJump = onSourceJump
        self.onLinkRequest = onLinkRequest
        self.onTaskRequest = onTaskRequest
        self.onScrollPositionChange = onScrollPositionChange
        self.onVisibleSourceLineChange = onVisibleSourceLineChange
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSourceJump: onSourceJump)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: Coordinator.sourceJumpHandlerName)
        configuration.userContentController.add(context.coordinator, name: Coordinator.scrollPositionHandlerName)
        configuration.userContentController.add(context.coordinator, name: Coordinator.interactionHandlerName)
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
        context.coordinator.onLinkRequest = onLinkRequest
        context.coordinator.onTaskRequest = onTaskRequest
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
            zoomScale: WorkspaceZoomPolicy.documentScale(zoomScale),
            codeFontSize: codeFontSize,
            contentWidthPercent: contentWidthPercent,
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
                            contentWidthPercent: appearanceRequest.contentWidthPercent,
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

    private static func javaScriptPayload(
        markdown: String,
        themeName: String,
        documentID: String,
        renderID: Int
    ) throws -> String {
        let payload: [String: Any] = [
            "markdown": markdown,
            "theme": themeName,
            "documentID": documentID,
            "renderID": renderID,
        ]
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
        webView.evaluateJavaScript(
            "window.monknotTearDown && window.monknotTearDown(); window.monknotScrollTrackingTeardown && window.monknotScrollTrackingTeardown();"
        )
        webView.stopLoading()
        coordinator.tearDown()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.sourceJumpHandlerName)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.scrollPositionHandlerName)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.interactionHandlerName)
        webView.configuration.userContentController.removeAllUserScripts()
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
        static let interactionHandlerName = "monknotInteraction"
        static let scrollTrackingScript = WKUserScript(
            source: """
            (() => {
              window.monknotScrollTrackingTeardown?.();
              let pending = false;
              const publish = () => {
                pending = false;
                const payload = {
                  x: window.scrollX || 0,
                  y: window.scrollY || 0
                };
                const identity = window.monknotCurrentIdentity?.();
                if (identity) {
                  payload.documentID = identity.documentID;
                  payload.renderID = identity.renderID;
                }
                if (window.monknotVisibleSourceLine) {
                  payload.sourceLine = window.monknotVisibleSourceLine();
                }
                window.webkit.messageHandlers.monknotScrollPosition.postMessage(payload);
              };
              const handleScroll = () => {
                if (pending) return;
                pending = true;
                window.requestAnimationFrame(publish);
              };
              window.addEventListener('scroll', handleScroll, { passive: true });
              window.monknotScrollTrackingTeardown = () => {
                window.removeEventListener('scroll', handleScroll);
                window.monknotScrollTrackingTeardown = undefined;
              };
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )

        let service = try? MarkdownRenderService()
        var onSourceJump: (MarkdownSourceLocation) -> Void
        var onScrollPositionChange: (DocumentScrollPosition) -> Void = { _ in }
        var onVisibleSourceLineChange: ((Int) -> Void)?
        var onLinkRequest: (MarkdownPreviewLinkRequest) -> Void = { _ in }
        var onTaskRequest: (MarkdownPreviewTaskRequest) -> Void = { _ in }
        var syncScrollEnabled = false
        var onSearchResult: (DocumentSearchResult) -> Void = { _ in }
        var onSourceRevealConsumed: () -> Void = {}
        private var shellTask: Task<Void, Never>?
        private var renderTask: Task<Void, Never>?
        private var renderSerial = 0
        private var activeRenderID: Int?
        private var documentID: String?
        private var isTornDown = false
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
            activeRenderID = nil
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
            activeRenderID = nil
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

        func tearDown() {
            guard !isTornDown else { return }
            isTornDown = true
            cancelShellLoad()
            documentID = nil
            activeRenderID = nil
            onSourceJump = { _ in }
            onScrollPositionChange = { _ in }
            onVisibleSourceLineChange = nil
            onSearchResult = { _ in }
            onSourceRevealConsumed = {}
            onLinkRequest = { _ in }
            onTaskRequest = { _ in }
        }

        func markShellNeedsReload() {
            isShellLoaded = false
            lastShellRequest = nil
            shellTask = nil
            renderTask?.cancel()
            renderTask = nil
            scheduledRenderContent = nil
            activeRenderID = nil
            renderSerial += 1
        }

        fileprivate func markRenderedContent(_ request: PreviewContentRequest, renderID: Int) {
            lastRenderedContent = request
            activeRenderID = renderID
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
                contentWidthPercent: request.contentWidthPercent,
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
                        themeName: latestThemeName,
                        documentID: request.documentID,
                        renderID: serial
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

                        self.markRenderedContent(request, renderID: serial)
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
            guard !isTornDown else { return }
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

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated else {
                decisionHandler(isTornDown ? .cancel : .allow)
                return
            }

            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if Self.allowsActivatedNavigation(to: url, currentURL: webView.url) {
                decisionHandler(.allow)
                return
            }

            decisionHandler(.cancel)
            guard let identity = currentIdentity else { return }
            let destination = url.absoluteString
            guard !destination.isEmpty, destination.utf8.count <= 16_384 else { return }
            onLinkRequest(MarkdownPreviewLinkRequest(
                identity: identity,
                kind: .markdown,
                destination: destination
            ))
        }

        static func allowsActivatedNavigation(to url: URL, currentURL: URL?) -> Bool {
            let fragment = url.fragment?.lowercased() ?? ""
            guard fragment.hasPrefix("fn-") || fragment.hasPrefix("fnref-") else { return false }
            guard let currentURL else { return false }
            if url.isFileURL, currentURL.isFileURL {
                return url.standardizedFileURL.path == currentURL.standardizedFileURL.path
            }
            return url.scheme == currentURL.scheme
                && url.host == currentURL.host
                && url.path == currentURL.path
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !isTornDown else { return }
            if message.name == Self.scrollPositionHandlerName {
                guard validatedIdentity(from: message.body) != nil else { return }
                publishScrollPosition(from: message.body)
                return
            }

            if message.name == Self.interactionHandlerName {
                handleInteraction(message.body)
                return
            }

            guard message.name == Self.sourceJumpHandlerName else { return }
            guard let body = message.body as? [String: Any],
                  validatedIdentity(from: body) != nil,
                  let line = Self.integer(body["line"]),
                  line > 0
            else { return }
            let offset = max(0, Self.integer(body["offset"]) ?? 0)
            let location = MarkdownSourceLocation(line: line, offset: offset)

            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTornDown else { return }
                self.onSourceJump(location)
            }
        }

        private var currentIdentity: MarkdownPreviewRenderIdentity? {
            guard let documentID, let activeRenderID, activeRenderID > 0 else { return nil }
            return MarkdownPreviewRenderIdentity(documentID: documentID, renderID: activeRenderID)
        }

        private func validatedIdentity(from body: Any) -> MarkdownPreviewRenderIdentity? {
            guard let body = body as? [String: Any],
                  let messageDocumentID = body["documentID"] as? String,
                  !messageDocumentID.isEmpty,
                  let messageRenderID = Self.integer(body["renderID"]),
                  messageRenderID > 0
            else { return nil }
            let identity = MarkdownPreviewRenderIdentity(
                documentID: messageDocumentID,
                renderID: messageRenderID
            )
            return identity == currentIdentity ? identity : nil
        }

        private func handleInteraction(_ value: Any) {
            guard let currentIdentity,
                  let interaction = Self.bridgeInteraction(from: value, expectedIdentity: currentIdentity)
            else { return }
            switch interaction {
            case .link(let request):
                onLinkRequest(request)
            case .task(let request):
                onTaskRequest(request)
            }
        }

        static func bridgeInteraction(
            from value: Any,
            expectedIdentity: MarkdownPreviewRenderIdentity
        ) -> MarkdownPreviewBridgeInteraction? {
            guard let body = value as? [String: Any],
                  messageIdentity(from: body) == expectedIdentity,
                  let action = body["action"] as? String
            else { return nil }
            switch action {
            case "link":
                guard let destination = body["destination"] as? String,
                      !destination.isEmpty,
                      destination.utf8.count <= 16_384
                else { return nil }
                let kind = (body["kind"] as? String).flatMap(MarkdownWorkspaceLinkKind.init(rawValue:))
                    ?? .markdown
                guard kind == .markdown || kind == .wikilink else { return nil }
                return .link(MarkdownPreviewLinkRequest(
                    identity: expectedIdentity,
                    kind: kind,
                    destination: destination
                ))
            case "task":
                guard let sourceLine = integer(body["sourceLine"]),
                      sourceLine > 0,
                      let expectedChecked = boolean(body["expectedChecked"]),
                      let desiredChecked = boolean(body["desiredChecked"]),
                      expectedChecked != desiredChecked
                else { return nil }
                return .task(MarkdownPreviewTaskRequest(
                    identity: expectedIdentity,
                    sourceLine: sourceLine,
                    expectedChecked: expectedChecked,
                    desiredChecked: desiredChecked
                ))
            default:
                return nil
            }
        }

        private static func messageIdentity(from body: [String: Any]) -> MarkdownPreviewRenderIdentity? {
            guard let documentID = body["documentID"] as? String,
                  !documentID.isEmpty,
                  let renderID = integer(body["renderID"]),
                  renderID > 0
            else { return nil }
            return MarkdownPreviewRenderIdentity(documentID: documentID, renderID: renderID)
        }

        private static func integer(_ value: Any?) -> Int? {
            if let number = value as? NSNumber { return number.intValue }
            return value as? Int
        }

        private static func boolean(_ value: Any?) -> Bool? {
            if let number = value as? NSNumber { return number.boolValue }
            return value as? Bool
        }

        private func publishScrollPosition(from body: Any) {
            let position = Self.scrollPosition(from: body)
            guard position.isMeaningfullyDifferent(from: lastPublishedScrollPosition) else { return }
            lastPublishedScrollPosition = position
            onScrollPositionChange(position)

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
    let contentWidthPercent: Double
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
