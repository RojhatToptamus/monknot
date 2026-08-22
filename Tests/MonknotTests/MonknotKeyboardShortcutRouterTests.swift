import XCTest
import MonknotCore

final class MonknotKeyboardShortcutRouterTests: XCTestCase {
    func testSaveShortcutRequiresASelectedDocument() {
        XCTAssertEqual(
            action(for: "s", modifiers: [.command], context: shortcutContext(selectedDocumentKind: .markdown)),
            .saveDocument
        )

        XCTAssertNil(
            action(for: "s", modifiers: [.command], context: shortcutContext(selectedDocumentKind: nil))
        )
    }

    func testPasteboardFileTransferShortcutsRequireSelectedDocumentAndIdleState() {
        XCTAssertEqual(
            action(for: "x", modifiers: [.command], context: shortcutContext(selectedDocumentKind: .markdown)),
            .cutDocument
        )
        XCTAssertEqual(
            action(for: "c", modifiers: [.command], context: shortcutContext(selectedDocumentKind: .markdown)),
            .copyDocument
        )

        XCTAssertNil(
            action(for: "x", modifiers: [.command], context: shortcutContext(selectedDocumentKind: nil))
        )
        XCTAssertNil(
            action(for: "c", modifiers: [.command], context: shortcutContext(selectedDocumentKind: nil))
        )
        XCTAssertNil(
            action(for: "x", modifiers: [.command], context: shortcutContext(selectedDocumentKind: .markdown, isBusy: true))
        )
        XCTAssertNil(
            action(for: "c", modifiers: [.command], context: shortcutContext(selectedDocumentKind: .markdown, isBusy: true))
        )
    }

    func testWorkspaceReplaceUndoShortcutTakesPriorityOverPDFUndo() {
        XCTAssertEqual(
            action(
                for: "z",
                modifiers: [.command],
                context: shortcutContext(
                    selectedDocumentKind: .pdf,
                    canUndoPDFAnnotation: true,
                    canUndoWorkspaceReplace: true
                )
            ),
            .undoWorkspaceReplace
        )
    }

    func testToggleSplitViewShortcutRequiresEligibleDocument() {
        XCTAssertEqual(
            action(
                for: "\\",
                modifiers: [.command],
                keyCode: 42,
                context: shortcutContext(selectedDocumentKind: .markdown, canToggleSplitView: true)
            ),
            .toggleSplitView
        )

        XCTAssertNil(
            action(
                for: "\\",
                modifiers: [.command],
                context: shortcutContext(selectedDocumentKind: .pdf, canToggleSplitView: false)
            )
        )
    }

    func testLinkInspectionShortcutRespectsEligibilityWithoutClaimingEscape() {
        XCTAssertEqual(
            action(
                for: "l",
                modifiers: [.command, .option],
                context: shortcutContext(selectedDocumentKind: .markdown, canInspectLinks: true)
            ),
            .toggleLinkInspection
        )
        XCTAssertNil(
            action(
                for: "l",
                modifiers: [.command, .option],
                context: shortcutContext(selectedDocumentKind: .pdf, canInspectLinks: false)
            )
        )
        XCTAssertNil(
            action(
                for: "",
                modifiers: [],
                keyCode: MonknotKeyboardShortcutRouter.escapeKeyCode,
                context: shortcutContext(isLinkInspectionPresented: true)
            )
        )
    }

    func testPDFUndoRedoShortcutsDoNotStealTextUndo() {
        XCTAssertEqual(
            action(
                for: "z",
                modifiers: [.command],
                context: shortcutContext(selectedDocumentKind: .pdf, canUndoPDFAnnotation: true)
            ),
            .undoPDFAnnotation
        )
        XCTAssertEqual(
            action(
                for: "z",
                modifiers: [.command, .shift],
                context: shortcutContext(selectedDocumentKind: .pdf, canRedoPDFAnnotation: true)
            ),
            .redoPDFAnnotation
        )

        XCTAssertNil(
            action(
                for: "z",
                modifiers: [.command],
                context: shortcutContext(selectedDocumentKind: .markdown, canUndoPDFAnnotation: true)
            )
        )
        XCTAssertNil(
            action(
                for: "z",
                modifiers: [.command, .shift],
                context: shortcutContext(selectedDocumentKind: .text, canRedoPDFAnnotation: true)
            )
        )
    }

