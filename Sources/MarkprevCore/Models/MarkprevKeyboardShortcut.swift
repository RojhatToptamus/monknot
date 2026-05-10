import Foundation

public struct MarkprevKeyboardShortcutModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = MarkprevKeyboardShortcutModifiers(rawValue: 1 << 0)
    public static let shift = MarkprevKeyboardShortcutModifiers(rawValue: 1 << 1)
    public static let option = MarkprevKeyboardShortcutModifiers(rawValue: 1 << 2)
    public static let control = MarkprevKeyboardShortcutModifiers(rawValue: 1 << 3)
}

public struct MarkprevKeyboardShortcutEvent: Equatable, Sendable {
    public var key: String
    public var modifiers: MarkprevKeyboardShortcutModifiers
    public var keyCode: UInt16?

    public init(
        key: String,
        modifiers: MarkprevKeyboardShortcutModifiers,
        keyCode: UInt16? = nil
    ) {
        self.key = key
        self.modifiers = modifiers
        self.keyCode = keyCode
    }
}

public struct MarkprevKeyboardShortcutContext: Equatable, Sendable {
    public var hasWorkspace: Bool
    public var hasSelectedDocument: Bool
    public var selectedDocumentKind: WorkspaceDocumentKind?
    public var canCloseTab: Bool
    public var canTogglePinTab: Bool
    public var canExportPDF: Bool
    public var canUndoPDFAnnotation: Bool
    public var canRedoPDFAnnotation: Bool
    public var isDocumentSearchPresented: Bool
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
        self.isBusy = isBusy
    }
}

public enum MarkprevKeyboardShortcutAction: Equatable, Sendable {
    case newMarkdown
    case openFolder
    case saveDocument
    case refreshWorkspace
    case closeTab
    case togglePinTab
    case exportPDF
    case showDocumentSearch
    case showWorkspaceSearch
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
}

public enum MarkprevKeyboardShortcutRouter {
    public static let escapeKeyCode: UInt16 = 53

    public static func action(
        for event: MarkprevKeyboardShortcutEvent,
        context: MarkprevKeyboardShortcutContext
    ) -> MarkprevKeyboardShortcutAction? {
        let key = event.key.lowercased()
        let modifiers = event.modifiers

        if event.keyCode == escapeKeyCode, modifiers.isEmpty {
            return context.isDocumentSearchPresented ? .dismissDocumentSearch : nil
        }

        if modifiers == [.command] {
            switch key {
            case "n":
                return context.hasWorkspace && !context.isBusy ? .newMarkdown : nil
            case "s":
                return context.hasSelectedDocument ? .saveDocument : nil
            case "r":
                return context.hasWorkspace ? .refreshWorkspace : nil
            case "w":
                return context.canCloseTab ? .closeTab : nil
            case "f":
                return context.hasSelectedDocument ? .showDocumentSearch : nil
            case "g":
                return context.hasSelectedDocument ? .findNext : nil
            case "p":
                return context.canExportPDF ? .exportPDF : nil
            case "+", "=":
                return .zoomIn
            case "-":
                return .zoomOut
            case "0":
                return .resetZoom
            case "z":
                return context.selectedDocumentKind == .pdf && context.canUndoPDFAnnotation ? .undoPDFAnnotation : nil
            case "v":
                return context.hasWorkspace && !context.isBusy ? .importPasteboard : nil
            default:
                return nil
            }
        }

        if modifiers == [.command, .shift] {
            switch key {
            case "o":
                return .openFolder
            case "f":
                return context.hasWorkspace ? .showWorkspaceSearch : nil
            case "g":
                return context.hasSelectedDocument ? .findPrevious : nil
            case "p":
                return context.canTogglePinTab ? .togglePinTab : nil
            case "z":
                return context.selectedDocumentKind == .pdf && context.canRedoPDFAnnotation ? .redoPDFAnnotation : nil
            default:
                return nil
            }
        }

        if modifiers == [.command, .option], key == "t" {
            return .toggleTerminal
        }

        if modifiers == [.command, .control], key == "s" {
            return .toggleSidebar
        }

        if modifiers == [.control], key == "f" {
            return context.hasSelectedDocument ? .showDocumentSearch : nil
        }

        return nil
    }
}
