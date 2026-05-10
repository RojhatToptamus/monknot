import Foundation

enum DocumentSaveState: Equatable, Sendable {
    case clean
    case edited
    case saving
    case failed(String)

    var isClean: Bool {
        if case .clean = self {
            return true
        }
        return false
    }

    var accessibilityDescription: String {
        switch self {
        case .clean:
            return "saved"
        case .edited:
            return "edited"
        case .saving:
            return "saving"
        case .failed:
            return "save failed"
        }
    }
}
