import Foundation
import MonknotCore

struct MonknotLaunchCaptureRequest: Equatable, Sendable {
    let workspaceURL: URL
    let item: WorkspacePasteboardImportItem
}

enum MonknotLaunchCaptureParser {
    static func request(arguments: [String] = CommandLine.arguments) -> MonknotLaunchCaptureRequest? {
        guard let workspacePath = value(for: "--workspace", in: arguments) else {
            return nil
        }

        let workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL
        let title = value(for: "--capture-title", in: arguments)

        if let urlText = value(for: "--capture-url", in: arguments),
           let item = WorkspacePasteboardImportService.capturedTextItem(from: urlText, isURL: true, titleOverride: title) {
            return MonknotLaunchCaptureRequest(workspaceURL: workspaceURL, item: item)
        }

        if let text = value(for: "--capture-text", in: arguments),
           let item = WorkspacePasteboardImportService.capturedTextItem(from: text, isURL: false, titleOverride: title) {
            return MonknotLaunchCaptureRequest(workspaceURL: workspaceURL, item: item)
        }

        return nil
    }

    static func request(url: URL) -> MonknotLaunchCaptureRequest? {
        guard url.scheme?.lowercased() == MonknotCaptureURLBuilder.scheme,
              url.host?.lowercased() == MonknotCaptureURLBuilder.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let workspacePath = components.queryItems?.firstValue(named: "workspace") else {
            return nil
        }

        let workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL
        let title = components.queryItems?.firstValue(named: "title")
        if let urlText = components.queryItems?.firstValue(named: "url"),
           let item = WorkspacePasteboardImportService.capturedTextItem(from: urlText, isURL: true, titleOverride: title) {
            return MonknotLaunchCaptureRequest(workspaceURL: workspaceURL, item: item)
        }

        if let text = components.queryItems?.firstValue(named: "text"),
           let item = WorkspacePasteboardImportService.capturedTextItem(from: text, isURL: false, titleOverride: title) {
            return MonknotLaunchCaptureRequest(workspaceURL: workspaceURL, item: item)
        }

        return nil
    }

    private static func value(for flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }
}

private extension Array where Element == URLQueryItem {
    func firstValue(named name: String) -> String? {
        first { $0.name == name }?.value
    }
}