    func testPDFUndoRedoShortcutsRespectUndoAvailability() {
        XCTAssertNil(
            action(for: "z", modifiers: [.command], context: shortcutContext(selectedDocumentKind: .pdf))
        )
        XCTAssertNil(
            action(for: "z", modifiers: [.command, .shift], context: shortcutContext(selectedDocumentKind: .pdf))
        )
    }

    func testWorkspaceAndTabShortcutsRespectContext() {
        XCTAssertEqual(
            action(for: "n", modifiers: [.command], context: shortcutContext(hasWorkspace: true)),
            .newMarkdown
        )
        XCTAssertNil(
            action(for: "n", modifiers: [.command], context: shortcutContext(hasWorkspace: true, isBusy: true))
        )
        XCTAssertNil(
            action(for: "n", modifiers: [.command], context: shortcutContext(hasWorkspace: false))
        )

        XCTAssertEqual(
            action(for: "w", modifiers: [.command], context: shortcutContext(canCloseTab: true)),
            .closeTab
        )
        XCTAssertNil(
            action(for: "w", modifiers: [.command], context: shortcutContext(canCloseTab: false))
        )

        XCTAssertEqual(
            action(for: "t", modifiers: [.command, .shift], context: shortcutContext(canReopenClosedTab: true)),
            .reopenClosedTab
        )
        XCTAssertNil(
            action(for: "t", modifiers: [.command, .shift], context: shortcutContext(canReopenClosedTab: false))
        )

        XCTAssertEqual(
            action(for: "p", modifiers: [.command, .shift], context: shortcutContext(canTogglePinTab: true)),
            .togglePinTab
        )
        XCTAssertNil(
            action(for: "p", modifiers: [.command, .shift], context: shortcutContext(canTogglePinTab: false))
        )
    }

    func testPasteShortcutRequiresWorkspaceAndIdleState() {
        XCTAssertEqual(
            action(for: "v", modifiers: [.command], context: shortcutContext(hasWorkspace: true)),
            .importPasteboard
        )
        XCTAssertNil(
            action(for: "v", modifiers: [.command], context: shortcutContext(hasWorkspace: false))
        )
        XCTAssertNil(
            action(for: "v", modifiers: [.command], context: shortcutContext(hasWorkspace: true, isBusy: true))
        )
    }

    func testFindSearchShortcutsRespectContext() {
        XCTAssertEqual(
            action(for: "f", modifiers: [.command], context: shortcutContext(selectedDocumentKind: .markdown)),
            .showDocumentSearch
        )
        XCTAssertNil(
            action(for: "f", modifiers: [.command], context: shortcutContext(selectedDocumentKind: nil))
        )
        XCTAssertNil(
            action(for: "f", modifiers: [.control], context: shortcutContext(selectedDocumentKind: .markdown))
        )

        XCTAssertNil(
            action(for: "k", modifiers: [.command, .shift], context: shortcutContext(hasWorkspace: true))
        )

        XCTAssertEqual(
            action(for: "f", modifiers: [.command, .shift], context: shortcutContext(hasWorkspace: true)),
            .showWorkspaceSearch
        )
        XCTAssertNil(
            action(for: "f", modifiers: [.command, .shift], context: shortcutContext(hasWorkspace: false))
        )

        XCTAssertEqual(
            action(for: "g", modifiers: [.command], context: shortcutContext(selectedDocumentKind: .markdown)),
            .findNext
        )
        XCTAssertEqual(
            action(for: "g", modifiers: [.command, .shift], context: shortcutContext(selectedDocumentKind: .markdown)),
            .findPrevious
        )
        XCTAssertNil(
            action(
                for: "",
                modifiers: [],
                keyCode: MonknotKeyboardShortcutRouter.escapeKeyCode,
                context: shortcutContext(isDocumentSearchPresented: true)
            )
        )
    }

    func testZoomTerminalSidebarAndExportShortcuts() {
        XCTAssertEqual(action(for: "=", modifiers: [.command]), .zoomIn)
        XCTAssertEqual(action(for: "+", modifiers: [.command]), .zoomIn)
        XCTAssertEqual(action(for: "-", modifiers: [.command]), .zoomOut)
        XCTAssertEqual(action(for: "0", modifiers: [.command]), .resetZoom)
        XCTAssertEqual(action(for: "j", modifiers: [.command, .option]), .toggleTerminal)
        XCTAssertEqual(action(for: "s", modifiers: [.command, .control]), .toggleSidebar)
        XCTAssertEqual(action(for: "o", modifiers: [.command]), .openFolder)

        XCTAssertEqual(
            action(for: "p", modifiers: [.command], context: shortcutContext(hasWorkspace: true)),
            .showQuickOpen
        )
        XCTAssertNil(
            action(for: "p", modifiers: [.command], context: shortcutContext(hasWorkspace: false))
        )
    }

