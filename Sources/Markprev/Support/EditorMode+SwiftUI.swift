import MarkprevCore

extension EditorMode {
    var title: String {
        switch self {
        case .source:
            return "Source"
        case .preview:
            return "Preview"
        }
    }
}
