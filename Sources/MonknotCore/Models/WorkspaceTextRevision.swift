import Foundation

public struct WorkspaceFileSignature: Equatable, Sendable {
    public let modificationDate: Date?
    public let fileSize: Int64?

    public init(modificationDate: Date?, fileSize: Int64?) {
        self.modificationDate = modificationDate
        self.fileSize = fileSize
    }
}

public struct WorkspaceTextRevision: Equatable, Sendable {
    public let text: String
    public let signature: WorkspaceFileSignature

    public init(text: String, signature: WorkspaceFileSignature) {
        self.text = text
        self.signature = signature
    }
}

public enum WorkspaceTextRevisionExpectation: Equatable, Sendable {
    case present(WorkspaceTextRevision)
    case absent
}

public enum WorkspaceDataRevisionExpectation: Equatable, Sendable {
    case present(Data)
    case absent
}

public enum WorkspaceTextRevisionError: LocalizedError, Equatable {
    case unreadable
    case invalidUTF8
    case changedOnDisk
    case unexpectedlyCreated

    public var errorDescription: String? {
        switch self {
        case .unreadable:
            return "The file could not be read."
        case .invalidUTF8:
            return "The file is no longer valid UTF-8 text."
        case .changedOnDisk:
            return "The file changed on disk before the operation could finish."
        case .unexpectedlyCreated:
            return "A file was created at this location before the operation could finish."
        }
    }
}

public enum WorkspaceConditionalTextWriter {
    public static func read(from url: URL) throws -> WorkspaceTextRevision {
        guard let data = try? Data(contentsOf: url) else {
            throw WorkspaceTextRevisionError.unreadable
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw WorkspaceTextRevisionError.invalidUTF8
        }
        return WorkspaceTextRevision(
            text: text,
            signature: signature(for: url)
        )
    }

    @discardableResult
    public static func write(
        _ text: String,
        to url: URL,
        expecting expectation: WorkspaceTextRevisionExpectation
    ) throws -> WorkspaceTextRevision {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationError: Error?
        var writtenRevision: WorkspaceTextRevision?

        coordinator.coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                let exists = FileManager.default.fileExists(atPath: coordinatedURL.path)
                switch expectation {
                case .absent:
                    guard !exists else {
                        throw WorkspaceTextRevisionError.unexpectedlyCreated
                    }
                case .present(let expected):
                    guard exists else {
                        throw WorkspaceTextRevisionError.changedOnDisk
                    }
                    let current = try read(from: coordinatedURL)
                    guard current == expected else {
                        throw WorkspaceTextRevisionError.changedOnDisk
                    }
                }

                let data = Data(text.utf8)
                try data.write(to: coordinatedURL, options: .atomic)
                writtenRevision = try read(from: coordinatedURL)
            } catch {
                operationError = error
            }
        }

        if let operationError {
            throw operationError
        }
        if let coordinationError {
            throw coordinationError
        }
        guard let writtenRevision else {
            throw WorkspaceTextRevisionError.unreadable
        }
        return writtenRevision
    }

    private static func signature(for url: URL) -> WorkspaceFileSignature {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.standardizedFileURL.path)
        return WorkspaceFileSignature(
            modificationDate: attributes?[.modificationDate] as? Date,
            fileSize: (attributes?[.size] as? NSNumber)?.int64Value
        )
    }
}

public enum WorkspaceConditionalDataWriter {
    @discardableResult
    public static func write(
        _ data: Data,
        to url: URL,
        expecting expectation: WorkspaceDataRevisionExpectation
    ) throws -> Data {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationError: Error?
        var writtenData: Data?

        coordinator.coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                let exists = FileManager.default.fileExists(atPath: coordinatedURL.path)
                switch expectation {
                case .absent:
                    guard !exists else {
                        throw WorkspaceTextRevisionError.unexpectedlyCreated
                    }
                case .present(let expected):
                    guard exists,
                          let current = try? Data(contentsOf: coordinatedURL),
                          current == expected
                    else {
                        throw WorkspaceTextRevisionError.changedOnDisk
                    }
                }

                try data.write(to: coordinatedURL, options: .atomic)
                guard let current = try? Data(contentsOf: coordinatedURL) else {
                    throw WorkspaceTextRevisionError.unreadable
                }
                writtenData = current
            } catch {
                operationError = error
            }
        }

        if let operationError { throw operationError }
        if let coordinationError { throw coordinationError }
        guard let writtenData else { throw WorkspaceTextRevisionError.unreadable }
        return writtenData
    }
}
