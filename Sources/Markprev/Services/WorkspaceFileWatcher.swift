import CoreServices
import Foundation

final class WorkspaceFileWatcher {
    struct Event: Sendable {
        let changedPaths: Set<String>
        let requiresFullRescan: Bool
    }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.local.Markprev.workspace-file-watcher", qos: .utility)
    private var callback: (@Sendable (Event) -> Void)?
    private var rootPath: String?

    func start(rootURL: URL, onChange: @escaping @Sendable (Event) -> Void) {
        let path = rootURL.standardizedFileURL.path
        if rootPath == path, stream != nil {
            callback = onChange
            return
        }

        stop()
        rootPath = path
        callback = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.handleEvents,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.35,
            flags
        )

        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else {
            callback = nil
            rootPath = nil
            return
        }

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        callback = nil
        rootPath = nil
    }

    private static let handleEvents: FSEventStreamCallback = { _, clientInfo, eventCount, eventPaths, eventFlags, _ in
        guard let clientInfo else { return }
        let watcher = Unmanaged<WorkspaceFileWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
        let pathArray = unsafeBitCast(eventPaths, to: NSArray.self)
        let paths = (pathArray as? [String]) ?? []

        var changedPaths = Set<String>()
        var requiresFullRescan = false

        for index in 0..<eventCount {
            if index < paths.count {
                changedPaths.insert(paths[index])
            }

            let flags = eventFlags[index]
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 ||
                flags & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped) != 0 ||
                flags & FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped) != 0 {
                requiresFullRescan = true
            }
        }

        watcher.callback?(Event(changedPaths: changedPaths, requiresFullRescan: requiresFullRescan))
    }

    deinit {
        stop()
    }
}
