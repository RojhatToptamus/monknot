import Foundation

public struct MonknotKeyboardShortcutModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = MonknotKeyboardShortcutModifiers(rawValue: 1 << 0)
    public static let shift = MonknotKeyboardShortcutModifiers(rawValue: 1 << 1)
    public static let option = MonknotKeyboardShortcutModifiers(rawValue: 1 << 2)
    public static let control = MonknotKeyboardShortcutModifiers(rawValue: 1 << 3)
}

public struct MonknotKeyboardShortcutEvent: Equatable, Sendable {
    public var key: String
    public var modifiers: MonknotKeyboardShortcutModifiers
    public var keyCode: UInt16?

    public init(
        key: String,
        modifiers: MonknotKeyboardShortcutModifiers,
        keyCode: UInt16? = nil
    ) {
        self.key = key
        self.modifiers = modifiers
        self.keyCode = keyCode
    }
}

public struct MonknotKeyboardShortcutContext: Equatable, Sendable {
    public var hasWorkspace: Bool
    public var hasSelectedDocument: Bool
    public var selectedDocumentKind: WorkspaceDocumentKind?
    public var canCloseTab: Bool
    public var canTogglePinTab: Bool
    public var canExportPDF: Bool
    public var canUndoPDFAnnotation: Bool
    public var canRedoPDFAnnotation: Bool
    public var isDocumentSearchPresented: Bool
    public var isQuickOpenPresented: Bool
    public var isKeyboardShortcutsHelpPresented: Bool
    public var isWorkspaceSearchPresented: Bool
    public var isSymbolQuickOpenPresented: Bool
    public var hasMarkdownOutline: Bool
    public var canToggleSplitView: Bool
    public var canUndoWorkspaceReplace: Bool
    public var isBusy: Bool

    public init(
        hasWorkspace: Bool,
        hasSelectedDocument: Bool,
        selectedDocumentKind: WorkspaceDocumentKind?,
        canCloseTab: Bool,
        canTogglePinTab: Bool,
        canExportPDF: Bool,
        canUndoPDFAnnotation: Bool,
        canRedoPDFAnnotation: Bool,
        isDocumentSearchPresented: Bool,
        isQuickOpenPresented: Bool = false,
        isKeyboardShortcutsHelpPresented: Bool = false,
        isWorkspaceSearchPresented: Bool = false,
        isSymbolQuickOpenPresented: Bool = false,
        hasMarkdownOutline: Bool = false,
        canToggleSplitView: Bool = false,
        canUndoWorkspaceReplace: Bool = false,
        isBusy: Bool
    ) {
        self.hasWorkspace = hasWorkspace
        self.hasSelectedDocument = hasSelectedDocument
        self.selectedDocumentKind = selectedDocumentKind
        self.canCloseTab = canCloseTab
        self.canTogglePinTab = canTogglePinTab
        self.canExportPDF = canExportPDF
        self.canUndoPDFAnnotation = canUndoPDFAnnotation
        self.canRedoPDFAnnotation = canRedoPDFAnnotation
        self.isDocumentSearchPresented = isDocumentSearchPresented
        self.isQuickOpenPresented = isQuickOpenPresented
        self.isKeyboardShortcutsHelpPresented = isKeyboardShortcutsHelpPresented
        self.isWorkspaceSearchPresented = isWorkspaceSearchPresented
        self.isSymbolQuickOpenPresented = isSymbolQuickOpenPresented
        self.hasMarkdownOutline = hasMarkdownOutline
        self.canToggleSplitView = canToggleSplitView
        self.canUndoWorkspaceReplace = canUndoWorkspaceReplace
        self.isBusy = isBusy
    }
}

public enum MonknotKeyboardShortcutAction: Equatable, Sendable {
    case newMarkdown
    case newDailyNote
    case openFolder
    case saveDocument
    case cutDocument
    case copyDocument
    case refreshWorkspace
    case closeTab
    case togglePinTab
    case exportPDF
    case showWorkspaceSearch
    case dismissWorkspaceSearch
    case showDocumentSearch
    case findNext
    case findPrevious
    case zoomIn
    case zoomOut
    case resetZoom
    case importPasteboard
    case toggleTerminal
    case toggleSidebar
    case undoPDFAnnotation
    case redoPDFAnnotation
    case dismissDocumentSearch
    case showQuickOpen
    case dismissQuickOpen
    case showGoToSymbol
    case dismissGoToSymbol
    case workspaceSearchNext
    case workspaceSearchPrevious
    case workspaceSearchConfirm
    case showKeyboardShortcutsHelp
    case dismissKeyboardShortcutsHelp
    case toggleSplitView
    case undoWorkspaceReplace
}

