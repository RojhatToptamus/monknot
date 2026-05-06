import Foundation

extension Notification.Name {
    static let markprevOpenFolder = Notification.Name("markprev.openFolder")
    static let markprevNewMarkdown = Notification.Name("markprev.newMarkdown")
    static let markprevSaveDocument = Notification.Name("markprev.saveDocument")
    static let markprevRefreshWorkspace = Notification.Name("markprev.refreshWorkspace")
    static let markprevZoomIn = Notification.Name("markprev.zoomIn")
    static let markprevZoomOut = Notification.Name("markprev.zoomOut")
    static let markprevResetZoom = Notification.Name("markprev.resetZoom")
}

struct MarkdownSourceLocation: Equatable, Sendable {
    let line: Int
    let offset: Int

    init(line: Int, offset: Int = 0) {
        self.line = max(1, line)
        self.offset = max(0, offset)
    }
}
