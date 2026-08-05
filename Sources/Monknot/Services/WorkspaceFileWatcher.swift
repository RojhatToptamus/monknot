import CoreServices
import Foundation

final class WorkspaceFileWatcher {
    struct Event: Sendable {
        let changedPaths: Set<String>
        let modifiedOnlyPaths: Set<String>
        let requiresFullRescan: Bool
    }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.monknot.app.workspace-file-watcher", qos: .utility)
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

        guard let event = WorkspaceFileWatcher.makeEvent(paths: paths, flags: Array(UnsafeBufferPointer(start: eventFlags, count: eventCount))) else {
            return
        }
        watcher.callback?(event)
    }

    internal static func makeEvent(paths: [String], flags eventFlags: [FSEventStreamEventFlags]) -> Event? {
        var changedPaths = Set<String>()
        var modifiedOnlyPaths = Set<String>()
        var requiresFullRescan = false
        let contentChangeFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated |
                kFSEventStreamEventFlagItemRemoved |
                kFSEventStreamEventFlagItemRenamed |
                kFSEventStreamEventFlagItemModified
        )
        let structuralChangeFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated |
                kFSEventStreamEventFlagItemRemoved |
                kFSEventStreamEventFlagItemRenamed
        )

        for index in eventFlags.indices {
            let flags = eventFlags[index]

            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 ||
                flags & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped) != 0 ||
                flags & FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped) != 0 {
                requiresFullRescan = true
            }

            guard flags & contentChangeFlags != 0, index < paths.count else {
                continue
            }

            let path = paths[index]
            changedPaths.insert(path)
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified) != 0,
               flags & structuralChangeFlags == 0 {
                modifiedOnlyPaths.insert(path)
            }
        }

        guard requiresFullRescan || !changedPaths.isEmpty else { return nil }
        return Event(
            changedPaths: changedPaths,
            modifiedOnlyPaths: modifiedOnlyPaths,
            requiresFullRescan: requiresFullRescan
        )
    }

    deinit {
        stop()
    }
}