public enum MonknotKeyboardShortcutRouter {
    public static let escapeKeyCode: UInt16 = 53

    public static func action(
        for event: MonknotKeyboardShortcutEvent,
        context: MonknotKeyboardShortcutContext
    ) -> MonknotKeyboardShortcutAction? {
        let key = event.key.lowercased()
        let modifiers = event.modifiers

        if event.keyCode == escapeKeyCode, modifiers.isEmpty {
            if context.isQuickOpenPresented { return .dismissQuickOpen }
            if context.isSymbolQuickOpenPresented { return .dismissGoToSymbol }
            if context.isKeyboardShortcutsHelpPresented { return .dismissKeyboardShortcutsHelp }
            if context.isWorkspaceSearchPresented { return .dismissWorkspaceSearch }
            return context.isDocumentSearchPresented ? .dismissDocumentSearch : nil
        }

        let isKeyboardHelpShortcut =
            (modifiers.isEmpty && key == "?")
            || (modifiers == [.shift] && (key == "?" || key == "/"))
        if isKeyboardHelpShortcut {
            return context.isKeyboardShortcutsHelpPresented ? nil : .showKeyboardShortcutsHelp
        }

        if context.isWorkspaceSearchPresented, modifiers == [.command] {
            switch key {
            case "g":
                return .workspaceSearchNext
            default:
                break
            }
        }

        if context.isWorkspaceSearchPresented, modifiers == [.command, .shift] {
            switch key {
            case "g":
                return .workspaceSearchPrevious
            default:
                break
            }
        }

        if context.isWorkspaceSearchPresented, modifiers.isEmpty, key == "\r" {
            return .workspaceSearchConfirm
        }

        if modifiers == [.command] {
            switch key {
            case "n":
                return context.hasWorkspace && !context.isBusy ? .newMarkdown : nil
            case "o":
                return .openFolder
            case "s":
                return context.hasSelectedDocument ? .saveDocument : nil
            case "x":
                return context.hasSelectedDocument && !context.isBusy ? .cutDocument : nil
            case "c":
                return context.hasSelectedDocument && !context.isBusy ? .copyDocument : nil
            case "r":
                return context.hasWorkspace ? .refreshWorkspace : nil
            case "w":
                return context.canCloseTab ? .closeTab : nil
            case "f":
                return context.hasSelectedDocument ? .showDocumentSearch : nil
            case "g":
                if context.isWorkspaceSearchPresented { return .workspaceSearchNext }
                return context.hasSelectedDocument ? .findNext : nil
            case "p":
                if context.isQuickOpenPresented { return .dismissQuickOpen }
                return context.hasWorkspace && !context.isBusy ? .showQuickOpen : nil
            case "+", "=":
                return .zoomIn
            case "-":
                return .zoomOut
            case "0":
                return .resetZoom
            case "z":
                if context.canUndoWorkspaceReplace {
                    return .undoWorkspaceReplace
                }
                return context.selectedDocumentKind == .pdf && context.canUndoPDFAnnotation ? .undoPDFAnnotation : nil
            case "v":
                return context.hasWorkspace && !context.isBusy ? .importPasteboard : nil
            case "\\", "|":
                return context.canToggleSplitView ? .toggleSplitView : nil
            default:
                if event.keyCode == 42 {
                    return context.canToggleSplitView ? .toggleSplitView : nil
                }
                return nil
            }
        }

        if modifiers == [.command, .shift] {
            switch key {
            case "n":
                return context.hasWorkspace && !context.isBusy ? .newDailyNote : nil
            case "o":
                return context.hasMarkdownOutline && !context.isSymbolQuickOpenPresented ? .showGoToSymbol : nil
            case "f":
                return context.hasWorkspace ? .showWorkspaceSearch : nil
            case "g":
                if context.isWorkspaceSearchPresented { return .workspaceSearchPrevious }
                return context.hasSelectedDocument ? .findPrevious : nil
            case "p":
                return context.canTogglePinTab ? .togglePinTab : nil
            case "z":
                return context.selectedDocumentKind == .pdf && context.canRedoPDFAnnotation ? .redoPDFAnnotation : nil
            default:
                return nil
            }
        }

        if modifiers == [.command, .option], key == "j" {
            return .toggleTerminal
        }

        if modifiers == [.command, .control], key == "s" {
            return .toggleSidebar
        }

        return nil
    }
}
