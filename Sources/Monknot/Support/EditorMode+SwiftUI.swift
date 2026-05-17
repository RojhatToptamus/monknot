import MonknotCore

extension EditorMode {
    var title: String {
        switch self {
        case .source:
            return "Write"
        case .preview:
            return "Preview"
        }
    }
}
