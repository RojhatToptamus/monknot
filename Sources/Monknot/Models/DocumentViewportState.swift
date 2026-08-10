import CoreGraphics
import Foundation

struct DocumentViewportState: Codable, Equatable {
    var textScrollPosition: DocumentScrollPosition?
    var textSelection: DocumentTextSelection?
    var markdownPreviewScrollPosition: DocumentScrollPosition?
    var htmlPreviewScrollPosition: DocumentScrollPosition?
    var pdfViewportState: PDFDocumentViewportState?
}

struct DocumentScrollPosition: Codable, Equatable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(_ point: CGPoint) {
        self.init(x: Double(point.x), y: Double(point.y))
    }

    var point: CGPoint {
        CGPoint(x: x, y: y)
    }

    func isMeaningfullyDifferent(from other: DocumentScrollPosition?, tolerance: Double = 0.5) -> Bool {
        guard let other else { return true }
        return abs(x - other.x) > tolerance || abs(y - other.y) > tolerance
    }
}

struct DocumentTextSelection: Codable, Equatable {
    var location: Int
    var length: Int

    init(location: Int, length: Int) {
        self.location = max(0, location)
        self.length = max(0, length)
    }
}

struct PDFDocumentViewportPosition: Codable, Equatable {
    var pageIndex: Int
    var point: DocumentScrollPosition

    init(pageIndex: Int, point: DocumentScrollPosition) {
        self.pageIndex = pageIndex
        self.point = point
    }

    func isMeaningfullyDifferent(from other: PDFDocumentViewportPosition?) -> Bool {
        guard let other else { return true }
        return pageIndex != other.pageIndex || point.isMeaningfullyDifferent(from: other.point)
    }
}

enum PDFZoomMode: Codable, Equatable {
    case fitToView
    case fixed(scaleFactor: Double)
}

struct PDFDocumentViewportState: Codable, Equatable {
    var position: PDFDocumentViewportPosition?
    var zoomMode: PDFZoomMode

    init(position: PDFDocumentViewportPosition?, zoomMode: PDFZoomMode) {
        self.position = position
        self.zoomMode = zoomMode
    }

    func isMeaningfullyDifferent(from other: PDFDocumentViewportState?, scaleTolerance: Double = 0.002) -> Bool {
        guard let other else { return true }

        let zoomIsDifferent: Bool
        switch (zoomMode, other.zoomMode) {
        case (.fitToView, .fitToView):
            zoomIsDifferent = false
        case (.fixed(let scaleFactor), .fixed(let otherScaleFactor)):
            zoomIsDifferent = abs(scaleFactor - otherScaleFactor) > scaleTolerance
        case (.fitToView, .fixed), (.fixed, .fitToView):
            zoomIsDifferent = true
        }

        let positionIsDifferent: Bool
        switch (position, other.position) {
        case (nil, nil):
            positionIsDifferent = false
        case (.some(let position), .some(let otherPosition)):
            positionIsDifferent = position.isMeaningfullyDifferent(from: otherPosition)
        case (.some, nil), (nil, .some):
            positionIsDifferent = true
        }

        return zoomIsDifferent || positionIsDifferent
    }
}

enum DocumentViewportStateChange {
    case textScrollPosition(DocumentScrollPosition)
    case textSelection(DocumentTextSelection)
    case markdownPreviewScrollPosition(DocumentScrollPosition)
    case htmlPreviewScrollPosition(DocumentScrollPosition)
    case pdfViewportState(PDFDocumentViewportState)
}

struct DocumentViewportStatePersistence {
    private struct StoredState: Codable {
        let statesByDocumentID: [String: DocumentViewportState]
    }

    private let defaults: UserDefaults
    private let keyPrefix: String
    private let maximumDocumentCount: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "Monknot.documentViewportState",
        maximumDocumentCount: Int = 100
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
        self.maximumDocumentCount = max(1, maximumDocumentCount)
    }

    func load(for workspaceURL: URL) -> [String: DocumentViewportState] {
        guard let data = defaults.data(forKey: key(for: workspaceURL)),
              let stored = try? decoder.decode(StoredState.self, from: data)
        else {
            return [:]
        }
        return stored.statesByDocumentID
    }

    func save(
        _ states: [String: DocumentViewportState],
        retaining documentIDs: [String],
        for workspaceURL: URL
    ) {
        var retained: [String: DocumentViewportState] = [:]
        for documentID in documentIDs.reversed() where retained.count < maximumDocumentCount {
            if let state = states[documentID] {
                retained[documentID] = state
            }
        }

        let stored = StoredState(statesByDocumentID: retained)
        guard let data = try? encoder.encode(stored) else { return }
        let storageKey = key(for: workspaceURL)
        guard defaults.data(forKey: storageKey) != data else { return }
        defaults.set(data, forKey: storageKey)
    }

    func key(for workspaceURL: URL) -> String {
        let pathData = Data(workspaceURL.standardizedFileURL.path.utf8)
        return "\(keyPrefix).\(pathData.base64EncodedString())"
    }
}
