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
    static let openFolder = "folder"
    static let searchWorkspace = "magnifyingglass"

    static var revealInFinder: String {
        MonknotSFSymbol.resolve("arrow.up.forward.app", fallback: "folder")
    }
    static let copyPath = "link"
    static let outline = "list.bullet.indent"
    static let exportPDF = "arrow.down.doc"
    static let settings = "gearshape"
    static let terminal = "terminal"
    static let sidebarLeft = "sidebar.left"
    static let sidebarRight = "sidebar.right"
}
