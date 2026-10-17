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
    /// The workspace root; local images and other files load from inside it only.
    let resourceRoot: URL?
    let theme: AppTheme
    let zoomScale: Double
    let codeFontSize: Double
    let contentWidthPercent: Double
    let usePointerCursors: Bool
    let fontSmoothing: Bool
    let scrollPosition: DocumentScrollPosition?
    let syncScrollEnabled: Bool
    let syncScrollTargetLine: Int?
    /// The source line to show at the top when the preview is created for a document already on
    /// screen (Source, Preview or split changed), instead of its own saved offset.
    let openingTopLine: Int?
    @Binding var sourceLocation: MarkdownSourceLocation?
    @Binding var searchState: DocumentSearchState
    let searchOptions: MonknotSearchOptions
    let onSourceJump: (MarkdownSourceLocation) -> Void
    let onScrollPositionChange: (DocumentScrollPosition) -> Void
    let onVisibleSourceLineChange: ((Int) -> Void)?
    let onLinkRequest: (MarkdownPreviewLinkRequest) -> Void
    let onTaskRequest: (MarkdownPreviewTaskRequest) -> Void
    /// Present when Preview edits the document in place.
    let editing: MarkdownVisualEditingConfiguration?

    init(
        documentID: String,
        markdown: String,
        baseURL: URL?,
        resourceRoot: URL? = nil,
        theme: AppTheme,
        zoomScale: Double,
        codeFontSize: Double,
        contentWidthPercent: Double,
        usePointerCursors: Bool,
        fontSmoothing: Bool,
        scrollPosition: DocumentScrollPosition?,
        syncScrollEnabled: Bool,
        syncScrollTargetLine: Int?,
        openingTopLine: Int? = nil,
        sourceLocation: Binding<MarkdownSourceLocation?>,
        searchState: Binding<DocumentSearchState>,
        searchOptions: MonknotSearchOptions = MonknotSearchOptions(),
        onSourceJump: @escaping (MarkdownSourceLocation) -> Void,
        onLinkRequest: @escaping (MarkdownPreviewLinkRequest) -> Void = { _ in },
        onTaskRequest: @escaping (MarkdownPreviewTaskRequest) -> Void = { _ in },
        onScrollPositionChange: @escaping (DocumentScrollPosition) -> Void,
        onVisibleSourceLineChange: ((Int) -> Void)?,
        editing: MarkdownVisualEditingConfiguration? = nil
    ) {
        self.documentID = documentID
        self.markdown = markdown
        self.baseURL = baseURL
        self.resourceRoot = resourceRoot
        self.theme = theme
        self.zoomScale = zoomScale
        self.codeFontSize = codeFontSize
        self.contentWidthPercent = contentWidthPercent
        self.usePointerCursors = usePointerCursors
        self.fontSmoothing = fontSmoothing
        self.scrollPosition = scrollPosition
        self.syncScrollEnabled = syncScrollEnabled
        self.syncScrollTargetLine = syncScrollTargetLine
        self.openingTopLine = openingTopLine
        self._sourceLocation = sourceLocation
        self._searchState = searchState
        self.searchOptions = searchOptions
        self.onSourceJump = onSourceJump
        self.onLinkRequest = onLinkRequest
        self.onTaskRequest = onTaskRequest
        self.onScrollPositionChange = onScrollPositionChange
        self.onVisibleSourceLineChange = onVisibleSourceLineChange
        self.editing = editing
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
        configuration.userContentController.add(context.coordinator, name: Coordinator.editorHandlerName)
        configuration.userContentController.addUserScript(Coordinator.scrollTrackingScript)
        if #available(macOS 15.0, *), editing != nil,
           configuration.responds(to: NSSelectorFromString("setWritingToolsBehavior:")) {
            // Writing Tools would rewrite the page directly; the editor changes it only through
            // source patches. Source keeps Writing Tools. The property is declared only for a
            // macOS 15 deployment target, hence key-value coding.
            configuration.setValue(NSWritingToolsBehavior.none.rawValue, forKey: "writingToolsBehavior")
        }

        configuration.setURLSchemeHandler(
            context.coordinator.resourceHandler,
            forURLScheme: WorkspaceResourceSchemeHandler.scheme
        )

        let webView = MarkdownEditorWebView(frame: .zero, configuration: configuration)
        webView.visualEditingSession = editing?.session
        webView.identifier = .monknotDocumentFocusTarget
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let isNewPreview = !context.coordinator.hasDocument
        let didChangeDocument = context.coordinator.prepareForDocument(documentID, in: webView)
        if isNewPreview {
            context.coordinator.openAtLine(openingTopLine, ignoringSyncLine: syncScrollTargetLine)
        }
        context.coordinator.onSourceJump = onSourceJump
        context.coordinator.onScrollPositionChange = onScrollPositionChange
        context.coordinator.onVisibleSourceLineChange = onVisibleSourceLineChange
        context.coordinator.onLinkRequest = onLinkRequest
        context.coordinator.onTaskRequest = onTaskRequest
        context.coordinator.syncScrollEnabled = syncScrollEnabled
        context.coordinator.onSearchResult = WebViewBridge.searchResultPublisher(for: $searchState)
        context.coordinator.onSourceRevealConsumed = {
            DispatchQueue.main.async {
                self.sourceLocation = nil
            }
        }
        context.coordinator.setPendingSearchOptions(searchOptions)
        context.coordinator.setPendingSourceReveal(sourceLocation)
        context.coordinator.setPendingScrollPosition(scrollPosition, force: didChangeDocument)
        context.coordinator.applySyncScrollTargetLine(syncScrollTargetLine, in: webView)
        context.coordinator.configureEditing(editing, documentID: documentID, in: webView)

        guard let service = context.coordinator.service else {
            webView.loadHTMLString(Self.errorHTML("Preview resources could not be loaded."), baseURL: nil)
            return
        }

        context.coordinator.resourceHandler.rootURL = resourceRoot
        let isEditable = editing != nil && service.supportsVisualEditing
        let shellRequest = PreviewShellRequest(
            baseURL: WorkspaceResourceSchemeHandler.pageBaseURL(forDirectory: baseURL),
            isEditable: isEditable
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
                            editable: shellRequest.isEditable,
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

        if let commandRequest = editing?.commandRequest {
            context.coordinator.applyEditorCommand(commandRequest, in: webView)
        }
        if context.coordinator.syncEditorIfActive(contentRequest, in: webView) {
            applySearch(searchState, options: searchOptions, in: webView, coordinator: context.coordinator)
            applySourceReveal(in: webView, coordinator: context.coordinator)
            applyScrollPositionIfNeeded(in: webView, coordinator: context.coordinator)
            return
        }

        guard context.coordinator.shouldRenderContent(contentRequest) else {
            applySearch(searchState, options: searchOptions, in: webView, coordinator: context.coordinator)
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

    private func applySearch(
        _ state: DocumentSearchState,
        options: MonknotSearchOptions,
        in webView: WKWebView,
        coordinator: Coordinator
    ) {
        guard coordinator.isShellLoaded else { return }
        coordinator.applySearch(state, options: options, in: webView)
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
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.editorHandlerName)
        webView.configuration.userContentController.removeAllUserScripts()
        (webView as? MarkdownEditorWebView)?.visualEditingSession = nil
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

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, MarkdownVisualEditorChannel {
        static let editorHandlerName = "monknotEditor"
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
        private var pendingSearchOptions = MonknotSearchOptions()
        private var pendingSourceReveal: MarkdownSourceLocation?
        private var pendingScrollPosition: DocumentScrollPosition?
        private var shouldRestorePendingScrollPosition = false
        private var lastPublishedScrollPosition: DocumentScrollPosition?
        private var lastPublishedSourceLine: Int?
        private var lastAppliedSyncScrollLine: Int?
        /// A source line to show at the top once content has rendered: a split-view line that
        /// arrived while the preview was loading, or a rebuilt preview's opening line.
        private var pendingSyncScrollLine: Int?
        private var suppressesNextSourceLine = false
        private(set) var isShellLoaded = false

        let resourceHandler = WorkspaceResourceSchemeHandler()

        init(onSourceJump: @escaping (MarkdownSourceLocation) -> Void) {
            self.onSourceJump = onSourceJump
        }

        // MARK: - Visual editing

        /// The page's copy of the source as of the last change it reported (`acknowledged`), so a
        /// store update the page caused is recognised and not sent back.
        private final class EditorState {
            var configuration: MarkdownVisualEditingConfiguration
            var documentID: String
            var renderID = 0
            var mirror: String?
            var acknowledged = 0
            var isReady = false
            var awaitingReset: String?
            var lastCommandSerial: Int?

            init(configuration: MarkdownVisualEditingConfiguration, documentID: String) {
                self.configuration = configuration
                self.documentID = documentID
            }
        }

        private var editor: EditorState?
        private weak var editorWebView: WKWebView?
        private var wikilinkTask: Task<Void, Never>?

        var isEditing: Bool { editor != nil }

        fileprivate func configureEditing(
            _ configuration: MarkdownVisualEditingConfiguration?,
            documentID: String,
            in webView: WKWebView
        ) {
            editorWebView = webView
            guard let configuration else {
                editor = nil
                return
            }
            configuration.session.prepare(documentID: documentID)
            configuration.session.channel = self
            (webView as? MarkdownEditorWebView)?.visualEditingSession = configuration.session
            if let editor, editor.documentID == documentID {
                editor.configuration = configuration
            } else {
                let state = EditorState(configuration: configuration, documentID: documentID)
                // A command requested before this page existed was meant for the previous one.
                state.lastCommandSerial = configuration.commandRequest?.serial
                editor = state
            }
        }

        fileprivate func editorRenderPayload(for request: PreviewContentRequest) -> [String: Any] {
            guard let editor, editor.documentID == request.documentID else { return [:] }
            var payload: [String: Any] = ["editable": true]
            if let selection = editor.configuration.initialSelection {
                payload["selection"] = [
                    "anchor": selection.location,
                    "head": selection.location + selection.length
                ]
            }
            if let window = editorWebView?.window,
               window.firstResponder === editorWebView || window.firstResponder === window || window.firstResponder == nil {
                payload["focus"] = true
            }
            return payload
        }

        fileprivate func editorDidRender(_ request: PreviewContentRequest, renderID: Int) {
            guard let editor, editor.documentID == request.documentID else { return }
            editor.renderID = renderID
            editor.mirror = request.markdown
            editor.acknowledged = 0
            editor.isReady = false
            editor.awaitingReset = nil
            if let webView = editorWebView {
                sendEditorIcons(to: webView)
            }
        }

        /// While the editor is showing this document, store changes reach the page as patches:
        /// nothing when the page made the change itself, otherwise the difference. True when the
        /// request was handled this way.
        fileprivate func syncEditorIfActive(_ request: PreviewContentRequest, in webView: WKWebView) -> Bool {
            guard let editor,
                  editor.documentID == request.documentID,
                  let mirror = editor.mirror,
                  lastRenderedContent?.documentID == request.documentID,
                  isShellLoaded
            else { return false }
            if request.markdown == mirror {
                lastRenderedContent = request
                return true
            }
            if editor.awaitingReset != nil {
                return true
            }
            guard let patch = MarkdownTextDifference.patch(from: mirror, to: request.markdown) else {
                lastRenderedContent = request
                return true
            }
            // A change from outside the editor (the file changed on disk, a task toggled elsewhere).
            sendEditorPatches([patch], selection: nil, reason: .external, in: webView)
            lastRenderedContent = request
            return true
        }

        fileprivate func applyEditorCommand(_ request: MarkdownVisualEditorCommandRequest, in webView: WKWebView) {
            guard let editor, editor.lastCommandSerial != request.serial else { return }
            editor.lastCommandSerial = request.serial
            let command = request.command.visualEditorCommand
            var arguments: [Any] = [command.name]
            if let value = command.value { arguments.append(value) }
            guard let json = try? WebViewBridge.literal(arguments) else { return }
            webView.evaluateJavaScript("window.MonknotEditor && window.MonknotEditor.command(...\(json));")
        }

        func applyFromApp(
            _ patches: [MarkdownVisualEditorPatch],
            selection: MarkdownVisualEditorSelection?,
            reason: MarkdownVisualEditorChange.Kind
        ) {
            guard let webView = editorWebView, editor?.isReady == true || editor?.mirror != nil else {
                NSSound.beep()
                return
            }
            sendEditorPatches(patches, selection: selection, reason: reason, in: webView)
        }

        private func sendEditorPatches(
            _ patches: [MarkdownVisualEditorPatch],
            selection: MarkdownVisualEditorSelection?,
            reason: MarkdownVisualEditorChange.Kind,
            in webView: WKWebView
        ) {
            guard let editor else { return }
            for (index, patch) in patches.enumerated() {
                var payload: [String: Any] = [
                    "base": editor.acknowledged,
                    "from": patch.location,
                    "to": patch.location + (patch.removed as NSString).length,
                    "expected": patch.removed,
                    "insert": patch.inserted,
                    "reason": reason.rawValue
                ]
                if index == patches.count - 1, let selection {
                    payload["selection"] = selection.payload
                }
                guard let json = try? WebViewBridge.literal(payload) else { continue }
                webView.evaluateJavaScript("window.MonknotEditor && window.MonknotEditor.applyRemote(\(json));")
            }
        }

        /// Replaces the page's document with the store's text, after a change the store refused or
        /// a version the two sides disagree on.
        private func resetEditor(in webView: WKWebView) {
            guard let editor else { return }
            let text = editor.configuration.currentText()
            editor.awaitingReset = text
            guard let json = try? WebViewBridge.literal(["text": text]) else { return }
            webView.evaluateJavaScript("window.MonknotEditor && window.MonknotEditor.reset(\(json));")
        }

        private func sendEditorIcons(to webView: WKWebView) {
            guard let json = try? WebViewBridge.literal(MarkdownEditorSymbolAssets.icons()) else { return }
            webView.evaluateJavaScript("window.MonknotEditor && window.MonknotEditor.setIcons(\(json));")
        }

        private func handleEditorMessage(_ value: Any) {
            guard let editor,
                  let body = value as? [String: Any],
                  body["documentID"] as? String == editor.documentID,
                  WebViewBridge.integer(body["renderID"]) == editor.renderID,
                  let type = body["type"] as? String,
                  let webView = editorWebView
            else { return }

            switch type {
            case "ready":
                editor.isReady = true
                editor.acknowledged = WebViewBridge.integer(body["v"]) ?? 0
            case "edit":
                guard editor.awaitingReset == nil else { return }
                guard let change = MarkdownVisualEditorChange.parse(body),
                      change.version == editor.acknowledged + 1,
                      let mirror = editor.mirror
                else {
                    resetEditor(in: webView)
                    return
                }
                let mirrorText = mirror as NSString
                guard NSMaxRange(change.range) <= mirrorText.length,
                      mirrorText.substring(with: change.range) == change.removed
                else {
                    resetEditor(in: webView)
                    return
                }
                let updated = mirrorText.replacingCharacters(in: change.range, with: change.inserted)
                editor.mirror = updated
                editor.acknowledged = change.version
                lastRenderedContent = PreviewContentRequest(documentID: editor.documentID, markdown: updated)
                if change.kind == .external { return }
                guard editor.configuration.applyChange(change) else {
                    resetEditor(in: webView)
                    return
                }
                editor.configuration.session.record(change)
            case "reset":
                guard let text = editor.awaitingReset else { return }
                editor.awaitingReset = nil
                editor.mirror = text
                editor.acknowledged = WebViewBridge.integer(body["v"]) ?? editor.acknowledged
                lastRenderedContent = PreviewContentRequest(documentID: editor.documentID, markdown: text)
            case "conflict":
                if body["reason"] as? String == MarkdownVisualEditorChange.Kind.external.rawValue {
                    resetEditor(in: webView)
                } else {
                    NSSound.beep()
                }
            case "selection":
                guard let selection = MarkdownVisualEditorSelection(body) else { return }
                editor.configuration.onSelectionChange(selection, (body["selectedMarkdown"] as? String) ?? "")
                editor.configuration.onFormattingChange(MarkdownVisualFormattingState(body))
            case "undo":
                let manager = editor.configuration.session.undoManager
                if manager.canUndo { manager.undo() } else { NSSound.beep() }
            case "redo":
                let manager = editor.configuration.session.undoManager
                if manager.canRedo { manager.redo() } else { NSSound.beep() }
            case "wikilinkQuery":
                suggestWikilinks(
                    for: (body["query"] as? String) ?? "",
                    serial: WebViewBridge.integer(body["serial"]) ?? 0,
                    documents: editor.configuration.wikilinkDocuments,
                    in: webView
                )
            case "requestImage":
                requestImageFile(at: MarkdownVisualEditorSelection(body["selection"]), in: webView)
            case "pasteImage":
                pasteImage(at: MarkdownVisualEditorSelection(body["selection"]), in: webView)
            default:
                break
            }
        }

        /// Ranks the workspace's notes for the text after `[[` off the main actor, with Source's
        /// ranking, and answers with that query's serial; the page drops answers it no longer needs.
        private func suggestWikilinks(
            for query: String,
            serial: Int,
            documents: [WorkspaceDocument],
            in webView: WKWebView
        ) {
            wikilinkTask?.cancel()
            wikilinkTask = Task { [weak self, weak webView] in
                let titles = await Task.detached(priority: .userInitiated) {
                    WikilinkAutocompleteService.suggestions(partial: query, documents: documents)
                }.value
                await MainActor.run {
                    guard !Task.isCancelled, let self, self.editor != nil, let webView,
                          let json = try? WebViewBridge.literal(["serial": serial, "titles": titles])
                    else { return }
                    self.wikilinkTask = nil
                    webView.evaluateJavaScript("window.MonknotEditor && window.MonknotEditor.wikilinkSuggestions(\(json));")
                }
            }
        }

        /// Inserts Markdown at a selection the page reported, once an image is saved. If the text
        /// changed meanwhile, the page inserts at its current caret instead.
        private func insertion(
            at selection: MarkdownVisualEditorSelection,
            expectedLength: Int,
            label: String
        ) -> (String) -> Bool {
            { [weak self] markdown in
                guard let self, let webView = self.editorWebView, self.editor != nil else { return false }
                let payload: [String: Any] = [
                    "markdown": markdown,
                    "selection": selection.payload,
                    "expectedLength": expectedLength,
                    "label": label
                ]
                guard let json = try? WebViewBridge.literal(payload) else { return false }
                webView.evaluateJavaScript("window.MonknotEditor && window.MonknotEditor.insertMarkdown(\(json));")
                return true
            }
        }

        private func requestImageFile(at selection: MarkdownVisualEditorSelection?, in webView: WKWebView) {
            guard let editor, let selection, let handler = editor.configuration.onFileDropRequest else { return }
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.image]
            panel.prompt = "Insert"
            panel.message = "Choose an image to insert"
            let documentID = editor.documentID
            let sourceText = editor.configuration.currentText()
            let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard response == .OK, let url = panel.url, let self else { return }
                let request = MarkdownFileDropRequest(
                    documentID: documentID,
                    revision: 0,
                    sourceText: sourceText,
                    insertionRange: selection.range,
                    urls: [url],
                    insertion: self.insertion(at: selection, expectedLength: (sourceText as NSString).length, label: "Insert Image")
                )
                handler(request)
            }
            if let window = webView.window {
                panel.beginSheetModal(for: window, completionHandler: complete)
            } else {
                panel.begin(completionHandler: complete)
            }
        }

        private func pasteImage(at selection: MarkdownVisualEditorSelection?, in webView: WKWebView) {
            guard let editor,
                  let selection,
                  let handler = editor.configuration.onImagePasteRequest,
                  let image = NSImage(pasteboard: .general)
            else {
                NSSound.beep()
                return
            }
            let sourceText = editor.configuration.currentText()
            handler(MarkdownImagePasteRequest(
                documentID: editor.documentID,
                revision: 0,
                sourceText: sourceText,
                selectedRange: selection.range,
                image: image,
                insertion: insertion(at: selection, expectedLength: (sourceText as NSString).length, label: "Paste Image")
            ))
        }

        fileprivate func prepareForDocument(_ nextDocumentID: String, in webView: WKWebView) -> Bool {
            guard documentID != nextDocumentID else { return false }
            WebViewBridge.readScrollPosition(of: webView, then: onScrollPositionChange)
            documentID = nextDocumentID
            activeRenderID = nil
            lastPublishedScrollPosition = nil
            shouldRestorePendingScrollPosition = true
            lastAppliedSyncScrollLine = nil
            pendingSyncScrollLine = nil
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
            if editor?.configuration.session.channel === self {
                editor?.configuration.session.channel = nil
            }
            editor = nil
            wikilinkTask?.cancel()
            wikilinkTask = nil
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
                let json = try WebViewBridge.literal(payload)
                webView.evaluateJavaScript("window.monknotApplyAppearance && window.monknotApplyAppearance(\(json));") { [weak self] _, error in
                    if error == nil {
                        self?.markAppliedAppearance(request)
                    }
                }
            } catch {
                webView.loadHTMLString(MarkdownPreviewView.errorHTML(error.localizedDescription), baseURL: nil)
            }
        }

        fileprivate func applySearch(
            _ state: DocumentSearchState,
            options: MonknotSearchOptions = MonknotSearchOptions(),
            in webView: WKWebView
        ) {
            pendingSearch = state
            pendingSearchOptions = options
            let request = DocumentSearchRequest(state, options: options)
            guard request != lastSearchRequest else { return }
            lastSearchRequest = request

            do {
                let json = try WebViewBridge.literal(WebViewBridge.searchPayload(request))
                webView.evaluateJavaScript("window.monknotSearch && window.monknotSearch(\(json));") { [weak self] value, _ in
                    self?.onSearchResult(WebViewBridge.searchResult(from: value))
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

                let editorPayload = await MainActor.run { self?.editorRenderPayload(for: request) ?? [:] }
                let payload: String
                do {
                    var body: [String: Any] = [
                        "markdown": request.markdown,
                        "theme": latestThemeName,
                        "documentID": request.documentID,
                        "renderID": serial,
                    ]
                    body.merge(editorPayload) { _, new in new }
                    payload = try WebViewBridge.literal(body)
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
                        self.editorDidRender(request, renderID: serial)
                        self.applySearch(
                            self.pendingSearch ?? searchState,
                            options: self.pendingSearchOptions,
                            in: webView
                        )
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

        fileprivate func setPendingSearchOptions(_ options: MonknotSearchOptions) {
            pendingSearchOptions = options
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
                let json = try WebViewBridge.literal(payload)
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

        var hasDocument: Bool { documentID != nil }

        /// A rebuilt preview starts at this source line once its content renders. The split-sync
        /// line it is handed was set for an earlier view and would otherwise override it.
        fileprivate func openAtLine(_ line: Int?, ignoringSyncLine syncLine: Int?) {
            lastAppliedSyncScrollLine = syncLine
            guard let line, line > 0 else { return }
            pendingSyncScrollLine = line
        }

        fileprivate func applySyncScrollTargetLine(_ line: Int?, in webView: WKWebView) {
            guard syncScrollEnabled, let line, line > 0, line != lastAppliedSyncScrollLine else { return }
            scrollToLine(line, in: webView)
        }

        private func scrollToLine(_ line: Int, in webView: WKWebView) {
            // Not rendered yet: apply once the content loads.
            guard isShellLoaded, lastRenderedContent?.documentID == documentID else {
                pendingSyncScrollLine = line
                return
            }

            pendingSyncScrollLine = nil
            lastAppliedSyncScrollLine = line
            // Don't echo this programmatic scroll back to the source.
            suppressesNextSourceLine = true

            let payload: [String: Any] = ["line": line]
            do {
                let json = try WebViewBridge.literal(payload)
                webView.evaluateJavaScript("window.monknotScrollToLine && window.monknotScrollToLine(\(json));") { [weak self] _, _ in
                    // If nothing scrolled, no report comes; stop waiting for one.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        self?.suppressesNextSourceLine = false
                    }
                }
            } catch {
                suppressesNextSourceLine = false
            }
        }

        fileprivate func applyPendingScrollPositionIfNeeded(in webView: WKWebView) {
            if let line = pendingSyncScrollLine {
                // The source's line decides where a rebuilt or split preview starts.
                shouldRestorePendingScrollPosition = false
                scrollToLine(line, in: webView)
                return
            }
            guard shouldRestorePendingScrollPosition else { return }
            shouldRestorePendingScrollPosition = false
            WebViewBridge.scroll(webView, to: pendingScrollPosition)
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
                let allows = !isTornDown
                    && WorkspaceResourceSchemeHandler.allowsPreviewNavigation(navigationAction)
                decisionHandler(allows ? .allow : .cancel)
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

            if message.name == Self.editorHandlerName {
                handleEditorMessage(message.body)
                return
            }

            guard message.name == Self.sourceJumpHandlerName else { return }
            guard let body = message.body as? [String: Any],
                  validatedIdentity(from: body) != nil,
                  let line = WebViewBridge.integer(body["line"]),
                  line > 0
            else { return }
            let offset = max(0, WebViewBridge.integer(body["offset"]) ?? 0)
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
                  let messageRenderID = WebViewBridge.integer(body["renderID"]),
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
                guard let sourceLine = WebViewBridge.integer(body["sourceLine"]),
                      sourceLine > 0,
                      let expectedChecked = WebViewBridge.boolean(body["expectedChecked"]),
                      let desiredChecked = WebViewBridge.boolean(body["desiredChecked"]),
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
                  let renderID = WebViewBridge.integer(body["renderID"]),
                  renderID > 0
            else { return nil }
            return MarkdownPreviewRenderIdentity(documentID: documentID, renderID: renderID)
        }

        private func publishScrollPosition(from body: Any) {
            let position = WebViewBridge.scrollPosition(from: body)
            guard position.isMeaningfullyDifferent(from: lastPublishedScrollPosition) else { return }
            lastPublishedScrollPosition = position
            onScrollPositionChange(position)

            let sourceLine = WebViewBridge.sourceLine(from: body)
            guard sourceLine > 0, sourceLine != lastPublishedSourceLine else { return }
            lastPublishedSourceLine = sourceLine
            if suppressesNextSourceLine {
                suppressesNextSourceLine = false
                return
            }
            onVisibleSourceLineChange?(sourceLine)
        }
    }
}

fileprivate struct PreviewShellRequest: Equatable {
    let baseURL: URL?
    var isEditable = false
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
