import Foundation

/// SF Symbols for workspace chrome actions (toolbar, sidebar header, menus).
enum MonknotWorkspaceIcons {
    static var newMarkdown: String {
        MonknotSFSymbol.resolve("square.and.pencil", fallback: "plus")
    }

    static var newFile: String {
        MonknotSFSymbol.resolve("square.and.pencil", fallback: "plus")
    }

    static let newFolder = "folder.badge.plus"
    /// A letter with the text cursor: the name is edited in place.
    static let rename = "character.cursor.ibeam"
    /// Back and forward through the documents opened: arrows with a shaft, drawn as marks.
    static let back = "arrow.left"
    static let forward = "arrow.right"
    /// Save, in the PDF and image bar: the tray with the arrow into it.
    static let save = "square.and.arrow.down"
    static let openFolder = "folder"
    static let searchWorkspace = "magnifyingglass"

    static var revealInFinder: String {
        MonknotSFSymbol.resolve("arrow.up.forward.app", fallback: "folder")
    }
    static let copyPath = "link"
    /// The copy that rides under the pointer when several items are dragged.
    static let dragItems = "doc.on.doc"
    static let outline = "list.bullet.indent"
    static let exportPDF = "arrow.down.doc"
    static let settings = "gearshape"
    static let terminal = "terminal"
    static let sidebarLeft = "sidebar.left"
    static let sidebarRight = "sidebar.right"
}
