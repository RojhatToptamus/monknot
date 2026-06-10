import Foundation

public struct MonknotCaptureURLBuilder: Sendable {
    public static let scheme = "monknot"
    public static let host = "capture"

    public init() {}

    public func captureURL(
        workspacePath: String,
        sourceURL: String? = nil,
        text: String? = nil,
        title: String? = nil
    ) throws -> URL {
        let workspace = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workspace.isEmpty else {
            throw Error.missingWorkspace
        }

        let trimmedSourceURL = sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch (trimmedSourceURL.isEmpty, trimmedText.isEmpty) {
        case (true, true):
            throw Error.missingPayload
        case (false, false):
            throw Error.multiplePayloads
        case (false, true):
            guard let url = URL(string: trimmedSourceURL), url.scheme?.isEmpty == false else {
                throw Error.invalidSourceURL
            }
        case (true, false):
            break
        }

        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host

        var queryItems = [
            URLQueryItem(name: "workspace", value: workspace)
        ]
        if !trimmedSourceURL.isEmpty {
            queryItems.append(URLQueryItem(name: "url", value: trimmedSourceURL))
        } else {
            queryItems.append(URLQueryItem(name: "text", value: trimmedText))
        }
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedTitle.isEmpty {
            queryItems.append(URLQueryItem(name: "title", value: trimmedTitle))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw Error.invalidCaptureURL
        }
        return url
    }

    public enum Error: LocalizedError, Equatable, Sendable {
        case missingWorkspace
        case missingPayload
        case multiplePayloads
        case invalidSourceURL
        case invalidCaptureURL

        public var errorDescription: String? {
            switch self {
            case .missingWorkspace:
                return "Missing workspace path."
            case .missingPayload:
                return "Provide either --url or --text."
            case .multiplePayloads:
                return "Provide only one capture payload: --url or --text."
            case .invalidSourceURL:
                return "The --url value is not a valid URL."
            case .invalidCaptureURL:
                return "Could not build a monknot:// capture URL."
            }
        }
    }
}
