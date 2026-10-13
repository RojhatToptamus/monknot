import Foundation
import MonknotCore
import UniformTypeIdentifiers
import WebKit

/// Serves workspace files to the in-app web views (Markdown preview, HTML preview, PDF export).
///
/// A page loaded with `loadHTMLString(_:baseURL:)` gets no file access, so these pages use a
/// `monknot-file:` base URL and this handler serves files inside `rootURL` (the workspace) only.
final class WorkspaceResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = MarkdownRenderService.workspaceResourceScheme

    /// Files outside this directory are refused, after resolving symbolic links.
    var rootURL: URL?
    private var stoppedTasks = Set<ObjectIdentifier>()

    /// The page base URL for a document directory: `file:///a/b` becomes `monknot-file:///a/b/`.
    static func pageBaseURL(forDirectory directory: URL?) -> URL? {
        guard let directory, directory.isFileURL else { return directory }
        var components = URLComponents()
        components.scheme = scheme
        components.host = ""
        components.path = directory.standardizedFileURL.path + "/"
        return components.url
    }

    /// Whether a preview may load a navigation it did not get from a clicked link. Of the main
    /// frame's `.other` loads only the preview's own page (from a string, with this scheme's base
    /// URL or none) may load; a file dropped on the view would load its `file:` URL instead.
    static func allowsPreviewNavigation(type: WKNavigationType, isMainFrame: Bool, to url: URL?) -> Bool {
        guard type == .other, isMainFrame else { return true }
        return url?.scheme == scheme || url?.absoluteString == "about:blank"
    }

    static func fileURL(for resourceURL: URL) -> URL? {
        guard resourceURL.scheme == scheme, !resourceURL.path.isEmpty else { return nil }
        return URL(fileURLWithPath: resourceURL.path)
    }

    /// The file a request may read, or nil when it lies outside the root. Resolves symbolic links, so
    /// it touches the file system: call it off the main thread.
    static func servableFileURL(for resourceURL: URL, within rootURL: URL?) -> URL? {
        guard let fileURL = fileURL(for: resourceURL), let rootURL else { return nil }
        let rootPath = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let filePath = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
        return filePath.hasPrefix(rootPath + "/") ? URL(fileURLWithPath: filePath) : nil
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let requestURL = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let taskID = ObjectIdentifier(task)
        let rootURL = rootURL
        DispatchQueue.global(qos: .userInitiated).async {
            let fileURL = Self.servableFileURL(for: requestURL, within: rootURL)
            let data = fileURL.flatMap { try? Data(contentsOf: $0) }
            DispatchQueue.main.async { [weak self] in
                // WebKit may cancel a load (navigation, teardown) before the read finishes.
                guard let self, self.stoppedTasks.remove(taskID) == nil else { return }
                guard let fileURL else {
                    task.didFailWithError(URLError(.noPermissionsToReadFile))
                    return
                }
                guard let data else {
                    task.didFailWithError(URLError(.fileDoesNotExist))
                    return
                }
                let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
                    ?? "application/octet-stream"
                task.didReceive(URLResponse(
                    url: requestURL,
                    mimeType: mimeType,
                    expectedContentLength: data.count,
                    textEncodingName: nil
                ))
                task.didReceive(data)
                task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        stoppedTasks.insert(ObjectIdentifier(task))
    }
}
