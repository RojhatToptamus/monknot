import Foundation

/// SF Symbols for workspace chrome actions (toolbar, sidebar header, menus).
enum MonknotWorkspaceIcons {
    static var newMarkdown: String {
        MonknotSFSymbol.resolve("doc.text.badge.plus", fallback: "doc.text.fill")
    }

    static var newFile: String {
        MonknotSFSymbol.resolve("doc.badge.plus", fallback: "doc")
    }

    static let newFolder = "folder.badge.plus"
    static let openFolder = "folder"
    static let searchWorkspace = "magnifyingglass"

    static var revealInFinder: String {
        MonknotSFSymbol.resolve("arrow.forward.folder", fallback: "folder.fill")
    }
    static let copyPath = "link"
    static let outline = "list.bullet.indent"
    static let exportPDF = "arrow.down.doc.fill"
    static let settings = "gearshape"
    static let terminal = "terminal"
    static let sidebarLeft = "sidebar.left"
    static let sidebarRight = "sidebar.right"
}