    func testTerminalFullscreenAcceptsBothReturnFormsAndKeyCodesWhenEligible() {
        let eligible = shortcutContext(canToggleTerminalFullscreen: true)
        for event in [
            MonknotKeyboardShortcutEvent(key: "\r", modifiers: [.command, .control], keyCode: nil),
            MonknotKeyboardShortcutEvent(key: "\n", modifiers: [.command, .control], keyCode: nil),
            MonknotKeyboardShortcutEvent(key: "", modifiers: [.command, .control], keyCode: 36),
            MonknotKeyboardShortcutEvent(key: "", modifiers: [.command, .control], keyCode: 76),
        ] {
            XCTAssertEqual(MonknotKeyboardShortcutRouter.action(for: event, context: eligible), .toggleTerminalFullscreen)
        }
    }

    func testTerminalFullscreenReturnEventsRemainUnhandledWhenIneligible() {
        let ineligible = shortcutContext(canToggleTerminalFullscreen: false)
        for keyCode: UInt16 in [36, 76] {
            XCTAssertNil(MonknotKeyboardShortcutRouter.action(
                for: MonknotKeyboardShortcutEvent(
                    key: keyCode == 36 ? "\r" : "\n",
                    modifiers: [.command, .control],
                    keyCode: keyCode
                ),
                context: ineligible
            ))
        }
    }

    func testQuestionMarkTypingIsNeverConsumed() {
        XCTAssertNil(action(for: "?", modifiers: [], context: shortcutContext()))
        XCTAssertNil(action(for: "?", modifiers: [.shift], context: shortcutContext()))
        XCTAssertNil(action(for: "/", modifiers: [.shift], context: shortcutContext()))
        XCTAssertNil(
            action(
                for: "?",
                modifiers: [],
                context: shortcutContext(isKeyboardShortcutsHelpPresented: true)
            )
        )
    }

    func testQuickOpenEscapeRespectsOverlayState() {
        XCTAssertEqual(
            action(
                for: "",
                modifiers: [],
                keyCode: MonknotKeyboardShortcutRouter.escapeKeyCode,
                context: shortcutContext(isQuickOpenPresented: true)
            ),
            .dismissQuickOpen
        )
        XCTAssertEqual(
            action(
                for: "",
                modifiers: [],
                keyCode: MonknotKeyboardShortcutRouter.escapeKeyCode,
                context: shortcutContext(isKeyboardShortcutsHelpPresented: true)
            ),
            .dismissKeyboardShortcutsHelp
        )
    }

    func testDailyNoteAndGoToSymbolShortcuts() {
        XCTAssertEqual(
            action(for: "n", modifiers: [.command, .shift], context: shortcutContext(hasWorkspace: true)),
            .newDailyNote
        )
        XCTAssertEqual(
            action(for: "o", modifiers: [.command, .shift], context: shortcutContext(selectedDocumentKind: .markdown, hasMarkdownOutline: true)),
            .showGoToSymbol
        )
        XCTAssertEqual(
            action(
                for: "g",
                modifiers: [.command],
                context: shortcutContext(
                    selectedDocumentKind: .markdown,
                    isWorkspaceSearchPresented: true,
                    isWorkspaceSearchFocused: true
                )
            ),
            .workspaceSearchNext
        )
        XCTAssertNil(
            action(
                for: "",
                modifiers: [],
                keyCode: MonknotKeyboardShortcutRouter.escapeKeyCode,
                context: shortcutContext(isWorkspaceSearchPresented: true)
            )
        )
    }

    func testOpenWorkspaceSearchDoesNotClaimOrdinaryResponderKeys() {
        let context = shortcutContext(
            selectedDocumentKind: .markdown,
            isWorkspaceSearchPresented: true
        )
        let ordinaryEvents: [(key: String, keyCode: UInt16?)] = [
            ("\r", 36),
            ("\t", 48),
            ("\u{7f}", 51),
            ("\u{F702}", 123),
            ("x", 7),
            ("", MonknotKeyboardShortcutRouter.escapeKeyCode),
        ]

        for event in ordinaryEvents {
            XCTAssertNil(
                action(
                    for: event.key,
                    modifiers: [],
                    keyCode: event.keyCode,
                    context: context
                ),
                "An open workspace search must not intercept ordinary key \(event.keyCode.map(String.init) ?? event.key.debugDescription)"
            )
        }
    }

    func testWorkspaceSearchNavigationFollowsTheFocusedOwner() {
        let workspaceSearchContext = shortcutContext(
            selectedDocumentKind: .markdown,
            isWorkspaceSearchPresented: true,
            isWorkspaceSearchFocused: true
        )
        XCTAssertEqual(
            action(for: "g", modifiers: [.command], context: workspaceSearchContext),
            .workspaceSearchNext
        )
        XCTAssertEqual(
            action(for: "g", modifiers: [.command, .shift], context: workspaceSearchContext),
            .workspaceSearchPrevious
        )

        let editorContext = shortcutContext(
            selectedDocumentKind: .markdown,
            isDocumentSearchPresented: true,
            isWorkspaceSearchPresented: true,
            isWorkspaceSearchFocused: false
        )
        XCTAssertEqual(action(for: "g", modifiers: [.command], context: editorContext), .findNext)
        XCTAssertEqual(action(for: "g", modifiers: [.command, .shift], context: editorContext), .findPrevious)
    }

    func testStandardTextEditingShortcutsAreNotConsumedByRouter() {
        XCTAssertNil(action(for: "a", modifiers: [.command], context: shortcutContext(selectedDocumentKind: .markdown)))
        XCTAssertNil(action(for: "a", modifiers: [.control], context: shortcutContext(selectedDocumentKind: .markdown)))
        XCTAssertNil(action(for: "f", modifiers: [.control], context: shortcutContext(selectedDocumentKind: .markdown)))
    }

    private func action(
        for key: String,
        modifiers: MonknotKeyboardShortcutModifiers,
        keyCode: UInt16? = nil,
        context: MonknotKeyboardShortcutContext? = nil
    ) -> MonknotKeyboardShortcutAction? {
        MonknotKeyboardShortcutRouter.action(
            for: MonknotKeyboardShortcutEvent(key: key, modifiers: modifiers, keyCode: keyCode),
            context: context ?? shortcutContext()
        )
    }

    private func shortcutContext(
        hasWorkspace: Bool = true,
        selectedDocumentKind: WorkspaceDocumentKind? = nil,
        canCloseTab: Bool = false,
        canReopenClosedTab: Bool = false,
        canTogglePinTab: Bool = false,
        canExportPDF: Bool = false,
        canUndoPDFAnnotation: Bool = false,
        canRedoPDFAnnotation: Bool = false,
        isDocumentSearchPresented: Bool = false,
        isQuickOpenPresented: Bool = false,
        isKeyboardShortcutsHelpPresented: Bool = false,
        isWorkspaceSearchPresented: Bool = false,
        isWorkspaceSearchFocused: Bool = false,
        isSymbolQuickOpenPresented: Bool = false,
        isLinkInspectionPresented: Bool = false,
        hasMarkdownOutline: Bool = false,
        canToggleSplitView: Bool = false,
        canInspectLinks: Bool = false,
        canUndoWorkspaceReplace: Bool = false,
        canToggleTerminalFullscreen: Bool = false,
        isBusy: Bool = false
    ) -> MonknotKeyboardShortcutContext {
        MonknotKeyboardShortcutContext(
            hasWorkspace: hasWorkspace,
            hasSelectedDocument: selectedDocumentKind != nil,
            selectedDocumentKind: selectedDocumentKind,
            canCloseTab: canCloseTab,
            canReopenClosedTab: canReopenClosedTab,
            canTogglePinTab: canTogglePinTab,
            canExportPDF: canExportPDF,
            canUndoPDFAnnotation: canUndoPDFAnnotation,
            canRedoPDFAnnotation: canRedoPDFAnnotation,
            isDocumentSearchPresented: isDocumentSearchPresented,
            isQuickOpenPresented: isQuickOpenPresented,
            isKeyboardShortcutsHelpPresented: isKeyboardShortcutsHelpPresented,
            isWorkspaceSearchPresented: isWorkspaceSearchPresented,
            isWorkspaceSearchFocused: isWorkspaceSearchFocused,
            isSymbolQuickOpenPresented: isSymbolQuickOpenPresented,
            isLinkInspectionPresented: isLinkInspectionPresented,
            hasMarkdownOutline: hasMarkdownOutline,
            canToggleSplitView: canToggleSplitView,
            canInspectLinks: canInspectLinks,
            canUndoWorkspaceReplace: canUndoWorkspaceReplace,
            canToggleTerminalFullscreen: canToggleTerminalFullscreen,
            isBusy: isBusy
        )
    }
}
